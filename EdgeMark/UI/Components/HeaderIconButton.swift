import SwiftUI

/// Toolbar icon with hover background animation.
struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isHovered ? DesignToken.bodyStrong : DesignToken.muted)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                        .fill(DesignToken.ink.opacity(isHovered ? DesignToken.Alpha.hover : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
