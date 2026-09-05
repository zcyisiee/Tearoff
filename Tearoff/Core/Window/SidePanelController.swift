import Cocoa
import OSLog
import SwiftUI

// MARK: - KeyableWindow

/// Custom NSWindow subclass that can become key and main (required for borderless windows).
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

// MARK: - SidePanelController

final class SidePanelController: NSWindowController {
    private let cornerRadius: CGFloat = 10
    private(set) var isShown = false
    private var isAnimating = false
    private var animationGeneration = 0
    private var hideTimer: Timer?
    /// While a Finder card drags files out of the panel, the pointer legitimately
    /// leaves the window and the drop may land in another app. Every dismissal
    /// path (mouse-exit timer, click-outside, timer firing) stays parked until the
    /// drag session ends.
    private(set) var isAutoHideSuspended = false
    private var dummyWindow: NSWindow?
    private var trackingArea: NSTrackingArea?
    private var previousApp: NSRunningApplication?
    /// Retained reference to the SwiftUI hosting view for layer updates.
    private var contentHostingView: NSView?
    /// Retained reference to the drag-to-resize handle for repositioning.
    private var resizeHandleView: ResizeHandleView?
    let edgeDetector: EdgeDetector
    let noteStore = NoteStore()
    let appSettings = AppSettings.shared

    // MARK: - Init

    init() {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelWidth = PanelSettings.shared.panelWidth
        let side = PanelSettings.shared.edgeSide

        // Park the window far off-screen so it can't overlap any monitor.
        // Using a large negative coordinate is guaranteed to miss all monitor arrangements.
        let startX: CGFloat = -panelWidth - 1000

        let window = KeyableWindow(
            contentRect: NSRect(
                x: startX,
                y: visibleFrame.minY,
                width: panelWidth,
                height: visibleFrame.height,
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false

        // Container view — sits between the window and the SwiftUI hosting view so we can
        // layer the resize handle on top without interfering with SwiftUI layout.
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: visibleFrame.height))

        // Host SwiftUI content — fills the container
        let hostingView = NSHostingView(
            rootView: ContentView()
                .environment(noteStore)
                .environment(appSettings)
                .environment(L10n.shared),
        )
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.maskedCorners = Self.maskedCorners(for: side)
        hostingView.layer?.masksToBounds = true
        containerView.addSubview(hostingView)

        // Resize handle — thin strip on the inner edge
        let handle = ResizeHandleView()
        handle.side = side
        handle.frame = Self.resizeHandleFrame(for: side, containerWidth: panelWidth, height: visibleFrame.height)
        handle.autoresizingMask = Self.resizeHandleAutoresizing(for: side)
        containerView.addSubview(handle)

        window.contentView = containerView

        edgeDetector = EdgeDetector()

        super.init(window: window)

        contentHostingView = hostingView
        resizeHandleView = handle

        handle.onDragBegan = { [weak self] in self?.suspendAutoHide() }
        handle.onDrag = { [weak self] newWidth in self?.panelDidResize(to: newWidth) }
        handle.onDragEnded = { [weak self] finalWidth in self?.panelResizeEnded(width: finalWidth) }

        // Order the window off-screen immediately so it joins all Spaces.
        // We never orderOut — the window stays ordered (off-screen when hidden)
        // to maintain its .canJoinAllSpaces membership across desktop switches.
        window.orderBack(nil)
        // Start invisible and non-interactive. The parking position for a right-edge panel
        // on screen A lands inside an adjacent screen B's coordinate space — both alpha=0
        // (no visual ghost) and ignoresMouseEvents=true (no click swallowing) are needed.
        window.alphaValue = 0
        window.ignoresMouseEvents = true

        setupDummyWindow()
        setupTrackingArea()

        edgeDetector.onEdgeActivated = { [weak self] screen in
            guard let self else { return }
            // Edge-toggle: a re-touch while shown dismisses. The activation-delay
            // dwell already elapsed before we get here (EdgeDetector fires
            // onEdgeActivated only after the timer), so a flick through the edge
            // doesn't kill the panel — only a deliberate push-and-hold does.
            // Auto mode: a re-touch while shown is a no-op (showPanel early-returns).
            if PanelSettings.shared.dismissalMode == .toggle, isShown {
                hidePanel()
            } else {
                showPanel(on: screen)
            }
        }
        edgeDetector.startMonitoring()

        // In Edge-toggle mode, a re-touch while shown is a dismiss — use the
        // (floored) toggle-dismiss delay instead of the show activation delay,
        // so a brush across the edge can't instantly kill the panel.
        edgeDetector.activationDelayProvider = { [weak self] in
            guard let self else { return PanelSettings.shared.activationDelay }
            let s = PanelSettings.shared
            if s.dismissalMode == .toggle, isShown {
                return max(s.toggleDismissDelay, 0.05)
            }
            return s.activationDelay
        }

        // Click-outside dismissal
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, isShown, !self.isMouseInPanel(),
                  // A Finder-card drag session in flight owns the pointer;
                  // its click-through must not dismiss the panel.
                  !self.isAutoHideSuspended,
                  PanelSettings.shared.hideOnClickOutside,
                  PanelSettings.shared.dismissalMode == .auto,
                  !PanelSettings.shared.isPanelPinned,
                  // Clicking a context-menu item lands outside the panel's
                  // window but must not dismiss the panel mid-action.
                  !self.isMenuWindowOpen
            else { return }
            // Don't restore previousApp on click-outside — the click itself is moving
            // focus to the clicked app; re-activating previousApp would yank focus back
            // and race the click, so the user had to click several times (#58).
            hidePanel(restoreFocus: false)
        }

