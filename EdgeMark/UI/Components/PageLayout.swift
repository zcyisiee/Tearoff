import SwiftUI

/// Shared single-surface layout used across all screens.
/// One continuous translucent vibrancy backdrop fills the panel; the header is
/// separated from the content by a hairline, not by card boundaries. Cards and
/// sheets float on the vibrancy as frosted glass (SideNotes-style). Pass
/// `onSwipeBack` to enable two-finger trackpad right-swipe to go back on the
/// header.
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

    var body: some View {
        ZStack {
            // Single-path vibrancy: NSVisualEffectView renders the frosted
            // backdrop identically from macOS 15.7 through 26 and honors
            // Reduce Transparency by going opaque on its own.
            VisualEffectView(tint: nil, material: .sidebar)

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
