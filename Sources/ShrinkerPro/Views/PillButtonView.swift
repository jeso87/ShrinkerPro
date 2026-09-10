import SwiftUI

/// Hairline-inset pill button: a small text label in a rounded, semi-
/// transparent ring that brightens on hover. Used for small inline actions
/// that should read as the same family of control rather than a stray,
/// differently-styled `Button` — the result row's "Reveal" pill and the
/// "RECENT" header's "Clear" pill both use this.
struct PillButtonView: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(isHovering ? 0.28 : 0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
