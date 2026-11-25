//! The PDF engine facade around PdfCraft v0.20.0.
//!
//! This crate deliberately stays independent of any UI layer. It owns
//! exactly one `pdfcraft_engine::Session` (and, through it, one
//! `pdfcraft_render::RenderPool` per open document), plus the per-document
//! state needed for safe saving.
//!
//! All state lives behind `Mutex`, because callers invoke engine methods from
//! background and UI threads. Rendering is serialized by `render_gate` and runs
//! on PdfCraft's own worker threads; the caller never blocks inside the
//! renderer itself, it only polls for a result while checking cancellation.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use pdfcraft_annot::{NewAnnotation, NoteIcon, Shape, Style, is_comment_subtype};
use pdfcraft_engine::{DocId, Edit, Markup, Session};
use pdfcraft_render::{
    PageRenderer, PageText, RenderConfig, RenderRequest, RenderedPage, RequestKind, effective_scale,
};
use sha2::{Digest, Sha256};

/// PdfCraft tag this facade was written and validated against.
pub const PDFCRAFT_TAG: &str = "v0.20.0";
/// PdfCraft commit the tag resolves to (see scripts/fetch-deps.sh).
pub const PDFCRAFT_SHA: &str = "2ad7717f87ad6f15b14bdf22cddc1019d6fd0aed";
/// Version string returned to Go; bump when the DTO shape changes.
pub const ABI: &str = "pdfcore-abi-1";

pub fn version_string() -> String {
    format!("pdfcore/0.1.0 {ABI}; pdfcraft/{PDFCRAFT_TAG}@{PDFCRAFT_SHA}")
}

