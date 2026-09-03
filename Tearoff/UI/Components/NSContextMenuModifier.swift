import Cocoa
import SwiftUI

// MARK: - Singleton menu action dispatcher

/// Single long-lived target for all NSMenuItem closure actions.
/// Uses tag-based dispatch: each menu item gets a unique tag mapped to its closure.
///
/// This avoids two pitfalls with per-item action targets:
/// 1. `NSMenuItem.target` is **weak** — per-item objects can be freed before the action fires.
/// 2. SwiftUI may recreate the NSViewRepresentable host during a popup, releasing any
///    retained references stored on the old view.
///
/// The singleton lives for the process lifetime, so neither issue applies.
@objc(EMMenuDispatch)
private final class MenuDispatch: NSObject {
    static let shared = MenuDispatch()

    private var actions: [Int: () -> Void] = [:]
    private var nextTag = 1

    /// Register a closure and return a unique tag for the menu item.
    func register(_ action: @escaping () -> Void) -> Int {
        let tag = nextTag
        nextTag += 1
        actions[tag] = action
        return tag
    }

    /// Remove all registered closures (call after the menu dismisses).
    func clear() {
        actions.removeAll()
        nextTag = 1
    }

    @objc(run:)
    func run(_ sender: NSMenuItem) {
        actions[sender.tag]?()
    }
}

// MARK: - NSMenu Context Menu Modifier

/// Attaches an NSMenu as the right-click context menu for any SwiftUI view.
/// Unlike SwiftUI's `.contextMenu`, NSMenu items reliably show SF Symbol icons on macOS.
struct NSContextMenuModifier: ViewModifier {
    let menuBuilder: () -> NSMenu

    /// True while one of our NSContextMenuModifier menus is tracking.
    /// `NSMenu.popUpContextMenu` blocks, so a simple flag brackets the whole
    /// interaction — SidePanelController uses this to suppress click-outside
    /// and auto-hide dismissal while the user is picking a menu item.
    static var isShowingMenu = false

    /// When the last menu finished dismissing. AppKit re-evaluates the cursor
    /// after the tracking loop ends and synthesizes `mouseExited` / re-dispatches
    /// the menu click, at which point the menu window is already gone — so the
    /// dismissal guards that consult `isMenuWindowOpen` would pass and hide the
    /// panel right after the user picked an item. Consumers treat everything
    /// within `menuDismissGracePeriod` of this timestamp as still mid-menu.
    static var lastMenuDismissAt = Date.distantPast

    /// How long after a menu closes dismissal stays suppressed.
    static let menuDismissGracePeriod: TimeInterval = 0.6

    /// Incremented each time a menu starts tracking, so a delayed reset from a
    /// previous popup can't clear the flag while a newer menu is still open.
    static var menuGeneration = 0

    func body(content: Content) -> some View {
        // The catcher sits BEHIND the content purely for geometry: it sizes to
        // the menu's region and the router resolves which catcher a right-click
        // belongs to (see ContextMenuRouter). It never takes part in AppKit
        // hit-testing — NSHostingView discards hit-test claims from
        // background-mounted representables anyway, and staying passive keeps
        // left-clicks, hovers and gestures flowing to the SwiftUI content in
        // front. (As an `.overlay` the catcher DID receive right-clicks, but
        // it sat topmost and shadowed every deeper menu in its frame.)
        content.background {
            NSContextMenuCatcherView(menuBuilder: menuBuilder)
        }
    }
}

extension View {
    /// Attach an NSMenu as the right-click context menu (icons render reliably).
    func nsContextMenu(_ menuBuilder: @escaping () -> NSMenu) -> some View {
        modifier(NSContextMenuModifier(menuBuilder: menuBuilder))
    }
}

// MARK: - Right-click routing

