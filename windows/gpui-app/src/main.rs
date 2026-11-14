//! YoPDF — GPUI Kit native reader (Slice B + Slice C).
//!
//! Continuous-scroll multi-tab reader on `pdfcore`:
//! - Slice B: continuous page scroll with HiDPI render cache, tabs, text
//!   search with sidebar, click/drag text selection + copy, light/dark theme.
//! - Slice C: text markup (Highlight / Underline / StrikeOut) with preset color
//!   palette & recoloring, sticky notes with inline/sidebar editing, undo/redo
//!   gated during saves, background serialized Save / Save As (`SaveController`),
//!   per-tab debounced autosave (750ms) with bounded unverified-fingerprint
//!   retry (4 × 750ms) and SHA-256 external-change refusal, generation-numbered
//!   `AppConfig` (recents + colors + theme), dirty-tab & window close guards,
//!   and quit drain barrier.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod config;
mod persistence;

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use config::{hex_to_rgba_u32, parse_hex_rgb, rgb_to_rgba_u32, AppConfig, PRESET_MARKUP_COLORS};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::dialog::DialogFooter;
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::tab::{Tab, TabBar};
use gpui_kit::component::theme::{Theme, ThemeMode};
use gpui_kit::component::{ActiveTheme as _, Disableable as _, Sizable as _, StyledExt as _, WindowExt as _};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Bounds, ClipboardItem, Context, Entity, FocusHandle, Focusable, KeyDownEvent,
    MouseDownEvent, MouseMoveEvent, MouseUpEvent, RenderImage, ScrollDelta, ScrollEvent,
    ScrollHandle, SharedString, Subscription, TitlebarOptions, Window, WindowOptions, div, img,
    px, size,
};
use pdfcore::{
    Annotation, CoreError, DocumentInfo, MarkupKind, PdfCore, Rect, SaveOptions, SearchMatch,
    TextBlock,
};
use persistence::{
    autosave_eligibility, preflight_save_as, run_save_chain, AutosaveDecision, EnqueueResult,
    SaveAsPreflight, SaveController, SaveErrorKind, SaveJob, SaveRegistry, SaveState,
    AUTO_SAVE_DELAY, MSG_AUTOSAVE_CHANGED, MSG_AUTOSAVE_PAUSED_UNVERIFIED,
    UNVERIFIED_AUTOSAVE_RETRIES,
};

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

const MIN_ZOOM: f32 = 0.25;
const MAX_ZOOM: f32 = 8.0;
const ZOOM_STEP: f32 = 1.25;
const PAGE_GAP: f32 = 16.0;
const PAGE_MARGIN: f32 = 24.0;
/// Max page rasters cached at once; far-from-viewport pages are evicted.
const MAX_CACHED_PAGES: usize = 24;
/// Max page renders in flight per viewer.
const MAX_PENDING: usize = 4;
/// Hard cap on search matches (pdfcore clamps to 10k).
const SEARCH_LIMIT: i64 = 1_000;

// ---------------------------------------------------------------------------
// Per-document state
// ---------------------------------------------------------------------------

struct PageImg {
    img: Arc<RenderImage>,
    /// points→pixels scale this raster was rendered at (zoom × scale_factor)
    scale: f64,
}

#[derive(Default)]
struct SearchState {
    query: String,
    matches: Vec<SearchMatch>,
    /// page → hit rectangles in view-space points
    rects: HashMap<i64, Vec<Rect>>,
    running: bool,
    active: usize,
}

struct DocTab {
    path: String,
    doc_id: String,
    title: String,
    info: DocumentInfo,
    /// (width, height) in view-space points per page
    page_sizes: Vec<(f64, f64)>,
    zoom: f32,
    images: HashMap<i64, PageImg>,
    pending: HashSet<i64>,
    /// page → annotations (cache; invalidated on any edit/undo/redo)
    anns: HashMap<i64, Vec<Annotation>>,
    /// page → text blocks (cache)
    blocks: HashMap<i64, Vec<TextBlock>>,
    /// selected text blocks — selection stays within one page at a time
    sel_page: i64,
    sel_anchor: Option<usize>,
    sel_blocks: Vec<usize>,
    /// currently selected annotation (page, /Annots index)
    selected_annot: Option<(i64, i64)>,
    search: Option<SearchState>,
    dirty: bool,
    save_ctrl: SaveController,
    /// page to scroll to once it has been laid out (search jump / open)
    pending_jump: Option<i64>,
}

impl DocTab {
    fn page_w(&self, page: i64, zoom: f32) -> f32 {
        self.page_sizes
            .get(page as usize)
            .map(|s| s.0 as f32 * zoom)
            .unwrap_or(612.0 * zoom)
    }

    fn page_h(&self, page: i64, zoom: f32) -> f32 {
        self.page_sizes
            .get(page as usize)
            .map(|s| s.1 as f32 * zoom)
            .unwrap_or(792.0 * zoom)
    }

    fn label(&self) -> String {
        if !self.title.is_empty() {
            self.title.clone()
        } else {
            std::path::Path::new(&self.path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| self.path.clone())
        }
    }

    fn invalidate_page(&mut self, page: i64) {
        self.images.remove(&page);
        self.pending.remove(&page);
        self.anns.remove(&page);
    }

    fn invalidate_all(&mut self) {
        self.images.clear();
        self.pending.clear();
        self.anns.clear();
    }
}

// ---------------------------------------------------------------------------
// Viewer
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq)]
enum Tool {
    Select,
    Note,
}

#[derive(Clone, Copy, PartialEq)]
enum Sidebar {
    Hidden,
    Search,
    Notes,
}

struct Viewer {
    engine: Arc<PdfCore>,
    config: Arc<AppConfig>,
    tabs: Vec<DocTab>,
    active: usize,
    tool: Tool,
    sidebar: Sidebar,
    active_markup: MarkupKind,
    dragging_sel: bool,
    drag_origin: Option<(i64, gpui_kit::Point<gpui_kit::Pixels>)>,
    drag_moved: bool,
    /// Set to true once the user confirms discarding or saving all tabs on window close.
    allow_window_close: bool,
    /// True while a window-close drain/save operation is already in progress.
    closing_window: bool,
    /// Registry of active and closing-tab `SaveController`s for quit/close barriers.
    save_registry: SaveRegistry,
    /// Bumped per search; stale search results are dropped.
    search_epoch: u64,
    cancel: Arc<AtomicBool>,
    /// Window backing scale factor, refreshed each layout pass.
    scale_factor: f64,
    scroll: ScrollHandle,
    focus_handle: FocusHandle,
    search_input: Entity<InputState>,
    note_input: Entity<InputState>,
    /// (page, annotation index) being edited in the notes sidebar
    note_editing: Option<(i64, i64)>,
    status: SharedString,
    info: SharedString,
    empty: bool,
    _subs: Vec<Subscription>,
}

impl Focusable for Viewer {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Viewer {
    fn tab(&self) -> Option<&DocTab> {
        self.tabs.get(self.active)
    }

    fn tab_mut(&mut self) -> Option<&mut DocTab> {
        self.tabs.get_mut(self.active)
    }

    fn tab_by_doc_id(&self, doc_id: &str) -> Option<&DocTab> {
        self.tabs.iter().find(|t| t.doc_id == doc_id)
    }

    fn tab_by_doc_id_mut(&mut self, doc_id: &str) -> Option<&mut DocTab> {
        self.tabs.iter_mut().find(|t| t.doc_id == doc_id)
    }

    fn index_by_doc_id(&self, doc_id: &str) -> Option<usize> {
        self.tabs.iter().position(|t| t.doc_id == doc_id)
    }

