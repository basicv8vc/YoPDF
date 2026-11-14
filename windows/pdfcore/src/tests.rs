//! Rust-level tests of the facade. All writes go to disposable copies in the
//! system temp directory; tracked fixtures are never modified.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use super::*;

static SEQ: AtomicU64 = AtomicU64::new(0);

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures").join(name).canonicalize().expect("fixture exists")
}

fn temp_copy(name: &str, label: &str) -> PathBuf {
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("yopdf-poc-tests-{}-{n}", std::process::id()));
    fs::create_dir_all(&dir).expect("temp dir");
    let out = dir.join(format!("{label}.pdf"));
    fs::copy(fixture(name), &out).expect("copy fixture");
    out
}

fn s(p: &PathBuf) -> String {
    p.to_string_lossy().into_owned()
}

fn never() -> bool {
    false
}

fn first_block_rect(core: &PdfCore, id: &str, page: i64) -> Rect {
    let blocks = core.get_text_blocks(id, page, &never).expect("text blocks");
    assert!(!blocks.is_empty(), "page {page} should have extracted text");
    blocks[0].rect
}

#[test]
fn engine_initialization_reports_pinned_version() {
    let core = PdfCore::new();
    assert_eq!(core.open_count(), 0);
    let v = version_string();
    assert!(v.contains("pdfcraft/v0.20.0@2ad7717f"), "{v}");
}

#[test]
fn open_close_lifecycle_and_error_propagation() {
    let core = PdfCore::new();
    let info = core.open_document(&s(&fixture("multi-page.pdf"))).expect("open");
    assert_eq!(info.page_count, 12);
    assert_eq!(info.title, "YoPDF PoC synthetic fixture");
    assert!(!info.dirty);
    assert_eq!(core.open_count(), 1);

    assert_eq!(core.get_page_info(&info.id, 11).unwrap().page, 11);
    assert_eq!(core.get_page_info(&info.id, 12), Err(CoreError::InvalidPage));
    assert_eq!(core.get_document_info("99999"), Err(CoreError::DocumentNotFound));

    core.close_document(&info.id).expect("close");
    assert_eq!(core.open_count(), 0);
    assert_eq!(core.get_document_info(&info.id), Err(CoreError::DocumentNotFound));
    assert_eq!(core.close_document(&info.id), Err(CoreError::DocumentNotFound));
}

#[test]
fn render_request_returns_a_real_raster() {
    let core = PdfCore::new();
    let info = core.open_document(&s(&fixture("simple-text.pdf"))).unwrap();
    let r = core.render_page(&info.id, 0, 1.5, 42, &never).expect("render");
    assert_eq!(r.tag, 42);
    assert!(r.width >= 918 && r.width <= 920, "unexpected width {}", r.width);
    assert!(r.height >= 1188 && r.height <= 1190, "unexpected height {}", r.height);
    assert_eq!(r.stride, r.width * 4);
    assert_eq!(r.rgba.len(), (r.stride * r.height) as usize);
    // A page with text is not entirely blank/transparent.
    assert!(r.rgba.iter().any(|b| *b != 0), "raster is empty");
}

#[test]
fn render_cancellation_propagates_and_pool_recovers() {
    let core = PdfCore::new();
    let info = core.open_document(&s(&fixture("simple-text.pdf"))).unwrap();
    // Warm up the pool's parser so the second call is a real in-flight render.
    let _ = core.render_page(&info.id, 0, 1.0, 1, &never).unwrap();

    let polls = AtomicU64::new(0);
    let cancel = || polls.fetch_add(1, Ordering::Relaxed) > 2;
    let err = core.render_page(&info.id, 0, 2.0, 2, &cancel).unwrap_err();
    assert_eq!(err, CoreError::Cancelled);

    // The queue was emptied; a fresh request must still be serviced.
    let r = core.render_page(&info.id, 0, 1.0, 3, &never).expect("render after cancel");
    assert_eq!(r.tag, 3);
    core.cancel_renders(&info.id).unwrap();
}

