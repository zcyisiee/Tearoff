import SwiftUI

/// Shared single-surface layout used across all screens.
/// The backdrop is a near-transparent vibrancy material — cards and the header
/// pill float on it as frosted glass (SideNotes-style); nothing else paints a
/// surface. The header renders as its own rounded-rect glass pill. Pass
/// `onSwipeBack` to enable two-finger trackpad right-swipe to go back on the
/// header.
struct PageLayout<Header: View, Content: View>: View {
    var onSwipeBack: (() -> Void)?
    var onContentSwipeRight: (() -> Void)?
    var onContentSwipeLeft: (() -> Void)?
    /// True when the screen renders its own chrome (expanded editor) — skips
    /// the header pill entirely instead of showing an empty one.
    var headerHidden: Bool
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    init(
        onSwipeBack: (() -> Void)? = nil,
        onContentSwipeRight: (() -> Void)? = nil,
        onContentSwipeLeft: (() -> Void)? = nil,
        headerHidden: Bool = false,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
    ) {
        self.onSwipeBack = onSwipeBack
        self.onContentSwipeRight = onContentSwipeRight
        self.onContentSwipeLeft = onContentSwipeLeft
        self.headerHidden = headerHidden
        self.header = header()
        self.content = content()
    }

    var body: some View {
        ZStack {
            // Single-path vibrancy: underWindowBackground keeps the backdrop
            // nearly invisible (desktop reads through with a light blur, like
            // SideNotes) and honors Reduce Transparency by going opaque.
            VisualEffectView(tint: nil, material: .underWindowBackground)

            VStack(spacing: DesignToken.Space.sm) {
                if !headerHidden {
                    header
                        .padding(.horizontal, DesignToken.Space.md)
                        .padding(.vertical, DesignToken.Space.sm + 2)
                        .frame(maxWidth: .infinity)
                        .background { headerPill }
                        .overlay { headerPillBorder }
                        .padding(.horizontal, DesignToken.Space.lg)
                        .padding(.top, DesignToken.Space.sm)
                        .overlay {
                            if let onSwipeBack {
                                SwipeDetectorView(onSwipeBack: onSwipeBack)
                            }
                        }
                }

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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var headerPill: some View {
        RoundedRectangle(cornerRadius: DesignToken.Radius.card)
            .fill(reduceTransparency ? DesignToken.surfaceCard : DesignToken.glassCard)
    }

    private var headerPillBorder: some View {
        RoundedRectangle(cornerRadius: DesignToken.Radius.card)
            .strokeBorder(DesignToken.hairlineSoft, lineWidth: 1)
    }
}