    fn open_path(
        &mut self,
        path: &str,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> anyhow::Result<usize> {
        // If already open in a tab, focus it instead of opening a duplicate.
        if let Some(existing) = self.tabs.iter().position(|t| t.path == path) {
            self.active = existing;
            self.empty = false;
            self.set_status(format!("switched to {}", path));
            cx.notify();
            return Ok(existing);
        }

        let info = self.engine.open_document(path)?;
        let count = info.page_count.max(0);
        let mut page_sizes = Vec::with_capacity(count as usize);
        for p in 0..count {
            let pi = self.engine.get_page_info(&info.id, p)?;
            page_sizes.push((pi.width, pi.height));
        }
        let save_ctrl = SaveController::new();
        self.save_registry.register(save_ctrl.clone());
        let tab = DocTab {
            path: path.to_string(),
            doc_id: info.id.clone(),
            title: if info.title.is_empty() {
                std::path::Path::new(path)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default()
            } else {
                info.title.clone()
            },
            info,
            page_sizes,
            zoom: 1.0,
            images: HashMap::new(),
            pending: HashSet::new(),
            anns: HashMap::new(),
            blocks: HashMap::new(),
            sel_page: -1,
            sel_anchor: None,
            sel_blocks: Vec::new(),
            selected_annot: None,
            search: None,
            dirty: false,
            save_ctrl,
            pending_jump: Some(0),
        };
        self.tabs.push(tab);
        self.empty = false;
        let idx = self.tabs.len() - 1;
        self.active = idx;
        self.config.touch_recent(path, 0, 1.0);
        self.set_status(format!("opened {} · {} pages", path, count));
        cx.notify();
        Ok(idx)
    }

    fn set_status(&mut self, s: impl Into<SharedString>) {
        self.status = s.into();
    }

    fn push_error(&mut self, title: &'static str, msg: impl Into<SharedString>, window: &mut Window, cx: &mut Context<Self>) {
        let m: SharedString = msg.into();
        self.set_status(m.clone());
        window.push_notification(Notification::error(m).title(title), cx);
    }

    fn request_close_tab(&mut self, idx: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(tab) = self.tabs.get(idx) else { return };
        if !tab.dirty && !tab.save_ctrl.has_pending() {
            self.finish_close_tab(idx, false, cx);
            return;
        }

        let doc_id = tab.doc_id.clone();
        let label = tab.label();
        let entity = cx.entity().clone();
        window.open_dialog(cx, move |dialog, _, _| {
            let entity_save = entity.clone();
            let entity_discard = entity.clone();
            let doc_id_save = doc_id.clone();
            let doc_id_discard = doc_id.clone();
            dialog
                .title(format!("Save changes to “{label}” before closing?"))
                .centered()
                .overlay_closable(false)
                .child(
                    div()
                        .text_size(px(13.0))
                        .child("Your changes will be lost if you don't save them."),
                )
                .footer(
                    DialogFooter::new()
                        .child(
                            Button::new("close-cancel")
                                .label("Cancel")
                                .on_click(|_, window, cx| {
                                    window.close_dialog(cx);
                                }),
                        )
                        .child(
                            Button::new("close-dont-save")
                                .danger()
                                .label("Don't Save")
                                .on_click(move |_, window, cx| {
                                    window.close_dialog(cx);
                                    entity_discard.update(cx, |this, cx| {
                                        if let Some(i) = this.index_by_doc_id(&doc_id_discard) {
                                            this.finish_close_tab(i, true, cx);
                                        }
                                    });
                                    window.refresh();
                                }),
                        )
                        .child(
                            Button::new("close-save")
                                .primary()
                                .label("Save")
                                .on_click(move |_, window, cx| {
                                    window.close_dialog(cx);
                                    entity_save.update(cx, |this, cx| {
                                        this.save_and_close_by_doc_id(&doc_id_save, window, cx);
                                    });
                                    window.refresh();
                                }),
                        ),
                )
        });
    }

    fn finish_close_tab(&mut self, idx: usize, discard_queued: bool, cx: &mut Context<Self>) {
        let Some(tab) = self.tabs.get(idx) else { return };
        if discard_queued {
            tab.save_ctrl.cancel_queued();
        }
        tab.save_ctrl.bump_doc_gen();
        let doc_id = tab.doc_id.clone();
        let ctrl = tab.save_ctrl.clone();
        let engine = self.engine.clone();
        let registry = self.save_registry.clone();

        self.tabs.remove(idx);
        self.note_editing = None;
        if self.tabs.is_empty() {
            self.empty = true;
            self.status = "no document — click Open…".into();
            self.info = "".into();
        } else {
            self.active = self.active.min(self.tabs.len() - 1);
        }
        cx.notify();

        // Never block the UI main thread waiting on an in-flight save or
        // PdfCore::close_document (which acquires render_gate). Wait on a
        // background worker until any running save finishes before closing the
        // document so Session outlives the save; `save_registry` keeps tracking
        // `ctrl` until it is idle so quit/window-close barriers cannot exit early.
        cx.background_executor()
            .spawn(async move {
                ctrl.wait_until_idle();
                let _ = engine.close_document(&doc_id);
                registry.unregister_if_idle(&ctrl);
            })
            .detach();
    }

    fn save_and_close_by_doc_id(
        &mut self,
        doc_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(tab) = self.tab_by_doc_id(doc_id) else { return };
        let path = tab.path.clone();
        if path.is_empty() {
            self.push_error(
                "Save & Close refused",
                "Document has no path on disk; use Save As… first.",
                window,
                cx,
            );
            return;
        }
        self.enqueue_save_for_doc(
            doc_id,
            path,
            SaveOptions { overwrite_existing_destination: false },
            false,
            true,
            window,
            cx,
        );
    }

    fn open_window_close_dialog(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.closing_window {
            return;
        }
        let dirty_count = self.tabs.iter().filter(|t| t.dirty).count();
        let pending_saves = self.save_registry.has_pending();
        let body = if dirty_count > 0 {
            format!("{dirty_count} open document(s) have unsaved annotations.")
        } else if pending_saves {
            "A background save is still in progress.".to_string()
        } else {
            "Close window?".to_string()
        };
        let entity = cx.entity().clone();
        window.open_dialog(cx, move |dialog, _, _| {
            let entity_discard = entity.clone();
            let entity_save_all = entity.clone();
            dialog
                .title("Save changes before closing window?")
                .centered()
                .overlay_closable(false)
                .child(div().text_size(px(13.0)).child(body.clone()))
                .footer(
                    DialogFooter::new()
                        .child(
                            Button::new("win-close-cancel")
                                .label("Cancel")
                                .on_click(|_, window, cx| {
                                    window.close_dialog(cx);
                                }),
                        )
                        .child(
                            Button::new("win-close-discard")
                                .danger()
                                .label("Don't Save")
                                .on_click(move |_, window, cx| {
                                    window.close_dialog(cx);
                                    entity_discard.update(cx, |this, cx| {
                                        for tab in &this.tabs {
                                            tab.save_ctrl.cancel_queued();
                                            tab.save_ctrl.bump_doc_gen();
                                        }
                                        if !this.save_registry.has_pending() {
                                            this.allow_window_close = true;
                                            window.remove_window();
                                            return;
                                        }
                                        this.closing_window = true;
                                        this.set_status("waiting for in-flight save to finish before closing…");
                                        cx.notify();
                                        let registry = this.save_registry.clone();
                                        cx.spawn_in(window, async move |this, cx| {
                                            cx.background_executor()
                                                .spawn(async move {
                                                    registry.drain_all();
                                                })
                                                .await;
                                            this.update_in(cx, |this, window, _| {
                                                this.allow_window_close = true;
                                                window.remove_window();
                                            })
                                            .ok();
                                        })
                                        .detach();
                                    });
                                    window.refresh();
                                }),
                        )
                        .child(
                            Button::new("win-close-save")
                                .primary()
                                .label("Save & Close")
                                .on_click(move |_, window, cx| {
                                    window.close_dialog(cx);
                                    entity_save_all.update(cx, |this, cx| {
                                        this.save_all_and_close_window(window, cx);
                                    });
                                }),
                        ),
                )
        });
    }

    fn save_all_and_close_window(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.closing_window {
            return;
        }
        if self.tabs.iter().any(|t| t.dirty && t.path.is_empty()) {
            self.push_error(
                "Save refused",
                "An untitled document has no file path; use Save As… first.",
                window,
                cx,
            );
            return;
        }
        let dirty_docs: Vec<(String, String)> = self
            .tabs
            .iter()
            .filter(|t| t.dirty && !t.path.is_empty())
            .map(|t| (t.doc_id.clone(), t.path.clone()))
            .collect();
        let registry = self.save_registry.clone();
        if dirty_docs.is_empty() && !registry.has_pending() {
            self.allow_window_close = true;
            window.remove_window();
            return;
        }
        self.closing_window = true;
        self.set_status("saving before closing window…");
        cx.notify();
        let engine = self.engine.clone();
        let ctrls: Vec<(String, String, SaveController)> = dirty_docs
            .into_iter()
            .filter_map(|(id, path)| {
                self.tab_by_doc_id(&id)
                    .map(|t| (id, path, t.save_ctrl.clone()))
            })
            .collect();

        cx.spawn_in(window, async move |this, cx| {
            let results: Vec<(String, Result<(), String>)> = cx
                .background_executor()
                .spawn(async move {
                    let mut out = Vec::new();
                    for (doc_id, path, ctrl) in ctrls {
                        let job = SaveJob {
                            doc_id: doc_id.clone(),
                            path,
                            opts: SaveOptions::default(),
                            doc_gen: ctrl.doc_gen(),
                            is_autosave: false,
                            close_after: false,
                        };
                        match ctrl.enqueue(job.clone()) {
                            EnqueueResult::StartNow => {
                                let mut err_msg = None;
                                run_save_chain(&engine, &ctrl, job, |_, res| {
                                    if let Err(e) = res {
                                        err_msg = Some(e.message);
                                    }
                                });
                                out.push((doc_id, err_msg.map_or(Ok(()), Err)));
                            }
                            EnqueueResult::Queued { .. } => {
                                ctrl.wait_until_idle();
                                match ctrl.snapshot() {
                                    SaveState::Succeeded(_) => out.push((doc_id, Ok(()))),
                                    SaveState::Failed { failure, .. } => {
                                        out.push((doc_id, Err(failure.message)))
                                    }
                                    _ => out.push((doc_id, Err("save did not finish".into()))),
                                }
                            }
                            EnqueueResult::StaleGeneration => out.push((doc_id, Ok(()))),
                        }
                    }
                    registry.drain_all();
                    out
                })
                .await;

            this.update_in(cx, |this, window, cx| {
                let mut any_error: Option<String> = None;
                for (doc_id, res) in results {
                    if let Err(msg) = res {
                        if any_error.is_none() {
                            any_error = Some(msg);
                        }
                    } else {
                        this.refresh_doc_meta(&doc_id);
                    }
                }
                if let Some(err) = any_error {
                    this.closing_window = false;
                    this.push_error("Save & Close refused", err, window, cx);
                    cx.notify();
                    window.refresh();
                } else if this.tabs.iter().all(|t| !t.dirty) && !this.save_registry.has_pending() {
                    this.allow_window_close = true;
                    window.remove_window();
                } else {
                    this.closing_window = false;
                    cx.notify();
                    window.refresh();
                }
            })
            .ok();
        })
        .detach();
    }

    // ---- zoom -------------------------------------------------------------

    fn set_zoom(&mut self, zoom: f32, cx: &mut Context<Self>) {
        let anchor = self.scroll.top_item() as i64;
        let Some(tab) = self.tab_mut() else { return };
        let zoom = zoom.clamp(MIN_ZOOM, MAX_ZOOM);
        if (zoom - tab.zoom).abs() <= f32::EPSILON {
            return;
        }
        // Keep the page at the top of the viewport anchored across the zoom.
        tab.zoom = zoom;
        tab.invalidate_all();
        tab.pending_jump = Some(anchor.min(tab.info.page_count - 1).max(0));
        self.set_status(format!("zoom {:.0}%", zoom * 100.0));
        cx.notify();
    }

    fn zoom_by(&mut self, factor: f32, cx: &mut Context<Self>) {
        let cur = self.tab().map(|t| t.zoom).unwrap_or(1.0);
        self.set_zoom(cur * factor, cx);
    }

    fn fit_width(&mut self, cx: &mut Context<Self>) {
        let Some(tab) = self.tab() else { return };
        let vw = self.scroll.bounds().size.width.as_f32();
        if vw <= 0.0 {
            return;
        }
        let page = self.scroll.top_item() as i64;
        let w = tab.page_sizes.get(page as usize).map(|s| s.0).unwrap_or(612.0);
        let target = ((vw - PAGE_MARGIN * 2.0) / w as f32).clamp(MIN_ZOOM, MAX_ZOOM);
        self.set_zoom(target, cx);
    }

    fn goto_page(&mut self, page: i64, window: &mut Window, cx: &mut Context<Self>) {
        let (page, zoom) = {
            let Some(tab) = self.tab() else { return };
            let page = page.clamp(0, tab.info.page_count - 1).max(0);
            (page, tab.zoom)
        };
        self.scroll.scroll_to_top_of_item(page as usize);
        self.set_status(format!("page {}", page + 1));
        let scale = zoom as f64 * self.scale_factor;
        self.spawn_page_render(page, scale, window, cx);
        cx.notify();
    }

    // ---- rendering --------------------------------------------------------

    /// Spawn renders for pages visible in the viewport (+prefetch) and evict
    /// rasters far away. Called every render pass; cheap when idle.
    fn ensure_visible_pages(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.scale_factor = window.scale_factor() as f64;
        let offset = self.scroll.offset().y.as_f32();
        let vh = self.scroll.bounds().size.height.as_f32().max(1.0);

        let (zoom, count, jump) = {
            let Some(tab) = self.tab() else { return };
            if tab.info.page_count <= 0 {
                return;
            }
            (tab.zoom, tab.info.page_count, tab.pending_jump)
        };
        if let Some(page) = jump {
            let page = page.clamp(0, count - 1).max(0);
            self.scroll.scroll_to_top_of_item(page as usize);
            if let Some(tab) = self.tab_mut() {
                tab.pending_jump = None;
            }
            let scale = zoom as f64 * self.scale_factor;
            self.spawn_page_render(page, scale, window, cx);
            cx.notify();
        }

        let mut first = 0i64;
        let mut y = 0.0f32;
        for i in 0..count {
            let h = {
                let tab = self.tab().unwrap();
                tab.page_h(i, zoom) + PAGE_GAP
            };
            if y + h > offset {
                first = i;
                break;
            }
            y += h;
        }
        let visible = {
            let tab = self.tab().unwrap();
            let page_area_h = tab.page_h(first, zoom);
            ((vh / (page_area_h + PAGE_GAP)).ceil() as i64 + 2).max(3).min(count)
        };

        let target_scale = zoom as f64 * self.scale_factor;
        let to_spawn: Vec<i64> = {
            let tab = self.tab_mut().unwrap();
            let wrong_scale: Vec<i64> = tab
                .images
                .iter()
                .filter(|(_, pi)| (pi.scale - target_scale).abs() > 1e-6)
                .map(|(p, _)| *p)
                .collect();
            for p in wrong_scale {
                tab.images.remove(&p);
            }
            if tab.images.len() > MAX_CACHED_PAGES {
                let lo = (first - 4).max(0);
                let hi = first + visible + 4;
                let stale: Vec<i64> = tab
                    .images
                    .keys()
                    .copied()
                    .filter(|p| *p < lo || *p >= hi)
                    .collect();
                for p in stale {
                    tab.images.remove(&p);
                }
            }
            let mut out = Vec::new();
            for i in first..(first + visible) {
                if tab.images.contains_key(&i) || tab.pending.contains(&i) {
                    continue;
                }
                if tab.pending.len() >= MAX_PENDING || out.len() >= 2 {
                    break;
                }
                out.push(i);
            }
            out
        };
        let scale = zoom as f64 * self.scale_factor;
        for i in to_spawn {
            self.spawn_page_render(i, scale, window, cx);
        }
    }

    fn spawn_page_render(
        &mut self,
        page: i64,
        scale: f64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(tab) = self.tab() else { return };
        if tab.pending.contains(&page) || tab.images.contains_key(&page) {
            return;
        }
        let doc_id = tab.doc_id.clone();
        let engine = self.engine.clone();
        let cancel_flag = Arc::new(AtomicBool::new(false));
        self.tab_mut().unwrap().pending.insert(page);

        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    engine.render_page(&doc_id, page, scale, 0, &|| {
                        cancel_flag.load(Ordering::SeqCst)
                    })
                })
                .await;
            this.update_in(cx, |this, window, cx| {
                let Some(tab) = this.tab_mut() else { return };
                tab.pending.remove(&page);
                let cur_scale = tab.zoom as f64 * this.scale_factor;
                let scale_changed = (cur_scale - scale).abs() > 1e-6;
                cx.notify();
                window.refresh();
                if scale_changed {
                    return;
                }
                match result {
                    Ok(raster) => {
                        let (w, h) = (raster.width.max(0) as u32, raster.height.max(0) as u32);
                        if let Some(buf) =
                            image::ImageBuffer::<image::Rgba<u8>, Vec<u8>>::from_raw(w, h, raster.rgba)
                        {
                            let img = Arc::new(RenderImage::new(vec![image::Frame::new(buf)]));
                            if let Some(tab) = this.tab_mut() {
                                tab.images.retain(|_, pi| (pi.scale - scale).abs() < 1e-6);
                                tab.images.insert(page, PageImg { img, scale });
                                this.info = format!(
                                    "page {}/{} · {}×{} px · {} ms",
                                    page + 1,
                                    tab.info.page_count,
                                    w,
                                    h,
                                    raster.render_millis
                                )
                                .into();
                            }
                        }
                    }
                    Err(CoreError::Cancelled) => {}
                    Err(e) => {
                        this.set_status(format!("render failed: {e}"));
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
        cx.notify();
    }

    // ---- text / search ----------------------------------------------------

    fn blocks_for(&mut self, page: i64) -> Result<Vec<TextBlock>, CoreError> {
        let Some(tab) = self.tab() else { return Ok(vec![]) };
        if let Some(b) = tab.blocks.get(&page) {
            return Ok(b.clone());
        }
        let doc_id = tab.doc_id.clone();
        let blocks = self
            .engine
            .get_text_blocks(&doc_id, page, &|| false)?;
        if let Some(tab) = self.tab_mut() {
            tab.blocks.insert(page, blocks.clone());
        }
        Ok(blocks)
    }

    fn run_search(&mut self, query: String, window: &mut Window, cx: &mut Context<Self>) {
        if self.tab().is_none() {
            return;
        }
        if query.is_empty() {
            if let Some(tab) = self.tab_mut() {
                tab.search = None;
            }
            cx.notify();
            return;
        }
        self.search_epoch += 1;
        let epoch = self.search_epoch;
        self.cancel.store(true, Ordering::SeqCst);
        let cancel = Arc::new(AtomicBool::new(false));
        self.cancel = cancel.clone();

        let engine = self.engine.clone();
        let doc_id = self.tab().unwrap().doc_id.clone();
        if let Some(tab) = self.tab_mut() {
            tab.search = Some(SearchState {
                query: query.clone(),
                running: true,
                ..Default::default()
            });
        }
        cx.notify();

        let query_for_status = query.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    engine.search_text(&doc_id, &query, SEARCH_LIMIT, &|| {
                        cancel.load(Ordering::SeqCst)
                    })
                })
                .await;
            this.update_in(cx, |this, window, cx| {
                if epoch != this.search_epoch {
                    return;
                }
                let mut by_page: HashMap<i64, Vec<Rect>> = HashMap::new();
                if let Ok(ref matches) = result {
                    let pages: HashSet<i64> = matches.iter().map(|m| m.page).collect();
                    for p in pages {
                        if let Ok(blocks) = this.blocks_for(p) {
                            let rects: Vec<Rect> = matches
                                .iter()
                                .filter(|m| m.page == p)
                                .filter_map(|m| {
                                    blocks
                                        .iter()
                                        .find(|b| m.start < b.end && m.end > b.start)
                                        .map(|b| b.rect)
                                })
                                .collect();
                            by_page.insert(p, rects);
                        }
                    }
                }
                let Some(tab) = this.tab_mut() else { return };
                let Some(search) = tab.search.as_mut() else { return };
                match result {
                    Ok(matches) => {
                        let n = matches.len();
                        search.matches = matches;
                        search.rects = by_page;
                        search.running = false;
                        search.active = 0;
                        if n > 0 {
                            let first = search.matches[0].page;
                            tab.pending_jump = Some(first);
                        }
                        this.set_status(format!("search “{query_for_status}”: {n} hits"));
                    }
                    Err(CoreError::Cancelled) => {}
                    Err(e) => {
                        search.running = false;
                        this.set_status(format!("search failed: {e}"));
                    }
                }
                cx.notify();
                window.refresh();
            })
            .ok();
        })
        .detach();
    }