/// Routes right-clicks that land on pure SwiftUI content to the deepest
/// catcher under the pointer.
///
/// SwiftUI's `NSHostingView` swallows the hit-test for representables mounted
/// behind content (`.background`): the catcher's `hitTest` may be consulted,
/// but its claim is discarded, so `rightMouseDown` lands on the hosting view
/// and dies inside SwiftUI's gesture system — every `nsContextMenu` over
/// pure-SwiftUI regions (tab buttons, path bar segments, chips, cards) goes
/// dead. Content-positioned representables (the Finder file lists, overlays)
/// still receive their events through normal dispatch.
///
/// A process-wide local monitor intercepts right-clicks before dispatch:
/// - clicks that hit-test to an embedded platform view dispatch normally, so
///   the file lists' own menus keep winning over any enclosing catcher;
/// - otherwise the deepest catcher containing the point pops its menu — a
///   path segment beats the bar's fallback menu, a card beats the board-wide
///   new-items menu.
private enum ContextMenuRouter {
    private static let catchers = NSHashTable<ContextMenuCatcher>.weakObjects()
    private static var monitor: Any?

    static func register(_ catcher: ContextMenuCatcher) {
        catchers.add(catcher)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            route(event)
        }
    }

    private static func route(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let contentView = window.contentView else { return event }
        let location = event.locationInWindow
        // Embedded platform views keep their own right-click handling — only
        // clicks that would land on pure SwiftUI content are rerouted.
        guard let hit = contentView.hitTest(location), isSwiftUIRegion(hit) else { return event }

        let candidates = catchers.allObjects.filter {
            $0.window === window && $0.convert($0.bounds, to: nil).contains(location)
        }
        guard let best = candidates.min(by: Self.isDeeper) else { return event }
        best.popMenu(for: event)
        return nil
    }

    /// The hit counts as pure SwiftUI content when its responder chain reaches
    /// the hosting view without crossing a platform-view host (an embedded
    /// NSViewRepresentable such as the Finder file lists).
    private static func isSwiftUIRegion(_ hit: NSView) -> Bool {
        var current: NSView? = hit
        while let view = current {
            let name = NSStringFromClass(type(of: view))
            if name.contains("PlatformViewHost") {
                return false
            }
            if name.contains("NSHostingView") {
                return true
            }
            current = view.superview
        }
        return false
    }

    /// Deeper catchers are more specific (segment > bar, card > board); at
    /// equal depth the smaller frame wins.
    private static func isDeeper(_ lhs: ContextMenuCatcher, _ rhs: ContextMenuCatcher) -> Bool {
        if lhs.depth != rhs.depth {
            return lhs.depth > rhs.depth
        }
        return lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
    }
}

// MARK: - NSViewRepresentable background catcher

private struct NSContextMenuCatcherView: NSViewRepresentable {
    let menuBuilder: () -> NSMenu

    func makeNSView(context _: Context) -> ContextMenuCatcher {
        let catcher = ContextMenuCatcher()
        ContextMenuRouter.register(catcher)
        return catcher
    }

    func updateNSView(_ nsView: ContextMenuCatcher, context _: Context) {
        nsView.menuBuilder = menuBuilder
    }
}

/// Transparent NSView sized to the menu's region. Purely passive: it never
/// participates in hit-testing (right-clicks reach it through
/// ContextMenuRouter, everything else flows to the SwiftUI content in front).
private final class ContextMenuCatcher: NSView {
    var menuBuilder: (() -> NSMenu)?

    /// Superview-chain length, for the router's deepest-wins comparison.
    var depth: Int {
        var value = 0
        var current: NSView? = self
        while let view = current {
            value += 1
            current = view.superview
        }
        return value
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func rightMouseDown(with event: NSEvent) {
        popMenu(for: event)
    }

    func popMenu(for event: NSEvent) {
        guard let menu = menuBuilder?() else { return }
        NSContextMenuModifier.menuGeneration += 1
        let generation = NSContextMenuModifier.menuGeneration
        NSContextMenuModifier.isShowingMenu = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        // Reset the flag on the next turn, not synchronously: AppKit
        // delivers the synthesized exit / re-dispatched click events
        // right after this method returns, and they must still read
        // as "menu open" (see lastMenuDismissAt).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard generation == NSContextMenuModifier.menuGeneration else { return }
            NSContextMenuModifier.isShowingMenu = false
            NSContextMenuModifier.lastMenuDismissAt = Date()
        }
        MenuDispatch.shared.clear()
    }
}