        // Escape key dismissal
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.isShown == true {
                if let fr = self?.window?.firstResponder as? NSTextView, fr.isFieldEditor {
                    return event
                }
                // A focused Finder card's file list clears its selection first.
                if let store = self?.noteStore,
                   let id = store.focusedFinderCardID,
                   FinderBrowserRegistry.shared.clearSelection(for: id)
                {
                    return nil
                }
                // Settings page closes first, then active title selection clears,
                // then an active selection clears, then the full editor shrinks
                // back into its card, then in-place card editing exits, then
                // the panel hides — one Escape per layer.
                if let store = self?.noteStore, store.showSettings {
                    store.showSettings = false
                    return nil
                }
                if let store = self?.noteStore, store.isEditorTitleSelected {
                    store.isEditorTitleSelected = false
                    return nil
                }
                if let store = self?.noteStore, store.selectedTitleNoteID != nil {
                    store.selectedTitleNoteID = nil
                    return nil
                }
                if let store = self?.noteStore, !store.selection.isEmpty {
                    store.clearSelection()
                    return nil
                }
                if let store = self?.noteStore, store.selectedNote != nil {
                    // Route through the board so the editor animates back into
                    // its card instead of vanishing.
                    NotificationCenter.default.post(name: .editorCloseRequested, object: nil)
                    return nil
                }
                if let store = self?.noteStore, store.inlineEditingNoteID != nil {
                    store.endInlineEdit()
                    return nil
                }
                self?.hidePanel()
            }
            return event
        }

        // List keyboard navigation: ↑ / ↓ / ⇧↑ / ⇧↓ move the Finder-style
        // selection, Return opens the single selected item.
        // Runs before any SwiftUI .onKeyPress so it wins over default focus traversal.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isShown else { return event }
            // Skip while editing text or browsing the editor / trash / settings.
            if let fr = window.firstResponder as? NSTextView, fr.isFieldEditor {
                return event
            }
            if noteStore.selectedNote != nil || noteStore.showTrash || noteStore.showSettings
                || noteStore.inlineEditingNoteID != nil
            {
                return event
            }
            // A focused Finder card's file list owns ↑/↓/Return while focused.
            if noteStore.focusedFinderCardID != nil {
                return event
            }
            let shift = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 125: // ↓
                noteStore.moveSelection(direction: 1, extending: shift)
                return nil
            case 126: // ↑
                noteStore.moveSelection(direction: -1, extending: shift)
                return nil
            case 36, 76: // Return / numpad Enter
                if noteStore.openSelectedItem() {
                    return nil
                }
                return event
            default:
                return event
            }
        }

        // Configurable local shortcuts
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isShown else { return event }
            let s = ShortcutSettings.shared
            // ⌘, toggles the in-panel settings page (panel key only).
            if event.keyCode == 44, // comma
               event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift),
               !event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.control)
            {
                if noteStore.showSettings {
                    noteStore.showSettings = false
                } else if noteStore.selectedNote == nil, !noteStore.showTrash, !noteStore.awaitingRootChoice {
                    noteStore.showSettings = true
                }
                return nil
            }
            if s.searchShortcut?.matches(event) == true {
                // Trash overlay: pass through (navigateToHome while Trash is active leaves
                // pendingSearchOnHome stuck).
                if noteStore.showTrash {
                    return event
                }
                // Note open: show the in-editor find bar instead of navigating to search.
                if noteStore.selectedNote != nil {
                    noteStore.pendingEditorFind = true
                    return nil
                }
                noteStore.searchReturnFolder = noteStore.selectedFolder
                noteStore.pendingSearchOnHome = true
                noteStore.navigateToHome()
                return nil
            }
            if s.pinShortcut?.matches(event) == true {
                PanelSettings.shared.isPanelPinned.toggle()
                return nil
            }
            if s.newNoteShortcut?.matches(event) == true {
                guard !noteStore.showTrash else { return event }
                if noteStore.selectedNote != nil {
                    noteStore.closeNote()
                }
                noteStore.pendingNewNote = true
                return nil
            }
            if s.newFolderShortcut?.matches(event) == true {
                // A focused Finder card creates its folder in place.
                if let id = noteStore.focusedFinderCardID {
                    FinderBrowserRegistry.shared.createFolder(
                        in: id,
                        defaultName: L10n.shared["finder.untitledFolder"],
                    )
                    return nil
                }
                // Only trigger when a list view is mounted. Editor and Trash both have
                // selectedNote == nil but no consumer, so pending would get stuck.
                guard noteStore.selectedNote == nil, !noteStore.showTrash else { return event }
                noteStore.pendingNewFolder = true
                return nil
            }
            return event
        }

        // Clear previousApp on desktop switch so we don't yank the user back
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
        )

        // Update previousApp when user switches apps while panel is shown
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
        )

        // Listen for settings changes (e.g. edge side) to reconfigure the panel
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: .shortcutSettingsChanged,
            object: nil,
        )

        #if DEBUG
            // Debug-only external trigger for the structural dump, so sandbox
            // probes can snapshot the panel state at any moment.
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("TearoffDebugDump"),
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                self?.debugDumpPanelState("notify")
            }
        #endif

        // Listen for pin state changes to toggle window draggability
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePinStateChanged),
            name: .panelPinStateChanged,
            object: nil,
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Settings Change

    @objc private func handleSettingsChanged() {
        guard let window, let containerView = window.contentView else { return }

        // Update corner radius for new edge side
        let side = PanelSettings.shared.edgeSide
        Log.window.info("[SidePanelController] settings changed — edge: \(side.rawValue, privacy: .public)")
        contentHostingView?.layer?.maskedCorners = Self.maskedCorners(for: side)

        // Reposition resize handle for new edge side
        let panelWidth = PanelSettings.shared.panelWidth
        resizeHandleView?.side = side
        resizeHandleView?.autoresizingMask = Self.resizeHandleAutoresizing(for: side)
        resizeHandleView?.frame = Self.resizeHandleFrame(for: side, containerWidth: panelWidth, height: containerView.bounds.height)

        // If panel is visible, hide it — user re-triggers to see it on the new edge
        if isShown {
            hidePanel()
        } else {
            // Reposition to safe parked location (edge may have changed so old position is stale)
            window.setFrame(parkedFrame(panelWidth: panelWidth), display: false)
        }
    }

    // MARK: - Pin State Change

    @objc private func handlePinStateChanged() {
        guard let window else { return }
        // The panel is edge-docked in both states — pinned only stops the
        // auto-hide, it never turns the header/tab bar into a drag surface.
        // Background dragging stays off so no region can move the window.
        window.isMovableByWindowBackground = false
        if !PanelSettings.shared.isPanelPinned {
            snapToEdge()
        }
    }

    /// Animate the panel back to its configured edge position after unpinning.
    /// If the panel is already at the edge frame, skips the animation.
    private func snapToEdge() {
        guard let window, isShown else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let side = PanelSettings.shared.edgeSide
        let (edgeFrame, _) = panelFrames(visibleFrame: screen.visibleFrame, side: side)

        // Already at the edge — nothing to animate
        guard window.frame != edgeFrame else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            window.setFrame(edgeFrame, display: true)
            contentHostingView?.layer?.maskedCorners = Self.maskedCorners(for: side)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Space Change

    @objc private func handleSpaceChange() {
        Log.window.debug("[SidePanelController] space changed")
        // Clear previousApp so hidePanel() doesn't activate an app on a
        // different Space and yank the user back.
        previousApp = nil

        // If the panel is shown and the mouse is outside, restart the auto-hide
        // timer with a short delay so the animation plays after the Space
        // transition settles (animations don't render mid-transition).
        guard isShown, !PanelSettings.shared.isPanelPinned,
              PanelSettings.shared.dismissalMode == .auto else { return }
        cancelHideTimer()
        if !isMouseInPanel() {
            let delay = max(PanelSettings.shared.hideDelay, 0.5)
            startHideTimer(delay: delay)
        }
    }

    // MARK: - App Activation

    @objc private func handleAppActivation(_ notification: Notification) {
        guard isShown else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        let name = app.localizedName ?? "unknown"
        Log.window.debug(
            "[SidePanelController] app activated while panel shown — updating previousApp to \(name, privacy: .public)",
        )
        previousApp = app
    }

    // MARK: - Dummy Window

    /// A 1×1 invisible window used as a focus chain anchor so the panel can resign
    /// key status without the system sending focus to a random window.
    private func setupDummyWindow() {
        let dummy = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        dummy.isOpaque = false
        dummy.backgroundColor = .clear
        dummy.alphaValue = 0
        dummy.ignoresMouseEvents = true
        dummy.level = .floating
        dummy.collectionBehavior = [.stationary, .ignoresCycle]
        dummy.orderBack(nil)
        dummyWindow = dummy
    }

    // MARK: - Tracking Area (auto-hide)

    private func setupTrackingArea() {
        guard let contentView = window?.contentView else { return }
        trackingArea = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        contentView.addTrackingArea(trackingArea!)
    }

    override func mouseExited(with _: NSEvent) {
        guard isShown, !isAnimating, !isEditorFocused, !isAutoHideSuspended,
              Date() >= dismissalDeferralDeadline,
              PanelSettings.shared.autoHideOnMouseExit,
              PanelSettings.shared.dismissalMode == .auto,
              !PanelSettings.shared.isPanelPinned,
              // Moving onto a context menu window counts as exiting the panel
              // bounds — the user is mid-interaction, not leaving.
              !isMenuWindowOpen
        else {
            let state = "suspended=\(isAutoHideSuspended), shown=\(isShown), animating=\(isAnimating)"
            Log.window.debug("[SidePanelController] mouseExited ignored (\(state, privacy: .public))")
            return
        }
        let delay = PanelSettings.shared.hideDelay
        if delay == 0 {
            hidePanel()
        } else {
            Log.window.debug("[SidePanelController] mouseExited — hide timer (\(delay)s)")
            startHideTimer(delay: delay)
        }
    }

    override func mouseEntered(with _: NSEvent) {
        cancelHideTimer()
    }

    // MARK: - Show / Hide

    func showPanel(on screen: NSScreen? = nil) {
        guard let window, !isShown else { return }
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = targetScreen.visibleFrame
        let side = PanelSettings.shared.edgeSide
        Log.window.info("[SidePanelController] showPanel (\(side.rawValue, privacy: .public) edge)")
        FileLog.shared.event("panel", "showPanel (side=\(side.rawValue))")

        // Check for external file changes every time the panel becomes visible
        noteStore.checkForExternalChanges()
        FinderBrowserRegistry.shared.resumeAllWatching()

        isShown = true
        let gen = animationGeneration &+ 1
        animationGeneration = gen

        let (shownFrame, _) = panelFrames(visibleFrame: visibleFrame, side: side)

        // Save the frontmost app so we can restore focus when hiding
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }

        if isAnimating {
            // Interrupt hide animation — snap to shown position instantly
            Log.window.debug("[SidePanelController] showPanel interrupted hide animation")
            isAnimating = false
            window.setFrame(shownFrame, display: true)
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            isAnimating = true
            window.ignoresMouseEvents = false
            window.makeKeyAndOrderFront(nil)

            if PanelSettings.shared.animationStyle == .slide {
                // Slide: teleport to the off-screen start position, then animate the frame inward.
                // Note: on multi-monitor setups the start position may overlap the adjacent display,
                // causing a brief ghost during the 0.2s travel. Use Fade in Settings to avoid this.
                let (_, startFrame) = panelFrames(visibleFrame: visibleFrame, side: side)
                window.setFrame(startFrame, display: true)
                window.alphaValue = 1

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().setFrame(shownFrame, display: false)
                } completionHandler: { [weak self] in
                    guard let self, animationGeneration == gen else { return }
                    isAnimating = false
                }
            } else {
                // Fade: position at the final frame while invisible, then animate alpha 0 → 1.
                // The window never moves off the triggering screen — no adjacent monitor bleed.
                window.setFrame(shownFrame, display: true)
                window.alphaValue = 0

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                } completionHandler: { [weak self] in
                    guard let self, animationGeneration == gen else { return }
                    isAnimating = false
                }
            }

            // Activate after animation is submitted to Core Animation
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hidePanel(restoreFocus: Bool = true) {
        guard let window, isShown else { return }
        Log.window.info("[SidePanelController] hidePanel")
        FileLog.shared.event("panel", "hidePanel")
        // Leaving the panel ends an in-place card edit session (flushes its save).
        noteStore.inlineEditingNoteID = nil
        noteStore.saveDirtyNotes()
        noteStore.saveSidecar(immediately: true)
        FinderBrowserRegistry.shared.suspendAllWatching()
        isShown = false
        let gen = animationGeneration &+ 1
        animationGeneration = gen
        cancelHideTimer()
        edgeDetector.pauseDetection()

        let panelWidth = window.frame.width
        let targetScreen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = targetScreen.visibleFrame
        let side = PanelSettings.shared.edgeSide
        let (_, hiddenFrame) = panelFrames(visibleFrame: visibleFrame, side: side)

        if isAnimating {
            // Interrupt show animation — snap to parked position instantly
            Log.window.debug("[SidePanelController] hidePanel interrupted show animation")
            isAnimating = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.setFrame(parkedFrame(panelWidth: panelWidth), display: false)
            if restoreFocus {
                restorePreviousApp()
            }
            edgeDetector.resumeDetection()
        } else {
            isAnimating = true
            window.ignoresMouseEvents = true

            if PanelSettings.shared.animationStyle == .slide {
                // Slide out, then park far off-screen so the invisible window can't block clicks.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    window.animator().setFrame(hiddenFrame, display: false)
                } completionHandler: { [weak self] in
                    guard let self, animationGeneration == gen else { return }
                    window.alphaValue = 0
                    window.setFrame(parkedFrame(panelWidth: panelWidth), display: false)
                    isAnimating = false
                    if restoreFocus {
                        restorePreviousApp()
                    }
                    edgeDetector.resumeDetection()
                }
            } else {
                // Fade out in place, then park. Window never moves off the current screen.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    window.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    guard let self, animationGeneration == gen else { return }
                    window.setFrame(parkedFrame(panelWidth: panelWidth), display: false)
                    isAnimating = false
                    if restoreFocus {
                        restorePreviousApp()
                    }
                    edgeDetector.resumeDetection()
                }
            }
        }
    }

    func togglePanel() {
        let state = isShown ? "shown" : "hidden"
        Log.window.debug("[SidePanelController] togglePanel (currently \(state, privacy: .public))")
        if isShown {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Resize

    private func panelDidResize(to newWidth: CGFloat) {
        guard let window else { return }
        let side = PanelSettings.shared.edgeSide
        let targetScreen = window.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let maxWidth = targetScreen.visibleFrame.width - 100
        let clampedWidth = min(max(newWidth, ResizeHandleView.minWidth), maxWidth)

        var frame = window.frame
        if side == .right {
            // Right screen edge is the fixed anchor — expand leftward
            frame.origin.x = frame.maxX - clampedWidth
        }
        // Left: left screen edge is the fixed anchor — origin.x stays the same
        frame.size.width = clampedWidth
        window.setFrame(frame, display: true)
    }

    private func panelResizeEnded(width: CGFloat) {
        PanelSettings.shared.panelWidth = window?.frame.width ?? width
        Log.window.info("[SidePanelController] panel resized to \(PanelSettings.shared.panelWidth, privacy: .public)pt")
        // Re-park auto-hide suspended for the drag; if the cursor ended up
        // outside the panel the normal hide-delay path tidies it away.
        resumeAutoHide(treatAsMouseExit: true)
    }

    // MARK: - Frame Calculation

    /// A safe off-screen parking position that can't overlap any monitor in any arrangement.
    /// The window is invisible (alphaValue = 0) and ignoresMouseEvents when parked here.
    /// Preserves the window's current height: squashing to a stub forced the whole
    /// SwiftUI tree to relayout at stub geometry and back on the next show — after a
    /// Finder-card drag-out session that relayout's render tree could wedge mid-spring,
    /// leaving the card body permanently blank. A pure move keeps the laid-out tree intact.
    private func parkedFrame(panelWidth: CGFloat) -> NSRect {
        let height = window?.frame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 800
        return NSRect(x: -panelWidth - 1000, y: -10000, width: panelWidth, height: height)
    }

    /// Returns (shown, hidden) frames for the given edge side using the persisted panel width.
    private func panelFrames(visibleFrame: NSRect, side: EdgeSide) -> (shown: NSRect, hidden: NSRect) {
        let width = PanelSettings.shared.panelWidth
        let shown: NSRect
        let hidden: NSRect
        switch side {
        case .right:
            shown = NSRect(x: visibleFrame.maxX - width, y: visibleFrame.minY,
                           width: width, height: visibleFrame.height)
            hidden = NSRect(x: visibleFrame.maxX, y: visibleFrame.minY,
                            width: width, height: visibleFrame.height)
        case .left:
            shown = NSRect(x: visibleFrame.minX, y: visibleFrame.minY,
                           width: width, height: visibleFrame.height)
            hidden = NSRect(x: visibleFrame.minX - width, y: visibleFrame.minY,
                            width: width, height: visibleFrame.height)
        }
        return (shown, hidden)
    }

    /// Corner mask for the given edge side.
    private static func maskedCorners(for side: EdgeSide) -> CACornerMask {
        switch side {
        case .right:
            // Right edge → round left corners
            [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        case .left:
            // Left edge → round right corners
            [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
    }

    /// Frame of the resize handle within the container view.
    /// Single-surface layout: the visible edge is the window edge itself, so the
    /// handle sits fully inside, hugging the inner edge.
    private static func resizeHandleFrame(for side: EdgeSide, containerWidth: CGFloat, height: CGFloat) -> NSRect {
        let w = ResizeHandleView.handleWidth
        switch side {
        case .right:
            return NSRect(x: 0, y: 0, width: w, height: height)
        case .left:
            return NSRect(x: containerWidth - w, y: 0, width: w, height: height)
        }
    }

    /// Autoresizing mask for the resize handle so it stays on the inner edge as the container resizes.
    private static func resizeHandleAutoresizing(for side: EdgeSide) -> NSView.AutoresizingMask {
        switch side {
        case .right: [.height, .maxXMargin] // stays glued to left edge
        case .left: [.height, .minXMargin] // stays glued to right edge
        }
    }

    // MARK: - Helpers

    /// Reactivate the app that was frontmost before the panel appeared,
    /// so its mouse events go through the global monitor again.
    /// Skips restoration if another Tearoff window (e.g. Settings, Update) is key.
    private func restorePreviousApp() {
        let hasOtherKeyWindow = NSApp.windows.contains { $0 !== window && $0.isKeyWindow }
        if !hasOtherKeyWindow {
            if let app = previousApp {
                let name = app.localizedName ?? "unknown"
                Log.window.debug("[SidePanelController] restoring focus to \(name, privacy: .public)")
            } else {
                Log.window.debug("[SidePanelController] no previousApp to restore")
            }
            previousApp?.activate()
        }
        previousApp = nil
    }

    private func isMouseInPanel() -> Bool {
        guard let window else { return false }
        let cursor = NSEvent.mouseLocation
        // 1. Inside the panel window itself
        if window.frame.contains(cursor) {
            return true
        }
        return false
    }

    /// Park every dismissal path while a Finder card drag session is in flight.
    func suspendAutoHide() {
        Log.window.debug("[SidePanelController] suspendAutoHide")
        FileLog.shared.event("panel", "suspendAutoHide")
        isAutoHideSuspended = true
        cancelHideTimer()
    }

    /// Minimum delay before auto-hiding after a suspended interaction (file
    /// drag-out, card/panel resize) ends. Hiding parks the window off-screen;
    /// when that runs in the same runloop turn as an AppKit drag-session
    /// teardown (`draggingSession ended` with `hideDelay = 0`), the drag
    /// source's collection view survives with its frame but its rendering
    /// layer is never re-attached — the card comes back blank on the next
    /// show. A short grace lets AppKit finish drag cleanup first.
    private static let postInteractionHideGrace: TimeInterval = 0.35

    /// Until when every dismissal path (mouse-exit, hide timer) is parked.
    /// Set by `resumeAutoHide` after a suspended interaction ends; the plain
    /// `isAutoHideSuspended` flag is cleared synchronously, so without this
    /// deadline the `hideDelay = 0` mouse-exit path would hide instantly
    /// anyway.
    private var dismissalDeferralDeadline = Date.distantPast

    /// Drag-blank recovery: detect any SwiftUI graphics-container views whose
    /// alpha was stuck at 0 by the drag-session animation teardown, restore
    /// them to 1, and then force a synchronous display pass.
    ///
    /// Root cause (confirmed by user logs 2026-09-05): the drag animation runs
    /// an opacity transition on the Finder-card body's `_NSGraphicsView`
    /// containers. When the drag session tears down it interrupts the render-
    /// server commit, leaving the presentation layer opacity at 0.0 — with no
    /// subsequent SwiftUI state change to trigger a new commit. The old
    /// `window.display()` poke was proven ineffective by the diagnostic logs
    /// (`viewsNeedDisplay=false`; no damage queued, nothing to display).
    /// Directly resetting alphaValue + layer.opacity + removing stale
    /// animations is the only reliable fix.
    func forceDisplayRecovery(after delay: Double) {
        guard let window, isShown else { return }
        debugDumpPanelState("poke(+\(delay)s)")

        // ── Alpha recovery ─────────────────────────────────────────────────
        // Walk the entire content-view tree. For every view that is:
        //   • not hidden (isHidden == false)
        //   • has a non-empty frame
        //   • has alphaValue essentially 0 (< 0.01)
        //   • is an `_NSGraphicsView` — the private SwiftUI rendering container
        //     that wraps NSViewRepresentable-backed content inside an NSHostingView
        // … restore alphaValue and layer.opacity to 1, strip stale animations,
        // then mark it dirty for repaint.
        //
        // Safety: we only touch _NSGraphicsView instances (SwiftUI rendering
        // containers). Views intentionally invisible via SwiftUI's own alpha/
        // transition system *also* use _NSGraphicsView, but those are either
        // already hidden (`isHidden = true`, which we skip) or have a zero
        // *frame* (not yet laid out). We further guard against zero frames.
        // The only pathological case — a legitimately zero-alpha but unhidden
        // _NSGraphicsView — would be an active SwiftUI opacity(0) modifier,
        // which we would erroneously raise to 1; this is acceptable given the
        // very narrow recovery window (called only 0.1s/0.7s/2.0s after a
        // drag session ends, not continuously).
        var recovered = 0
        if let contentView = window.contentView {
            var stack: [NSView] = [contentView]
            while !stack.isEmpty {
                let view = stack.removeLast()
                // Only candidate: unhidden, has area, alpha effectively 0.
                if !view.isHidden,
                   !view.frame.isEmpty,
                   view.alphaValue < 0.01
                {
                    let className = NSStringFromClass(type(of: view))
                    // Target _NSGraphicsView (SwiftUI rendering container).
                    // Class name check: private API name may carry a prefix like
                    // "SwiftUI." — accept any class whose name ends with the token.
                    if className.hasSuffix("_NSGraphicsView") || className == "_NSGraphicsView" {
                        // Restore this container.
                        view.alphaValue = 1
                        if let layer = view.layer {
                            layer.removeAllAnimations()
                            layer.opacity = 1
                        }
                        // Walk up and clear any ancestor layer that is also stuck < 1.
                        var ancestor: NSView? = view.superview
                        while let anc = ancestor {
                            if let al = anc.layer, al.opacity < 0.99 {
                                al.removeAllAnimations()
                                al.opacity = 1
                            }
                            ancestor = anc.superview
                        }
                        view.needsDisplay = true
                        recovered += 1
                    }
                }
                // Always recurse — even into alpha=0 subtrees (the children
                // we want to fix live there).
                for sub in view.subviews {
                    stack.append(sub)
                }
            }
        }

        if recovered > 0 {
            FileLog.shared.event(
                "panel",
                "alpha-recovery restored \(recovered) container(s) (+\(String(format: "%.1f", delay))s)",
            )
        }

        // ── Original display poke (keep as belt-and-suspenders) ────────────
        let pending = window.viewsNeedDisplay
        window.contentView?.needsDisplay = true
        window.display()
        FileLog.shared.event("panel", "display-recovery poke (+\(delay)s) viewsNeedDisplay=\(pending)")
    }

    // MARK: - Debug Dump (blank-card investigation; runs only while debug logging is on)

    /// Structural dump of the panel window: full AppKit view tree (with layer
    /// attachment) plus the layer-superlayer chain of every embedded file
    /// list, so the post-drag blank state can be compared against a healthy
    /// baseline from the log alone.
    func debugDumpPanelState(_ tag: String) {
        guard FileLog.shared.isEnabled, let window, let contentView = window.contentView else { return }
        var lines: [String] = []
        var stack: [(view: NSView, depth: Int)] = [(contentView, 0)]
        var collections: [NSCollectionView] = []
        var tables: [NSTableView] = []
        while let (view, depth) = stack.popLast() {
            let indent = String(repeating: ". ", count: min(depth, 16))
            let layerDesc = if let layer = view.layer {
                "layer=\(type(of: layer))(super=\(layer.superlayer == nil ? "nil" : "set"))"
            } else {
                "layer=nil"
            }
            lines.append("\(indent)\(type(of: view)) \(Int(view.frame.width))x\(Int(view.frame.height)) hidden=\(view.isHidden) alpha=\(view.alphaValue) \(layerDesc)")
            if let cv = view as? NSCollectionView {
                collections.append(cv)
            }
            if let tv = view as? NSTableView, !(tv is NSOutlineView) {
                tables.append(tv)
            }
            for subview in view.subviews.reversed() {
                stack.append((subview, depth + 1))
            }
        }
        FileLog.shared.event("dump", "\(tag) win=\(window.frame) viewsNeedDisplay=\(window.viewsNeedDisplay) tree:\n\(lines.joined(separator: "\n"))")
        for cv in collections {
            var chain: [String] = []
            var layer = cv.layer
            var depth = 0
            var containsContentLayer = false
            while let current = layer, depth < 24 {
                let originInRoot = contentView.layer.map { current.convert(CGPoint.zero, to: $0) } ?? .zero
                if let cl = contentView.layer, current === cl {
                    containsContentLayer = true
                }
                chain.append("\(type(of: current)){f=\(current.frame) hid=\(current.isHidden) op=\(current.opacity) o@root=\(Int(originInRoot.x)),\(Int(originInRoot.y)) contents=\(current.contents != nil)}")
                layer = current.superlayer
                depth += 1
            }
            FileLog.shared.event("dump", "collection window=\(cv.window != nil) visibleItems=\(cv.visibleItems().count) chainContainsContentLayer=\(containsContentLayer) layerChain=[\(chain.joined(separator: " > "))]")
            var ancestors: [String] = []
            var v: NSView? = cv.superview
            while let cur = v {
                ancestors.append("\(type(of: cur)){f=\(cur.frame) a=\(cur.alphaValue) layerOp=\(cur.layer?.opacity ?? -1)}")
                v = cur.superview
            }
            FileLog.shared.event("dump", "collection viewAncestors=[\(ancestors.joined(separator: " > "))]")
            // Visual probe: render the card area through the normal display
            // machinery (which skips zero-alpha subtrees) and count ink pixels,
            // so the log reflects what is actually on screen.
            let rect = cv.convert(cv.bounds, to: contentView).intersection(contentView.bounds)
            var ink = 0
            if !rect.isEmpty, let rep = contentView.bitmapImageRepForCachingDisplay(in: rect) {
                contentView.cacheDisplay(in: rect, to: rep)
                if let cg = rep.cgImage, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) {
                    let total = CFDataGetLength(data)
                    var i = 0
                    while i + 3 < total {
                        let c0 = ptr[i], c1 = ptr[i + 1], c2 = ptr[i + 2], alpha = ptr[i + 3]
                        if alpha > 8, c0 < 235 || c1 < 235 || c2 < 235 {
                            ink += 1
                        }
                        i += 97 * 4
                    }
                }
            }
            FileLog.shared.event("dump", "visualProbe ink=\(ink) rect=\(rect)")
        }
        for tv in tables {
            FileLog.shared.event("dump", "table window=\(tv.window != nil) rows=\(tv.numberOfRows)")
        }
    }

    /// `treatAsMouseExit`: after a drop the pointer is usually outside — run the normal
    /// hide-delay path once so the panel tidies itself away exactly as if the user had left.
    func resumeAutoHide(treatAsMouseExit: Bool) {
        let wasSuspended = isAutoHideSuspended
        Log.window.debug("[SidePanelController] resumeAutoHide(treatAsMouseExit=\(treatAsMouseExit, privacy: .public)) suspended=\(wasSuspended, privacy: .public)")
        FileLog.shared.event("panel", "resumeAutoHide(treatAsMouseExit=\(treatAsMouseExit)) suspended=\(wasSuspended)")
        isAutoHideSuspended = false
        dismissalDeferralDeadline = Date().addingTimeInterval(Self.postInteractionHideGrace)
        guard treatAsMouseExit, isShown, !isMouseInPanel(),
              !PanelSettings.shared.isPanelPinned,
              PanelSettings.shared.autoHideOnMouseExit,
              PanelSettings.shared.dismissalMode == .auto
        else { return }
        let delay = max(PanelSettings.shared.hideDelay, Self.postInteractionHideGrace)
        Log.window.debug("[SidePanelController] resumeAutoHide → hide timer (\(delay)s)")
        startHideTimer(delay: delay)
    }

    private func startHideTimer(delay: Double) {
        cancelHideTimer()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, isShown, !isMouseInPanel(), !isAutoHideSuspended,
                  Date() >= dismissalDeferralDeadline
            else { return }
            // A context menu opened after the exit began — the user is picking
            // an item; let the interaction finish instead of yanking the panel.
            guard !isMenuWindowOpen else { return }
            hidePanel()
        }
    }

    /// Whether a popup/context menu is currently open — or was open so recently
    /// that its dismissal fallout is still in flight. While one is up,
    /// click-outside and auto-hide dismissal are suspended — clicking a menu
    /// item (e.g. setting a note color) lands outside the panel's window and
    /// moving onto the menu reads as a mouse exit, but the user is clearly
    /// mid-interaction, not leaving.
    ///
    /// The grace period covers the moment *after* the menu closes: AppKit
    /// re-evaluates the cursor once the tracking loop ends and synthesizes
    /// `mouseExited` / re-delivers the click while the menu window no longer
    /// exists, which used to hide the panel immediately after picking an item.
    ///
    /// Two live signals: an explicit flag bracketing our own (blocking)
    /// `NSMenu.popUpContextMenu` calls (reset one runloop turn later), plus a
    /// window scan for SwiftUI Menus, which we don't drive. The scan matches
    /// loosely — the private menu window class name varies across macOS versions.
    private var isMenuWindowOpen: Bool {
        if NSContextMenuModifier.isShowingMenu {
            return true
        }
        if Date().timeIntervalSince(NSContextMenuModifier.lastMenuDismissAt)
            < NSContextMenuModifier.menuDismissGracePeriod
        {
            Log.window.debug("[SidePanelController] menu dismiss grace period — suppressing auto-hide")
            return true
        }
        if let key = NSApp.keyWindow, NSStringFromClass(type(of: key)).contains("Menu") {
            return true
        }
        return NSApp.windows.contains { NSStringFromClass(type(of: $0)).contains("MenuWindow") }
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    /// Whether an NSTextView in the panel is the first responder (user is editing).
    private var isEditorFocused: Bool {
        window?.firstResponder is NSTextView
    }
}

// MARK: - ResizeHandleView

/// Invisible strip covering the board's inner gutter (the blank margin left
/// of the cards — `DesignToken.Space.lg` wide). Hovering anywhere in the
/// visually blank strip shows the resize cursor; dragging it resizes the panel.
private final class ResizeHandleView: NSView {
    /// Matches the board's horizontal card padding, so the whole visual
    /// gutter left of the cards is the resize zone.
    static var handleWidth: CGFloat {
        DesignToken.Space.lg
    }

    static let minWidth: CGFloat = 400

    var side: EdgeSide = .right
    /// Fired on mouseDown — the controller suspends auto-hide so a fast drag
    /// that flings the cursor out of the window can't dismiss the panel
    /// mid-resize.
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?

    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    override func mouseDown(with _: NSEvent) {
        onDragBegan?()
        dragStartX = NSEvent.mouseLocation.x
        dragStartWidth = window?.frame.width ?? PanelSettings.shared.panelWidth
        let w = dragStartWidth
        let s = side.rawValue
        Log.window.debug("[ResizeHandleView] drag began — startWidth: \(w, privacy: .public)pt side: \(s, privacy: .public)")
    }

    override func mouseDragged(with _: NSEvent) {
        let deltaX = NSEvent.mouseLocation.x - dragStartX
        let newWidth: CGFloat = switch side {
        case .right:
            // Left edge draggable: moving left (negative deltaX) widens the panel
            max(Self.minWidth, dragStartWidth - deltaX)
        case .left:
            // Right edge draggable: moving right (positive deltaX) widens the panel
            max(Self.minWidth, dragStartWidth + deltaX)
        }
        onDrag?(newWidth)
    }

    override func mouseUp(with _: NSEvent) {
        let finalWidth = window?.frame.width ?? PanelSettings.shared.panelWidth
        Log.window.debug("[ResizeHandleView] drag ended — finalWidth: \(finalWidth, privacy: .public)pt")
        onDragEnded?(finalWidth)
        NSCursor.arrow.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas {
            removeTrackingArea(ta)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil,
        ))
    }

    override func mouseEntered(with _: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with _: NSEvent) {
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }
}
