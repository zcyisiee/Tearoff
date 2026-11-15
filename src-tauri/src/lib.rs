mod error;
mod finder;
mod legacy;
mod panel;
mod settings;
mod vault;

use error::{Error, Result};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use parking_lot::Mutex;
use serde::Serialize;
use settings::Settings;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tauri_plugin_opener::OpenerExt;
use vault::{FolderCard, NoteContent, NoteMeta, SearchHit, Vault};

/// Surface for integration tests (`tests/`); not used by the app itself.
pub mod testing {
    pub use crate::finder::{list_dir, move_into, new_folder, rename};
    pub use crate::vault::{preview_of, Vault};
}

pub struct AppState {
    pub vault: Mutex<Vault>,
    pub settings: Mutex<Settings>,
    settings_file: PathBuf,
    pub panel: panel::PanelState,
    watch: Mutex<Watch>,
}

/// One filesystem watcher for the vault (recursive) and for whatever
/// directories the folder cards are currently showing.
#[derive(Default)]
struct Watch {
    watcher: Option<RecommendedWatcher>,
    vault_root: PathBuf,
    dirs: HashSet<PathBuf>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AppSnapshot {
    notes: Vec<NoteMeta>,
    folder_cards: Vec<FolderCard>,
    settings: Settings,
    today: String,
    panel_pinned: bool,
    panel_shown: bool,
}

fn card_dirs(cards: &[FolderCard]) -> HashSet<PathBuf> {
    cards
        .iter()
        .filter_map(|c| {
            c.current_path.clone().or_else(|| {
                let fav = c.favorites.iter().find(|f| Some(&f.id) == c.selected_favorite.as_ref()).or(c.favorites.first())?;
                Some(fav.path.clone())
            })
        })
        .map(PathBuf::from)
        .collect()
}

/// Point the watcher at the current vault and folder-card directories.
fn sync_watches(state: &AppState) {
    let (root, dirs) = {
        let vault = state.vault.lock();
        (vault.root().to_path_buf(), card_dirs(&vault.folder_cards()))
    };
    let mut guard = state.watch.lock();
    let Watch { watcher, vault_root, dirs: watched } = &mut *guard;
    let Some(watcher) = watcher.as_mut() else { return };
    if *vault_root != root {
        let _ = watcher.unwatch(vault_root);
        let _ = watcher.watch(&root, RecursiveMode::Recursive);
    }
    for gone in watched.difference(&dirs) {
        let _ = watcher.unwatch(gone);
    }
    for new in dirs.difference(watched) {
        let _ = watcher.watch(new, RecursiveMode::NonRecursive);
    }
    *vault_root = root;
    *watched = dirs;
}

fn start_watcher(app: &AppHandle) {
    let (tx, rx) = mpsc::channel::<PathBuf>();
    let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if let Ok(event) = event {
            if matches!(event.kind, notify::EventKind::Access(_)) {
                return;
            }
            for path in event.paths {
                let _ = tx.send(path);
            }
        }
    });
    let state = app.state::<AppState>();
    state.watch.lock().watcher = watcher.ok();
    sync_watches(&state);

    let app = app.clone();
    std::thread::spawn(move || {
        // Collect a burst of events, then tell the UI once.
        while let Ok(first) = rx.recv() {
            let mut paths = vec![first];
            while let Ok(more) = rx.recv_timeout(Duration::from_millis(250)) {
                paths.push(more);
            }
            let state = app.state::<AppState>();
            // The OS reports canonical paths (/private/tmp/… for /tmp/…), so
            // compare canonically but answer with the path the UI knows.
            let canon = |p: &Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
            let (root, dirs) = {
                let w = state.watch.lock();
                (canon(&w.vault_root), w.dirs.iter().map(|d| (canon(d), d.clone())).collect::<Vec<_>>())
            };
            let mut vault_changed = false;
            let mut changed_dirs = HashSet::new();
            for p in &paths {
                let internal = p.components().any(|c| c.as_os_str() == vault::SIDECAR_DIR)
                    || p.file_name().is_some_and(|n| n.to_string_lossy().ends_with(".tearoff-tmp"));
                if p.starts_with(&root) && !internal {
                    vault_changed = true;
                }
                for (canonical, original) in &dirs {
                    if p.parent() == Some(canonical.as_path()) || p == canonical {
                        changed_dirs.insert(original.clone());
                    }
                }
            }
            if vault_changed {
                let _ = app.emit("vault-changed", ());
            }
            for d in changed_dirs {
                let _ = app.emit("dir-changed", d.to_string_lossy().into_owned());
            }
        }
    });
}

// ── Notes ───────────────────────────────────────────────────────────────

