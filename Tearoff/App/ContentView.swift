import SwiftUI

struct ContentView: View {
    @Environment(NoteStore.self) var noteStore

    /// Trash uses vertical slide (from bottom), or opacity in Fade mode.
    private var trashTransition: AnyTransition {
        guard PanelSettings.shared.animationStyle == .slide else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom),
            removal: .move(edge: .bottom),
        )
    }

    var body: some View {
        ZStack {
            // The board is the single home surface: tabs/sections over note
            // cards, with the expanded editor living inside it. Trash overlays
            // as its own page.
            NoteBoardView()

            if noteStore.showTrash {
                TrashView()
                    .transition(trashTransition)
            }
        }
        .clipped()
    }
}

#Preview {
    ContentView()
        .environment(NoteStore())
        .environment(AppSettings.shared)
        .environment(L10n.shared)
        .frame(width: 400, height: 600)
}
