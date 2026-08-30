import SwiftUI

/// Shared chrome for the editor/list header icon buttons: fixed 28×28 hit
/// target, hover wash, and color states. `active` renders accent-tinted and
/// stays highlighted (used by toggle-style buttons like Pin and Outline).
struct IconHoverChrome: ViewModifier {
    let isHovered: Bool
    var isActive: Bool = false

    private var foreground: Color {
        if isActive { return DesignToken.accent }
        if isHovered { return DesignToken.bodyStrong }
        return DesignToken.muted
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                    .fill(
                        isActive
                            ? DesignToken.accent.opacity(isHovered ? DesignToken.Alpha.selected : DesignToken.Alpha.hover)
                            : DesignToken.ink.opacity(isHovered ? DesignToken.Alpha.hover : 0),
                    )
            }
            .contentShape(Rectangle())
    }
}

extension View {
    func iconHoverChrome(isHovered: Bool, isActive: Bool = false) -> some View {
        modifier(IconHoverChrome(isHovered: isHovered, isActive: isActive))
    }
}
