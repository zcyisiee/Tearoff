//! The edge panel: one frameless always-on-top window that slides out when the
//! pointer rests on a screen edge (or the global shortcut fires) and leaves
//! when the pointer does.
//!
//! All decisions run on one polling thread that reads the real cursor
//! position. Nothing depends on enter/leave events being delivered, so a drag
//! or a lost event can never strand the panel in the wrong state.

use crate::AppState;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, WebviewWindow};

pub const LABEL: &str = "panel";
const POLL: Duration = Duration::from_millis(40);
/// Slide-out animation in the webview; the window is hidden after it.
const SLIDE: Duration = Duration::from_millis(210);
/// Pointer may stray this far outside the panel without counting as leaving.
const GRACE: f64 = 8.0;
/// How close to the screen edge counts as touching it.
const EDGE_BAND: f64 = 2.0;

#[derive(Default)]
pub struct PanelState {
    pub shown: AtomicBool,
    pub pinned: AtomicBool,
    /// >0 while a menu, dialog or drag is in progress — never auto-hide then.
    pub busy: AtomicI32,
    /// The pointer has been inside since the panel was shown. Leaving only
    /// counts after entering, so a shortcut-summoned panel waits for the user.
    entered: AtomicBool,
    /// Bumped on every show/hide; a delayed hide checks it is still current.
    generation: AtomicU64,
    /// Where the panel was last placed, in window units.
    rect: parking_lot::Mutex<Rect>,
    #[cfg(target_os = "macos")]
    previous_app: AtomicI32,
}

fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(LABEL)
}

fn primary_button_down() -> bool {
    #[cfg(target_os = "macos")]
    {
        objc2_app_kit::NSEvent::pressedMouseButtons() & 1 != 0
    }
    #[cfg(target_os = "windows")]
    {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
        unsafe { GetAsyncKeyState(VK_LBUTTON as i32) < 0 }
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        false
    }
}

/// A rectangle in *window units*: logical points on macOS (where displays of
/// different scale share one point space), physical pixels elsewhere.
#[derive(Clone, Copy, Default, Debug)]
pub struct Rect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

impl Rect {
    fn contains(&self, (x, y): (f64, f64), grace: f64) -> bool {
        x >= self.x - grace && x <= self.x + self.w + grace && y >= self.y - grace && y <= self.y + self.h + grace
    }
}

/// Pointer position and the full bounds of the display it is on.
#[cfg(target_os = "macos")]
fn pointer(_app: &AppHandle) -> Option<((f64, f64), Rect)> {
    use core_graphics::display::CGDisplay;
    use core_graphics::event::CGEvent;
    use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
    let source = CGEventSource::new(CGEventSourceStateID::CombinedSessionState).ok()?;
    let p = CGEvent::new(source).ok()?.location();
    let cursor = (p.x, p.y);
    let displays = CGDisplay::active_displays().ok()?;
    let rects = displays.iter().map(|id| {
        let b = CGDisplay::new(*id).bounds();
        Rect { x: b.origin.x, y: b.origin.y, w: b.size.width, h: b.size.height }
    });
    let screen = rects.clone().find(|r| r.contains(cursor, 0.0)).or_else(|| rects.clone().next())?;
    Some((cursor, screen))
}

#[cfg(not(target_os = "macos"))]
fn pointer(app: &AppHandle) -> Option<((f64, f64), Rect)> {
    let c = app.cursor_position().ok()?;
    let m = app.monitor_from_point(c.x, c.y).ok().flatten().or_else(|| app.primary_monitor().ok().flatten())?;
    Some(((c.x, c.y), Rect { x: m.position().x as f64, y: m.position().y as f64, w: m.size().width as f64, h: m.size().height as f64 }))
}

/// Where the panel goes for a pointer at `cursor`: full usable height at the
/// chosen side of that display. Must run on the main thread.
#[cfg(target_os = "macos")]
fn target_rect(_app: &AppHandle, cursor: (f64, f64), side: &str, width: f64) -> Option<Rect> {
    let work = mac::work_area_at(cursor)?;
    let w = width.min(work.w);
    Some(Rect { x: if side == "left" { work.x } else { work.x + work.w - w }, y: work.y, w, h: work.h })
}

