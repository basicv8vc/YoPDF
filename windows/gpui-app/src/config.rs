//! App config: recent documents and user preferences, persisted as JSON in
//! the user config directory.
//!
//! Locking & ordering policy (CTO verification §2 & boundary 3):
//! - `inner` (`Mutex`) guards in-memory state + a monotonic `gen` counter and is
//!   NEVER held across disk I/O.
//! - Every mutation snapshots `(gen, data)` under `inner`, releases `inner`, and
//!   passes `(gen, data)` to `persist_snapshot`.
//! - `writer` (`Mutex`) serializes disk writes and skips any snapshot whose
//!   `gen < written_gen`, so racing mutations always converge on the newest
//!   state and a stale snapshot can never overwrite a newer write.

use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use pdfcore::MarkupKind;
use serde::{Deserialize, Serialize};

pub const MAX_RECENTS: usize = 10;

pub const DEFAULT_HIGHLIGHT_HEX: &str = "#FFD60A";
pub const DEFAULT_UNDERLINE_HEX: &str = "#007AFF";
pub const DEFAULT_STRIKEOUT_HEX: &str = "#FF3B30";
pub const DEFAULT_NOTE_HEX: &str = "#FFD60A";

/// Six macOS-parity preset sRGB colors (docs/macos-ui-parity-spec.md §7).
pub const PRESET_MARKUP_COLORS: [(&str, &str); 6] = [
    ("Yellow", "#FFD60A"),
    ("Green", "#34C759"),
    ("Blue", "#007AFF"),
    ("Pink", "#FF2D55"),
    ("Purple", "#AF52DE"),
    ("Orange", "#FF9500"),
];