    fn jump_to_match(&mut self, index: usize, cx: &mut Context<Self>) {
        let hit = {
            let Some(tab) = self.tab() else { return };
            let Some(search) = tab.search.as_ref() else { return };
            search
                .matches
                .get(index)
                .map(|m| (m.page, search.matches.len()))
        };
        let Some((page, total)) = hit else { return };
        if let Some(tab) = self.tab_mut() {
            tab.pending_jump = Some(page);
            if let Some(s) = tab.search.as_mut() {
                s.active = index;
            }
        }
        self.set_status(format!("hit {}/{} — page {}", index + 1, total, page + 1));
        cx.notify();
    }

    // ---- annotations ------------------------------------------------------

    fn anns_for(&mut self, page: i64) -> Vec<Annotation> {
        let Some(tab) = self.tab() else { return vec![] };
        if let Some(a) = tab.anns.get(&page) {
            return a.clone();
        }
        let doc_id = tab.doc_id.clone();
        let anns = self.engine.list_annotations(&doc_id, page).unwrap_or_default();
        if let Some(tab) = self.tab_mut() {
            tab.anns.insert(page, anns.clone());
        }
        anns
    }

    fn all_anns(&mut self) -> Vec<Annotation> {
        let Some(tab) = self.tab() else { return vec![] };
        let doc_id = tab.doc_id.clone();
        let anns = self.engine.list_annotations(&doc_id, -1).unwrap_or_default();
        let mut by_page: HashMap<i64, Vec<Annotation>> = HashMap::new();
        for a in &anns {
            by_page.entry(a.page).or_default().push(a.clone());
        }
        if let Some(tab) = self.tab_mut() {
            for (p, v) in by_page {
                tab.anns.insert(p, v);
            }
        }
        anns
    }

    fn refresh_doc_meta(&mut self, doc_id: &str) {
        if let Ok(info) = self.engine.get_document_info(doc_id)
            && let Some(tab) = self.tab_by_doc_id_mut(doc_id)
        {
            tab.dirty = info.dirty;
            tab.info = info;
        }
    }