#[tauri::command]
fn get_state(state: State<AppState>) -> AppSnapshot {
    let vault = state.vault.lock();
    AppSnapshot {
        notes: vault.list_notes(),
        folder_cards: vault.folder_cards(),
        settings: state.settings.lock().clone(),
        today: chrono::Local::now().format("%Y-%m-%d").to_string(),
        panel_pinned: state.panel.pinned.load(Ordering::SeqCst),
        panel_shown: state.panel.shown.load(Ordering::SeqCst),
    }
}

#[tauri::command]
fn read_note(state: State<AppState>, path: String) -> Result<NoteContent> {
    state.vault.lock().read_note(&path)
}

#[tauri::command]
fn write_note(state: State<AppState>, path: String, content: String, base_modified: Option<i64>) -> Result<NoteMeta> {
    state.vault.lock().write_note(&path, &content, base_modified)
}

#[tauri::command]
fn create_note(state: State<AppState>, title: Option<String>) -> Result<NoteMeta> {
    state.vault.lock().create_note(title.as_deref())
}

#[tauri::command]
fn rename_note(state: State<AppState>, path: String, title: String) -> Result<NoteMeta> {
    state.vault.lock().rename_note(&path, &title)
}

#[tauri::command]
fn delete_note(state: State<AppState>, path: String) -> Result<()> {
    state.vault.lock().delete_note(&path)
}

#[tauri::command]
fn set_pinned(state: State<AppState>, path: String, pinned: bool) -> Result<()> {
    state.vault.lock().set_pinned(&path, pinned)
}

#[tauri::command]
fn reorder_cards(state: State<AppState>, keys: Vec<String>) -> Result<()> {
    state.vault.lock().reorder_cards(&keys)
}

#[tauri::command]
fn search(state: State<AppState>, query: String) -> Vec<SearchHit> {
    state.vault.lock().search(&query)
}

#[tauri::command]
fn save_image(state: State<AppState>, note_path: String, name: String, data_base64: String) -> Result<String> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD.decode(data_base64).map_err(|e| Error::Other(e.to_string()))?;
    state.vault.lock().save_image(&note_path, &name, &bytes)
}

// ── Folder cards ────────────────────────────────────────────────────────

#[tauri::command]
fn create_folder_card(state: State<AppState>, dir: String) -> Result<FolderCard> {
    let card = state.vault.lock().create_folder_card(&dir)?;
    sync_watches(&state);
    Ok(card)
}

#[tauri::command]
fn update_folder_card(state: State<AppState>, card: FolderCard) -> Result<()> {
    state.vault.lock().update_folder_card(card)?;
    sync_watches(&state);
    Ok(())
}

#[tauri::command]
fn delete_folder_card(state: State<AppState>, id: String) -> Result<()> {
    state.vault.lock().delete_folder_card(&id)?;
    sync_watches(&state);
    Ok(())
}

#[tauri::command]
fn list_dir(path: String, show_hidden: bool) -> Result<Vec<finder::DirEntry>> {
    finder::list_dir(Path::new(&path), show_hidden)
}

#[tauri::command]
fn fs_move(sources: Vec<String>, dest_dir: String, copy: bool) -> Result<()> {
    let sources: Vec<PathBuf> = sources.into_iter().map(PathBuf::from).collect();
    finder::move_into(&sources, Path::new(&dest_dir), copy)
}

#[tauri::command]
fn fs_rename(path: String, new_name: String) -> Result<()> {
    finder::rename(Path::new(&path), new_name.trim())
}

#[tauri::command]
fn fs_trash(paths: Vec<String>) -> Result<()> {
    finder::trash(&paths.into_iter().map(PathBuf::from).collect::<Vec<_>>())
}

#[tauri::command]
fn fs_new_folder(dir: String) -> Result<String> {
    Ok(finder::new_folder(Path::new(&dir))?.to_string_lossy().into_owned())
}

#[tauri::command]
fn open_path(app: AppHandle, path: String) -> Result<()> {
    let is_url = path.split_once(':').is_some_and(|(scheme, _)| scheme.len() > 1 && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c)));
    let result = if is_url { app.opener().open_url(path, None::<&str>) } else { app.opener().open_path(path, None::<&str>) };
    result.map_err(|e| Error::Other(e.to_string()))
}

#[tauri::command]
fn reveal_path(app: AppHandle, path: String) -> Result<()> {
    app.opener().reveal_item_in_dir(path).map_err(|e| Error::Other(e.to_string()))
}

// ── Settings and panel ──────────────────────────────────────────────────

fn register_shortcut(app: &AppHandle, shortcut: &str) -> Result<()> {
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    if shortcut.trim().is_empty() {
        return Ok(());
    }
    gs.register(shortcut.trim()).map_err(|e| Error::Other(format!("快捷键“{shortcut}”无法使用：{e}")))
}

