//! The vault: a folder of `.md` files plus one sidecar, `.tearoff/v5.json`.
//!
//! Notes are identified by their vault-relative path. The sidecar only holds
//! what a file cannot (pin, manual order, creation time, folder cards) and is
//! owned exclusively by this version of the app — the legacy `meta.json`
//! written by the Swift app is read once for import and never modified.

use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;

pub const SIDECAR_DIR: &str = ".tearoff";
const SIDECAR_FILE: &str = "v5.json";
const LEGACY_FILE: &str = "meta.json";
const MAX_DEPTH: usize = 8;
const PREVIEW_BYTES: usize = 2400;
const PREVIEW_CHARS: usize = 240;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NoteMeta {
    pub path: String,
    pub title: String,
    pub folder: String,
    pub created: i64,
    pub modified: i64,
    pub pinned: bool,
    pub order: Option<i64>,
    pub preview: String,
    pub daily_date: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Favorite {
    pub id: String,
    pub path: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FolderCard {
    pub id: String,
    pub title: Option<String>,
    pub favorites: Vec<Favorite>,
    pub selected_favorite: Option<String>,
    pub current_path: Option<String>,
    pub view_mode: String,
    pub sort_key: String,
    pub sort_asc: bool,
    pub list_height: f64,
    pub order: Option<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NoteEntry {
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub order: Option<i64>,
    #[serde(default)]
    pub created: Option<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sidecar {
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub notes: BTreeMap<String, NoteEntry>,
    #[serde(default)]
    pub folder_cards: Vec<FolderCard>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteContent {
    pub content: String,
    pub modified: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub path: String,
    pub title: String,
    pub snippet: String,
}

pub struct Vault {
    root: PathBuf,
    sidecar: Sidecar,
}

fn mtime_ms(meta: &fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn created_ms(meta: &fs::Metadata) -> i64 {
    meta.created()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or_else(|| mtime_ms(meta))
}

fn is_daily_title(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 10
        && b.iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            _ => c.is_ascii_digit(),
        })
}

/// Body text with markdown syntax removed, for one-line list previews.
pub fn preview_of(markdown: &str) -> String {
    let mut body = markdown;
    if let Some(rest) = body.strip_prefix("---\n") {
        if let Some(end) = rest.find("\n---") {
            body = rest[end + 4..].trim_start_matches(['\r', '\n']);
        }
    }
    let mut out = String::new();
    let mut in_fence = false;
    for line in body.lines() {
        let mut t = line.trim();
        if t.starts_with("```") || t.starts_with("~~~") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence || t.is_empty() {
            continue;
        }
        if t.chars().all(|c| matches!(c, '-' | '*' | '_' | '=' | ' ' | '|' | ':')) {
            continue;
        }
        t = t.trim_start_matches(['#', '>', ' ']);
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "- ", "* ", "+ "] {
            if let Some(rest) = t.strip_prefix(marker) {
                t = rest;
                break;
            }
        }
        let digits = t.chars().take_while(|c| c.is_ascii_digit()).count();
        if digits > 0 && (t[digits..].starts_with(". ") || t[digits..].starts_with(") ")) {
            t = &t[digits + 2..];
        }
        for c in t.chars() {
            if !matches!(c, '*' | '_' | '~' | '`' | '=') {
                out.push(c);
            }
        }
        out.push(' ');
        if out.chars().count() >= PREVIEW_CHARS {
            break;
        }
    }
    out.trim().chars().take(PREVIEW_CHARS).collect()
}

fn read_head(path: &Path) -> String {
    let mut buf = Vec::with_capacity(PREVIEW_BYTES);
    if let Ok(f) = fs::File::open(path) {
        let _ = f.take(PREVIEW_BYTES as u64).read_to_end(&mut buf);
    }
    String::from_utf8_lossy(&buf).into_owned()
}

/// Write-then-rename so a crash never leaves a half-written note.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let name = path.file_name().and_then(|n| n.to_str()).ok_or(Error::InvalidPath)?;
    let tmp = path.with_file_name(format!(".{name}.tearoff-tmp"));
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, path).inspect_err(|_| {
        let _ = fs::remove_file(&tmp);
    })?;
    Ok(())
}

pub fn sanitize_title(title: &str) -> String {
    let cleaned: String = title
        .chars()
        .filter(|c| !matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') && !c.is_control())
        .collect();
    cleaned.trim().trim_matches('.').trim().to_string()
}

impl Vault {
    pub fn open(root: PathBuf) -> Result<Self> {
        fs::create_dir_all(&root)?;
        let mut vault = Vault { root, sidecar: Sidecar::default() };
        let own = vault.sidecar_path();
        if own.exists() {
            vault.sidecar = serde_json::from_slice(&fs::read(&own)?).unwrap_or_default();
        } else if let Some(imported) = crate::legacy::import(&vault.root.join(SIDECAR_DIR).join(LEGACY_FILE)) {
            vault.sidecar = imported;
            vault.save_sidecar()?;
        }
        vault.sidecar.version = 1;
        Ok(vault)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn sidecar_path(&self) -> PathBuf {
        self.root.join(SIDECAR_DIR).join(SIDECAR_FILE)
    }

    fn save_sidecar(&self) -> Result<()> {
        atomic_write(&self.sidecar_path(), &serde_json::to_vec_pretty(&self.sidecar)?)
    }

    /// Resolve a vault-relative note path, refusing anything that could leave the vault.
    pub fn resolve(&self, rel: &str) -> Result<PathBuf> {
        let p = Path::new(rel);
        if rel.is_empty() || !rel.ends_with(".md") || p.components().any(|c| !matches!(c, Component::Normal(_))) {
            return Err(Error::InvalidPath);
        }
        Ok(self.root.join(p))
    }

    fn meta_for(&self, rel: &str, with_preview: bool) -> Result<NoteMeta> {
        let abs = self.resolve(rel)?;
        let fsm = fs::metadata(&abs).map_err(|_| Error::NotFound)?;
        let entry = self.sidecar.notes.get(rel).cloned().unwrap_or_default();
        let (folder, file) = match rel.rfind('/') {
            Some(i) => (&rel[..i], &rel[i + 1..]),
            None => ("", rel),
        };
        let title = file.trim_end_matches(".md").to_string();
        let daily_date = (folder.split('/').next() == Some("Daily") && is_daily_title(&title)).then(|| title.clone());
        Ok(NoteMeta {
            path: rel.to_string(),
            folder: folder.to_string(),
            created: entry.created.unwrap_or_else(|| created_ms(&fsm)),
            modified: mtime_ms(&fsm),
            pinned: entry.pinned,
            order: entry.order,
            preview: if with_preview { preview_of(&read_head(&abs)) } else { String::new() },
            daily_date,
            title,
        })
    }

    pub fn list_notes(&self) -> Vec<NoteMeta> {
        let mut out = Vec::new();
        let walker = walkdir::WalkDir::new(&self.root).max_depth(MAX_DEPTH).into_iter().filter_entry(|e| {
            let name = e.file_name().to_string_lossy();
            e.depth() == 0 || !(name.starts_with('.') || (e.file_type().is_dir() && (name == "assets" || name == "node_modules")))
        });
        for entry in walker.flatten() {
            if !entry.file_type().is_file() || entry.path().extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            let Ok(rel) = entry.path().strip_prefix(&self.root) else { continue };
            let rel = rel.components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/");
            if let Ok(meta) = self.meta_for(&rel, true) {
                out.push(meta);
            }
        }
        out
    }

    pub fn folder_cards(&self) -> Vec<FolderCard> {
        self.sidecar.folder_cards.clone()
    }

    pub fn read_note(&self, rel: &str) -> Result<NoteContent> {
        let abs = self.resolve(rel)?;
        match fs::read(&abs) {
            Ok(bytes) => Ok(NoteContent {
                content: String::from_utf8_lossy(&bytes).into_owned(),
                modified: mtime_ms(&fs::metadata(&abs)?),
            }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(NoteContent { content: String::new(), modified: 0 }),
            Err(e) => Err(e.into()),
        }
    }

    /// Write a note. `base_modified` is the mtime the caller last saw; if the
    /// file has moved on since, the write is refused so nothing is clobbered.
    pub fn write_note(&mut self, rel: &str, content: &str, base_modified: Option<i64>) -> Result<NoteMeta> {
        let abs = self.resolve(rel)?;
        let existing = fs::metadata(&abs).ok();
        if let (Some(base), Some(meta)) = (base_modified, &existing) {
            if mtime_ms(meta) != base {
                return Err(Error::Conflict);
            }
        }
        atomic_write(&abs, content.as_bytes())?;
        if existing.is_none() {
            let now = chrono::Utc::now().timestamp_millis();
            self.sidecar.notes.entry(rel.to_string()).or_default().created = Some(now);
            self.save_sidecar()?;
        }
        self.meta_for(rel, true)
    }

    pub fn create_note(&mut self, title: Option<&str>) -> Result<NoteMeta> {
        let base = title.map(sanitize_title).filter(|t| !t.is_empty()).unwrap_or_else(|| "未命名".to_string());
        let mut name = base.clone();
        let mut i = 2;
        while self.root.join(format!("{name}.md")).exists() {
            name = format!("{base} {i}");
            i += 1;
        }
        self.write_note(&format!("{name}.md"), "", None)
    }

    pub fn rename_note(&mut self, rel: &str, title: &str) -> Result<NoteMeta> {
        let title = sanitize_title(title);
        if title.is_empty() {
            return Err(Error::InvalidPath);
        }
        let from = self.resolve(rel)?;
        let folder = rel.rfind('/').map(|i| &rel[..=i]).unwrap_or("");
        let next = format!("{folder}{title}.md");
        if next == rel {
            return self.meta_for(rel, true);
        }
        let to = self.resolve(&next)?;
        // Case-only renames on case-insensitive volumes point at the same file.
        let same_file = next.to_lowercase() == rel.to_lowercase();
        if to.exists() && !same_file {
            return Err(Error::Exists(title));
        }
        if !from.exists() {
            return Err(Error::NotFound);
        }
        fs::rename(&from, &to)?;
        if let Some(entry) = self.sidecar.notes.remove(rel) {
            self.sidecar.notes.insert(next.clone(), entry);
            self.save_sidecar()?;
        }
        self.meta_for(&next, true)
    }

    /// Notes are never destroyed by the app: deletion means the system trash.
    pub fn delete_note(&mut self, rel: &str) -> Result<()> {
        let abs = self.resolve(rel)?;
        if abs.exists() {
            trash::delete(&abs).map_err(|e| Error::Other(e.to_string()))?;
        }
        if self.sidecar.notes.remove(rel).is_some() {
            self.save_sidecar()?;
        }
        Ok(())
    }

    pub fn set_pinned(&mut self, rel: &str, pinned: bool) -> Result<()> {
        self.resolve(rel)?;
        let entry = self.sidecar.notes.entry(rel.to_string()).or_default();
        entry.pinned = pinned;
        if !pinned {
            entry.order = None;
        }
        self.prune();
        self.save_sidecar()
    }

    /// Keys are `note:<path>` or `folder:<id>` in display order.
    pub fn reorder_cards(&mut self, keys: &[String]) -> Result<()> {
        for (i, key) in keys.iter().enumerate() {
            if let Some(rel) = key.strip_prefix("note:") {
                self.sidecar.notes.entry(rel.to_string()).or_default().order = Some(i as i64);
            } else if let Some(id) = key.strip_prefix("folder:") {
                if let Some(card) = self.sidecar.folder_cards.iter_mut().find(|c| c.id == id) {
                    card.order = Some(i as i64);
                }
            }
        }
        self.save_sidecar()
    }

    /// Drop sidecar entries that say nothing or point at files that are gone.
    fn prune(&mut self) {
        let root = self.root.clone();
        self.sidecar.notes.retain(|rel, e| (*e != NoteEntry::default()) && root.join(rel).exists());
    }

    pub fn search(&self, query: &str) -> Vec<SearchHit> {
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            return Vec::new();
        }
        let mut hits = Vec::new();
        for note in self.list_notes() {
            let Ok(abs) = self.resolve(&note.path) else { continue };
            let content = fs::read(&abs).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
            let lower = content.to_lowercase();
            let snippet = match lower.find(&q) {
                Some(byte) => {
                    // Work in chars of the lowercased text to stay on boundaries.
                    let at = lower[..byte].chars().count();
                    let chars: Vec<char> = content.chars().collect();
                    let start = at.saturating_sub(18).min(chars.len());
                    let end = (at + 60).min(chars.len());
                    chars[start..end].iter().collect::<String>().split_whitespace().collect::<Vec<_>>().join(" ")
                }
                None if note.title.to_lowercase().contains(&q) => note.preview.chars().take(80).collect(),
                None => continue,
            };
            hits.push(SearchHit { path: note.path, title: note.title, snippet });
            if hits.len() >= 60 {
                break;
            }
        }
        hits
    }

    /// Store a pasted image next to the note (Typora-style `assets/`) and
    /// return the note-relative markdown src.
    pub fn save_image(&self, note_rel: &str, name: &str, bytes: &[u8]) -> Result<String> {
        let note = self.resolve(note_rel)?;
        let dir = note.parent().ok_or(Error::InvalidPath)?.join("assets");
        fs::create_dir_all(&dir)?;
        let ext = Path::new(name)
            .extension()
            .and_then(|e| e.to_str())
            .filter(|e| e.chars().all(|c| c.is_ascii_alphanumeric()))
            .unwrap_or("png");
        let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S");
        let mut file = format!("image-{stamp}.{ext}");
        let mut i = 2;
        while dir.join(&file).exists() {
            file = format!("image-{stamp}-{i}.{ext}");
            i += 1;
        }
        fs::write(dir.join(&file), bytes)?;
        Ok(format!("assets/{file}"))
    }

    pub fn create_folder_card(&mut self, dir: &str) -> Result<FolderCard> {
        let name = Path::new(dir).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| dir.to_string());
        let fav = Favorite { id: new_id(), path: dir.to_string(), name };
        let card = FolderCard {
            id: new_id(),
            title: None,
            selected_favorite: Some(fav.id.clone()),
            favorites: vec![fav],
            current_path: None,
            view_mode: "list".into(),
            sort_key: "name".into(),
            sort_asc: true,
            list_height: 220.0,
            order: None,
        };
        self.sidecar.folder_cards.push(card.clone());
        self.save_sidecar()?;
        Ok(card)
    }

    pub fn update_folder_card(&mut self, card: FolderCard) -> Result<()> {
        match self.sidecar.folder_cards.iter_mut().find(|c| c.id == card.id) {
            Some(slot) => *slot = card,
            None => return Err(Error::NotFound),
        }
        self.save_sidecar()
    }

    pub fn delete_folder_card(&mut self, id: &str) -> Result<()> {
        self.sidecar.folder_cards.retain(|c| c.id != id);
        self.save_sidecar()
    }
}

pub fn new_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    let t = chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0) as u64;
    format!("{:x}-{:x}", t, N.fetch_add(1, Ordering::Relaxed))
}
