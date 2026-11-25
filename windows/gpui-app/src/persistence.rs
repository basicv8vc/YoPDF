//! UI-independent save lifecycle, edit gating, per-tab autosave policy, and
//! Save & Close chain (Rust counterpart of CTO P0–P2 persistence semantics).
//!
//! Design invariants (matching `app/save.go` & `app/actions.go`):
//! 1. At most ONE save runs in `PdfCore` at a time per tab, and at most ONE
//!    more waits in the queue (latest-wins).
//! 2. Document mutations (`add_highlight`, `add_markup`, `add_sticky_note`,
//!    `update_annotation`, `delete_annotation`, `set_annotation_color`, `undo`,
//!    `redo`) are rejected while a save is queued or running (`gate_edit`), so
//!    user edits never race an incremental save.
//! 3. Same-path saves (manual Save, Autosave, Save & Close) share the same
//!    `PdfCore` SHA-256 fingerprint policy: `Matched` is required; `Changed`
//!    refuses with `ExternalChange`; `Unverified` refuses (autosave retries on
//!    a bounded schedule `4 × 750ms` and escalates to an actionable error).
//! 4. Save As to a different path is the recovery path and never consults the
//!    original file's fingerprint; destination stat errors fail closed.
//! 5. In-flight saves run to completion and are drained before quit (`wait_idle`).

use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
#[cfg(test)]
use std::time::Instant;

use pdfcore::{CoreError, DiskVerdict, PdfCore, SaveOptions, SaveReport};

pub const AUTO_SAVE_DELAY: Duration = Duration::from_millis(750);
pub const UNVERIFIED_AUTOSAVE_RETRIES: u32 = 4;

pub const MSG_SAVING_EDIT_LOCKED: &str =
    "document is being saved; editing is disabled until the save finishes";
pub const MSG_EXTERNAL_CHANGE_MANUAL: &str =
    "the file changed on disk since it was opened; saving would overwrite those changes — use Save As to a new file, or Close and reopen to review";
pub const MSG_UNVERIFIED_MANUAL: &str =
    "the document on disk cannot be verified right now; saving is refused to avoid overwriting unknown changes — try again in a moment, or use Save As to a new file";
pub const MSG_AUTOSAVE_CHANGED: &str =
    "the file changed on disk; autosave skipped to avoid overwriting it — use Save As to keep your edits";