#[tauri::command]
fn set_settings(app: AppHandle, state: State<AppState>, settings: Settings) -> Result<()> {
    let mut next = settings;
    next.sanitize();
    let previous = state.settings.lock().clone();
    if next.vault_path != previous.vault_path {
        let vault = Vault::open(PathBuf::from(&next.vault_path))?;
        *state.vault.lock() = vault;
    }
    if next.toggle_shortcut != previous.toggle_shortcut {
        if let Err(e) = register_shortcut(&app, &next.toggle_shortcut) {
            let _ = register_shortcut(&app, &previous.toggle_shortcut);
            return Err(e);
        }
    }
    next.save(&state.settings_file)?;
    let reposition = next.side != previous.side || next.panel_width != previous.panel_width;
    *state.settings.lock() = next;
    sync_watches(&state);
    if reposition && state.panel.shown.load(Ordering::SeqCst) {
        panel::show(&app, false);
    }
    Ok(())
}

#[tauri::command]
fn set_panel_pinned(state: State<AppState>, pinned: bool) {
    state.panel.pinned.store(pinned, Ordering::SeqCst);
}

#[tauri::command]
fn set_panel_busy(state: State<AppState>, busy: bool) {
    let n = state.panel.busy.fetch_add(if busy { 1 } else { -1 }, Ordering::SeqCst);
    if !busy && n <= 0 {
        state.panel.busy.store(0, Ordering::SeqCst);
    }
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    panel::hide(&app);
}

/// Development self-test sink: the frontend reports what it verified through
/// the real IPC bridge. Only active when `TEAROFF_SELFTEST` names a file.
#[tauri::command]
fn selftest_report(report: Option<String>) -> bool {
    let Some(file) = std::env::var_os("TEAROFF_SELFTEST") else { return false };
    if let Some(report) = report {
        let _ = std::fs::write(file, report);
    }
    true
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.exit(0);
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    use tauri::menu::{Menu, MenuItem};
    use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
    let show = MenuItem::with_id(app, "show", "显示 Tearoff", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "退出 Tearoff", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &quit])?;
    TrayIconBuilder::with_id("tearoff")
        .icon(tauri::image::Image::from_bytes(include_bytes!("../icons/tray.png"))?)
        .icon_as_template(true)
        .tooltip("Tearoff")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "show" => panel::show(app, true),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                panel::toggle(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_drag::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state() == ShortcutState::Pressed {
                        panel::toggle(app);
                    }
                })
                .build(),
        )
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let handle = app.handle().clone();
            let config_dir = std::env::var_os("TEAROFF_CONFIG_DIR").map(PathBuf::from).unwrap_or(app.path().app_config_dir()?);
            let settings_file = config_dir.join("settings.json");
            let default_vault = app.path().document_dir().unwrap_or_else(|_| config_dir.clone()).join("Tearoff");
            let mut settings = Settings::load(&settings_file, default_vault);
            // Development and tests point the app at a throwaway vault.
            if let Some(vault) = std::env::var_os("TEAROFF_VAULT") {
                settings.vault_path = PathBuf::from(vault).to_string_lossy().into_owned();
            }
            let vault = Vault::open(PathBuf::from(&settings.vault_path))?;
            let shortcut = settings.toggle_shortcut.clone();
            let width = settings.panel_width;

            app.manage(AppState {
                vault: Mutex::new(vault),
                settings: Mutex::new(settings),
                settings_file,
                panel: panel::PanelState::default(),
                watch: Mutex::new(Watch::default()),
            });

            let builder = WebviewWindowBuilder::new(app, panel::LABEL, WebviewUrl::App("index.html".into()))
                .title("Tearoff")
                .inner_size(width, 800.0)
                .decorations(false)
                .transparent(true)
                .shadow(false)
                .resizable(false)
                .always_on_top(true)
                .skip_taskbar(true)
                .visible_on_all_workspaces(true)
                .visible(false);
            #[cfg(target_os = "macos")]
            let builder = builder.accept_first_mouse(true);
            let win = builder.build()?;
            panel::configure(&win);
            let blur_handle = handle.clone();
            win.on_window_event(move |event| {
                if let tauri::WindowEvent::Focused(false) = event {
                    panel::on_blur(&blur_handle);
                }
            });

            if let Err(e) = register_shortcut(&handle, &shortcut) {
                eprintln!("tearoff: {e}");
            }
            build_tray(&handle)?;
            start_watcher(&handle);
            panel::spawn_watcher(handle.clone());

            if std::env::var_os("TEAROFF_SHOW").is_some() {
                handle.state::<AppState>().panel.pinned.store(true, Ordering::SeqCst);
                let h = handle.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(900));
                    panel::show(&h, false);
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_state, read_note, write_note, create_note, rename_note, delete_note, set_pinned, reorder_cards, search, save_image,
            create_folder_card, update_folder_card, delete_folder_card, list_dir, fs_move, fs_rename, fs_trash, fs_new_folder,
            open_path, reveal_path, set_settings, set_panel_pinned, set_panel_busy, hide_panel, quit, selftest_report,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Tearoff");
}