#[cfg(not(target_os = "macos"))]
fn target_rect(app: &AppHandle, cursor: (f64, f64), side: &str, width: f64) -> Option<Rect> {
    let m = app.monitor_from_point(cursor.0, cursor.1).ok().flatten().or_else(|| app.primary_monitor().ok().flatten())?;
    let work = m.work_area();
    let w = (width * m.scale_factor()).round().min(work.size.width as f64);
    let x = work.position.x as f64;
    Some(Rect { x: if side == "left" { x } else { x + work.size.width as f64 - w }, y: work.position.y as f64, w, h: work.size.height as f64 })
}

fn place(win: &WebviewWindow, r: Rect) {
    #[cfg(target_os = "macos")]
    {
        let _ = win.set_size(tauri::LogicalSize::new(r.w, r.h));
        let _ = win.set_position(tauri::LogicalPosition::new(r.x, r.y));
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = win.set_size(tauri::PhysicalSize::new(r.w, r.h));
        let _ = win.set_position(tauri::PhysicalPosition::new(r.x, r.y));
    }
}

pub fn show(app: &AppHandle, focus: bool, why: &str) {
    let state = app.state::<AppState>();
    let panel = &state.panel;
    let (side, width) = {
        let s = state.settings.lock();
        (s.side.clone(), s.panel_width)
    };
    let Some((cursor, _)) = pointer(app) else { return };
    let Some(win) = window(app) else { return };

    panel.generation.fetch_add(1, Ordering::SeqCst);
    let was_shown = panel.shown.swap(true, Ordering::SeqCst);
    if !was_shown {
        panel.entered.store(false, Ordering::SeqCst);
    }

    let app2 = app.clone();
    let why = why.to_string();
    let _ = app.run_on_main_thread(move || {
        let Some(rect) = target_rect(&app2, cursor, &side, width) else { return };
        *app2.state::<AppState>().panel.rect.lock() = rect;
        log::info!("panel show ({why}) focus={focus} at {rect:?}");
        place(&win, rect);
        #[cfg(target_os = "macos")]
        mac::remember_frontmost(&app2);
        if focus {
            let _ = win.show();
            let _ = win.set_focus();
        } else {
            #[cfg(target_os = "macos")]
            mac::order_front_without_activating(&win);
            #[cfg(not(target_os = "macos"))]
            let _ = win.show();
        }
        let _ = app2.emit("panel-shown", focus);
    });
}

pub fn hide(app: &AppHandle, why: &str) {
    let state = app.state::<AppState>();
    let panel = &state.panel;
    if !panel.shown.swap(false, Ordering::SeqCst) {
        return;
    }
    log::info!("panel hide ({why})");
    let generation = panel.generation.fetch_add(1, Ordering::SeqCst) + 1;
    let _ = app.emit("panel-hidden", ());
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(SLIDE);
        let app2 = app.clone();
        let _ = app.run_on_main_thread(move || {
            let state = app2.state::<AppState>();
            if state.panel.generation.load(Ordering::SeqCst) != generation {
                return; // shown again meanwhile
            }
            if let Some(win) = window(&app2) {
                let _ = win.hide();
            }
            #[cfg(target_os = "macos")]
            mac::give_focus_back(&app2);
        });
    });
}

pub fn toggle(app: &AppHandle, why: &str) {
    if app.state::<AppState>().panel.shown.load(Ordering::SeqCst) {
        hide(app, why);
    } else {
        show(app, true, why);
    }
}

/// Focus moved to another app while we had it: treat like the pointer leaving.
pub fn on_blur(app: &AppHandle) {
    let panel = &app.state::<AppState>().panel;
    if panel.pinned.load(Ordering::SeqCst) || panel.busy.load(Ordering::SeqCst) > 0 || primary_button_down() {
        log::debug!("blur ignored (pinned/busy/button down)");
        return;
    }
    hide(app, "lost focus");
}