#[test]
fn text_search_selection_and_blocks() {
    let core = PdfCore::new();
    let info = core.open_document(&s(&fixture("simple-text.pdf"))).unwrap();
    let blocks = core.get_text_blocks(&info.id, 0, &never).unwrap();
    assert!(blocks.len() >= 4, "expected several lines, got {}", blocks.len());
    assert!(blocks.iter().any(|b| b.text.contains("ALPHA")));
    let hits = core.search_text(&info.id, "ALPHA", 20, &never).unwrap();
    assert!(hits.len() >= 3, "expected >=3 ALPHA hits, got {}", hits.len());
    let h = &hits[0];
    let selected = core.get_selected_text(&info.id, h.page, h.start, h.end).unwrap();
    assert!(selected.to_uppercase().contains("ALPHA"), "selected={selected:?}");
    assert_eq!(core.get_selected_text(&info.id, 0, 0, 100_000), Err(CoreError::InvalidPage));
}

#[test]
fn annotation_operations_undo_redo_and_editing() {
    let core = PdfCore::new();
    let info = core.open_document(&s(&fixture("simple-text.pdf"))).unwrap();
    let r = first_block_rect(&core, &info.id, 0);

    let h = core.add_highlight(&info.id, 0, &[r], &never).expect("highlight");
    assert_eq!(h.subtype, "Highlight");
    let n = core.add_sticky_note(&info.id, 0, 30.0, 30.0, "PoC note", &never).expect("note");
    assert_eq!(n.subtype, "Text");
    assert_eq!(n.contents, "PoC note");
    assert_eq!(core.list_annotations(&info.id, -1).unwrap().len(), 2);

    core.update_annotation(&info.id, n.page, n.index, "Edited note").unwrap();
    let list = core.list_annotations(&info.id, -1).unwrap();
    assert!(list.iter().any(|a| a.contents == "Edited note"));

    let label = core.undo(&info.id).unwrap();
    assert!(!label.is_empty(), "undo label should name the action");
    assert!(core.list_annotations(&info.id, -1).unwrap().iter().all(|a| a.contents != "Edited note"));
    core.redo(&info.id).unwrap();
    assert!(core.list_annotations(&info.id, -1).unwrap().iter().any(|a| a.contents == "Edited note"));

    let before = core.list_annotations(&info.id, -1).unwrap().len();
    core.delete_annotation(&info.id, h.page, h.index).unwrap();
    assert_eq!(core.list_annotations(&info.id, -1).unwrap().len(), before - 1);
    assert!(core.get_document_info(&info.id).unwrap().dirty);
}

#[test]
fn existing_annotations_survive_edits_and_undo() {
    let core = PdfCore::new();
    let info = core.open_document(&s(&fixture("existing-annotations.pdf"))).unwrap();
    let original = core.list_annotations(&info.id, -1).unwrap();
    assert_eq!(original.len(), 2, "fixture must expose both pre-existing annotations");

    let r = first_block_rect(&core, &info.id, 0);
    core.add_highlight(&info.id, 0, &[r], &never).unwrap();
    core.undo(&info.id).unwrap();
    let after = core.list_annotations(&info.id, -1).unwrap();
    assert_eq!(after.len(), original.len());
    for a in &original {
        assert!(after.iter().any(|x| x.subtype == a.subtype && x.contents == a.contents), "lost {a:?}");
    }
}

#[test]
fn rotated_pages_have_correct_view_geometry_and_accept_highlights() {
    let core = PdfCore::new();
    let info = core.open_document(&s(&fixture("rotated-pages.pdf"))).unwrap();
    assert_eq!(info.page_count, 4);
    let p0 = core.get_page_info(&info.id, 0).unwrap();
    let p1 = core.get_page_info(&info.id, 1).unwrap();
    assert_eq!(p1.rotation, 90);
    assert!((p0.width - p1.height).abs() < 1.0, "90deg rotation must swap width/height");
    let r = Rect { x0: 72.0, y0: 100.0, x1: 300.0, y1: 120.0 };
    core.add_highlight(&info.id, 1, &[r], &never).expect("highlight on rotated page");
    assert_eq!(core.list_annotations(&info.id, 1).unwrap().len(), 1);
}

#[test]
fn cjk_fixture_opens_and_exposes_page_geometry() {
    let core = PdfCore::new();
    let info = core.open_document(&s(&fixture("cjk-text.pdf"))).unwrap();
    assert_eq!(info.page_count, 2);
    // Font substitution is viewer-dependent; extraction must not fail, but the
    // glyph count is intentionally not asserted.
    let _ = core.get_text_blocks(&info.id, 1, &never).expect("CJK text extraction does not fail");
    let raster = core.render_page(&info.id, 1, 1.0, 1, &never).expect("CJK page renders");
    assert!(raster.width > 0 && raster.height > 0);
}