// ---------------------------------------------------------------------------
// Plain DTOs. Field names and numeric widths mirror the Go DTOs in
// modules/pdfengine/pdfengine.go; the adapter converts 1:1.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq)]
pub struct DocumentInfo {
    pub id: String,
    pub page_count: i64,
    pub title: String,
    pub pdf_version: String,
    pub encrypted: bool,
    pub dirty: bool,
    pub can_undo: bool,
    pub can_redo: bool,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct PageInfo {
    pub page: i64,
    pub width: f64,
    pub height: f64,
    pub rotation: i64,
    pub label: String,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Raster {
    pub width: i64,
    pub height: i64,
    pub stride: i64,
    pub rgba: Vec<u8>,
    pub tag: i64,
    pub render_millis: i64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Rect {
    pub x0: f64,
    pub y0: f64,
    pub x1: f64,
    pub y1: f64,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct TextBlock {
    pub page: i64,
    pub start: i64,
    pub end: i64,
    pub text: String,
    pub rect: Rect,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct SearchMatch {
    pub page: i64,
    pub start: i64,
    pub end: i64,
    pub preview: String,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Annotation {
    pub page: i64,
    pub index: i64,
    pub name: String,
    pub subtype: String,
    pub contents: String,
    pub author: String,
    pub rect: Rect,
    pub color: Option<[f32; 3]>,
    pub quad_rects: Vec<Rect>,
    pub locked: bool,
    pub modified: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkupKind {
    Highlight,
    Underline,
    StrikeOut,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskVerdict {
    /// No baseline fingerprint yet, or the on-disk file cannot be read right now.
    /// Never a permission to overwrite.
    Unverified,
    /// On-disk content is readable and SHA-256 matches the baseline.
    Matched,
    /// On-disk content is readable and differs from the baseline.
    Changed,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SaveOptions {
    /// Whether Save As to a different existing file was explicitly confirmed by the user.
    pub overwrite_existing_destination: bool,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct SaveReport {
    pub path: String,
    pub bytes_written: i64,
    pub original_bytes: i64,
    pub incremental: bool,
    pub annotation_count: i64,
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum CoreError {
    DocumentNotFound,
    InvalidPage,
    ExternalChange,
    Unverified(String),
    DestinationExists(String),
    ReadOnly(String),
    SaveFailed(String),
    Cancelled,
    Engine(String),
    Io(String),
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CoreError::DocumentNotFound => f.write_str("document not found or already closed"),
            CoreError::InvalidPage => f.write_str("page index out of range"),
            CoreError::ExternalChange => {
                f.write_str("the file changed on disk after it was opened; save refused")
            }
            CoreError::Unverified(s) => write!(f, "target cannot be verified: {s}"),
            CoreError::DestinationExists(s) => write!(f, "destination already exists: {s}"),
            CoreError::ReadOnly(s) => write!(f, "document is read-only: {s}"),
            CoreError::SaveFailed(s) => write!(f, "save failed: {s}"),
            CoreError::Cancelled => f.write_str("cancelled"),
            CoreError::Engine(s) => write!(f, "pdf engine: {s}"),
            CoreError::Io(s) => write!(f, "file I/O: {s}"),
        }
    }
}

impl std::error::Error for CoreError {}

fn map_edit(e: pdfcraft_engine::EditError) -> CoreError {
    use pdfcraft_engine::EditError as E;
    match e {
        E::NoDocument => CoreError::DocumentNotFound,
        E::ReadOnly(s) => CoreError::ReadOnly(if s.is_empty() { "document permissions".to_string() } else { s }),
        E::NotPermitted(s) => CoreError::ReadOnly(format!("document permissions do not allow {s}")),
        E::Cancelled => CoreError::Cancelled,
        E::Write(s) | E::Reopen(s) => CoreError::SaveFailed(s),
        other => CoreError::Engine(other.to_string()),
    }
}

fn map_open(e: pdfcraft_render::OpenError) -> CoreError {
    CoreError::Engine(format!("could not open PDF: {e}"))
}

// ---------------------------------------------------------------------------
// Owned state
// ---------------------------------------------------------------------------

/// Content-verified file fingerprint (metadata + SHA-256 of readable bytes).
/// Metadata alone is never trusted: a same-size, timestamp-preserving external
/// rewrite is still caught by `sha256`, and an unreadable file fails to verify
/// rather than falling back to metadata (CTO boundary 2 / P1-2).
#[derive(Clone, Debug, PartialEq, Eq)]
struct Fingerprint {
    len: u64,
    modified: Option<SystemTime>,
    sha256: [u8; 32],
}

fn sha256_bytes(bytes: &[u8]) -> [u8; 32] {
    let digest = Sha256::digest(bytes);
    let mut out = [0u8; 32];
    out.copy_from_slice(&digest);
    out
}

fn fingerprint_with_bytes(path: &str, bytes: &[u8]) -> Result<Fingerprint, CoreError> {
    let meta = fs::metadata(path).map_err(|e| CoreError::Io(format!("{path}: {e}")))?;
    Ok(Fingerprint { len: meta.len(), modified: meta.modified().ok(), sha256: sha256_bytes(bytes) })
}

fn fingerprint_file(path: &str) -> std::io::Result<Fingerprint> {
    let meta = fs::metadata(path)?;
    let bytes = fs::read(path)?;
    Ok(Fingerprint { len: meta.len(), modified: meta.modified().ok(), sha256: sha256_bytes(&bytes) })
}

struct DocMeta {
    path: String,
    fingerprint: Option<Fingerprint>,
    /// The exact `Document::display` bytes the text renderer was built from.
    display: Arc<Vec<u8>>,
    /// A single-threaded PdfCraft text extractor, rebuilt when display changes.
    text: Arc<Mutex<PageRenderer>>,
}

struct Inner {
    session: Session,
    docs: HashMap<u64, DocMeta>,
}

/// The facade. Cheap to construct; one instance is held by the native module.
pub struct PdfCore {
    inner: Mutex<Inner>,
    /// Serializes renders: RenderPool's queue is per document and a queued
    /// request is cancelled as soon as a newer one replaces it.
    render_gate: Mutex<()>,
}

impl Default for PdfCore {
    fn default() -> Self {
        Self::new()
    }
}

static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

fn same_existing_file(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    match (fs::canonicalize(a), fs::canonicalize(b)) {
        (Ok(ca), Ok(cb)) => ca == cb,
        _ => false,
    }
}

impl PdfCore {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner { session: Session::new(), docs: HashMap::new() }),
            render_gate: Mutex::new(()),
        }
    }

    /// Number of documents currently open (test/introspection helper).
    pub fn open_count(&self) -> usize {
        self.inner.lock().map(|i| i.docs.len()).unwrap_or(0)
    }

    fn parse_id(id: &str) -> Result<DocId, CoreError> {
        let n: u64 = id.parse().map_err(|_| CoreError::DocumentNotFound)?;
        Ok(DocId(n))
    }

    fn lock_inner(&self) -> Result<std::sync::MutexGuard<'_, Inner>, CoreError> {
        self.inner.lock().map_err(|_| CoreError::Engine("engine state mutex poisoned".into()))
    }

    fn check_page(info: &pdfcraft_render::DocInfo, page: usize) -> Result<(), CoreError> {
        if page >= info.pages.len() { Err(CoreError::InvalidPage) } else { Ok(()) }
    }

    fn document_info(doc: &pdfcraft_engine::Document, id: DocId) -> DocumentInfo {
        DocumentInfo {
            id: id.0.to_string(),
            page_count: doc.info.pages.len() as i64,
            title: doc.info.title.clone().unwrap_or_default(),
            pdf_version: doc.info.pdf_version.clone(),
            encrypted: doc.info.encrypted,
            dirty: doc.dirty,
            can_undo: doc.can_undo().is_some(),
            can_redo: doc.can_redo().is_some(),
        }
    }

    // ---- lifecycle -------------------------------------------------------

    pub fn open_document(&self, path: &str) -> Result<DocumentInfo, CoreError> {
        let bytes = fs::read(path).map_err(|e| CoreError::Io(format!("{path}: {e}")))?;
        let fp = fingerprint_with_bytes(path, &bytes)?;
        let arc = Arc::new(bytes);
        let name = Path::new(path).file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| path.to_string());

        let mut inner = self.lock_inner()?;
        let Inner { session, docs } = &mut *inner;
        let id = session.open(name, Some(path.to_string()), arc, None).map_err(map_open)?;
        let doc = session.get(id).ok_or(CoreError::DocumentNotFound)?;
        let config = session.render_config(id).unwrap_or_else(|| RenderConfig::default().on_screen());
        let display = doc.display.clone();
        let text = Arc::new(Mutex::new(PageRenderer::new(display.clone(), config)));
        let info = Self::document_info(doc, id);
        docs.insert(id.0, DocMeta { path: path.to_string(), fingerprint: Some(fp), display, text });
        Ok(info)
    }

    /// Classify the on-disk file against this document's baseline fingerprint.
    /// Does not hold any lock across file reads.
    pub fn disk_verdict(&self, id: &str) -> Result<DiskVerdict, CoreError> {
        let doc_id = Self::parse_id(id)?;
        let (path, baseline) = {
            let inner = self.lock_inner()?;
            let meta = inner.docs.get(&doc_id.0).ok_or(CoreError::DocumentNotFound)?;
            (meta.path.clone(), meta.fingerprint.clone())
        };
        let Some(baseline) = baseline else {
            return Ok(DiskVerdict::Unverified);
        };
        let Ok(now) = fingerprint_file(&path) else {
            return Ok(DiskVerdict::Unverified);
        };
        if now.sha256 != baseline.sha256 {
            Ok(DiskVerdict::Changed)
        } else {
            Ok(DiskVerdict::Matched)
        }
    }

    /// Attempt to establish or refresh the baseline fingerprint from the
    /// document's saved bytes if currently unverified, or from disk.
    #[doc(hidden)]
    pub fn clear_fingerprint_for_test(&self, id: &str) -> Result<(), CoreError> {
        let doc_id = Self::parse_id(id)?;
        let mut inner = self.lock_inner()?;
        let meta = inner.docs.get_mut(&doc_id.0).ok_or(CoreError::DocumentNotFound)?;
        meta.fingerprint = None;
        Ok(())
    }

    /// Establish a missing baseline fingerprint by hashing the file on disk and
    /// verifying it matches the opened bytes (`saved_bytes()`).
    pub fn establish_baseline(&self, id: &str) -> Result<DiskVerdict, CoreError> {
        let doc_id = Self::parse_id(id)?;
        let (path, expected_sha) = {
            let inner = self.lock_inner()?;
            let meta = inner.docs.get(&doc_id.0).ok_or(CoreError::DocumentNotFound)?;
            let doc = inner.session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
            (meta.path.clone(), sha256_bytes(&doc.saved_bytes()))
        };
        let Ok(now) = fingerprint_file(&path) else {
            return Ok(DiskVerdict::Unverified);
        };
        if now.sha256 != expected_sha {
            return Ok(DiskVerdict::Changed);
        }
        let mut inner = self.lock_inner()?;
        if let Some(meta) = inner.docs.get_mut(&doc_id.0) {
            meta.fingerprint = Some(now);
        }
        Ok(DiskVerdict::Matched)
    }

    pub fn close_document(&self, id: &str) -> Result<(), CoreError> {
        let id = Self::parse_id(id)?;
        let _gate = self.render_gate.lock().map_err(|_| CoreError::Engine("render gate poisoned".into()))?;
        let mut inner = self.lock_inner()?;
        if inner.docs.remove(&id.0).is_none() {
            return Err(CoreError::DocumentNotFound);
        }
        inner.session.close(id);
        Ok(())
    }

    pub fn get_document_info(&self, id: &str) -> Result<DocumentInfo, CoreError> {
        let id = Self::parse_id(id)?;
        let inner = self.lock_inner()?;
        let doc = inner.session.get(id).ok_or(CoreError::DocumentNotFound)?;
        Ok(Self::document_info(doc, id))
    }

    pub fn get_page_info(&self, id: &str, page: i64) -> Result<PageInfo, CoreError> {
        let id = Self::parse_id(id)?;
        let inner = self.lock_inner()?;
        let doc = inner.session.get(id).ok_or(CoreError::DocumentNotFound)?;
        let p = usize::try_from(page).map_err(|_| CoreError::InvalidPage)?;
        Self::check_page(&doc.info, p)?;
        let info = &doc.info.pages[p];
        Ok(PageInfo {
            page,
            width: f64::from(info.width),
            height: f64::from(info.height),
            rotation: i64::from(info.rotation),
            label: info.label.clone(),
        })
    }

    // ---- rendering -------------------------------------------------------

    /// Rasterize one page. `cancel` is polled every 2 ms; on cancellation the
    /// request is removed from the pool's queue, which stops the in-flight
    /// render through PdfCraft's interpreter cancellation flag.
    pub fn render_page(
        &self,
        id: &str,
        page: i64,
        scale: f64,
        tag: i64,
        cancel: &dyn Fn() -> bool,
    ) -> Result<Raster, CoreError> {
        let doc_id = Self::parse_id(id)?;
        let page = usize::try_from(page).map_err(|_| CoreError::InvalidPage)?;
        let _gate = self.render_gate.lock().map_err(|_| CoreError::Engine("render gate poisoned".into()))?;

        let request = {
            let inner = self.lock_inner()?;
            let doc = inner.session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
            Self::check_page(&doc.info, page)?;
            let pi = &doc.info.pages[page];
            let effective = effective_scale(pi.width, pi.height, scale as f32);
            let req = RenderRequest { page, kind: RequestKind::Pixels, scale: effective, tag: tag as u64, ..RenderRequest::default() };
            // Replaces the queue: any older request is cancelled in flight and
            // its result will never be delivered. No obsolete request can pile up.
            doc.renderer.set_queue(vec![req]);
            req
        };

        let started = Instant::now();
        loop {
            if cancel() {
                self.clear_queue(doc_id);
                return Err(CoreError::Cancelled);
            }
            let result = {
                let inner = self.lock_inner()?;
                inner.session.get(doc_id).map(|d| d.renderer.try_recv())
            };
            match result {
                Some(Some(r)) => {
                    // A stale generation can still be in flight when the queue
                    // changed under us; never hand it to the caller.
                    if r.request.tag != request.tag || r.request.page != page {
                        continue;
                    }
                    return raster_of(r);
                }
                Some(None) => {
                    if started.elapsed() > Duration::from_secs(30) {
                        self.clear_queue(doc_id);
                        return Err(CoreError::Engine("page render timed out after 30s".into()));
                    }
                    std::thread::sleep(Duration::from_millis(2));
                }
                None => {
                    self.clear_queue(doc_id);
                    return Err(CoreError::DocumentNotFound);
                }
            }
        }
    }

    fn clear_queue(&self, doc_id: DocId) {
        if let Ok(inner) = self.lock_inner()
            && let Some(doc) = inner.session.get(doc_id)
        {
            doc.renderer.set_queue(Vec::new());
        }
    }

    pub fn cancel_renders(&self, id: &str) -> Result<(), CoreError> {
        let doc_id = Self::parse_id(id)?;
        {
            let inner = self.lock_inner()?;
            let doc = inner.session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
            doc.renderer.set_queue(Vec::new());
        }
        Ok(())
    }

    // ---- text ------------------------------------------------------------

    /// Extract one page's glyph layer, reusing (and invalidating) a cached
    /// `PageRenderer` whenever the working/display bytes change after an edit.
    fn page_text(&self, doc_id: DocId, page: usize) -> Result<Arc<PageText>, CoreError> {
        let renderer = {
            let mut inner = self.lock_inner()?;
            let Inner { session, docs } = &mut *inner;
            let doc = session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
            Self::check_page(&doc.info, page)?;
            let meta = docs.get_mut(&doc_id.0).ok_or(CoreError::DocumentNotFound)?;
            if !Arc::ptr_eq(&meta.display, &doc.display) {
                let config = session.render_config(doc_id).unwrap_or_else(|| RenderConfig::default().on_screen());
                meta.display = doc.display.clone();
                meta.text = Arc::new(Mutex::new(PageRenderer::new(meta.display.clone(), config)));
            }
            meta.text.clone()
        };

        let mut r = renderer.lock().map_err(|_| CoreError::Engine("text renderer poisoned".into()))?;
        let out = r.render(RenderRequest {
            page,
            kind: RequestKind::Text,
            scale: 1.0,
            ..RenderRequest::default()
        });
        if let Some(e) = out.error {
            return Err(CoreError::Engine(format!("text extraction failed: {e}")));
        }
        out.text.ok_or_else(|| CoreError::Engine("text extraction produced no glyph layer".into()))
    }

    pub fn get_text_blocks(&self, id: &str, page: i64, cancel: &dyn Fn() -> bool) -> Result<Vec<TextBlock>, CoreError> {
        if cancel() {
            return Err(CoreError::Cancelled);
        }
        let doc_id = Self::parse_id(id)?;
        let p = usize::try_from(page).map_err(|_| CoreError::InvalidPage)?;
        let text = self.page_text(doc_id, p)?;
        let mut out = Vec::new();
        let mut start = 0usize;
        while start < text.glyphs.len() {
            let line = text.line_of.get(start).copied().unwrap_or(0);
            let mut end = start + 1;
            while end < text.glyphs.len() && text.line_of.get(end).copied().unwrap_or(0) == line {
                end += 1;
            }
            let rects = text.line_rects(start..end);
            let rect = union_rects(&rects);
            out.push(TextBlock {
                page,
                start: start as i64,
                end: end as i64,
                text: text.text_of(start..end),
                rect: Rect { x0: rect[0], y0: rect[1], x1: rect[2], y1: rect[3] },
            });
            start = end;
        }
        Ok(out)
    }

    pub fn get_selected_text(&self, id: &str, page: i64, start: i64, end: i64) -> Result<String, CoreError> {
        let doc_id = Self::parse_id(id)?;
        let p = usize::try_from(page).map_err(|_| CoreError::InvalidPage)?;
        let a = usize::try_from(start).map_err(|_| CoreError::InvalidPage)?;
        let b = usize::try_from(end).map_err(|_| CoreError::InvalidPage)?;
        let text = self.page_text(doc_id, p)?;
        if a > b || b > text.glyphs.len() {
            return Err(CoreError::InvalidPage);
        }
        Ok(text.text_of(a..b))
    }

    pub fn search_text(
        &self,
        id: &str,
        query: &str,
        limit: i64,
        cancel: &dyn Fn() -> bool,
    ) -> Result<Vec<SearchMatch>, CoreError> {
        let doc_id = Self::parse_id(id)?;
        let max = usize::try_from(limit).unwrap_or(0).min(10_000);
        if query.is_empty() || max == 0 {
            return Ok(Vec::new());
        }
        let count = {
            let inner = self.lock_inner()?;
            let doc = inner.session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
            doc.info.pages.len()
        };
        let mut out = Vec::new();
        for page in 0..count {
            if cancel() {
                return Err(CoreError::Cancelled);
            }
            if out.len() >= max {
                break;
            }
            let text = self.page_text(doc_id, page)?;
            let hits = text.find_opts_limited(query, false, false, max - out.len());
            for range in hits {
                let preview = text.text_of(range.clone());
                out.push(SearchMatch {
                    page: page as i64,
                    start: range.start as i64,
                    end: range.end as i64,
                    preview: preview.chars().take(120).collect(),
                });
            }
        }
        Ok(out)
    }

    // ---- annotations -----------------------------------------------------

    fn annotation_dto(doc: &pdfcraft_engine::Document, a: &pdfcraft_render::Annotation) -> Annotation {
        // `Annotation.rect` is in PDF user space; callers work in view space.
        let user_rect = doc
            .info
            .pages
            .get(a.page)
            .map(|pi| a.shown_rect(pi.rotation))
            .unwrap_or(a.rect);
        let (rect, _) = view_rect_from_user(doc, a.page, user_rect);
        let quad_rects = a
            .quads
            .iter()
            .map(|q| {
                let xs = [q[0], q[2], q[4], q[6]];
                let ys = [q[1], q[3], q[5], q[7]];
                let ux0 = xs.iter().copied().fold(f32::INFINITY, f32::min);
                let uy0 = ys.iter().copied().fold(f32::INFINITY, f32::min);
                let ux1 = xs.iter().copied().fold(f32::NEG_INFINITY, f32::max);
                let uy1 = ys.iter().copied().fold(f32::NEG_INFINITY, f32::max);
                view_rect_from_user(doc, a.page, [ux0, uy0, ux1, uy1]).0
            })
            .collect();
        Annotation {
            page: a.page as i64,
            index: a.index as i64,
            name: a.name.clone().unwrap_or_default(),
            subtype: a.subtype.clone(),
            contents: a.contents.clone().unwrap_or_default(),
            author: a.author.clone().unwrap_or_default(),
            rect,
            color: a.color,
            quad_rects,
            locked: a.locked,
            modified: a.modified.clone().unwrap_or_default(),
        }
    }

    pub fn list_annotations(&self, id: &str, page: i64) -> Result<Vec<Annotation>, CoreError> {
        let doc_id = Self::parse_id(id)?;
        let inner = self.lock_inner()?;
        let doc = inner.session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
        if page >= 0 {
            Self::check_page(&doc.info, page as usize)?;
        }
        Ok(doc
            .info
            .annotations
            .iter()
            .filter(|a| {
                a.is_comment()
                    && is_comment_subtype(&a.subtype)
                    && (page < 0 || a.page == page as usize)
            })
            .map(|a| Self::annotation_dto(doc, a))
            .collect())
    }

    /// Record the names before an edit, then find the annotation it created.
    fn annotation_added(
        &self,
        doc_id: DocId,
        page: usize,
        before: &HashSet<String>,
    ) -> Result<Annotation, CoreError> {
        let inner = self.lock_inner()?;
        let doc = inner.session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
        let added = doc
            .info
            .annotations
            .iter()
            .find(|a| {
                a.page == page
                    && a.is_comment()
                    && is_comment_subtype(&a.subtype)
                    && a.name.as_ref().is_some_and(|n| !before.contains(n))
            })
            .or_else(|| {
                doc.info
                    .annotations
                    .iter()
                    .rev()
                    .find(|a| a.page == page && a.is_comment() && is_comment_subtype(&a.subtype))
            });
        match added {
            Some(a) => Ok(Self::annotation_dto(doc, a)),
            None => Err(CoreError::Engine("the edit succeeded but no annotation was listed".into())),
        }
    }

    fn existing_names(&self, doc_id: DocId) -> Result<HashSet<String>, CoreError> {
        let inner = self.lock_inner()?;
        let doc = inner.session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
        Ok(doc.info.annotations.iter().filter_map(|a| a.name.clone()).collect())
    }

    fn apply(&self, doc_id: DocId, edit: Edit) -> Result<(), CoreError> {
        // Session::apply replaces the document's RenderPool; don't let a
        // render poll observe a half-swapped pool.
        let _gate = self.render_gate.lock().map_err(|_| CoreError::Engine("render gate poisoned".into()))?;
        let mut inner = self.lock_inner()?;
        inner.session.apply(doc_id, edit).map_err(map_edit)
    }

    /// Convert a view-space rectangle to a PdfCraft `/QuadPoints` array.
    /// `PageInfo::view_rect_to_quad` handles page rotation and CropBox offsets
    /// while keeping top-left, top-right, bottom-left, bottom-right order.
    fn view_rect_to_quad(doc: &pdfcraft_engine::Document, page: usize, r: Rect) -> Result<[f64; 8], CoreError> {
        let pi = doc.info.pages.get(page).ok_or(CoreError::InvalidPage)?;
        let norm = [
            r.x0.min(r.x1) as f32,
            r.y0.min(r.y1) as f32,
            r.x0.max(r.x1) as f32,
            r.y0.max(r.y1) as f32,
        ];
        let quad = pi.view_rect_to_quad(norm);
        if !quad.iter().all(|v| v.is_finite()) {
            return Err(CoreError::Engine("non-finite markup geometry".into()));
        }
        Ok(quad)
    }

    fn view_point_to_user(doc: &pdfcraft_engine::Document, page: usize, x: f64, y: f64) -> Result<[f64; 2], CoreError> {
        let pi = doc.info.pages.get(page).ok_or(CoreError::InvalidPage)?;
        let [ux, uy] = pi.view_to_user(x as f32, y as f32);
        Ok([f64::from(ux), f64::from(uy)])
    }

    pub fn add_highlight(&self, id: &str, page: i64, rects: &[Rect], cancel: &dyn Fn() -> bool) -> Result<Annotation, CoreError> {
        self.add_markup(id, page, MarkupKind::Highlight, rects, [1.0, 1.0, 0.0], cancel)
    }

    pub fn add_markup(
        &self,
        id: &str,
        page: i64,
        kind: MarkupKind,
        rects: &[Rect],
        color: [f64; 3],
        cancel: &dyn Fn() -> bool,
    ) -> Result<Annotation, CoreError> {
        if cancel() {
            return Err(CoreError::Cancelled);
        }
        let doc_id = Self::parse_id(id)?;
        let p = usize::try_from(page).map_err(|_| CoreError::InvalidPage)?;
        if rects.is_empty() {
            return Err(CoreError::Engine("markup needs at least one line rectangle".into()));
        }
        let quads = {
            let inner = self.lock_inner()?;
            let doc = inner.session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
            Self::check_page(&doc.info, p)?;
            rects.iter().map(|r| Self::view_rect_to_quad(doc, p, *r)).collect::<Result<Vec<_>, _>>()?
        };
        let before = self.existing_names(doc_id)?;
        let pdf_kind = match kind {
            MarkupKind::Highlight => Markup::Highlight,
            MarkupKind::Underline => Markup::Underline,
            MarkupKind::StrikeOut => Markup::StrikeOut,
        };
        let shape = Shape::TextMarkup { kind: pdf_kind, quads };
        let mut style = Style::default_for(&shape);
        style.color = color.map(|c| c.clamp(0.0, 1.0));
        style.opacity = match kind {
            MarkupKind::Highlight => 0.45,
            MarkupKind::Underline | MarkupKind::StrikeOut => 1.0,
        };
        let edit = Edit::AddAnnotation(NewAnnotation {
            page: p,
            shape,
            style,
            contents: String::new(),
            author: "YoPDF".to_string(),
        });
        self.apply(doc_id, edit)?;
        self.annotation_added(doc_id, p, &before)
    }

    pub fn add_sticky_note(
        &self,
        id: &str,
        page: i64,
        x: f64,
        y: f64,
        contents: &str,
        cancel: &dyn Fn() -> bool,
    ) -> Result<Annotation, CoreError> {
        self.add_sticky_note_with_color(id, page, x, y, contents, None, cancel)
    }

    pub fn add_sticky_note_with_color(
        &self,
        id: &str,
        page: i64,
        x: f64,
        y: f64,
        contents: &str,
        color: Option<[f64; 3]>,
        cancel: &dyn Fn() -> bool,
    ) -> Result<Annotation, CoreError> {
        if cancel() {
            return Err(CoreError::Cancelled);
        }
        let doc_id = Self::parse_id(id)?;
        let p = usize::try_from(page).map_err(|_| CoreError::InvalidPage)?;
        let at = {
            let inner = self.lock_inner()?;
            let doc = inner.session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
            Self::check_page(&doc.info, p)?;
            Self::view_point_to_user(doc, p, x, y)?
        };
        let before = self.existing_names(doc_id)?;
        let shape = Shape::Note { at, icon: NoteIcon::Comment };
        let mut style = Style::default_for(&shape);
        if let Some(c) = color {
            style.color = c.map(|v| v.clamp(0.0, 1.0));
        }
        let edit = Edit::AddAnnotation(NewAnnotation {
            page: p,
            shape,
            style,
            contents: contents.to_string(),
            author: "YoPDF".to_string(),
        });
        self.apply(doc_id, edit)?;
        self.annotation_added(doc_id, p, &before)
    }

    pub fn set_annotation_color(&self, id: &str, page: i64, index: i64, color: [f64; 3]) -> Result<(), CoreError> {
        let doc_id = Self::parse_id(id)?;
        let p = usize::try_from(page).map_err(|_| CoreError::InvalidPage)?;
        let i = usize::try_from(index).map_err(|_| CoreError::InvalidPage)?;
        let rgb = color.map(|v| v.clamp(0.0, 1.0));
        self.apply(
            doc_id,
            Edit::StyleAnnotation { page: p, index: i, color: Some(rgb), opacity: None, width: None, endings: None },
        )
    }

    pub fn update_annotation(&self, id: &str, page: i64, index: i64, contents: &str) -> Result<(), CoreError> {
        let doc_id = Self::parse_id(id)?;
        let p = usize::try_from(page).map_err(|_| CoreError::InvalidPage)?;
        let i = usize::try_from(index).map_err(|_| CoreError::InvalidPage)?;
        self.apply(doc_id, Edit::SetAnnotationContents { page: p, index: i, text: contents.to_string() })
    }

    pub fn delete_annotation(&self, id: &str, page: i64, index: i64) -> Result<(), CoreError> {
        let doc_id = Self::parse_id(id)?;
        let p = usize::try_from(page).map_err(|_| CoreError::InvalidPage)?;
        let i = usize::try_from(index).map_err(|_| CoreError::InvalidPage)?;
        self.apply(doc_id, Edit::DeleteAnnotation { page: p, index: i })
    }

    pub fn undo(&self, id: &str) -> Result<String, CoreError> {
        let doc_id = Self::parse_id(id)?;
        let _gate = self.render_gate.lock().map_err(|_| CoreError::Engine("render gate poisoned".into()))?;
        let mut inner = self.lock_inner()?;
        let label = inner.session.get(doc_id).and_then(|d| d.can_undo()).unwrap_or("").to_string();
        inner.session.undo(doc_id).map_err(map_edit)?;
        Ok(label)
    }

    pub fn redo(&self, id: &str) -> Result<String, CoreError> {
        let doc_id = Self::parse_id(id)?;
        let _gate = self.render_gate.lock().map_err(|_| CoreError::Engine("render gate poisoned".into()))?;
        let mut inner = self.lock_inner()?;
        let label = inner.session.get(doc_id).and_then(|d| d.can_redo()).unwrap_or("").to_string();
        inner.session.redo(doc_id).map_err(map_edit)?;
        Ok(label)
    }

    // ---- persistence -----------------------------------------------------

    fn verify_save_target(meta: &DocMeta, path: &str, opts: SaveOptions) -> Result<(), CoreError> {
        if same_existing_file(&meta.path, path) {
            let Some(ref baseline) = meta.fingerprint else {
                return Err(CoreError::Unverified(
                    "the document on disk cannot be verified right now; saving is refused to avoid overwriting unknown changes"
                        .into(),
                ));
            };
            let now = fingerprint_file(path).map_err(|e| {
                CoreError::Unverified(format!(
                    "the document on disk cannot be verified ({e}); saving is refused to avoid overwriting unknown changes"
                ))
            })?;
            if now.sha256 != baseline.sha256 {
                return Err(CoreError::ExternalChange);
            }
            return Ok(());
        }

        // Save As to a different path: never consult the original file's
        // fingerprint (this is the recovery path when the original changed).
        // Stat must distinguish NotFound (new file: allowed) from every other
        // error (ENOTDIR, EACCES, I/O): fail closed even when confirmed.
        match fs::metadata(path) {
            Ok(_) => {
                if !opts.overwrite_existing_destination {
                    Err(CoreError::DestinationExists(format!(
                        "the destination file already exists: {path}"
                    )))
                } else {
                    Ok(())
                }
            }
            Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
            Err(e) => Err(CoreError::Unverified(format!(
                "the destination {path} could not be checked ({e}); saving is refused"
            ))),
        }
    }

    /// Preflight save-target safety without producing bytes or writing disk.
    pub fn check_save_target(&self, id: &str, path: &str, opts: SaveOptions) -> Result<(), CoreError> {
        let doc_id = Self::parse_id(id)?;
        let inner = self.lock_inner()?;
        let meta = inner.docs.get(&doc_id.0).ok_or(CoreError::DocumentNotFound)?;
        Self::verify_save_target(meta, path, opts)
    }

    /// Incremental, atomic save with default options (does not overwrite an
    /// unrelated existing Save As destination).
    pub fn save_document(&self, id: &str, path: &str) -> Result<SaveReport, CoreError> {
        self.save_document_with_options(id, path, SaveOptions::default())
    }

    /// Incremental, atomic save. Refuses to overwrite a file that changed
    /// externally or cannot be verified, refuses an unconfirmed existing
    /// Save As destination, fails closed on destination stat errors, refuses a
    /// silent full rewrite, and validates the produced bytes with PdfCraft's
    /// own `check_save` before touching the disk.
    pub fn save_document_with_options(
        &self,
        id: &str,
        path: &str,
        opts: SaveOptions,
    ) -> Result<SaveReport, CoreError> {
        let doc_id = Self::parse_id(id)?;
        let _gate = self.render_gate.lock().map_err(|_| CoreError::Engine("render gate poisoned".into()))?;
        let mut inner = self.lock_inner()?;
        let Inner { session, docs } = &mut *inner;

        let meta = docs.get(&doc_id.0).ok_or(CoreError::DocumentNotFound)?;
        Self::verify_save_target(meta, path, opts)?;

        let (bytes, original_len, incremental, annotation_count) = {
            let doc = session.get(doc_id).ok_or(CoreError::DocumentNotFound)?;
            let saved = doc.saved_bytes();
            let original_len = saved.len();
            let bytes = session.save_bytes(doc_id).map_err(map_edit)?;
            session.check_save(doc_id, &bytes).map_err(map_edit)?;
            // write_incremental appends a revision to the original bytes. A
            // full rewrite breaks that prefix relation: report it, never hide it.
            let incremental = bytes.len() >= original_len && bytes[..original_len] == saved[..];
            let annotation_count = doc
                .info
                .annotations
                .iter()
                .filter(|a| a.is_comment() && is_comment_subtype(&a.subtype))
                .count() as i64;
            (bytes, original_len, incremental, annotation_count)
        };

        if !incremental {
            return Err(CoreError::SaveFailed(
                "PdfCraft produced a full rewrite instead of an incremental update; refusing to write it".into(),
            ));
        }

        // Write to a sibling temp file, fsync, then atomically replace. A
        // failed write never truncates the original.
        let target = PathBuf::from(path);
        let parent = target.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
        let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
        let tmp = parent.join(format!(".{}.poc-{}-{}.tmp", target.file_name().unwrap_or_default().to_string_lossy(), std::process::id(), seq));
        let write_result = (|| -> std::io::Result<()> {
            let mut f = File::create(&tmp)?;
            f.write_all(&bytes)?;
            f.sync_all()
        })();
        if let Err(e) = write_result {
            let _ = fs::remove_file(&tmp);
            return Err(CoreError::SaveFailed(format!("temporary file: {e}")));
        }
        if let Err(e) = fs::rename(&tmp, &target) {
            let _ = fs::remove_file(&tmp);
            return Err(CoreError::SaveFailed(format!("atomic replace: {e}")));
        }

        session.mark_saved(doc_id, bytes.clone(), Some(path.to_string())).map_err(map_edit)?;
        if let Some(m) = docs.get_mut(&doc_id.0) {
            // Save As re-points the guard at the new path so future saves and
            // autosaves track the new destination, not the original file.
            m.path = path.to_string();
            m.fingerprint = fingerprint_file(path).ok();
        }

        Ok(SaveReport {
            path: path.to_string(),
            bytes_written: bytes.len() as i64,
            original_bytes: original_len as i64,
            incremental: true,
            annotation_count,
        })
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn raster_of(r: RenderedPage) -> Result<Raster, CoreError> {
    if let Some(e) = r.error {
        return Err(CoreError::Engine(format!("page render failed: {e}")));
    }
    let (w, h) = (r.width as i64, r.height as i64);
    let stride = w.saturating_mul(4);
    let rgba: Vec<u8> = r.rgba.as_ref().to_vec();
    if rgba.len() < stride.saturating_mul(h) as usize {
        return Err(CoreError::Engine("renderer returned a short pixel buffer".into()));
    }
    Ok(Raster { width: w, height: h, stride, rgba, tag: r.request.tag as i64, render_millis: i64::from(r.millis) })
}

fn union_rects(rects: &[[f32; 4]]) -> [f64; 4] {
    let mut out = [f64::INFINITY, f64::INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY];
    for r in rects {
        out[0] = out[0].min(f64::from(r[0]));
        out[1] = out[1].min(f64::from(r[1]));
        out[2] = out[2].max(f64::from(r[2]));
        out[3] = out[3].max(f64::from(r[3]));
    }
    if !out.iter().all(|v| v.is_finite()) {
        return [0.0; 4];
    }
    out
}

/// PDF user-space rect -> view-space rect, using both corners so a rotated
/// page maps correctly.
fn view_rect_from_user(doc: &pdfcraft_engine::Document, page: usize, r: [f32; 4]) -> (Rect, bool) {
    let Some(pi) = doc.info.pages.get(page) else { return (Rect::default(), false) };
    let corners = [[r[0], r[1]], [r[2], r[1]], [r[0], r[3]], [r[2], r[3]]];
    let mut xs = Vec::with_capacity(4);
    let mut ys = Vec::with_capacity(4);
    for [x, y] in corners {
        let [vx, vy] = pi.user_to_view(x, y);
        xs.push(f64::from(vx));
        ys.push(f64::from(vy));
    }
    let min = |v: &Vec<f64>| v.iter().copied().fold(f64::INFINITY, f64::min);
    let max = |v: &Vec<f64>| v.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    (Rect { x0: min(&xs), y0: min(&ys), x1: max(&xs), y1: max(&ys) }, true)
}

#[cfg(test)]
mod tests;