// MARK: - Row Click Modifier (single + double click, no SwiftUI delay)

/// Attaches an AppKit-driven click handler to a row.
/// SwiftUI's `.onTapGesture(count: 1)` waits for the multi-tap window before firing,
/// which feels laggy. AppKit delivers each `mouseDown` immediately with `clickCount`
/// indicating 1 or 2 — so we fire the single-click action right away and the
/// double-click action when the second click arrives.
struct RowClickModifier: ViewModifier {
    let onSingle: (NSEvent.ModifierFlags) -> Void
    let onDouble: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            RowClickOverlay(onSingle: onSingle, onDouble: onDouble)
        }
    }
}

extension View {
    /// Attach an instant single/double click handler.
    /// Single click fires immediately on mouse-down with the active modifier flags.
    /// Double click fires when the second click arrives.
    func rowClick(
        onSingle: @escaping (NSEvent.ModifierFlags) -> Void,
        onDouble: @escaping () -> Void,
    ) -> some View {
        modifier(RowClickModifier(onSingle: onSingle, onDouble: onDouble))
    }
}

private struct RowClickOverlay: NSViewRepresentable {
    let onSingle: (NSEvent.ModifierFlags) -> Void
    let onDouble: () -> Void

    func makeNSView(context _: Context) -> RowClickCatcher {
        RowClickCatcher()
    }

    func updateNSView(_ nsView: RowClickCatcher, context _: Context) {
        nsView.onSingle = onSingle
        nsView.onDouble = onDouble
    }

    /// Transparent NSView that intercepts only left-mouse-down (so right-clicks,
    /// scrolls, hovers and drags continue to flow into SwiftUI as normal).
    final class RowClickCatcher: NSView {
        var onSingle: ((NSEvent.ModifierFlags) -> Void)?
        var onDouble: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only intercept left-clicks; pass everything else through.
            if let event = NSApp.currentEvent, event.type == .leftMouseDown {
                let local = convert(point, from: superview)
                if bounds.contains(local) {
                    return self
                }
            }
            return nil
        }

        override func mouseDown(with event: NSEvent) {
            // clickCount is 1 for the first click and 2 for a quick second click.
            // We fire each immediately — selection is harmless before a follow-up
            // open, and openNote/navigate clear the selection anyway.
            if event.clickCount >= 2 {
                onDouble?()
            } else {
                onSingle?(event.modifierFlags)
            }
        }
    }
}

// MARK: - NSMenu Builder Helpers

extension NSMenu {
    /// Pop up this menu (built with addActionItem) at a point in a view without an NSEvent.
    /// Blocks until dismissed, then clears MenuDispatch closures.
    func popUpAtPoint(_ point: NSPoint, in view: NSView) {
        popUp(positioning: nil, at: point, in: view)
        MenuDispatch.shared.clear()
    }

    /// Pop up this menu at a screen-coordinate point.
    /// AppKit automatically flips the menu above the cursor when near the bottom of the screen.
    func popUpAtScreenPoint(_ screenPoint: NSPoint) {
        popUp(positioning: nil, at: screenPoint, in: nil)
        MenuDispatch.shared.clear()
    }

    /// Add a menu item with an SF Symbol icon and a closure action.
    @discardableResult
    func addActionItem(
        title: String,
        icon: String,
        action: @escaping () -> Void,
    ) -> NSMenuItem {
        let tag = MenuDispatch.shared.register(action)
        let item = NSMenuItem(
            title: title,
            action: #selector(MenuDispatch.run(_:)),
            keyEquivalent: "",
        )
        item.tag = tag
        item.target = MenuDispatch.shared
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        addItem(item)
        return item
    }
}