#[test]
fn save_close_reopen_round_trip_is_incremental() {
    let path = temp_copy("simple-text.pdf", "roundtrip");
    let original_bytes = fs::read(&path).unwrap();
    let core = PdfCore::new();

    let info = core.open_document(&s(&path)).unwrap();
    let r = first_block_rect(&core, &info.id, 0);
    core.add_highlight(&info.id, 0, &[r], &never).unwrap();
    let note = core.add_sticky_note(&info.id, 0, 40.0, 40.0, "Round trip note", &never).unwrap();
    core.undo(&info.id).unwrap();   // undoes the sticky note
    core.redo(&info.id).unwrap();   // restores it
    assert!(core.get_document_info(&info.id).unwrap().can_undo);

    let report = core.save_document(&info.id, &s(&path)).expect("incremental save");
    assert!(report.incremental);
    assert!(report.bytes_written > report.original_bytes, "an incremental revision must append bytes");
    assert_eq!(report.annotation_count, 2);
    assert!(!core.get_document_info(&info.id).unwrap().dirty);

    let written = fs::read(&path).unwrap();
    assert_eq!(&written[..original_bytes.len()], &original_bytes[..], "original bytes must be preserved verbatim");

    // Independent check with pdfcraft-cos (the object layer, not the facade):
    // the saved file must carry a real extra xref revision, not a rewrite.
    let cos = pdfcraft_cos::Document::open_with_password(std::sync::Arc::new(written.clone()), None).expect("cos reopens saved PDF");
    assert!(cos.revisions().len() >= 2, "expected an appended revision, got {}", cos.revisions().len());
    let page_count = pdfcraft_render::inspect(std::sync::Arc::new(written), None).expect("render inspection reopens saved PDF").pages.len();
    assert_eq!(page_count, 1);

    core.close_document(&info.id).unwrap();
    let reopened = core.open_document(&s(&path)).unwrap();
    let annots = core.list_annotations(&reopened.id, -1).unwrap();
    assert_eq!(annots.len(), 2, "both annotations must survive reopening");
    assert!(annots.iter().any(|a| a.subtype == "Highlight"));
    assert!(annots.iter().any(|a| a.subtype == "Text" && a.contents == "Round trip note"));
    // Document content is intact, not just the annotations.
    assert!(!core.search_text(&reopened.id, "ALPHA", 5, &never).unwrap().is_empty());
    assert_eq!(note.contents, "Round trip note");
}

#[test]
fn save_refuses_external_changes_and_failed_writes_are_non_destructive() {
    let path = temp_copy("simple-text.pdf", "safety");
    let core = PdfCore::new();
    let info = core.open_document(&s(&path)).unwrap();
    core.add_sticky_note(&info.id, 0, 10.0, 10.0, "x", &never).unwrap();

    let before = fs::read(&path).unwrap();
    // Simulate another program touching the file after we opened it.
    let mut touched = before.clone();
    touched.push(b'%');
    fs::write(&path, &touched).unwrap();
    assert_eq!(core.save_document(&info.id, &s(&path)), Err(CoreError::ExternalChange));
    assert_eq!(fs::read(&path).unwrap(), touched, "refused save must not touch the file");

    // Restore the fingerprint situation with a fresh core, then force an I/O
    // failure by saving into a directory that does not exist.
    let core2 = PdfCore::new();
    let info2 = core2.open_document(&s(&path)).unwrap();
    core2.add_sticky_note(&info2.id, 0, 10.0, 10.0, "y", &never).unwrap();
    let impossible = s(&path).replace("safety.pdf", "no-such-dir/out.pdf");
    assert!(matches!(core2.save_document(&info2.id, &impossible), Err(CoreError::SaveFailed(_))));
    assert_eq!(fs::read(&path).unwrap(), touched, "failed save must not damage the original");
}

#[test]
fn large_document_stays_bounded_while_rendering() {
    let core = PdfCore::new();
    let info = core.open_document(&s(&fixture("large-320p.pdf"))).unwrap();
    assert_eq!(info.page_count, 320);
    // Only a handful of pages are rasterized; no per-page state is accumulated.
    for page in [0i64, 1, 2, 159, 319] {
        let r = core.render_page(&info.id, page, 0.75, page, &never).unwrap_or_else(|e| panic!("page {page}: {e}"));
        assert!(r.rgba.len() > 0);
        assert_eq!(r.tag, page);
    }
    assert_eq!(core.open_count(), 1);
}

