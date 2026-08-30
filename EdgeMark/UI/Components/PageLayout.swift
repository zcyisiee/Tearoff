import SwiftUI

/// Shared single-surface layout used across all screens.
/// One continuous backdrop fills the panel; the header is separated from the
/// content by a hairline, not by card boundaries. Pass `onSwipeBack` to enable
/// two-finger trackpad right-swipe to go back on the header.
struct PageLayout<Header: View, Content: View>: View {
    var onSwipeBack: (() -> Void)?
    var onContentSwipeRight: (() -> Void)?
    var onContentSwipeLeft: (() -> Void)?
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    init(
        onSwipeBack: (() -> Void)? = nil,
        onContentSwipeRight: (() -> Void)? = nil,
        onContentSwipeLeft: (() -> Void)? = nil,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
    ) {
        self.onSwipeBack = onSwipeBack
        self.onContentSwipeRight = onContentSwipeRight
        self.onContentSwipeLeft = onContentSwipeLeft
        self.header = header()
        self.content = content()
    }

    /// Theme canvas wash over the vibrancy material. Opaque themes paint
    /// nearly solid; translucent ones keep the backdrop visible through the wash.
    private var canvasWash: some View {
        DesignToken.canvas
            .opacity(ThemeEngine.shared.activeTheme.material.washOpacity)
    }

    var body: some View {
        ZStack {
            VisualEffectView(tint: nil, material: ThemeEngine.shared.activeTheme.material.nsMaterial)
            canvasWash.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, DesignToken.Space.lg)
                    .padding(.vertical, DesignToken.Space.sm + 2)
                    .overlay {
                        if let onSwipeBack {
                            SwipeDetectorView(onSwipeBack: onSwipeBack)
                        }
                    }

                DesignToken.hairlineSoft.frame(height: 1)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if onContentSwipeRight != nil || onContentSwipeLeft != nil {
                            SwipeDetectorView(
                                onSwipeBack: onContentSwipeRight,
                                onSwipeForward: onContentSwipeLeft,
                            )
                        }
                    }
            }
        }
    }
}