    fn gate_active_edit(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Option<String> {
        let Some(tab) = self.tab() else { return None };
        if let Err(msg) = tab.save_ctrl.gate_edit() {
            self.push_error("Edit paused", msg, window, cx);
            cx.notify();
            return None;
        }
        Some(tab.doc_id.clone())
    }

    fn active_color_rgb(&self, kind: MarkupKind) -> [f64; 3] {
        let hex = self.config.markup_color(kind);
        parse_hex_rgb(&hex).unwrap_or([1.0, 0.839, 0.039])
    }

    fn apply_markup(&mut self, kind: MarkupKind, window: &mut Window, cx: &mut Context<Self>) {
        let Some(doc_id) = self.gate_active_edit(window, cx) else { return };
        let (page, rects) = {
            let Some(tab) = self.tab() else { return };
            if tab.sel_page < 0 || tab.sel_blocks.is_empty() {
                return;
            }
            let page = tab.sel_page;
            let mut rects: Vec<Rect> = tab
                .blocks
                .get(&page)
                .map(|blocks| {
                    tab.sel_blocks
                        .iter()
                        .filter_map(|i| blocks.get(*i))
                        .map(|b| b.rect)
                        .collect()
                })
                .unwrap_or_default();
            rects.sort_by(|a, b| a.y0.total_cmp(&b.y0).then(a.x0.total_cmp(&b.x0)));
            (page, rects)
        };
        if rects.is_empty() {
            return;
        }
        self.active_markup = kind;
        let color = self.active_color_rgb(kind);
        let cancel = self.cancel.clone();
        match self
            .engine
            .add_markup(&doc_id, page, kind, &rects, color, &|| cancel.load(Ordering::SeqCst))
        {
            Ok(ann) => {
                if let Some(tab) = self.tab_by_doc_id_mut(&doc_id) {
                    tab.sel_blocks.clear();
                    tab.sel_anchor = None;
                    tab.sel_page = -1;
                    tab.selected_annot = Some((ann.page, ann.index));
                    tab.invalidate_page(page);
                    tab.save_ctrl.note_edited();
                }
                self.refresh_doc_meta(&doc_id);
                let verb = match kind {
                    MarkupKind::Highlight => "highlighted",
                    MarkupKind::Underline => "underlined",
                    MarkupKind::StrikeOut => "struck out",
                };
                self.set_status(format!("{verb} page {}", page + 1));
                self.schedule_autosave(&doc_id, window, cx);
            }
            Err(e) => self.push_error("Markup failed", format!("{e}"), window, cx),
        }
        cx.notify();
    }

    fn copy_selection(&mut self, cx: &mut Context<Self>) {
        let Some(tab) = self.tab() else { return };
        if tab.sel_page < 0 || tab.sel_blocks.is_empty() {
            return;
        }
        let page = tab.sel_page;
        let text = tab
            .blocks
            .get(&page)
            .map(|blocks| {
                let mut idx: Vec<usize> = tab.sel_blocks.clone();
                idx.sort();
                idx.iter()
                    .filter_map(|i| blocks.get(*i))
                    .map(|b| b.text.trim().to_string())
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default();
        if !text.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(text.clone()));
            let chars = text.chars().count();
            self.set_status(format!("copied {chars} chars to clipboard"));
        }
        cx.notify();
    }

    fn add_note_at_selection_or_page(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(tab) = self.tab() else { return };
        let (page, x, y) = if tab.sel_page >= 0 && !tab.sel_blocks.is_empty() {
            let p = tab.sel_page;
            let anchor = tab
                .sel_blocks
                .first()
                .and_then(|i| tab.blocks.get(&p).and_then(|b| b.get(*i)))
                .map(|b| (b.rect.x0, b.rect.y0))
                .unwrap_or((36.0, 36.0));
            (p, anchor.0, anchor.1)
        } else {
            (self.scroll.top_item() as i64, 36.0, 36.0)
        };
        self.add_note_at(page, x, y, window, cx);
    }

    fn add_note_at(
        &mut self,
        page: i64,
        x: f64,
        y: f64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(doc_id) = self.gate_active_edit(window, cx) else { return };
        let color = parse_hex_rgb(&self.config.note_color());
        let cancel = self.cancel.clone();
        match self.engine.add_sticky_note_with_color(
            &doc_id,
            page,
            x,
            y,
            "",
            color,
            &|| cancel.load(Ordering::SeqCst),
        ) {
            Ok(a) => {
                if let Some(tab) = self.tab_by_doc_id_mut(&doc_id) {
                    tab.invalidate_page(page);
                    tab.selected_annot = Some((a.page, a.index));
                    tab.save_ctrl.note_edited();
                }
                self.refresh_doc_meta(&doc_id);
                self.sidebar = Sidebar::Notes;
                self.note_editing = Some((a.page, a.index));
                self.note_input.update(cx, |state, cx| {
                    state.set_value(String::new(), window, cx);
                });
                self.note_input.focus_handle(cx).focus(window, cx);
                self.set_status(format!("note added on page {}", page + 1));
                self.schedule_autosave(&doc_id, window, cx);
            }
            Err(e) => self.push_error("Note failed", format!("{e}"), window, cx),
        }
        cx.notify();
    }

    fn save_note(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((page, index)) = self.note_editing else { return };
        let Some(doc_id) = self.gate_active_edit(window, cx) else { return };
        let contents = self.note_input.read(cx).value().to_string();
        match self.engine.update_annotation(&doc_id, page, index, &contents) {
            Ok(_) => {
                if let Some(tab) = self.tab_by_doc_id_mut(&doc_id) {
                    tab.invalidate_page(page);
                    tab.save_ctrl.note_edited();
                }
                self.refresh_doc_meta(&doc_id);
                self.set_status("note updated");
                self.schedule_autosave(&doc_id, window, cx);
            }
            Err(e) => self.push_error("Note save failed", format!("{e}"), window, cx),
        }
        cx.notify();
    }

    fn delete_note(&mut self, page: i64, index: i64, window: &mut Window, cx: &mut Context<Self>) {
        let Some(doc_id) = self.gate_active_edit(window, cx) else { return };
        match self.engine.delete_annotation(&doc_id, page, index) {
            Ok(_) => {
                if let Some(tab) = self.tab_by_doc_id_mut(&doc_id) {
                    tab.invalidate_page(page);
                    tab.selected_annot = match tab.selected_annot {
                        Some((sp, si)) if sp == page && si == index => None,
                        Some((sp, si)) if sp == page && si > index => Some((sp, si - 1)),
                        other => other,
                    };
                    tab.save_ctrl.note_edited();
                }
                match self.note_editing {
                    Some((ep, ei)) if ep == page && ei == index => {
                        self.note_editing = None;
                        self.note_input.update(cx, |s, cx| s.set_value(String::new(), window, cx));
                    }
                    Some((ep, ei)) if ep == page && ei > index => {
                        self.note_editing = Some((ep, ei - 1));
                    }
                    _ => {}
                }
                self.refresh_doc_meta(&doc_id);
                self.set_status("annotation deleted");
                self.schedule_autosave(&doc_id, window, cx);
            }
            Err(e) => self.push_error("Delete failed", format!("{e}"), window, cx),
        }
        cx.notify();
    }

    fn select_color_swatch(&mut self, hex: &str, window: &mut Window, cx: &mut Context<Self>) {
        // If an annotation is currently selected, recolor it immediately (undoable!)
        // and persist the color for that annotation's kind.
        let selected = self.tab().and_then(|t| t.selected_annot);
        if let Some((page, index)) = selected
            && let Some(rgb) = parse_hex_rgb(hex)
        {
            let subtype = self
                .anns_for(page)
                .into_iter()
                .find(|a| a.index == index)
                .map(|a| a.subtype);
            match subtype.as_deref() {
                Some("Text") | Some("Note") => self.config.set_note_color(hex),
                Some("Underline") => self.config.set_markup_color(MarkupKind::Underline, hex),
                Some("StrikeOut") => self.config.set_markup_color(MarkupKind::StrikeOut, hex),
                Some("Highlight") => self.config.set_markup_color(MarkupKind::Highlight, hex),
                _ => {
                    self.config.set_markup_color(self.active_markup, hex);
                    self.config.set_note_color(hex);
                }
            }
            let Some(doc_id) = self.gate_active_edit(window, cx) else { return };
            match self.engine.set_annotation_color(&doc_id, page, index, rgb) {
                Ok(_) => {
                    if let Some(tab) = self.tab_by_doc_id_mut(&doc_id) {
                        tab.invalidate_page(page);
                        tab.save_ctrl.note_edited();
                    }
                    self.refresh_doc_meta(&doc_id);
                    self.set_status(format!("recolored annotation ({hex})"));
                    self.schedule_autosave(&doc_id, window, cx);
                }
                Err(e) => self.push_error("Recolor failed", format!("{e}"), window, cx),
            }
        } else {
            self.config.set_markup_color(self.active_markup, hex);
            self.config.set_note_color(hex);
            self.set_status(format!("markup color {hex}"));
        }
        cx.notify();
    }

    fn undo_redo(&mut self, redo: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(doc_id) = self.gate_active_edit(window, cx) else { return };
        let r = if redo {
            self.engine.redo(&doc_id)
        } else {
            self.engine.undo(&doc_id)
        };
        match r {
            Ok(label) => {
                if let Some(tab) = self.tab_by_doc_id_mut(&doc_id) {
                    tab.invalidate_all();
                    tab.selected_annot = None;
                    tab.save_ctrl.note_edited();
                }
                self.note_editing = None;
                self.refresh_doc_meta(&doc_id);
                self.set_status(if redo {
                    format!("redo: {label}")
                } else {
                    format!("undo: {label}")
                });
                self.schedule_autosave(&doc_id, window, cx);
            }
            Err(e) => self.set_status(format!("{e}")),
        }
        cx.notify();
    }

    // ---- persistence (Save / Save As / Autosave) --------------------------

    fn save(&mut self, save_as: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(tab) = self.tab() else { return };
        let doc_id = tab.doc_id.clone();
        let current = tab.path.clone();

        if save_as || current.is_empty() {
            let dir = std::path::Path::new(&current)
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_default();
            let suggested = std::path::Path::new(&current)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned());
            let engine = self.engine.clone();
            let task = cx.prompt_for_new_path(&dir, suggested.as_deref());
            cx.spawn_in(window, async move |this, cx| {
                let picked = task.await.ok().and_then(|r| r.ok()).flatten();
                let Some(new_path) = picked else { return };
                let path_s = new_path.to_string_lossy().into_owned();
                let doc_id_bg = doc_id.clone();
                let path_bg = path_s.clone();
                let preflight = cx
                    .background_executor()
                    .spawn(async move { preflight_save_as(&engine, &doc_id_bg, &path_bg) })
                    .await;
                this.update_in(cx, |this, window, cx| {
                    match preflight {
                        SaveAsPreflight::Ready => {
                            this.enqueue_save_for_doc(
                                &doc_id,
                                path_s,
                                SaveOptions { overwrite_existing_destination: false },
                                false,
                                false,
                                window,
                                cx,
                            );
                        }
                        SaveAsPreflight::NeedsOverwriteConfirmation => {
                            this.open_save_as_overwrite_dialog(&doc_id, path_s, window, cx);
                        }
                        SaveAsPreflight::Refuse(failure) => {
                            let title = match failure.kind {
                                SaveErrorKind::ExternalChange => "External Change Detected",
                                SaveErrorKind::Unverified => "Target Unverified",
                                SaveErrorKind::DestinationExists => "Destination Exists",
                                SaveErrorKind::ReadOnly => "Read-Only Document",
                                SaveErrorKind::Other => "Save Failed",
                            };
                            this.push_error(title, failure.message, window, cx);
                            cx.notify();
                        }
                    }
                    window.refresh();
                })
                .ok();
            })
            .detach();
        } else {
            self.enqueue_save_for_doc(
                &doc_id,
                current,
                SaveOptions { overwrite_existing_destination: false },
                false,
                false,
                window,
                cx,
            );
        }
    }

    fn open_save_as_overwrite_dialog(
        &mut self,
        doc_id: &str,
        path: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.tab_by_doc_id(doc_id).is_none() {
            return;
        }
        let filename = std::path::Path::new(&path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.clone());
        let doc_id_owned = doc_id.to_string();
        let entity = cx.entity().clone();
        window.open_dialog(cx, move |dialog, _, _| {
            let entity_replace = entity.clone();
            let doc_id_replace = doc_id_owned.clone();
            let path_replace = path.clone();
            let path_display = path.clone();
            dialog
                .title(format!("Replace “{filename}”?"))
                .centered()
                .overlay_closable(false)
                .child(div().text_size(px(13.0)).child(format!(
                    "“{path_display}” already exists. Replacing it will overwrite its contents."
                )))
                .footer(
                    DialogFooter::new()
                        .child(
                            Button::new("save-as-replace-cancel")
                                .label("Cancel")
                                .on_click(|_, window, cx| {
                                    window.close_dialog(cx);
                                }),
                        )
                        .child(
                            Button::new("save-as-replace-confirm")
                                .danger()
                                .label("Replace")
                                .on_click(move |_, window, cx| {
                                    window.close_dialog(cx);
                                    entity_replace.update(cx, |this, cx| {
                                        this.enqueue_save_for_doc(
                                            &doc_id_replace,
                                            path_replace.clone(),
                                            SaveOptions { overwrite_existing_destination: true },
                                            false,
                                            false,
                                            window,
                                            cx,
                                        );
                                    });
                                    window.refresh();
                                }),
                        ),
                )
        });
    }

    #[allow(clippy::too_many_arguments)]
    fn enqueue_save_for_doc(
        &mut self,
        doc_id: &str,
        path: String,
        opts: SaveOptions,
        is_autosave: bool,
        close_after: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(tab) = self.tab_by_doc_id(doc_id) else { return };
        let save_ctrl = tab.save_ctrl.clone();
        let job = SaveJob {
            doc_id: doc_id.to_string(),
            path: path.clone(),
            opts,
            doc_gen: save_ctrl.doc_gen(),
            is_autosave,
            close_after,
        };
        match save_ctrl.enqueue(job.clone()) {
            EnqueueResult::StaleGeneration => return,
            EnqueueResult::Queued { .. } => {
                if !is_autosave {
                    self.set_status(format!("save queued: {path}"));
                }
                cx.notify();
                return;
            }
            EnqueueResult::StartNow => {}
        }

        if !is_autosave {
            self.set_status(format!("saving {path}…"));
        }
        cx.notify();

        let engine = self.engine.clone();
        let config = self.config.clone();
        let doc_id_owned = doc_id.to_string();

        cx.spawn_in(window, async move |this, cx| {
            let steps: Vec<(SaveJob, Result<pdfcore::SaveReport, persistence::SaveFailure>)> = cx
                .background_executor()
                .spawn(async move {
                    let mut out = Vec::new();
                    run_save_chain(&engine, &save_ctrl, job, |step, res| {
                        out.push((step.clone(), res));
                    });
                    out
                })
                .await;

            this.update_in(cx, |this, window, cx| {
                let mut last_ok = false;
                let mut should_close = false;
                let cur_page = this.scroll.top_item() as i64;
                for (step, res) in steps {
                    should_close |= step.close_after;
                    match res {
                        Ok(report) => {
                            last_ok = true;
                            let saved_path = report.path.clone();
                            let zoom = this
                                .tab_by_doc_id(&doc_id_owned)
                                .map(|t| t.zoom)
                                .unwrap_or(1.0);
                            if let Some(tab) = this.tab_by_doc_id_mut(&doc_id_owned)
                                && tab.save_ctrl.doc_gen() == step.doc_gen
                            {
                                tab.path = saved_path.clone();
                            }
                            this.refresh_doc_meta(&doc_id_owned);
                            config.touch_recent(&saved_path, cur_page, zoom);
                            this.set_status(format!(
                                "saved {} ({} bytes, {} annotations{})",
                                saved_path,
                                report.bytes_written,
                                report.annotation_count,
                                if report.incremental { ", incremental" } else { "" }
                            ));
                        }
                        Err(failure) => {
                            last_ok = false;
                            if failure.kind == SaveErrorKind::DestinationExists && !step.is_autosave {
                                this.open_save_as_overwrite_dialog(
                                    &doc_id_owned,
                                    step.path.clone(),
                                    window,
                                    cx,
                                );
                            } else {
                                let title = match failure.kind {
                                    SaveErrorKind::ExternalChange => "External Change Detected",
                                    SaveErrorKind::Unverified => "Target Unverified",
                                    SaveErrorKind::DestinationExists => "Destination Exists",
                                    SaveErrorKind::ReadOnly => "Read-Only Document",
                                    SaveErrorKind::Other => "Save Failed",
                                };
                                this.push_error(title, failure.message, window, cx);
                            }
                        }
                    }
                }
                if should_close && last_ok {
                    if let Some(idx) = this.index_by_doc_id(&doc_id_owned) {
                        this.finish_close_tab(idx, false, cx);
                    }
                }
                cx.notify();
                window.refresh();
            })
            .ok();
        })
        .detach();
    }

