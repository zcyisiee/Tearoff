import SwiftUI

/// Shared single-surface layout used across all screens.
/// One continuous backdrop fills the panel; the header is separated from the
/// content by a hairline, not by card boundaries. Pass `onSwipeBack` to enable
/// two-finger trackpad right-swipe to go back on the header.
struct PageLayout<Header: View, Content: View>: View {
    @Environment(AppSettings.self) private var appSettings
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

    /// Warm canvas wash over the vibrancy material. Opaque style paints nearly
    /// solid; translucent keeps the backdrop visible through the wash.
    private var canvasWash: some View {
        DesignToken.canvas
            .opacity(appSettings.panelStyle == .opaque ? 0.94 : 0.8)
    }

    var body: some View {
        ZStack {
            VisualEffectView(tint: appSettings.panelTint.color, material: appSettings.panelStyle.material)
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
