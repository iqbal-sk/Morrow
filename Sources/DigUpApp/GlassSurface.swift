import SwiftUI

/// The custom search field is the only SwiftUI surface that needs an explicit glass effect.
/// Standard sidebars, inspectors, sheets, pickers and buttons use their platform styles.
private struct MorrowSearchSurface: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(!reduceMotion), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    func morrowSearchSurface() -> some View { modifier(MorrowSearchSurface()) }
}

/// Groups nearby native glass actions without adding another material layer.
struct MorrowGlassGroup<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: () -> Content

    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