    fn schedule_autosave(&mut self, doc_id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(tab) = self.tab_by_doc_id(doc_id) else { return };
        if tab.path.is_empty() {
            return;
        }
        let save_ctrl = tab.save_ctrl.clone();
        let seq = save_ctrl.bump_autosave_seq();
        let doc_gen = save_ctrl.doc_gen();
        let doc_id_owned = doc_id.to_string();
        let engine = self.engine.clone();

        cx.spawn_in(window, async move |this, cx| {
            cx.background_executor().timer(AUTO_SAVE_DELAY).await;
            for attempt in 0..=UNVERIFIED_AUTOSAVE_RETRIES {
                if save_ctrl.current_autosave_seq() != seq || save_ctrl.doc_gen() != doc_gen {
                    return;
                }
                let state = this.read_with(cx, |this, _| {
                    let tab = this.tab_by_doc_id(&doc_id_owned)?;
                    if tab.save_ctrl.doc_gen() != doc_gen
                        || tab.save_ctrl.current_autosave_seq() != seq
                    {
                        return None;
                    }
                    Some((tab.path.clone(), tab.dirty))
                });
                let Ok(Some((path, dirty))) = state else {
                    return;
                };

                // Run SHA-256 disk verification off the UI thread.
                let engine_check = engine.clone();
                let id_check = doc_id_owned.clone();
                let path_check = path.clone();
                let ctrl_check = save_ctrl.clone();
                let decision = cx
                    .background_executor()
                    .spawn(async move {
                        autosave_eligibility(&engine_check, &id_check, &path_check, dirty, &ctrl_check)
                    })
                    .await;

                if save_ctrl.current_autosave_seq() != seq || save_ctrl.doc_gen() != doc_gen {
                    return;
                }

                match decision {
                    AutosaveDecision::QuietSkip => return,
                    AutosaveDecision::Eligible => {
                        let _ = this.update_in(cx, |this, window, cx| {
                            let Some(tab) = this.tab_by_doc_id(&doc_id_owned) else {
                                return;
                            };
                            if tab.save_ctrl.doc_gen() != doc_gen
                                || tab.save_ctrl.current_autosave_seq() != seq
                            {
                                return;
                            }
                            this.enqueue_save_for_doc(
                                &doc_id_owned,
                                path,
                                SaveOptions { overwrite_existing_destination: false },
                                true,
                                false,
                                window,
                                cx,
                            );
                        });
                        return;
                    }
                    AutosaveDecision::RefuseExternalChange => {
                        let _ = this.update_in(cx, |this, window, cx| {
                            save_ctrl.record_autosave_refusal(
                                &path,
                                doc_gen,
                                SaveErrorKind::ExternalChange,
                                MSG_AUTOSAVE_CHANGED.to_string(),
                            );
                            this.push_error("Autosave Skipped", MSG_AUTOSAVE_CHANGED, window, cx);
                            cx.notify();
                            window.refresh();
                        });
                        return;
                    }
                    AutosaveDecision::RetryUnverified => {
                        if attempt >= UNVERIFIED_AUTOSAVE_RETRIES {
                            let _ = this.update_in(cx, |this, window, cx| {
                                save_ctrl.record_autosave_refusal(
                                    &path,
                                    doc_gen,
                                    SaveErrorKind::Unverified,
                                    MSG_AUTOSAVE_PAUSED_UNVERIFIED.to_string(),
                                );
                                this.push_error(
                                    "Autosave Paused",
                                    MSG_AUTOSAVE_PAUSED_UNVERIFIED,
                                    window,
                                    cx,
                                );
                                cx.notify();
                                window.refresh();
                            });
                            return;
                        }
                        let engine_bg = engine.clone();
                        let id_bg = doc_id_owned.clone();
                        let _ = cx
                            .background_executor()
                            .spawn(async move {
                                let _ = engine_bg.establish_baseline(&id_bg);
                            })
                            .await;
                        cx.background_executor().timer(AUTO_SAVE_DELAY).await;
                    }
                }
            }
        })
        .detach();
    }

    // ---- tool interactions ------------------------------------------------

    fn mouse_to_page_pt(
        &self,
        page: i64,
        mouse: gpui_kit::Point<gpui_kit::Pixels>,
        zoom: f32,
    ) -> Option<(f64, f64)> {
        let _tab = self.tab()?;
        let origin = self.scroll.bounds().origin - self.scroll.offset();
        let item = self.scroll.bounds_for_item(page as usize)?;
        let scale = zoom.max(1e-3) as f64;
        let x = (mouse.x.as_f32() - origin.x.as_f32() - item.origin.x.as_f32()) as f64 / scale;
        let y = (mouse.y.as_f32() - origin.y.as_f32() - item.origin.y.as_f32()) as f64 / scale;
        Some((x, y))
    }

    fn hit_test_annotation(
        anns: &[Annotation],
        x: f64,
        y: f64,
        sticky_only: bool,
        zoom: f32,
    ) -> Option<(i64, i64, String)> {
        let badge_pt = 22.0 / zoom.max(0.25) as f64;
        for a in anns {
            let is_note = a.subtype.contains("Note") || a.subtype == "Text";
            if sticky_only && !is_note {
                continue;
            }
            let hit = if is_note {
                // Note icon badge is rendered at 22×22 px anchored near rect top-left.
                let x1 = a.rect.x1.max(a.rect.x0 + badge_pt);
                let y1 = a.rect.y1.max(a.rect.y0 + badge_pt);
                x >= a.rect.x0 - 2.0 && x <= x1 + 2.0 && y >= a.rect.y0 - 2.0 && y <= y1 + 2.0
            } else if !a.quad_rects.is_empty() {
                a.quad_rects
                    .iter()
                    .any(|r| x >= r.x0 && x <= r.x1 && y >= r.y0 && y <= r.y1)
            } else {
                x >= a.rect.x0 && x <= a.rect.x1 && y >= a.rect.y0 && y <= a.rect.y1
            };
            if hit {
                return Some((a.page, a.index, a.contents.clone()));
            }
        }
        None
    }

    fn handle_page_down(
        &mut self,
        page: i64,
        ev: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.focus_handle.focus(window, cx);
        let Some(tab) = self.tab() else { return };
        let zoom = tab.zoom;
        let Some((x, y)) = self.mouse_to_page_pt(page, ev.position, zoom) else {
            return;
        };
        match self.tool {
            Tool::Select => {
                self.drag_origin = Some((page, ev.position));
                self.drag_moved = false;
                let anns = self.anns_for(page);
                if let Some((ap, ai, contents)) = Self::hit_test_annotation(&anns, x, y, true, zoom)
                {
                    self.drag_origin = None;
                    if let Some(tab) = self.tab_mut() {
                        tab.selected_annot = Some((ap, ai));
                        tab.sel_blocks.clear();
                        tab.sel_anchor = None;
                        tab.sel_page = -1;
                    }
                    self.note_editing = Some((ap, ai));
                    self.sidebar = Sidebar::Notes;
                    self.note_input.update(cx, |s, cx| s.set_value(contents, window, cx));
                    self.set_status(format!("selected note on page {}", page + 1));
                    cx.notify();
                    return;
                }

                let blocks = match self.blocks_for(page) {
                    Ok(b) => b,
                    Err(_) => return,
                };
                let hit = blocks.iter().position(|b| {
                    x >= b.rect.x0 && x <= b.rect.x1 && y >= b.rect.y0 && y <= b.rect.y1
                });
                if let Some(idx) = hit {
                    self.dragging_sel = true;
                    if let Some(tab) = self.tab_mut() {
                        tab.selected_annot = None;
                        tab.sel_page = page;
                        tab.sel_anchor = Some(idx);
                        tab.sel_blocks = vec![idx];
                        self.set_status("selected 1 text line — drag to extend, Copy / Highlight / Underline / Strike");
                    }
                } else if let Some((ap, ai, contents)) =
                    Self::hit_test_annotation(&anns, x, y, false, zoom)
                {
                    self.drag_origin = None;
                    if let Some(tab) = self.tab_mut() {
                        tab.selected_annot = Some((ap, ai));
                        tab.sel_blocks.clear();
                        tab.sel_anchor = None;
                        tab.sel_page = -1;
                    }
                    self.note_editing = Some((ap, ai));
                    self.note_input.update(cx, |s, cx| s.set_value(contents, window, cx));
                    self.set_status(format!("selected annotation on page {} (click color or Delete)", page + 1));
                } else if let Some(tab) = self.tab_mut() {
                    tab.sel_blocks.clear();
                    tab.sel_anchor = None;
                    tab.sel_page = -1;
                    tab.selected_annot = None;
                }
            }
            Tool::Note => {
                self.drag_origin = None;
                self.add_note_at(page, x, y, window, cx);
                self.tool = Tool::Select;
            }
        }
        cx.notify();
    }

    fn handle_page_move(&mut self, page: i64, ev: &MouseMoveEvent, cx: &mut Context<Self>) {
        if let Some((_, origin)) = self.drag_origin {
            let dx = (ev.position.x.as_f32() - origin.x.as_f32()).abs();
            let dy = (ev.position.y.as_f32() - origin.y.as_f32()).abs();
            if dx > 4.0 || dy > 4.0 {
                self.drag_moved = true;
            }
        }
        if !self.dragging_sel {
            return;
        }
        let Some(tab) = self.tab() else { return };
        if tab.sel_page != page {
            return;
        }
        let (Some(anchor), zoom) = (tab.sel_anchor, tab.zoom) else { return };
        let Some((x, y)) = self.mouse_to_page_pt(page, ev.position, zoom) else {
            return;
        };
        let Some(blocks) = tab.blocks.get(&page) else { return };
        let hit = blocks.iter().position(|b| {
            x >= b.rect.x0 && x <= b.rect.x1 && y >= b.rect.y0 && y <= b.rect.y1
        });
        if let Some(idx) = hit {
            let (lo, hi) = if anchor <= idx { (anchor, idx) } else { (idx, anchor) };
            let next: Vec<usize> = (lo..=hi).collect();
            let n = next.len();
            if let Some(tab) = self.tab_mut()
                && tab.sel_blocks != next
            {
                tab.sel_blocks = next;
                self.set_status(format!("selected {n} line(s) — Copy / Highlight / Underline / Strike"));
                cx.notify();
            }
        }
    }

    fn handle_mouse_up(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let was_click = !self.drag_moved;
        let origin = self.drag_origin.take();
        self.dragging_sel = false;
        self.drag_moved = false;

        if was_click
            && self.tool == Tool::Select
            && let Some((page, pos)) = origin
            && let Some(zoom) = self.tab().map(|t| t.zoom)
            && let Some((x, y)) = self.mouse_to_page_pt(page, pos, zoom)
        {
            let anns = self.anns_for(page);
            if let Some((ap, ai, contents)) = Self::hit_test_annotation(&anns, x, y, false, zoom) {
                if let Some(tab) = self.tab_mut() {
                    tab.selected_annot = Some((ap, ai));
                    tab.sel_blocks.clear();
                    tab.sel_anchor = None;
                    tab.sel_page = -1;
                }
                self.note_editing = Some((ap, ai));
                self.note_input.update(cx, |s, cx| s.set_value(contents, window, cx));
                self.set_status(format!(
                    "selected annotation on page {} (click color or Delete)",
                    page + 1
                ));
                cx.notify();
            }
        }
    }