static CFG_TMP_SEQ: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RecentDoc {
    pub path: String,
    pub opened_at_unix: u64,
    #[serde(default)]
    pub page: i64,
    #[serde(default)]
    pub zoom: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConfigData {
    #[serde(default)]
    pub recents: Vec<RecentDoc>,
    #[serde(default = "default_dark_mode")]
    pub dark_mode: String,
    #[serde(default)]
    pub sidebar_on: bool,
    #[serde(default = "default_highlight_hex")]
    pub highlight_color: String,
    #[serde(default = "default_underline_hex")]
    pub underline_color: String,
    #[serde(default = "default_strikeout_hex")]
    pub strikeout_color: String,
    #[serde(default = "default_note_hex")]
    pub note_color: String,
}

fn default_dark_mode() -> String {
    "system".to_string()
}
fn default_highlight_hex() -> String {
    DEFAULT_HIGHLIGHT_HEX.to_string()
}
fn default_underline_hex() -> String {
    DEFAULT_UNDERLINE_HEX.to_string()
}
fn default_strikeout_hex() -> String {
    DEFAULT_STRIKEOUT_HEX.to_string()
}
fn default_note_hex() -> String {
    DEFAULT_NOTE_HEX.to_string()
}

impl Default for ConfigData {
    fn default() -> Self {
        Self {
            recents: Vec::new(),
            dark_mode: default_dark_mode(),
            sidebar_on: false,
            highlight_color: default_highlight_hex(),
            underline_color: default_underline_hex(),
            strikeout_color: default_strikeout_hex(),
            note_color: default_note_hex(),
        }
    }
}

struct ConfigInner {
    generation: u64,
    data: ConfigData,
}

struct WriteState {
    written_gen: u64,
    path: Option<PathBuf>,
}

pub struct AppConfig {
    inner: Mutex<ConfigInner>,
    writer: Mutex<WriteState>,
}

impl AppConfig {
    pub fn default_config_path() -> Option<PathBuf> {
        dirs::config_dir().map(|base| base.join("YoPDF").join("config.json"))
    }

    pub fn load_default() -> Self {
        match Self::default_config_path() {
            Some(p) => Self::load_from_path(p),
            None => Self::in_memory(),
        }
    }

    pub fn in_memory() -> Self {
        Self {
            inner: Mutex::new(ConfigInner { generation: 0, data: ConfigData::default() }),
            writer: Mutex::new(WriteState { written_gen: 0, path: None }),
        }
    }

    pub fn load_from_path(path: PathBuf) -> Self {
        let mut data = ConfigData::default();
        if let Ok(raw) = fs::read(&path)
            && let Ok(parsed) = serde_json::from_slice::<ConfigData>(&raw)
        {
            data = parsed;
            if data.dark_mode.is_empty() {
                data.dark_mode = default_dark_mode();
            }
            if parse_hex_rgb(&data.highlight_color).is_none() {
                data.highlight_color = default_highlight_hex();
            }
            if parse_hex_rgb(&data.underline_color).is_none() {
                data.underline_color = default_underline_hex();
            }
            if parse_hex_rgb(&data.strikeout_color).is_none() {
                data.strikeout_color = default_strikeout_hex();
            }
            if parse_hex_rgb(&data.note_color).is_none() {
                data.note_color = default_note_hex();
            }
        }
        Self {
            inner: Mutex::new(ConfigInner { generation: 0, data }),
            writer: Mutex::new(WriteState { written_gen: 0, path: Some(path) }),
        }
    }

    fn mutate<F>(&self, f: F) -> (u64, ConfigData)
    where
        F: FnOnce(&mut ConfigData),
    {
        let mut guard = self.inner.lock().expect("config mutex poisoned");
        f(&mut guard.data);
        guard.generation += 1;
        (guard.generation, guard.data.clone())
    }

    /// Persist `(generation, data)` outside `self.inner` while serializing disk I/O
    /// under `self.writer`. Any snapshot older than `written_gen` is dropped.
    pub(crate) fn persist_snapshot(&self, generation: u64, data: ConfigData) {
        let mut w = self.writer.lock().expect("config writer mutex poisoned");
        if generation < w.written_gen {
            return;
        }
        w.written_gen = generation;
        let Some(ref path) = w.path else { return };
        let _ = write_json_atomic(path, &data);
    }

    #[cfg(test)]
    pub(crate) fn mutate_without_persist<F>(&self, f: F) -> (u64, ConfigData)
    where
        F: FnOnce(&mut ConfigData),
    {
        self.mutate(f)
    }

    pub fn touch_recent(&self, path: &str, page: i64, zoom: f32) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let snap = self.mutate(|d| {
            d.recents.retain(|r| r.path != path);
            d.recents.insert(
                0,
                RecentDoc {
                    path: path.to_string(),
                    opened_at_unix: now,
                    page,
                    zoom,
                },
            );
            d.recents.truncate(MAX_RECENTS);
        });
        self.persist_snapshot(snap.0, snap.1);
    }

    pub fn recents(&self) -> Vec<RecentDoc> {
        self.inner
            .lock()
            .expect("config mutex poisoned")
            .data
            .recents
            .clone()
    }

    pub fn dark_mode(&self) -> String {
        self.inner
            .lock()
            .expect("config mutex poisoned")
            .data
            .dark_mode
            .clone()
    }

    pub fn set_dark_mode(&self, mode: &str) {
        let snap = self.mutate(|d| {
            d.dark_mode = mode.to_string();
        });
        self.persist_snapshot(snap.0, snap.1);
    }

    pub fn markup_color(&self, kind: MarkupKind) -> String {
        let guard = self.inner.lock().expect("config mutex poisoned");
        match kind {
            MarkupKind::Highlight => guard.data.highlight_color.clone(),
            MarkupKind::Underline => guard.data.underline_color.clone(),
            MarkupKind::StrikeOut => guard.data.strikeout_color.clone(),
        }
    }

    pub fn set_markup_color(&self, kind: MarkupKind, hex: &str) {
        if parse_hex_rgb(hex).is_none() {
            return;
        }
        let normalized = hex.to_ascii_uppercase();
        let snap = self.mutate(|d| match kind {
            MarkupKind::Highlight => d.highlight_color = normalized,
            MarkupKind::Underline => d.underline_color = normalized,
            MarkupKind::StrikeOut => d.strikeout_color = normalized,
        });
        self.persist_snapshot(snap.0, snap.1);
    }

    pub fn note_color(&self) -> String {
        self.inner
            .lock()
            .expect("config mutex poisoned")
            .data
            .note_color
            .clone()
    }

    pub fn set_note_color(&self, hex: &str) {
        if parse_hex_rgb(hex).is_none() {
            return;
        }
        let normalized = hex.to_ascii_uppercase();
        let snap = self.mutate(|d| {
            d.note_color = normalized;
        });
        self.persist_snapshot(snap.0, snap.1);
    }
}

fn write_json_atomic(path: &Path, data: &ConfigData) -> std::io::Result<()> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    let bytes = serde_json::to_vec_pretty(data).map_err(std::io::Error::other)?;
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let seq = CFG_TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = parent.join(format!(
        ".{}.{}-{}.tmp",
        path.file_name().unwrap_or_default().to_string_lossy(),
        std::process::id(),
        seq
    ));
    let write_res = (|| -> std::io::Result<()> {
        let mut f = File::create(&tmp)?;
        f.write_all(&bytes)?;
        f.sync_all()
    })();
    if let Err(e) = write_res {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    if let Err(e) = fs::rename(&tmp, path) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Color helpers (sRGB hex <-> [f64; 3] <-> gpui rgba u32)
// ---------------------------------------------------------------------------

pub fn parse_hex_rgb(hex: &str) -> Option<[f64; 3]> {
    let s = hex.trim().strip_prefix('#').unwrap_or(hex.trim());
    if s.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&s[0..2], 16).ok()?;
    let g = u8::from_str_radix(&s[2..4], 16).ok()?;
    let b = u8::from_str_radix(&s[4..6], 16).ok()?;
    Some([f64::from(r) / 255.0, f64::from(g) / 255.0, f64::from(b) / 255.0])
}