#[test]
fn same_size_external_rewrite_is_detected_by_sha256() {
    let path = temp_copy("simple-text.pdf", "same-size");
    let core = PdfCore::new();
    let info = core.open_document(&s(&path)).unwrap();
    core.add_sticky_note(&info.id, 0, 20.0, 20.0, "edit", &never).unwrap();
    assert_eq!(core.disk_verdict(&info.id).unwrap(), DiskVerdict::Matched);

    // Overwrite a comment/byte in-place preserving exact byte length (and
    // mtime if possible; even if mtime matches, SHA-256 catches it).
    let mut bytes = fs::read(&path).unwrap();
    let meta_before = fs::metadata(&path).unwrap();
    let idx = bytes.len() - 1;
    bytes[idx] ^= 0x01;
    fs::write(&path, &bytes).unwrap();
    if let Ok(mtime) = meta_before.modified() {
        let _ = fs::File::options().write(true).open(&path).and_then(|f| f.set_modified(mtime));
    }

    assert_eq!(core.disk_verdict(&info.id).unwrap(), DiskVerdict::Changed);
    assert_eq!(core.save_document(&info.id, &s(&path)), Err(CoreError::ExternalChange));
    assert_eq!(fs::read(&path).unwrap(), bytes, "refused save must not modify disk");
}

#[test]
fn unverified_baseline_or_vanished_target_refuses_save_until_reverified() {
    let path = temp_copy("simple-text.pdf", "unverified");
    let core = PdfCore::new();
    let info = core.open_document(&s(&path)).unwrap();
    core.add_sticky_note(&info.id, 0, 20.0, 20.0, "edit", &never).unwrap();

    // Missing baseline => Unverified => refused.
    core.clear_fingerprint_for_test(&info.id).unwrap();
    assert_eq!(core.disk_verdict(&info.id).unwrap(), DiskVerdict::Unverified);
    assert!(matches!(core.save_document(&info.id, &s(&path)), Err(CoreError::Unverified(_))));

    // Establish baseline => Matched => save succeeds.
    assert_eq!(core.establish_baseline(&info.id).unwrap(), DiskVerdict::Matched);
    core.save_document(&info.id, &s(&path)).expect("save succeeds once baseline lands");

    // Vanished target => Unverified => refused.
    fs::remove_file(&path).unwrap();
    assert_eq!(core.disk_verdict(&info.id).unwrap(), DiskVerdict::Unverified);
    assert!(matches!(core.save_document(&info.id, &s(&path)), Err(CoreError::Unverified(_))));
    assert!(!path.exists(), "must not recreate vanished file on same-path save");
}

#[test]
fn save_as_recovers_from_external_change_and_repoints_future_saves() {
    let orig = temp_copy("simple-text.pdf", "orig-changed");
    let core = PdfCore::new();
    let info = core.open_document(&s(&orig)).unwrap();
    core.add_sticky_note(&info.id, 0, 24.0, 24.0, "rescued", &never).unwrap();

    // Original changes externally.
    let mut touched = fs::read(&orig).unwrap();
    touched.push(b'%');
    fs::write(&orig, &touched).unwrap();
    assert_eq!(core.save_document(&info.id, &s(&orig)), Err(CoreError::ExternalChange));

    // Save As to a fresh path succeeds and re-points the document guard.
    let rescue = orig.with_file_name("rescued.pdf");
    let report = core.save_document(&info.id, &s(&rescue)).expect("save as rescue");
    assert!(report.incremental);
    assert_eq!(fs::read(&orig).unwrap(), touched, "original untouched by Save As");

    // Further edits + same-path Save now target `rescue` (would previously fail!).
    core.add_sticky_note(&info.id, 0, 48.0, 48.0, "second edit", &never).unwrap();
    let report2 = core.save_document(&info.id, &s(&rescue)).expect("subsequent save on new path");
    assert!(report2.incremental);
    assert_eq!(report2.annotation_count, 2);
}