    fn handle_key_down(&mut self, ev: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let cmd = ev.keystroke.modifiers.platform || ev.keystroke.modifiers.control;
        if !cmd {
            return;
        }
        let shift = ev.keystroke.modifiers.shift;
        let input_focused = window.has_focused_input(cx);
        match ev.keystroke.key.as_str() {
            "o" => self.open_dialog(window, cx),
            "w" if !self.empty => self.request_close_tab(self.active, window, cx),
            "s" if !self.empty => self.save(shift, window, cx),
            "z" if !input_focused && !self.empty => self.undo_redo(shift, window, cx),
            "c" if !input_focused && !self.empty => self.copy_selection(cx),
            "f" if !self.empty => {
                self.sidebar = if self.sidebar == Sidebar::Search {
                    Sidebar::Hidden
                } else {
                    Sidebar::Search
                };
                if self.sidebar == Sidebar::Search {
                    self.search_input.focus_handle(cx).focus(window, cx);
                }
                cx.notify();
            }
            "h" if shift && !self.empty => self.apply_markup(MarkupKind::Highlight, window, cx),
            "u" if shift && !self.empty => self.apply_markup(MarkupKind::Underline, window, cx),
            "n" if shift && !self.empty => self.add_note_at_selection_or_page(window, cx),
            "0" if !self.empty => self.set_zoom(1.0, cx),
            "9" if !self.empty => self.fit_width(cx),
            "backspace" if !input_focused && !self.empty => {
                if let Some((page, index)) = self.tab().and_then(|t| t.selected_annot) {
                    self.delete_note(page, index, window, cx);
                }
            }
            "enter" if self.sidebar == Sidebar::Notes && self.note_editing.is_some() => {
                self.save_note(window, cx);
            }
            _ => return,
        }
        cx.stop_propagation();
    }
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

impl Render for Viewer {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.empty {
            return self.render_empty(cx).into_any_element();
        }
        self.ensure_visible_pages(window, cx);

        let theme = cx.theme().clone();
        let tabs_bar = self.render_tabs(cx);
        let toolbar = self.render_toolbar(&theme, cx);
        let page_area = self.render_pages(&theme, cx);
        let status_bar = self.render_status(&theme);

        div()
            .id("yopdf-root")
            .track_focus(&self.focus_handle)
            .on_key_down(cx.listener(|this, ev: &KeyDownEvent, window, cx| {
                this.handle_key_down(ev, window, cx);
            }))
            .on_mouse_up(
                gpui_kit::MouseButton::Left,
                cx.listener(|this, _ev: &MouseUpEvent, window, cx| {
                    this.handle_mouse_up(window, cx);
                }),
            )
            .v_flex()
            .size_full()
            .bg(theme.background)
            .text_color(theme.foreground)
            .child(tabs_bar)
            .child(toolbar)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_1()
                    .min_h_0()
                    .child(page_area)
                    .children(self.render_sidebar(&theme, cx)),
            )
            .child(status_bar)
            .into_any_element()
    }
}