pub fn spawn_watcher(app: AppHandle) {
    std::thread::spawn(move || {
        let mut at_edge_since: Option<Instant> = None;
        let mut outside_since: Option<Instant> = None;
        loop {
            std::thread::sleep(POLL);
            let state = app.state::<AppState>();
            let panel = &state.panel;
            let (side, edge_on, activation, hide_delay) = {
                let s = state.settings.lock();
                (s.side.clone(), s.edge_activation, Duration::from_millis(s.activation_delay_ms), Duration::from_millis(s.hide_delay_ms))
            };
            let Some((cursor, screen)) = pointer(&app) else { continue };

            if !panel.shown.load(Ordering::SeqCst) {
                outside_since = None;
                let touching = if side == "left" { cursor.0 <= screen.x + EDGE_BAND } else { cursor.0 >= screen.x + screen.w - EDGE_BAND };
                // A press at the edge is someone dragging a scrollbar or window, not asking for notes.
                if !(edge_on && touching) || primary_button_down() {
                    at_edge_since = None;
                    continue;
                }
                let since = *at_edge_since.get_or_insert_with(Instant::now);
                if since.elapsed() >= activation {
                    at_edge_since = None;
                    show(&app, false, "edge hover");
                }
                continue;
            }

            at_edge_since = None;
            let rect = *panel.rect.lock();
            if rect.contains(cursor, GRACE) {
                panel.entered.store(true, Ordering::SeqCst);
                outside_since = None;
                continue;
            }
            let hold = panel.pinned.load(Ordering::SeqCst)
                || panel.busy.load(Ordering::SeqCst) > 0
                || !panel.entered.load(Ordering::SeqCst)
                || primary_button_down();
            if hold {
                outside_since = None;
                continue;
            }
            let since = *outside_since.get_or_insert_with(Instant::now);
            if since.elapsed() >= hide_delay {
                outside_since = None;
                hide(&app, "pointer left");
            }
        }
    });
}

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    use objc2::MainThreadMarker;
    use objc2_app_kit::{NSApplication, NSApplicationActivationOptions, NSRunningApplication, NSScreen, NSWindow, NSWindowCollectionBehavior, NSWorkspace};

    fn ns_window(win: &WebviewWindow) -> Option<&NSWindow> {
        let ptr = win.ns_window().ok()? as *const NSWindow;
        // SAFETY: tao hands out the live NSWindow backing this window; we only use it on the main thread.
        unsafe { ptr.as_ref() }
    }

    /// Usable area (no menu bar, no Dock) of the screen under `cursor`, in the
    /// top-left-origin point space CoreGraphics and tao use.
    pub fn work_area_at(cursor: (f64, f64)) -> Option<Rect> {
        let mtm = MainThreadMarker::new()?;
        let screens = NSScreen::screens(mtm);
        let primary_height = screens.iter().next()?.frame().size.height;
        let flip = |f: objc2_foundation::NSRect| Rect { x: f.origin.x, y: primary_height - f.origin.y - f.size.height, w: f.size.width, h: f.size.height };
        let screen = screens.iter().find(|s| flip(s.frame()).contains(cursor, 0.0)).or_else(|| screens.iter().next())?;
        Some(flip(screen.visibleFrame()))
    }

    /// Let the panel appear on every space, including over full-screen apps.
    pub fn configure(win: &WebviewWindow) {
        if let Some(w) = ns_window(win) {
            let behavior = w.collectionBehavior() | NSWindowCollectionBehavior::CanJoinAllSpaces | NSWindowCollectionBehavior::FullScreenAuxiliary;
            w.setCollectionBehavior(behavior);
        }
    }

    /// Hover reveal must not steal the keyboard from the app being used.
    pub fn order_front_without_activating(win: &WebviewWindow) {
        if let Some(w) = ns_window(win) {
            w.orderFrontRegardless();
        }
    }

    pub fn remember_frontmost(app: &AppHandle) {
        let me = std::process::id() as i32;
        let front = NSWorkspace::sharedWorkspace().frontmostApplication();
        if let Some(pid) = front.map(|a| a.processIdentifier()).filter(|pid| *pid != me) {
            app.state::<AppState>().panel.previous_app.store(pid, Ordering::SeqCst);
        }
    }

    /// If typing in the panel made us the active app, hand activation back to
    /// whatever was in front before — hiding should feel like nothing happened.
    pub fn give_focus_back(app: &AppHandle) {
        let Some(mtm) = MainThreadMarker::new() else { return };
        if !NSApplication::sharedApplication(mtm).isActive() {
            return;
        }
        let pid = app.state::<AppState>().panel.previous_app.load(Ordering::SeqCst);
        if pid <= 0 {
            return;
        }
        if let Some(previous) = NSRunningApplication::runningApplicationWithProcessIdentifier(pid) {
            previous.activateWithOptions(NSApplicationActivationOptions::empty());
        }
    }
}

pub fn configure(win: &WebviewWindow) {
    #[cfg(target_os = "macos")]
    mac::configure(win);
    #[cfg(not(target_os = "macos"))]
    let _ = win;
}