#[test]
fn save_as_destination_policy_requires_confirmation_and_stat_error_fails_closed() {
    let path = temp_copy("simple-text.pdf", "dest-policy");
    let existing = path.with_file_name("existing.pdf");
    fs::write(&existing, b"do not clobber silently").unwrap();

    let core = PdfCore::new();
    let info = core.open_document(&s(&path)).unwrap();
    core.add_sticky_note(&info.id, 0, 20.0, 20.0, "note", &never).unwrap();

    // Unconfirmed overwrite of existing destination is refused.
    assert!(matches!(
        core.save_document(&info.id, &s(&existing)),
        Err(CoreError::DestinationExists(_))
    ));
    assert_eq!(fs::read(&existing).unwrap(), b"do not clobber silently");

    // Stat error (parent is a regular file => ENOTDIR) fails closed even when confirmed!
    let blocker = path.with_file_name("blocker-file");
    fs::write(&blocker, b"not a dir").unwrap();
    let bad_dest = blocker.join("out.pdf");
    assert!(matches!(
        core.save_document_with_options(
            &info.id,
            &s(&bad_dest),
            SaveOptions { overwrite_existing_destination: true }
        ),
        Err(CoreError::Unverified(_))
    ));

    // Confirmed overwrite of existing destination succeeds.
    let report = core
        .save_document_with_options(
            &info.id,
            &s(&existing),
            SaveOptions { overwrite_existing_destination: true },
        )
        .expect("confirmed Save As overwrite");
    assert!(report.incremental);
}

#[test]
fn markup_kinds_colors_quads_and_recoloring_round_trip() {
    let path = temp_copy("simple-text.pdf", "markups");
    let core = PdfCore::new();
    let info = core.open_document(&s(&path)).unwrap();
    let blocks = core.get_text_blocks(&info.id, 0, &never).unwrap();
    assert!(blocks.len() >= 3);

    let blue = [0.0, 0.478, 1.0];
    let pink = [1.0, 0.176, 0.333];
    let green = [0.204, 0.780, 0.349];

    let hl = core
        .add_markup(&info.id, 0, MarkupKind::Highlight, &[blocks[0].rect, blocks[1].rect], pink, &never)
        .unwrap();
    assert_eq!(hl.subtype, "Highlight");
    assert_eq!(hl.quad_rects.len(), 2, "multi-line highlight should expose per-line quad_rects");
    assert!(hl.color.is_some());

    let ul = core
        .add_markup(&info.id, 0, MarkupKind::Underline, &[blocks[1].rect], blue, &never)
        .unwrap();
    assert_eq!(ul.subtype, "Underline");

    let so = core
        .add_markup(&info.id, 0, MarkupKind::StrikeOut, &[blocks[2].rect], [1.0, 0.231, 0.188], &never)
        .unwrap();
    assert_eq!(so.subtype, "StrikeOut");

    // Recolor the highlight and verify undo/redo restores the previous color.
    core.set_annotation_color(&info.id, hl.page, hl.index, green).unwrap();
    let anns = core.list_annotations(&info.id, 0).unwrap();
    let updated = anns.iter().find(|a| a.index == hl.index).unwrap();
    let c = updated.color.unwrap();
    assert!((c[1] - green[1] as f32).abs() < 0.02, "expected green color, got {c:?}");

    core.undo(&info.id).unwrap();
    let undone = core.list_annotations(&info.id, 0).unwrap();
    let reverted = undone.iter().find(|a| a.index == hl.index).unwrap();
    let c2 = reverted.color.unwrap();
    assert!((c2[0] - pink[0] as f32).abs() < 0.02, "undo should restore pink, got {c2:?}");

    core.redo(&info.id).unwrap();
    core.save_document(&info.id, &s(&path)).unwrap();
    core.close_document(&info.id).unwrap();

    let reopened = core.open_document(&s(&path)).unwrap();
    let final_anns = core.list_annotations(&reopened.id, 0).unwrap();
    assert_eq!(final_anns.len(), 3);
    assert!(final_anns.iter().any(|a| a.subtype == "Highlight" && a.quad_rects.len() == 2));
    assert!(final_anns.iter().any(|a| a.subtype == "Underline"));
    assert!(final_anns.iter().any(|a| a.subtype == "StrikeOut"));
}

#[test]
fn save_as_via_path_alias_to_changed_original_still_refuses() {
    let path = temp_copy("simple-text.pdf", "alias-target");
    let alias = path
        .parent()
        .unwrap()
        .join(".")
        .join(path.file_name().unwrap());

    let core = PdfCore::new();
    let info = core.open_document(&s(&path)).unwrap();
    core.add_sticky_note(&info.id, 0, 20.0, 20.0, "alias", &never).unwrap();

    let mut touched = fs::read(&path).unwrap();
    touched.push(b'%');
    fs::write(&path, &touched).unwrap();

    assert_eq!(
        core.save_document_with_options(
            &info.id,
            &s(&alias),
            SaveOptions { overwrite_existing_destination: true }
        ),
        Err(CoreError::ExternalChange)
    );
}