pub const MSG_AUTOSAVE_PAUSED_UNVERIFIED: &str =
    "autosave paused: the document on disk could not be verified for saving — use Save As to a new file to keep your edits, or Close and reopen the document";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SaveErrorKind {
    ExternalChange,
    Unverified,
    DestinationExists,
    ReadOnly,
    Other,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SaveFailure {
    pub kind: SaveErrorKind,
    pub message: String,
    pub is_autosave: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SaveState {
    Idle,
    Queued { path: String },
    Saving { path: String },
    Succeeded(SaveReport),
    Failed { path: String, failure: SaveFailure },
}

#[derive(Debug, Clone)]
pub struct SaveJob {
    pub doc_id: String,
    pub path: String,
    pub opts: SaveOptions,
    pub doc_gen: u64,
    pub is_autosave: bool,
    pub close_after: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnqueueResult {
    /// No save was running; caller must execute `job` immediately on a worker.
    StartNow,
    /// A save was already running; `job` is now queued (possibly superseding an older queued job).
    Queued { superseded_previous: bool },
    /// Document generation changed before enqueue completed.
    StaleGeneration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutosaveDecision {
    QuietSkip,
    Eligible,
    RefuseExternalChange,
    RetryUnverified,
}

struct SlotInner {
    doc_gen: u64,
    autosave_seq: u64,
    running: Option<SaveJob>,
    queued: Option<SaveJob>,
    last_state: SaveState,
}

/// Thread-safe per-tab save queue and edit gate.
#[derive(Clone)]
pub struct SaveController {
    inner: Arc<Mutex<SlotInner>>,
    idle_cv: Arc<Condvar>,
}

impl Default for SaveController {
    fn default() -> Self {
        Self::new()
    }
}

impl SaveController {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(SlotInner {
                doc_gen: 1,
                autosave_seq: 0,
                running: None,
                queued: None,
                last_state: SaveState::Idle,
            })),
            idle_cv: Arc::new(Condvar::new()),
        }
    }

    pub fn doc_gen(&self) -> u64 {
        self.inner.lock().expect("save slot poisoned").doc_gen
    }

    pub fn bump_doc_gen(&self) -> u64 {
        let mut g = self.inner.lock().expect("save slot poisoned");
        g.doc_gen += 1;
        g.autosave_seq += 1;
        g.queued = None;
        g.last_state = SaveState::Idle;
        g.doc_gen
    }

    pub fn bump_autosave_seq(&self) -> u64 {
        let mut g = self.inner.lock().expect("save slot poisoned");
        g.autosave_seq += 1;
        g.autosave_seq
    }

    pub fn current_autosave_seq(&self) -> u64 {
        self.inner.lock().expect("save slot poisoned").autosave_seq
    }

    pub fn has_pending(&self) -> bool {
        let g = self.inner.lock().expect("save slot poisoned");
        g.running.is_some() || g.queued.is_some()
    }

    pub fn snapshot(&self) -> SaveState {
        let g = self.inner.lock().expect("save slot poisoned");
        if let Some(ref q) = g.queued {
            SaveState::Queued { path: q.path.clone() }
        } else if let Some(ref r) = g.running {
            SaveState::Saving { path: r.path.clone() }
        } else {
            g.last_state.clone()
        }
    }

    /// Reject document mutations while a save is queued or running.
    pub fn gate_edit(&self) -> Result<(), &'static str> {
        if self.has_pending() {
            Err(MSG_SAVING_EDIT_LOCKED)
        } else {
            Ok(())
        }
    }

    /// Cancel any queued (not yet started) save. Running saves are never
    /// interrupted.
    pub fn cancel_queued(&self) -> bool {
        let mut g = self.inner.lock().expect("save slot poisoned");
        g.queued.take().is_some()
    }

    /// Enqueue a save job under the 1-running + 1-queued latest-wins protocol.
    pub fn enqueue(&self, mut job: SaveJob) -> EnqueueResult {
        let mut g = self.inner.lock().expect("save slot poisoned");
        if g.doc_gen != job.doc_gen {
            return EnqueueResult::StaleGeneration;
        }
        if g.running.is_some() {
            let mut superseded_previous = false;
            if let Some(prev) = g.queued.take() {
                superseded_previous = true;
                job.close_after |= prev.close_after;
            }
            g.queued = Some(job);
            EnqueueResult::Queued { superseded_previous }
        } else {
            g.running = Some(job);
            EnqueueResult::StartNow
        }
    }

    /// Record completion of the running job and promote any queued job (if its
    /// `doc_gen` is still current). Returns `Some(next_job)` if a queued job
    /// is now promoted to running and must be executed by the caller.
    pub fn finish_running(
        &self,
        job: &SaveJob,
        result: &Result<SaveReport, SaveFailure>,
    ) -> Option<SaveJob> {
        let mut g = self.inner.lock().expect("save slot poisoned");
        if g.doc_gen == job.doc_gen {
            g.last_state = match result {
                Ok(report) => SaveState::Succeeded(report.clone()),
                Err(failure) => SaveState::Failed {
                    path: job.path.clone(),
                    failure: failure.clone(),
                },
            };
        }
        g.running = None;
        while let Some(next) = g.queued.take() {
            if next.doc_gen == g.doc_gen {
                g.running = Some(next.clone());
                return Some(next);
            }
        }
        self.idle_cv.notify_all();
        None
    }

    /// Mark an autosave failure that occurred during preflight (e.g. external
    /// change or unverified retry exhaustion) so the toolbar indicator shows
    /// "Auto-save failed".
    pub fn record_autosave_refusal(&self, path: &str, doc_gen: u64, kind: SaveErrorKind, message: String) {
        let mut g = self.inner.lock().expect("save slot poisoned");
        if g.doc_gen == doc_gen && g.running.is_none() && g.queued.is_none() {
            g.last_state = SaveState::Failed {
                path: path.to_string(),
                failure: SaveFailure {
                    kind,
                    message,
                    is_autosave: true,
                },
            };
        }
    }

    /// Clear `Failed` / `Succeeded` state when a new edit starts.
    pub fn note_edited(&self) {
        let mut g = self.inner.lock().expect("save slot poisoned");
        if g.running.is_none() && g.queued.is_none() {
            g.last_state = SaveState::Idle;
        }
    }

    /// Block until no save is running or queued. Never truncates an in-flight
    /// save, regardless of duration.
    pub fn wait_until_idle(&self) {
        let mut g = self.inner.lock().expect("save slot poisoned");
        while g.running.is_some() || g.queued.is_some() {
            g = self.idle_cv.wait(g).expect("save slot poisoned");
        }
    }

    /// Wait until no save is running or queued, up to `timeout`.
    /// Returns `false` if a save is still queued or executing when `timeout` elapses.
    #[cfg(test)]
    #[must_use = "timeout must be checked; use wait_until_idle() when an in-flight save must not be truncated"]
    pub fn wait_idle(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut g = self.inner.lock().expect("save slot poisoned");
        while g.running.is_some() || g.queued.is_some() {
            let Some(rem) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (guard, res) = self.idle_cv.wait_timeout(g, rem).expect("save slot poisoned");
            g = guard;
            if res.timed_out() && (g.running.is_some() || g.queued.is_some()) {
                return false;
            }
        }
        true
    }

    pub fn same_slot(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.inner, &other.inner)
    }

    fn abort_running_on_panic(&self) {
        if let Ok(mut g) = self.inner.lock() {
            if let Some(job) = g.running.take()
                && g.doc_gen == job.doc_gen
            {
                g.last_state = SaveState::Failed {
                    path: job.path,
                    failure: SaveFailure {
                        kind: SaveErrorKind::Other,
                        message: "save worker panicked unexpectedly".to_string(),
                        is_autosave: job.is_autosave,
                    },
                };
            }
            g.queued = None;
            self.idle_cv.notify_all();
        }
    }
}

