//! One-way import from the Swift app's `.tearoff/meta.json`. Read-only: the
//! legacy file is never written, so the old app keeps working on the same vault.

use crate::vault::{Favorite, FolderCard, NoteEntry, Sidecar};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::Path;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyNote {
    path: String,
    created_at: Option<String>,
    pinned: Option<bool>,
    sort_order: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyFavorite {
    id: String,
    path: String,
    display_name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyFinderCard {
    title: Option<String>,
    #[serde(default)]
    favorites: Vec<LegacyFavorite>,
    #[serde(rename = "selectedFavoriteID")]
    selected_favorite_id: Option<String>,
    current_path: Option<String>,
    sort_order: Option<i64>,
    list_height: Option<f64>,
    view_mode: Option<String>,
    sort_key: Option<String>,
    sort_ascending: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyPayload {
    #[serde(default)]
    notes: HashMap<String, LegacyNote>,
    #[serde(default)]
    finder_cards: HashMap<String, LegacyFinderCard>,
}

fn parse_iso(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp_millis())
}

pub fn import(meta_json: &Path) -> Option<Sidecar> {
    let bytes = std::fs::read(meta_json).ok()?;
    let legacy: LegacyPayload = serde_json::from_slice(&bytes).ok()?;
    let mut sidecar = Sidecar { version: 1, ..Default::default() };

    for note in legacy.notes.into_values() {
        let entry = NoteEntry {
            pinned: note.pinned.unwrap_or(false),
            order: if note.pinned.unwrap_or(false) { note.sort_order } else { None },
            created: note.created_at.as_deref().and_then(parse_iso),
        };
        if entry != NoteEntry::default() {
            sidecar.notes.insert(note.path.replace('\\', "/"), entry);
        }
    }

    let mut cards: Vec<(String, LegacyFinderCard)> = legacy.finder_cards.into_iter().collect();
    cards.sort_by(|a, b| a.1.sort_order.unwrap_or(i64::MAX).cmp(&b.1.sort_order.unwrap_or(i64::MAX)).then(a.0.cmp(&b.0)));
    for (id, card) in cards {
        sidecar.folder_cards.push(FolderCard {
            id,
            title: card.title.filter(|t| !t.trim().is_empty()),
            favorites: card.favorites.into_iter().map(|f| Favorite { id: f.id, path: f.path, name: f.display_name }).collect(),
            selected_favorite: card.selected_favorite_id,
            current_path: card.current_path,
            view_mode: match card.view_mode.as_deref() {
                Some("list") => "list".into(),
                _ => "icon".into(),
            },
            sort_key: match card.sort_key.as_deref() {
                Some("kind") => "kind".into(),
                Some("modifiedDate") => "modified".into(),
                _ => "name".into(),
            },
            sort_asc: card.sort_ascending.unwrap_or(true),
            list_height: card.list_height.unwrap_or(240.0),
            order: card.sort_order,
        });
    }
    Some(sidecar)
}