pub fn rgb_to_rgba_u32(rgb: [f32; 3], alpha: u8) -> u32 {
    let r = (rgb[0].clamp(0.0, 1.0) * 255.0).round() as u32;
    let g = (rgb[1].clamp(0.0, 1.0) * 255.0).round() as u32;
    let b = (rgb[2].clamp(0.0, 1.0) * 255.0).round() as u32;
    (r << 24) | (g << 16) | (b << 8) | (alpha as u32)
}

pub fn hex_to_rgba_u32(hex: &str, alpha: u8) -> u32 {
    if let Some([r, g, b]) = parse_hex_rgb(hex) {
        rgb_to_rgba_u32([r as f32, g as f32, b as f32], alpha)
    } else {
        0xFFD60A00 | (alpha as u32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    fn temp_cfg_path(name: &str) -> PathBuf {
        let seq = CFG_TMP_SEQ.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!("yopdf-cfg-test-{}-{}-{name}.json", std::process::id(), seq))
    }

    #[test]
    fn recents_dedup_order_and_cap_at_10() {
        let p = temp_cfg_path("recents");
        let cfg = AppConfig::load_from_path(p.clone());
        for i in 0..15 {
            cfg.touch_recent(&format!("/docs/{i}.pdf"), i, 1.25);
        }
        let rec = cfg.recents();
        assert_eq!(rec.len(), MAX_RECENTS);
        assert_eq!(rec[0].path, "/docs/14.pdf");
        assert_eq!(rec[9].path, "/docs/5.pdf");

        // Re-opening an older item moves it to front without duplicating.
        cfg.touch_recent("/docs/7.pdf", 3, 1.5);
        let rec2 = cfg.recents();
        assert_eq!(rec2.len(), MAX_RECENTS);
        assert_eq!(rec2[0].path, "/docs/7.pdf");
        assert_eq!(rec2[0].page, 3);
        let _ = fs::remove_file(p);
    }

    #[test]
    fn stale_snapshot_cannot_overwrite_newer_state() {
        let p = temp_cfg_path("stale");
        let cfg = AppConfig::load_from_path(p.clone());

        let (gen1, snap1) = cfg.mutate_without_persist(|d| {
            d.recents.push(RecentDoc {
                path: "/older.pdf".into(),
                opened_at_unix: 1,
                page: 0,
                zoom: 1.0,
            });
        });
        let (gen2, snap2) = cfg.mutate_without_persist(|d| {
            d.recents.insert(
                0,
                RecentDoc {
                    path: "/newer.pdf".into(),
                    opened_at_unix: 2,
                    page: 4,
                    zoom: 1.5,
                },
            );
        });
        assert!(gen2 > gen1);

        // Newer arrives on disk first, then older arrives late.
        cfg.persist_snapshot(gen2, snap2);
        cfg.persist_snapshot(gen1, snap1);

        let reloaded = AppConfig::load_from_path(p.clone());
        let rec = reloaded.recents();
        assert_eq!(rec.len(), 2);
        assert_eq!(rec[0].path, "/newer.pdf");
        let _ = fs::remove_file(p);
    }

    #[test]
    fn concurrent_mutations_converge_to_newest_generation() {
        let p = temp_cfg_path("concurrent");
        let cfg = Arc::new(AppConfig::load_from_path(p.clone()));
        let mut handles = Vec::new();
        for t in 0..8 {
            let c = Arc::clone(&cfg);
            handles.push(thread::spawn(move || {
                for j in 0..20 {
                    c.touch_recent(&format!("/t{t}/doc{j}.pdf"), j, 1.0);
                }
            }));
        }
        for h in handles {
            h.join().expect("worker thread must not deadlock or panic");
        }
        let in_mem = cfg.recents();
        let on_disk = AppConfig::load_from_path(p.clone()).recents();
        assert_eq!(in_mem.first().map(|r| &r.path), on_disk.first().map(|r| &r.path));
        let _ = fs::remove_file(p);
    }

    #[test]
    fn colors_and_preferences_persist_across_reload() {
        let p = temp_cfg_path("prefs");
        let cfg = AppConfig::load_from_path(p.clone());
        cfg.set_dark_mode("dark");
        cfg.set_markup_color(MarkupKind::Highlight, "#ff2d55");
        cfg.set_markup_color(MarkupKind::Underline, "#34c759");
        cfg.set_markup_color(MarkupKind::StrikeOut, "#af52de");
        cfg.set_note_color("#007aff");

        let reloaded = AppConfig::load_from_path(p.clone());
        assert_eq!(reloaded.dark_mode(), "dark");
        assert_eq!(reloaded.markup_color(MarkupKind::Highlight), "#FF2D55");
        assert_eq!(reloaded.markup_color(MarkupKind::Underline), "#34C759");
        assert_eq!(reloaded.markup_color(MarkupKind::StrikeOut), "#AF52DE");
        assert_eq!(reloaded.note_color(), "#007AFF");
        let _ = fs::remove_file(p);
    }
}