/// Process-wide registry of all `SaveController`s (both open tabs and tabs
/// already removed from the UI whose in-flight save is still draining).
/// Used as the quit and window-close barrier so no active save is ever
/// truncated.
#[derive(Clone, Default)]
pub struct SaveRegistry {
    controllers: Arc<Mutex<Vec<SaveController>>>,
}

impl SaveRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&self, ctrl: SaveController) {
        let mut list = self.controllers.lock().expect("save registry poisoned");
        if !list.iter().any(|c| c.same_slot(&ctrl)) {
            list.push(ctrl);
        }
    }

    pub fn unregister_if_idle(&self, ctrl: &SaveController) {
        let mut list = self.controllers.lock().expect("save registry poisoned");
        if !ctrl.has_pending() {
            list.retain(|c| !c.same_slot(ctrl));
        }
    }

    pub fn has_pending(&self) -> bool {
        let list = self.controllers.lock().expect("save registry poisoned");
        list.iter().any(|c| c.has_pending())
    }

    /// Block until every registered controller finishes all running and queued
    /// saves. Never times out or truncates a save.
    pub fn drain_all(&self) {
        loop {
            let pending: Vec<SaveController> = {
                let list = self.controllers.lock().expect("save registry poisoned");
                list.iter().filter(|c| c.has_pending()).cloned().collect()
            };
            if pending.is_empty() {
                break;
            }
            for ctrl in pending {
                ctrl.wait_until_idle();
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SaveAsPreflight {
    /// Destination does not exist yet (or is the unchanged current document).
    Ready,
    /// Destination is a different existing file and needs explicit user confirmation.
    NeedsOverwriteConfirmation,
    /// Saving to this destination is refused (external change, unreadable path, etc.).
    Refuse(SaveFailure),
}

/// Preflight a Save As target without trusting the OS file dialog to have
/// enforced overwrite confirmation.
pub fn preflight_save_as(engine: &PdfCore, doc_id: &str, path: &str) -> SaveAsPreflight {
    match engine.check_save_target(
        doc_id,
        path,
        SaveOptions { overwrite_existing_destination: false },
    ) {
        Ok(()) => SaveAsPreflight::Ready,
        Err(CoreError::DestinationExists(_)) => SaveAsPreflight::NeedsOverwriteConfirmation,
        Err(e) => SaveAsPreflight::Refuse(map_save_error(e, false)),
    }
}

pub fn map_save_error(err: CoreError, is_autosave: bool) -> SaveFailure {
    match err {
        CoreError::ExternalChange => SaveFailure {
            kind: SaveErrorKind::ExternalChange,
            message: if is_autosave {
                MSG_AUTOSAVE_CHANGED.to_string()
            } else {
                MSG_EXTERNAL_CHANGE_MANUAL.to_string()
            },
            is_autosave,
        },
        CoreError::Unverified(detail) => SaveFailure {
            kind: SaveErrorKind::Unverified,
            message: if is_autosave {
                MSG_AUTOSAVE_PAUSED_UNVERIFIED.to_string()
            } else if detail.is_empty() {
                MSG_UNVERIFIED_MANUAL.to_string()
            } else {
                format!("{MSG_UNVERIFIED_MANUAL} ({detail})")
            },
            is_autosave,
        },
        CoreError::DestinationExists(detail) => SaveFailure {
            kind: SaveErrorKind::DestinationExists,
            message: detail,
            is_autosave,
        },
        CoreError::ReadOnly(detail) => SaveFailure {
            kind: SaveErrorKind::ReadOnly,
            message: format!("document is read-only: {detail}"),
            is_autosave,
        },
        other => SaveFailure {
            kind: SaveErrorKind::Other,
            message: other.to_string(),
            is_autosave,
        },
    }
}

/// Evaluate whether an open document should autosave right now.
pub fn autosave_eligibility(
    engine: &PdfCore,
    doc_id: &str,
    path: &str,
    dirty: bool,
    save_ctrl: &SaveController,
) -> AutosaveDecision {
    if path.is_empty() || !dirty || save_ctrl.has_pending() {
        return AutosaveDecision::QuietSkip;
    }
    match engine.disk_verdict(doc_id) {
        Ok(DiskVerdict::Matched) => AutosaveDecision::Eligible,
        Ok(DiskVerdict::Changed) => AutosaveDecision::RefuseExternalChange,
        Ok(DiskVerdict::Unverified) | Err(_) => AutosaveDecision::RetryUnverified,
    }
}

struct RunningGuard<'a> {
    ctrl: &'a SaveController,
    armed: bool,
}

impl Drop for RunningGuard<'_> {
    fn drop(&mut self) {
        if self.armed {
            self.ctrl.abort_running_on_panic();
        }
    }
}

/// Execute a save job (plus any jobs subsequently queued behind it)
/// synchronously on the caller's background thread/executor. Invokes `on_step`
/// after each job completes so the UI can refresh its state.
pub fn run_save_chain(
    engine: &PdfCore,
    save_ctrl: &SaveController,
    initial: SaveJob,
    mut on_step: impl FnMut(&SaveJob, Result<SaveReport, SaveFailure>),
) {
    let mut current = Some(initial);
    let mut guard = RunningGuard {
        ctrl: save_ctrl,
        armed: true,
    };
    while let Some(job) = current {
        guard.armed = true;
        let res = engine
            .save_document_with_options(&job.doc_id, &job.path, job.opts)
            .map_err(|e| map_save_error(e, job.is_autosave));
        guard.armed = false;
        let next = save_ctrl.finish_running(&job, &res);
        on_step(&job, res);
        current = next;
    }
}

/// Synchronous body of Save & Close: consults the exact same guarded save path
/// as manual Save (`overwrite_existing_destination = false`). Only closes the
/// document if saving succeeded; on refusal or error the document stays open
/// and dirty with all edits intact.
#[cfg(test)]
pub fn save_and_close_document(
    engine: &PdfCore,
    save_ctrl: &SaveController,
    doc_id: &str,
    path: &str,
) -> Result<Option<SaveReport>, SaveFailure> {
    if path.is_empty() {
        return Err(SaveFailure {
            kind: SaveErrorKind::Unverified,
            message: "document has no file path; use Save As before closing".to_string(),
            is_autosave: false,
        });
    }
    let job = SaveJob {
        doc_id: doc_id.to_string(),
        path: path.to_string(),
        opts: SaveOptions { overwrite_existing_destination: false },
        doc_gen: save_ctrl.doc_gen(),
        is_autosave: false,
        close_after: true,
    };
    match save_ctrl.enqueue(job.clone()) {
        EnqueueResult::StartNow => {
            let mut outcome: Option<Result<SaveReport, SaveFailure>> = None;
            run_save_chain(engine, save_ctrl, job, |step, res| {
                if outcome.is_none() {
                    let _ = step;
                    outcome = Some(res);
                }
            });
            let report = outcome.unwrap_or_else(|| {
                Err(SaveFailure {
                    kind: SaveErrorKind::Other,
                    message: "save produced no result".to_string(),
                    is_autosave: false,
                })
            })?;
            engine
                .close_document(doc_id)
                .map_err(|e| map_save_error(e, false))?;
            Ok(Some(report))
        }
        EnqueueResult::Queued { .. } => {
            // Wait for the running+queued saves to drain without truncating,
            // then check outcome.
            save_ctrl.wait_until_idle();
            match save_ctrl.snapshot() {
                SaveState::Succeeded(report) => {
                    engine
                        .close_document(doc_id)
                        .map_err(|e| map_save_error(e, false))?;
                    Ok(Some(report))
                }
                SaveState::Failed { failure, .. } => Err(failure),
                _ => Err(SaveFailure {
                    kind: SaveErrorKind::Other,
                    message: "save did not complete".to_string(),
                    is_autosave: false,
                }),
            }
        }
        EnqueueResult::StaleGeneration => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::thread;

    static SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_pdf(label: &str) -> PathBuf {
        let src = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../fixtures/simple-text.pdf")
            .canonicalize()
            .expect("simple-text fixture");
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("yopdf-gpui-persist-{}-{n}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let dst = dir.join(format!("{label}.pdf"));
        fs::copy(src, &dst).unwrap();
        dst
    }

    #[test]
    fn per_tab_autosave_seq_is_independent() {
        let tab_a = SaveController::new();
        let tab_b = SaveController::new();
        let seq_a = tab_a.bump_autosave_seq();
        let _ = tab_b.bump_autosave_seq();
        let _ = tab_b.bump_autosave_seq();
        assert_eq!(tab_a.current_autosave_seq(), seq_a);
    }

    #[test]
    fn autosave_eligibility_and_same_size_external_change() {
        let path = temp_pdf("autosave-same-size");
        let path_s = path.to_string_lossy().into_owned();
        let core = PdfCore::new();
        let info = core.open_document(&path_s).unwrap();
        let ctrl = SaveController::new();

        // Clean => quiet skip.
        assert_eq!(
            autosave_eligibility(&core, &info.id, &path_s, false, &ctrl),
            AutosaveDecision::QuietSkip
        );

        // Dirty => eligible.
        core.add_sticky_note(&info.id, 0, 20.0, 20.0, "a", &|| false).unwrap();
        assert_eq!(
            autosave_eligibility(&core, &info.id, &path_s, true, &ctrl),
            AutosaveDecision::Eligible
        );

        // Same-size, same-mtime external rewrite => RefuseExternalChange.
        let mut bytes = fs::read(&path).unwrap();
        let mtime = fs::metadata(&path).unwrap().modified().ok();
        let last = bytes.len() - 1;
        bytes[last] ^= 0x01;
        fs::write(&path, &bytes).unwrap();
        if let Some(m) = mtime {
            let _ = fs::File::options().write(true).open(&path).and_then(|f| f.set_modified(m));
        }

        assert_eq!(
            autosave_eligibility(&core, &info.id, &path_s, true, &ctrl),
            AutosaveDecision::RefuseExternalChange
        );
    }

    #[test]
    fn autosave_unverified_retries_then_recovers_or_escalates() {
        let path = temp_pdf("autosave-retry");
        let path_s = path.to_string_lossy().into_owned();
        let core = PdfCore::new();
        let info = core.open_document(&path_s).unwrap();
        core.add_sticky_note(&info.id, 0, 20.0, 20.0, "retry", &|| false).unwrap();

        // Drop baseline => Unverified.
        core.clear_fingerprint_for_test(&info.id).unwrap();
        let ctrl = SaveController::new();
        assert_eq!(
            autosave_eligibility(&core, &info.id, &path_s, true, &ctrl),
            AutosaveDecision::RetryUnverified
        );

        // Baseline lands => Eligible => run_save_chain persists cleanly.
        assert_eq!(core.establish_baseline(&info.id).unwrap(), DiskVerdict::Matched);
        assert_eq!(
            autosave_eligibility(&core, &info.id, &path_s, true, &ctrl),
            AutosaveDecision::Eligible
        );
        let job = SaveJob {
            doc_id: info.id.clone(),
            path: path_s.clone(),
            opts: SaveOptions::default(),
            doc_gen: ctrl.doc_gen(),
            is_autosave: true,
            close_after: false,
        };
        assert_eq!(ctrl.enqueue(job.clone()), EnqueueResult::StartNow);
        let mut saved_ok = false;
        run_save_chain(&core, &ctrl, job, |_, res| {
            saved_ok = res.is_ok();
        });
        assert!(saved_ok);
        assert!(!core.get_document_info(&info.id).unwrap().dirty);

        // Now vanish the file => unverified exhaustion records actionable Failed state.
        core.add_sticky_note(&info.id, 0, 30.0, 30.0, "stuck", &|| false).unwrap();
        fs::remove_file(&path).unwrap();
        assert_eq!(
            autosave_eligibility(&core, &info.id, &path_s, true, &ctrl),
            AutosaveDecision::RetryUnverified
        );
        ctrl.record_autosave_refusal(
            &path_s,
            ctrl.doc_gen(),
            SaveErrorKind::Unverified,
            MSG_AUTOSAVE_PAUSED_UNVERIFIED.to_string(),
        );
        match ctrl.snapshot() {
            SaveState::Failed { failure, .. } => {
                assert_eq!(failure.kind, SaveErrorKind::Unverified);
                assert!(failure.message.contains("autosave paused"));
            }
            other => panic!("expected Failed, got {other:?}"),
        }
    }

    #[test]
    fn save_queue_latest_wins_gates_edits_and_wait_idle_drains() {
        let path = temp_pdf("queue");
        let path_s = path.to_string_lossy().into_owned();
        let core = Arc::new(PdfCore::new());
        let info = core.open_document(&path_s).unwrap();
        core.add_sticky_note(&info.id, 0, 20.0, 20.0, "q", &|| false).unwrap();

        let ctrl = SaveController::new();
        let generation = ctrl.doc_gen();
        let j1 = SaveJob {
            doc_id: info.id.clone(),
            path: path_s.clone(),
            opts: SaveOptions::default(),
            doc_gen: generation,
            is_autosave: false,
            close_after: false,
        };
        let j2 = SaveJob {
            doc_id: info.id.clone(),
            path: path.with_file_name("q2.pdf").to_string_lossy().into_owned(),
            opts: SaveOptions::default(),
            doc_gen: generation,
            is_autosave: false,
            close_after: false,
        };
        let j3 = SaveJob {
            doc_id: info.id.clone(),
            path: path.with_file_name("q3.pdf").to_string_lossy().into_owned(),
            opts: SaveOptions::default(),
            doc_gen: generation,
            is_autosave: false,
            close_after: false,
        };

        assert_eq!(ctrl.enqueue(j1.clone()), EnqueueResult::StartNow);
        assert!(ctrl.gate_edit().is_err(), "edits must be gated while save runs");
        assert_eq!(
            ctrl.enqueue(j2),
            EnqueueResult::Queued { superseded_previous: false }
        );
        assert_eq!(
            ctrl.enqueue(j3),
            EnqueueResult::Queued { superseded_previous: true }
        );

        let core_bg = Arc::clone(&core);
        let ctrl_bg = ctrl.clone();
        let mut completed_paths = Vec::new();
        let h = thread::spawn(move || {
            run_save_chain(&core_bg, &ctrl_bg, j1, |job, res| {
                res.expect("save job should succeed");
                completed_paths.push(job.path.clone());
            });
            completed_paths
        });

        assert!(ctrl.wait_idle(Duration::from_secs(5)));
        let ran = h.join().unwrap();
        // j2 was superseded by j3, so only j1 and j3 ran!
        assert_eq!(ran.len(), 2);
        assert!(ran[1].ends_with("q3.pdf"));
        assert!(!path.with_file_name("q2.pdf").exists());
        assert!(path.with_file_name("q3.pdf").exists());
        assert!(ctrl.gate_edit().is_ok());
    }

    #[test]
    fn save_and_close_chain_conflict_keeps_doc_open_and_clean_path_closes() {
        // Conflict path: external change refuses Save & Close and keeps doc open + dirty.
        let p_conflict = temp_pdf("close-conflict");
        let p_conflict_s = p_conflict.to_string_lossy().into_owned();
        let core = PdfCore::new();
        let info = core.open_document(&p_conflict_s).unwrap();
        core.add_sticky_note(&info.id, 0, 20.0, 20.0, "keep-me", &|| false).unwrap();

        let mut bytes = fs::read(&p_conflict).unwrap();
        bytes.push(b'%');
        fs::write(&p_conflict, &bytes).unwrap();

        let ctrl = SaveController::new();
        let err = save_and_close_document(&core, &ctrl, &info.id, &p_conflict_s).unwrap_err();
        assert_eq!(err.kind, SaveErrorKind::ExternalChange);
        assert_eq!(core.open_count(), 1, "conflicting Save & Close must keep document open");
        assert!(core.get_document_info(&info.id).unwrap().dirty);

        // Clean path: persists and closes document.
        let p_clean = temp_pdf("close-clean");
        let p_clean_s = p_clean.to_string_lossy().into_owned();
        let info2 = core.open_document(&p_clean_s).unwrap();
        core.add_sticky_note(&info2.id, 0, 20.0, 20.0, "save-and-close", &|| false).unwrap();

        let ctrl2 = SaveController::new();
        let report = save_and_close_document(&core, &ctrl2, &info2.id, &p_clean_s)
            .unwrap()
            .expect("save report");
        assert!(report.incremental);
        assert_eq!(core.open_count(), 1, "clean document should now be closed (only conflict doc left)");
        assert_eq!(core.get_document_info(&info2.id), Err(CoreError::DocumentNotFound));
    }

    #[test]
    fn queued_save_and_close_preserves_close_after_through_chain_and_supersede() {
        let path = temp_pdf("close-queued");
        let path_s = path.to_string_lossy().into_owned();
        let core = PdfCore::new();
        let info = core.open_document(&path_s).unwrap();
        core.add_sticky_note(&info.id, 0, 20.0, 20.0, "queued-close", &|| false).unwrap();

        let ctrl = SaveController::new();
        let generation = ctrl.doc_gen();

        // 1. Autosave is running (`close_after: false`).
        let autosave = SaveJob {
            doc_id: info.id.clone(),
            path: path_s.clone(),
            opts: SaveOptions::default(),
            doc_gen: generation,
            is_autosave: true,
            close_after: false,
        };
        assert_eq!(ctrl.enqueue(autosave.clone()), EnqueueResult::StartNow);

        // 2. User triggers Save & Close while autosave is in-flight (`close_after: true`).
        let close_job = SaveJob {
            doc_id: info.id.clone(),
            path: path_s.clone(),
            opts: SaveOptions::default(),
            doc_gen: generation,
            is_autosave: false,
            close_after: true,
        };
        assert_eq!(
            ctrl.enqueue(close_job),
            EnqueueResult::Queued { superseded_previous: false }
        );

        // 3. Even if another manual Save supersedes the queued job, `close_after` sticks.
        let manual_follow = SaveJob {
            doc_id: info.id.clone(),
            path: path_s,
            opts: SaveOptions::default(),
            doc_gen: generation,
            is_autosave: false,
            close_after: false,
        };
        assert_eq!(
            ctrl.enqueue(manual_follow),
            EnqueueResult::Queued { superseded_previous: true }
        );

        let mut steps = Vec::new();
        run_save_chain(&core, &ctrl, autosave, |job, res| {
            assert!(res.is_ok(), "chained save step failed: {res:?}");
            steps.push(job.close_after);
        });
        assert_eq!(steps, vec![false, true]);
    }

    #[test]
    fn save_as_preflight_requires_confirmation_for_existing_destination_and_fails_closed() {
        let orig = temp_pdf("save-as-orig");
        let orig_s = orig.to_string_lossy().into_owned();
        let existing_other = temp_pdf("save-as-other");
        let existing_other_bytes = fs::read(&existing_other).unwrap();
        let existing_other_s = existing_other.to_string_lossy().into_owned();
        let fresh_s = orig
            .with_file_name("save-as-fresh.pdf")
            .to_string_lossy()
            .into_owned();

        let core = PdfCore::new();
        let info = core.open_document(&orig_s).unwrap();
        core.add_sticky_note(&info.id, 0, 20.0, 20.0, "save-as", &|| false)
            .unwrap();

        // 1. Fresh destination -> Ready to save with overwrite_existing_destination = false.
        assert_eq!(
            preflight_save_as(&core, &info.id, &fresh_s),
            SaveAsPreflight::Ready
        );

        // 2. Existing unrelated PDF -> must require explicit app-level confirmation.
        assert_eq!(
            preflight_save_as(&core, &info.id, &existing_other_s),
            SaveAsPreflight::NeedsOverwriteConfirmation
        );
        assert_eq!(
            fs::read(&existing_other).unwrap(),
            existing_other_bytes,
            "preflight must never touch or overwrite the existing destination"
        );

        // 3. Unstatable destination (regular file used as parent directory) -> fail closed.
        let impossible = orig.join("child.pdf").to_string_lossy().into_owned();
        match preflight_save_as(&core, &info.id, &impossible) {
            SaveAsPreflight::Refuse(f) => assert_eq!(f.kind, SaveErrorKind::Unverified),
            other => panic!("expected Refuse(Unverified), got {other:?}"),
        }

        // 4. Same-path Save As still enforces external-change verification.
        assert_eq!(
            preflight_save_as(&core, &info.id, &orig_s),
            SaveAsPreflight::Ready
        );
        let mut touched = fs::read(&orig).unwrap();
        touched.push(b'%');
        fs::write(&orig, &touched).unwrap();
        match preflight_save_as(&core, &info.id, &orig_s) {
            SaveAsPreflight::Refuse(f) => assert_eq!(f.kind, SaveErrorKind::ExternalChange),
            other => panic!("expected Refuse(ExternalChange), got {other:?}"),
        }
        // Recovery path to another existing file still prompts rather than failing on orig.
        assert_eq!(
            preflight_save_as(&core, &info.id, &existing_other_s),
            SaveAsPreflight::NeedsOverwriteConfirmation
        );
    }

    #[test]
    fn quit_barrier_waits_past_10s_without_truncating_in_flight_save() {
        use std::sync::atomic::AtomicBool;
        use std::sync::mpsc;

        let path = temp_pdf("long-save-barrier");
        let path_s = path.to_string_lossy().into_owned();
        let core = Arc::new(PdfCore::new());
        let info = core.open_document(&path_s).unwrap();
        core.add_sticky_note(&info.id, 0, 24.0, 24.0, "must-finish", &|| false)
            .unwrap();

        let registry = SaveRegistry::new();
        let ctrl_open = SaveController::new();
        let ctrl_closed_tab = SaveController::new();
        registry.register(ctrl_open.clone());
        registry.register(ctrl_closed_tab.clone());

        let job = SaveJob {
            doc_id: info.id.clone(),
            path: path_s.clone(),
            opts: SaveOptions {
                overwrite_existing_destination: false,
            },
            doc_gen: ctrl_closed_tab.doc_gen(),
            is_autosave: false,
            close_after: false,
        };
        assert_eq!(ctrl_closed_tab.enqueue(job.clone()), EnqueueResult::StartNow);

        // Simulate user closing this tab while the save is already running:
        // queued work may be discarded and doc_gen bumped, but the running
        // save remains tracked by `registry` until completion.
        ctrl_closed_tab.cancel_queued();
        ctrl_closed_tab.bump_doc_gen();
        assert!(registry.has_pending());
        assert!(
            !ctrl_closed_tab.wait_idle(Duration::from_millis(50)),
            "bounded wait_idle must report false while save is in flight"
        );

        let save_completed = Arc::new(AtomicBool::new(false));
        let save_completed_bg = Arc::clone(&save_completed);
        let core_bg = Arc::clone(&core);
        let ctrl_bg = ctrl_closed_tab.clone();
        let save_worker = thread::spawn(move || {
            // Simulate a large PDF save taking >10 seconds (longer than the old 10s barrier).
            thread::sleep(Duration::from_millis(10_500));
            let res = core_bg
                .save_document_with_options(&job.doc_id, &job.path, job.opts)
                .map_err(|e| map_save_error(e, job.is_autosave));
            assert!(res.is_ok(), "long save failed: {res:?}");
            save_completed_bg.store(true, Ordering::SeqCst);
            let next = ctrl_bg.finish_running(&job, &res);
            assert!(next.is_none());
        });

        let started = Instant::now();
        let (tx, rx) = mpsc::channel();
        let registry_quit = registry.clone();
        let quit_waiter = thread::spawn(move || {
            registry_quit.drain_all();
            tx.send(Instant::now()).unwrap();
        });

        // Must NOT return early at 10s!
        assert!(
            rx.recv_timeout(Duration::from_millis(10_100)).is_err(),
            "quit barrier returned before 10.1s while save was still in flight"
        );
        assert!(
            !save_completed.load(Ordering::SeqCst),
            "test precondition: save should still be running at 10.1s"
        );

        let finished_at = rx
            .recv_timeout(Duration::from_secs(5))
            .expect("quit barrier must unblock once the 10.5s save completes");
        assert!(
            finished_at.duration_since(started) >= Duration::from_millis(10_400),
            "quit barrier unblocked too early: {:?}",
            finished_at.duration_since(started)
        );
        assert!(save_completed.load(Ordering::SeqCst));
        assert!(!registry.has_pending());

        save_worker.join().unwrap();
        quit_waiter.join().unwrap();
        let _ = core.close_document(&info.id);
        registry.unregister_if_idle(&ctrl_closed_tab);
        registry.unregister_if_idle(&ctrl_open);
        assert!(!registry.has_pending());

        // Verify persisted PDF on disk actually contains the note after quit barrier unblocks.
        let verify_core = PdfCore::new();
        let reopened = verify_core.open_document(&path_s).unwrap();
        let anns = verify_core.list_annotations(&reopened.id, 0).unwrap();
        assert_eq!(anns.len(), 1);
        assert_eq!(anns[0].contents, "must-finish");
    }
}