impl Viewer {
    fn render_empty(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let recents = self.config.recents();
        let recent_rows: Vec<AnyElement> = recents
            .into_iter()
            .map(|r| {
                let p = r.path.clone();
                let name = std::path::Path::new(&p)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| p.clone());
                div()
                    .id(SharedString::from(format!("recent-{p}")))
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap_3()
                    .px_3()
                    .py_1p5()
                    .rounded_sm()
                    .cursor_pointer()
                    .hover(|s| s.bg(theme.secondary))
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(move |this, _, window, cx| {
                            if let Err(e) = this.open_path(&p, window, cx) {
                                this.push_error("Open failed", format!("{e}"), window, cx);
                            }
                            window.refresh();
                        }),
                    )
                    .child(
                        div()
                            .text_size(px(13.0))
                            .text_color(theme.foreground)
                            .child(name),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(theme.muted_foreground)
                            .child(r.path),
                    )
                    .into_any_element()
            })
            .collect();

        div()
            .id("yopdf-empty")
            .track_focus(&self.focus_handle)
            .on_key_down(cx.listener(|this, ev: &KeyDownEvent, window, cx| {
                this.handle_key_down(ev, window, cx);
            }))
            .v_flex()
            .size_full()
            .items_center()
            .justify_center()
            .gap_3()
            .bg(theme.background)
            .text_color(theme.foreground)
            .child(
                div()
                    .text_size(px(18.0))
                    .text_color(theme.muted_foreground)
                    .child("YoPDF"),
            )
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(theme.muted_foreground)
                    .child("Open a PDF to get started"),
            )
            .child(
                Button::new("open-empty")
                    .primary()
                    .label("Open PDF…")
                    .on_click(cx.listener(|this, _, window, cx| this.open_dialog(window, cx))),
            )
            .when(!recent_rows.is_empty(), |el| {
                el.child(
                    div()
                        .v_flex()
                        .w(px(460.0))
                        .mt_4()
                        .p_2()
                        .gap_1()
                        .rounded_md()
                        .border_1()
                        .border_color(theme.border)
                        .child(
                            div()
                                .px_2()
                                .pb_1()
                                .text_size(px(11.0))
                                .text_color(theme.muted_foreground)
                                .child("Recent Documents"),
                        )
                        .children(recent_rows),
                )
            })
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(theme.muted_foreground)
                    .child(self.status.clone()),
            )
    }

    fn render_tabs(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme().clone();
        let tabs: Vec<Tab> = self
            .tabs
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let dirty = if t.dirty { " •" } else { "" };
                Tab::new()
                    .label(format!("{}{}", t.label(), dirty))
                    .suffix(
                        Button::new(SharedString::from(format!("tab-close-{i}")))
                            .xsmall()
                            .ghost()
                            .label("×")
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.request_close_tab(i, window, cx);
                            })),
                    )
            })
            .collect();
        div()
            .flex()
            .flex_row()
            .items_center()
            .px_2()
            .h(px(36.0))
            .bg(theme.secondary)
            .border_b_1()
            .border_color(theme.border)
            .child(
                TabBar::new("doc-tabs")
                    .selected_index(self.active)
                    .on_click(cx.listener(|this, idx: &usize, _window, cx| {
                        this.active = *idx;
                        this.note_editing = None;
                        cx.notify();
                    }))
                    .children(tabs),
            )
            .into_any_element()
    }

    fn render_toolbar(&mut self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let tool_select = self.tool == Tool::Select;
        let sidebar_search = self.sidebar == Sidebar::Search;
        let sidebar_notes = self.sidebar == Sidebar::Notes;

        let (has_sel, can_undo, can_redo, saving, dirty, save_state) = self
            .tab()
            .map(|t| {
                (
                    t.sel_page >= 0 && !t.sel_blocks.is_empty(),
                    t.info.can_undo,
                    t.info.can_redo,
                    t.save_ctrl.has_pending(),
                    t.dirty,
                    t.save_ctrl.snapshot(),
                )
            })
            .unwrap_or((false, false, false, false, false, SaveState::Idle));

        let active_hex = self.config.markup_color(self.active_markup);
        let swatches: Vec<AnyElement> = PRESET_MARKUP_COLORS
            .iter()
            .map(|(name, hex)| {
                let hex_owned = (*hex).to_string();
                let selected = active_hex.eq_ignore_ascii_case(hex);
                div()
                    .id(SharedString::from(format!("swatch-{name}")))
                    .w(px(16.0))
                    .h(px(16.0))
                    .rounded_full()
                    .cursor_pointer()
                    .bg(hsla(hex_to_rgba_u32(hex, 0xFF)))
                    .border_2()
                    .border_color(if selected {
                        theme.foreground
                    } else {
                        hsla(0x00000022)
                    })
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(move |this, _, window, cx| {
                            this.select_color_swatch(&hex_owned, window, cx);
                        }),
                    )
                    .into_any_element()
            })
            .collect();

        let (autosave_label, autosave_danger) = match &save_state {
            SaveState::Saving { .. } | SaveState::Queued { .. } => ("Saving…", false),
            SaveState::Failed { .. } => ("⚠ Auto-save failed", true),
            SaveState::Succeeded(_) if !dirty => ("Saved", false),
            _ if dirty => ("Edited", false),
            _ => ("", false),
        };

        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .px_2()
            .h(px(44.0))
            .border_b_1()
            .border_color(theme.border)
            .bg(theme.secondary)
            .child(
                Button::new("open")
                    .label("Open…")
                    .on_click(cx.listener(|this, _, window, cx| this.open_dialog(window, cx))),
            )
            .child(
                Button::new("save")
                    .label("Save")
                    .on_click(cx.listener(|this, _, window, cx| this.save(false, window, cx))),
            )
            .child(
                Button::new("save-as")
                    .label("Save As…")
                    .on_click(cx.listener(|this, _, window, cx| this.save(true, window, cx))),
            )
            .child(separator(theme))
            .child(
                Button::new("undo")
                    .label("↶")
                    .disabled(!can_undo || saving)
                    .on_click(cx.listener(|this, _, window, cx| this.undo_redo(false, window, cx))),
            )
            .child(
                Button::new("redo")
                    .label("↷")
                    .disabled(!can_redo || saving)
                    .on_click(cx.listener(|this, _, window, cx| this.undo_redo(true, window, cx))),
            )
            .child(separator(theme))
            .child(
                Button::new("tool-select")
                    .label(if tool_select { "✋ Select·" } else { "✋ Select" })
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.tool = Tool::Select;
                        cx.notify();
                    })),
            )
            .child(
                Button::new("tool-note")
                    .label(if self.tool == Tool::Note { "📌 Note·" } else { "📌 Note" })
                    .disabled(saving)
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.tool = Tool::Note;
                        cx.notify();
                    })),
            )
            .child(
                Button::new("copy-sel")
                    .label("Copy")
                    .disabled(!has_sel)
                    .on_click(cx.listener(|this, _, _window, cx| this.copy_selection(cx))),
            )
            .child(
                Button::new("highlight-sel")
                    .label("Highlight")
                    .disabled(!has_sel || saving)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.apply_markup(MarkupKind::Highlight, window, cx)
                    })),
            )
            .child(
                Button::new("underline-sel")
                    .label("U̲")
                    .disabled(!has_sel || saving)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.apply_markup(MarkupKind::Underline, window, cx)
                    })),
            )
            .child(
                Button::new("strike-sel")
                    .label("S̶")
                    .disabled(!has_sel || saving)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.apply_markup(MarkupKind::StrikeOut, window, cx)
                    })),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .px_1()
                    .children(swatches),
            )
            .child(separator(theme))
            .child(
                Button::new("zoom-out")
                    .label("−")
                    .on_click(cx.listener(|this, _, _window, cx| this.zoom_by(1.0 / ZOOM_STEP, cx))),
            )
            .child(
                Button::new("zoom-fit")
                    .label("Fit")
                    .on_click(cx.listener(|this, _, _window, cx| this.fit_width(cx))),
            )
            .child(
                Button::new("zoom-in")
                    .label("+")
                    .on_click(cx.listener(|this, _, _window, cx| this.zoom_by(ZOOM_STEP, cx))),
            )
            .child(
                div()
                    .min_w(px(40.0))
                    .text_size(px(12.0))
                    .text_color(theme.muted_foreground)
                    .child(
                        self.tab()
                            .map(|t| format!("{:.0}%", t.zoom * 100.0))
                            .unwrap_or_default(),
                    ),
            )
            .child(div().flex_1())
            .when(!autosave_label.is_empty(), |el| {
                el.child(
                    div()
                        .px_2()
                        .text_size(px(11.0))
                        .text_color(if autosave_danger {
                            theme.danger
                        } else {
                            theme.muted_foreground
                        })
                        .child(autosave_label),
                )
            })
            .child(
                Button::new("toggle-search")
                    .label(if sidebar_search { "🔍 Search·" } else { "🔍 Search" })
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.sidebar = if this.sidebar == Sidebar::Search {
                            Sidebar::Hidden
                        } else {
                            Sidebar::Search
                        };
                        cx.notify();
                    })),
            )
            .child(
                Button::new("toggle-notes")
                    .label(if sidebar_notes { "📝 Notes·" } else { "📝 Notes" })
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.sidebar = if this.sidebar == Sidebar::Notes {
                            Sidebar::Hidden
                        } else {
                            Sidebar::Notes
                        };
                        cx.notify();
                    })),
            )
            .child(
                Button::new("toggle-theme")
                    .label(if theme.mode == ThemeMode::Dark { "☀ Light" } else { "🌙 Dark" })
                    .on_click(cx.listener(|this, _, _window, cx| {
                        let next = if cx.theme().mode == ThemeMode::Dark {
                            ThemeMode::Light
                        } else {
                            ThemeMode::Dark
                        };
                        this.config.set_dark_mode(if next == ThemeMode::Dark {
                            "dark"
                        } else {
                            "light"
                        });
                        Theme::change(next, None, cx);
                        this.set_status("theme changed");
                        cx.notify();
                    })),
            )
            .into_any_element()
    }

    fn render_pages(&mut self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let (zoom, count) = (
            self.tab().map(|t| t.zoom).unwrap_or(1.0),
            self.tab().map(|t| t.info.page_count).unwrap_or(0),
        );
        let mut sel_page = -1i64;
        let mut sel_blocks: Vec<usize> = vec![];
        let mut selected_annot: Option<(i64, i64)> = None;
        let mut search_rects: HashMap<i64, Vec<Rect>> = HashMap::new();
        let mut search_active_hit: Option<(i64, usize)> = None;
        if let Some(tab) = self.tab() {
            sel_page = tab.sel_page;
            sel_blocks = tab.sel_blocks.clone();
            selected_annot = tab.selected_annot;
            if let Some(s) = tab.search.as_ref() {
                search_rects = s.rects.clone();
                if let Some(m) = s.matches.get(s.active) {
                    search_active_hit = Some((m.page, s.active));
                }
            }
        }
        let anns_by_page: HashMap<i64, Vec<Annotation>> = (0..count)
            .map(|p| (p, self.anns_for(p)))
            .filter(|(_, a)| !a.is_empty())
            .collect();

        let pages: Vec<AnyElement> = (0..count)
            .map(|page| {
                let w = self
                    .tab()
                    .map(|t| t.page_w(page, zoom))
                    .unwrap_or(612.0 * zoom);
                let h = self
                    .tab()
                    .map(|t| t.page_h(page, zoom))
                    .unwrap_or(792.0 * zoom);
                let raster = self
                    .tab()
                    .and_then(|t| t.images.get(&page))
                    .map(|pi| pi.img.clone());
                let busy = self.tab().map(|t| t.pending.contains(&page)).unwrap_or(false);
                let zf = zoom as f64;

                let mut page_div = div()
                    .id(SharedString::from(format!("page-{page}")))
                    .relative()
                    .w(px(w))
                    .h(px(h))
                    .mx_auto()
                    .mt(px(if page == 0 { PAGE_MARGIN } else { PAGE_GAP }))
                    .mb(px(PAGE_GAP))
                    .rounded_sm()
                    .overflow_hidden()
                    .bg(gpui_kit::white())
                    .shadow_lg()
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                            this.handle_page_down(page, ev, window, cx);
                        }),
                    )
                    .on_mouse_move(cx.listener(move |this, ev: &MouseMoveEvent, _window, cx| {
                        this.handle_page_move(page, ev, cx);
                    }));

                if let Some(raster_img) = raster.clone() {
                    page_div = page_div.child(img(raster_img).absolute().top_0().left_0().w(px(w)).h(px(h)));
                } else {
                    page_div = page_div.child(
                        div()
                            .absolute()
                            .top_0()
                            .left_0()
                            .size_full()
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_color(theme.muted_foreground)
                            .child(if busy { "rendering…" } else { "…" }),
                    );
                }

                // Overlay: search hits (light blue, active solid blue).
                if let Some(rects) = search_rects.get(&page) {
                    for (i, r) in rects.iter().enumerate() {
                        let active = search_active_hit == Some((page, i));
                        page_div = page_div.child(
                            div()
                                .absolute()
                                .left(px((r.x0 * zf) as f32))
                                .top(px((r.y0 * zf) as f32))
                                .w(px(((r.x1 - r.x0) * zf) as f32))
                                .h(px(((r.y1 - r.y0) * zf) as f32))
                                .rounded_xs()
                                .bg(if active {
                                    hsla(0x2563eb99)
                                } else {
                                    hsla(0x93c5fd66)
                                }),
                        );
                    }
                }
                // Overlay: selected text blocks (indigo).
                if sel_page == page {
                    let blocks = self.tab().and_then(|t| t.blocks.get(&page)).cloned();
                    if let Some(blocks) = blocks {
                        for i in &sel_blocks {
                            if let Some(b) = blocks.get(*i) {
                                page_div = page_div.child(
                                    div()
                                        .absolute()
                                        .left(px((b.rect.x0 * zf) as f32))
                                        .top(px((b.rect.y0 * zf) as f32))
                                        .w(px(((b.rect.x1 - b.rect.x0) * zf) as f32))
                                        .h(px(((b.rect.y1 - b.rect.y0) * zf) as f32))
                                        .rounded_xs()
                                        .bg(hsla(0x6366f155)),
                                );
                            }
                        }
                    }
                }
                // Overlay: annotations (quad-accurate Highlight/Underline/StrikeOut + Note badges).
                if let Some(anns) = anns_by_page.get(&page) {
                    for a in anns {
                        let is_selected = selected_annot == Some((a.page, a.index));
                        let is_note = a.subtype.contains("Note") || a.subtype == "Text";
                        if is_note {
                            let bg = a
                                .color
                                .map(|c| rgb_to_rgba_u32(c, 0xEE))
                                .unwrap_or(0xFFD60AEE);
                            page_div = page_div.child(
                                div()
                                    .absolute()
                                    .left(px((a.rect.x0 * zf) as f32))
                                    .top(px((a.rect.y0 * zf) as f32))
                                    .w(px(22.0))
                                    .h(px(22.0))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .rounded_sm()
                                    .bg(hsla(bg))
                                    .border_2()
                                    .border_color(if is_selected {
                                        hsla(0x2563EBFF)
                                    } else {
                                        hsla(0x00000033)
                                    })
                                    .text_size(px(12.0))
                                    .child("📝"),
                            );
                        } else {
                            let rects: Vec<Rect> = if a.quad_rects.is_empty() {
                                vec![a.rect]
                            } else {
                                a.quad_rects.clone()
                            };
                            let default_rgb = match a.subtype.as_str() {
                                "Underline" => [0.0, 0.478, 1.0],
                                "StrikeOut" => [1.0, 0.231, 0.188],
                                _ => [1.0, 0.839, 0.039],
                            };
                            let rgb = a.color.unwrap_or(default_rgb);
                            for r in rects {
                                let left = px((r.x0 * zf) as f32);
                                let top = px((r.y0 * zf) as f32);
                                let rw = px(((r.x1 - r.x0) * zf).max(2.0) as f32);
                                let rh = px(((r.y1 - r.y0) * zf).max(2.0) as f32);
                                match a.subtype.as_str() {
                                    "Underline" => {
                                        page_div = page_div.child(
                                            div()
                                                .absolute()
                                                .left(left)
                                                .top(px(((r.y1 * zf) as f32) - 2.0))
                                                .w(rw)
                                                .h(px(2.0))
                                                .bg(hsla(rgb_to_rgba_u32(rgb, 0xFF))),
                                        );
                                        if is_selected {
                                            page_div = page_div.child(
                                                div()
                                                    .absolute()
                                                    .left(left)
                                                    .top(top)
                                                    .w(rw)
                                                    .h(rh)
                                                    .rounded_xs()
                                                    .border_2()
                                                    .border_color(hsla(0x2563EBFF)),
                                            );
                                        }
                                    }
                                    "StrikeOut" => {
                                        let mid_y = ((r.y0 + r.y1) * 0.5 * zf) as f32;
                                        page_div = page_div.child(
                                            div()
                                                .absolute()
                                                .left(left)
                                                .top(px(mid_y - 1.0))
                                                .w(rw)
                                                .h(px(2.0))
                                                .bg(hsla(rgb_to_rgba_u32(rgb, 0xFF))),
                                        );
                                        if is_selected {
                                            page_div = page_div.child(
                                                div()
                                                    .absolute()
                                                    .left(left)
                                                    .top(top)
                                                    .w(rw)
                                                    .h(rh)
                                                    .rounded_xs()
                                                    .border_2()
                                                    .border_color(hsla(0x2563EBFF)),
                                            );
                                        }
                                    }
                                    _ => {
                                        page_div = page_div.child(
                                            div()
                                                .absolute()
                                                .left(left)
                                                .top(top)
                                                .w(rw)
                                                .h(rh)
                                                .rounded_xs()
                                                .bg(hsla(rgb_to_rgba_u32(rgb, 0x55)))
                                                .when(is_selected, |el| {
                                                    el.border_2().border_color(hsla(0x2563EBFF))
                                                }),
                                        );
                                    }
                                }
                            }
                        }
                    }
                }

                page_div.into_any_element()
            })
            .collect();

        div()
            .id("page-area")
            .flex_1()
            .min_w_0()
            .h_full()
            .overflow_scroll()
            .track_scroll(&self.scroll)
            .bg(theme.secondary)
            .on_scroll(cx.listener(|this, ev: &ScrollEvent, _window, cx| {
                if let ScrollDelta::Pixels(p) = ev.delta
                    && (ev.modifiers.control || ev.modifiers.platform)
                {
                    let factor = if p.y.as_f32() > 0.0 { 1.1 } else { 1.0 / 1.1 };
                    this.zoom_by(factor, cx);
                    cx.stop_propagation();
                }
            }))
            .children(pages)
            .into_any_element()
    }

    fn render_sidebar(&mut self, theme: &Theme, cx: &mut Context<Self>) -> Option<AnyElement> {
        match self.sidebar {
            Sidebar::Hidden => None,
            Sidebar::Search => Some(self.render_search_sidebar(theme, cx).into_any_element()),
            Sidebar::Notes => Some(self.render_notes_sidebar(theme, cx).into_any_element()),
        }
    }

    fn render_search_sidebar(&mut self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let query = self.search_input.read(cx).value().to_string();
        let (matches, active, running) = self
            .tab()
            .and_then(|t| t.search.as_ref().map(|s| (s.matches.clone(), s.active, s.running)))
            .unwrap_or((vec![], 0, false));

        let hits: Vec<AnyElement> = matches
            .iter()
            .enumerate()
            .map(|(i, m)| {
                let is_active = i == active;
                div()
                    .id(SharedString::from(format!("hit-{i}")))
                    .px_2()
                    .py_1()
                    .rounded_sm()
                    .cursor_pointer()
                    .hover(|s| s.bg(theme.accent))
                    .bg(if is_active { theme.accent } else { hsla(0x00000000) })
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(move |this, _ev: &MouseDownEvent, _window, cx| {
                            this.jump_to_match(i, cx);
                        }),
                    )
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(if is_active {
                                theme.accent_foreground
                            } else {
                                theme.foreground
                            })
                            .child(format!("p{} · {}", m.page + 1, m.preview)),
                    )
                    .into_any_element()
            })
            .collect();

        div()
            .v_flex()
            .w(px(280.0))
            .h_full()
            .flex_shrink_0()
            .border_l_1()
            .border_color(theme.border)
            .bg(theme.secondary)
            .child(
                div()
                    .v_flex()
                    .gap_2()
                    .p_2()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap_1()
                            .items_center()
                            .child(div().flex_1().child(Input::new(&self.search_input).small()))
                            .child(
                                Button::new("do-search")
                                    .label("Go")
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        let q = this.search_input.read(cx).value().to_string();
                                        this.run_search(q, window, cx);
                                    })),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(theme.muted_foreground)
                            .child(if running {
                                "searching…".to_string()
                            } else {
                                format!("{} hits for “{}”", matches.len(), query)
                            }),
                    ),
            )
            .child(
                div()
                    .id("search-hits")
                    .flex_1()
                    .min_h_0()
                    .overflow_scroll()
                    .v_flex()
                    .p_1()
                    .gap_1()
                    .children(hits),
            )
            .into_any_element()
    }

    fn render_notes_sidebar(&mut self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let anns = self.all_anns();
        let editing = self.note_editing;
        let selected_annot = self.tab().and_then(|t| t.selected_annot);
        let saving = self.tab().map(|t| t.save_ctrl.has_pending()).unwrap_or(false);

        let rows: Vec<AnyElement> = anns
            .iter()
            .map(|a| {
                let is_editing = editing == Some((a.page, a.index));
                let is_selected = selected_annot == Some((a.page, a.index));
                let (page, index) = (a.page, a.index);
                let dot_rgba = a
                    .color
                    .map(|c| rgb_to_rgba_u32(c, 0xFF))
                    .unwrap_or(0xFFD60AFF);
                let contents_preview = if a.contents.is_empty() {
                    "(empty)".to_string()
                } else {
                    a.contents.chars().take(200).collect::<String>()
                };
                div()
                    .id(SharedString::from(format!("ann-row-{page}-{index}")))
                    .v_flex()
                    .gap_1()
                    .p_2()
                    .rounded_sm()
                    .mb_1()
                    .border_1()
                    .border_color(if is_editing || is_selected {
                        theme.accent
                    } else {
                        theme.border
                    })
                    .bg(if is_editing || is_selected {
                        hsla(0x6366f111)
                    } else {
                        hsla(0x00000000)
                    })
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_1()
                            .child(div().w(px(8.0)).h(px(8.0)).rounded_full().bg(hsla(dot_rgba)))
                            .child(
                                div()
                                    .flex_1()
                                    .text_size(px(11.0))
                                    .text_color(theme.muted_foreground)
                                    .child(format!(
                                        "{}{} · p{} · {}",
                                        if a.locked { "🔒 " } else { "" },
                                        a.subtype,
                                        a.page + 1,
                                        a.author
                                    )),
                            )
                            .child(
                                Button::new(SharedString::from(format!("note-edit-{page}-{index}")))
                                    .xsmall()
                                    .label("edit")
                                    .disabled(saving || a.locked)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.note_editing = Some((page, index));
                                        if let Some(tab) = this.tab_mut() {
                                            tab.selected_annot = Some((page, index));
                                        }
                                        let contents = this
                                            .all_anns()
                                            .into_iter()
                                            .find(|a| a.page == page && a.index == index)
                                            .map(|a| a.contents)
                                            .unwrap_or_default();
                                        this.note_input.update(cx, |state, cx| {
                                            state.set_value(contents, window, cx);
                                        });
                                        this.note_input.focus_handle(cx).focus(window, cx);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new(SharedString::from(format!("note-del-{page}-{index}")))
                                    .xsmall()
                                    .danger()
                                    .label("del")
                                    .disabled(saving || a.locked)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.delete_note(page, index, window, cx);
                                    })),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(theme.foreground)
                            .child(contents_preview),
                    )
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                            if let Some(tab) = this.tab_mut() {
                                tab.selected_annot = Some((page, index));
                            }
                            if ev.click_count >= 2 {
                                this.goto_page(page, window, cx);
                            }
                            cx.notify();
                        }),
                    )
                    .into_any_element()
            })
            .collect();

        div()
            .v_flex()
            .w(px(280.0))
            .h_full()
            .flex_shrink_0()
            .border_l_1()
            .border_color(theme.border)
            .bg(theme.secondary)
            .child(
                div()
                    .v_flex()
                    .gap_2()
                    .p_2()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(theme.muted_foreground)
                            .child(format!("{} annotations", anns.len())),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap_1()
                            .items_center()
                            .child(div().flex_1().child(Input::new(&self.note_input)))
                            .child(
                                Button::new("save-note")
                                    .label("Save")
                                    .disabled(editing.is_none() || saving)
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.save_note(window, cx)
                                    })),
                            ),
                    ),
            )
            .child(
                div()
                    .id("notes-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_scroll()
                    .v_flex()
                    .p_1()
                    .children(rows),
            )
            .into_any_element()
    }

    fn render_status(&self, theme: &Theme) -> AnyElement {
        let page_info = self.tab().map(|t| {
            let page = self.scroll.top_item() as i64 + 1;
            format!(
                "{}/{} p · {} · {}%{}",
                page,
                t.info.page_count,
                t.label(),
                (t.zoom * 100.0) as i32,
                if t.dirty { " · unsaved" } else { "" }
            )
        });
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .px_2()
            .h(px(26.0))
            .border_t_1()
            .border_color(theme.border)
            .bg(theme.secondary)
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(theme.muted_foreground)
                    .child(page_info.unwrap_or_default()),
            )
            .child(div().flex_1())
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(theme.muted_foreground)
                    .child(self.status.clone()),
            )
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(theme.muted_foreground)
                    .child(self.info.clone()),
            )
            .into_any_element()
    }

    fn open_dialog(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let task = cx.prompt_for_paths(gpui_kit::PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: None,
        });
        cx.spawn_in(window, async move |this, cx| {
            let picked = task
                .await
                .ok()
                .and_then(|r| r.ok())
                .flatten()
                .and_then(|p| p.into_iter().next());
            let Some(path) = picked else { return };
            this.update_in(cx, |this, window, cx| {
                match this.open_path(&path.to_string_lossy(), window, cx) {
                    Ok(_) => cx.notify(),
                    Err(e) => {
                        this.push_error("Open failed", format!("{e}"), window, cx);
                        cx.notify();
                    }
                }
                window.refresh();
            })
            .ok();
        })
        .detach();
    }
}

