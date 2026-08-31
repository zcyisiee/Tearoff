import SwiftUI

@main
struct EdgeMarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // A scene is required by the App protocol, but EdgeMark is a pure
    // LSUIElement menu-bar app: the panel is built in code by
    // SidePanelController and settings live inside the panel. The empty
    // Settings scene keeps ⌘,/the system menu from opening a blank window —
    // all real entries (gear button, status-menu "设置…", in-panel ⌘,) route
    // through AppDelegate.openSettings.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