fn hsla(hex: u32) -> gpui_kit::Hsla {
    gpui_kit::rgba(hex).into()
}

fn separator(theme: &Theme) -> impl IntoElement {
    div().w(px(1.0)).h(px(20.0)).rounded_full().bg(theme.border)
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

fn main() {
    // Usage: yopdf-gpui [pdf-path] [initial-page (1-based, optional)]
    let mut args = std::env::args().skip(1);
    let path = args.next();
    let initial_page: Option<i64> = args
        .next()
        .and_then(|s| s.parse::<i64>().ok())
        .map(|p| (p - 1).max(0));

    let save_registry = SaveRegistry::new();
    let registry_for_app = save_registry.clone();

    gpui_kit::application()
        .with_assets(gpui_kit::assets::Assets)
        .run(move |cx: &mut App| {
            gpui_kit::init(cx);
            let config = Arc::new(AppConfig::load_default());
            match config.dark_mode().as_str() {
                "dark" => Theme::change(ThemeMode::Dark, None, cx),
                "light" => Theme::change(ThemeMode::Light, None, cx),
                _ => {}
            }

            let bounds = Bounds::centered(None, size(px(1200.0), px(860.0)), cx);
            let options = WindowOptions {
                window_bounds: Some(gpui_kit::WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some(SharedString::from("YoPDF")),
                    ..Default::default()
                }),
                ..Default::default()
            };

            let config_win = Arc::clone(&config);
            let registry_for_win = registry_for_app.clone();
            let (_win_handle, _viewer_entity) = gpui_kit::open_window(options, cx, |window, cx| {
                let search_input =
                    cx.new(|cx| InputState::new(window, cx).placeholder("Search text…"));
                let note_input =
                    cx.new(|cx| InputState::new(window, cx).placeholder("Note contents…"));
                let viewer = cx.new(|cx| {
                    let sub_search = cx.subscribe_in(
                        &search_input,
                        window,
                        |this: &mut Viewer, input, ev: &InputEvent, window, cx| {
                            if let InputEvent::PressEnter { shift, .. } = ev {
                                let q = input.read(cx).value().to_string();
                                let already_matched = this
                                    .tab()
                                    .and_then(|t| t.search.as_ref())
                                    .is_some_and(|s| s.query == q && !s.matches.is_empty());
                                if already_matched {
                                    let (cur, total) = this
                                        .tab()
                                        .and_then(|t| t.search.as_ref())
                                        .map(|s| (s.active, s.matches.len()))
                                        .unwrap_or((0, 0));
                                    if total > 0 {
                                        let next = if *shift {
                                            (cur + total - 1) % total
                                        } else {
                                            (cur + 1) % total
                                        };
                                        this.jump_to_match(next, cx);
                                    }
                                } else {
                                    this.run_search(q, window, cx);
                                }
                            }
                        },
                    );
                    let sub_note = cx.subscribe_in(
                        &note_input,
                        window,
                        |this: &mut Viewer, _input, ev: &InputEvent, window, cx| {
                            if matches!(ev, InputEvent::PressEnter { .. })
                                && this.note_editing.is_some()
                            {
                                this.save_note(window, cx);
                            }
                        },
                    );
                    let mut viewer = Viewer {
                        engine: Arc::new(PdfCore::new()),
                        config: config_win,
                        tabs: Vec::new(),
                        active: 0,
                        tool: Tool::Select,
                        sidebar: Sidebar::Hidden,
                        active_markup: MarkupKind::Highlight,
                        dragging_sel: false,
                        drag_origin: None,
                        drag_moved: false,
                        allow_window_close: false,
                        closing_window: false,
                        save_registry: registry_for_win,
                        search_epoch: 0,
                        cancel: Arc::new(AtomicBool::new(false)),
                        scale_factor: 1.0,
                        scroll: ScrollHandle::new(),
                        focus_handle: cx.focus_handle(),
                        search_input,
                        note_input,
                        note_editing: None,
                        status: "no document — click Open…".into(),
                        info: "".into(),
                        empty: true,
                        _subs: vec![sub_search, sub_note],
                    };
                    if let Some(path) = path.as_deref() {
                        if let Err(e) = viewer.open_path(path, window, cx) {
                            viewer.set_status(format!("open failed: {e}"));
                        }
                        if let Some(page) = initial_page
                            && let Some(tab) = viewer.tab_mut()
                        {
                            tab.pending_jump = Some(page);
                        }
                    }
                    viewer
                });

                let viewer_for_close = viewer.clone();
                window.on_window_should_close(cx, move |window, cx| {
                    let (allow, closing, any_dirty, any_saving) =
                        viewer_for_close.read_with(cx, |v, _| {
                            (
                                v.allow_window_close,
                                v.closing_window,
                                v.tabs.iter().any(|t| t.dirty),
                                v.save_registry.has_pending(),
                            )
                        });
                    if allow {
                        return true;
                    }
                    if closing {
                        return false;
                    }
                    if !any_dirty && !any_saving {
                        return true;
                    }
                    viewer_for_close.update(cx, |this, cx| {
                        this.open_window_close_dialog(window, cx);
                    });
                    false
                });

                viewer
            })
            .expect("failed to open window");

            // Quit-time barrier: wait synchronously before returning the quit
            // future because gpui-pre's App::shutdown() only polls quit futures
            // for SHUTDOWN_TIMEOUT (200 ms). Background save workers never depend
            // on the foreground thread to complete `finish_running`.
            let registry_for_quit = registry_for_app.clone();
            cx.on_app_quit(move |_cx| {
                registry_for_quit.drain_all();
                async {}
            })
            .detach();
        });

    // Belt-and-suspenders drain after the event loop returns before exiting main.
    save_registry.drain_all();
}
