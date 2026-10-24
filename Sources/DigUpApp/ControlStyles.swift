import SwiftUI

/// Semantic action roles. Rendering, focus, pressing and accessibility remain system-owned.
enum MorrowActionProminence {
    case standard, primary
}

struct MorrowActionStyle: PrimitiveButtonStyle {
    var prominence: MorrowActionProminence = .standard

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            switch prominence {
            case .standard:
                Button(configuration).buttonStyle(.glass).tint(nil)
            case .primary:
                Button(configuration).buttonStyle(.glassProminent).tint(Brand.accent)
            }
        } else {
            switch prominence {
            case .standard:
                Button(configuration).buttonStyle(.bordered).tint(nil)
            case .primary:
                Button(configuration).buttonStyle(.borderedProminent).tint(Brand.accent)
            }
        }
    }
}

/// Selection is a tinted glass surface, distinct from an opaque prominent action.
/// Keep the label semantic so it remains readable in light/dark and accessibility appearances.
struct MorrowSelectionStyle: PrimitiveButtonStyle {
    var selected: Bool

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if !selected {
            Button(configuration).buttonStyle(MorrowActionStyle())
        } else if #available(macOS 26.1, *) {
            Button(configuration)
                .buttonStyle(.glass(.regular.tint(Brand.coral.opacity(0.6))))
                .tint(Brand.coral)
                .foregroundStyle(.primary)
        } else if #available(macOS 26.0, *) {
            Button(configuration).buttonStyle(.glass).tint(Brand.coral)
                .foregroundStyle(.primary)
        } else {
            Button(configuration).buttonStyle(.borderedProminent).tint(Brand.accent)
        }
    }
}

private struct MorrowTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(MorrowActionStyle())
            .tint(Brand.accent)
    }
}

extension View {
    /// Install once at each window/panel root. Links, cards and system menus keep explicit styles.
    func morrowTheme() -> some View { modifier(MorrowTheme()) }

    func morrowAction(_ prominence: MorrowActionProminence = .standard) -> some View {
        buttonStyle(MorrowActionStyle(prominence: prominence))
    }

    func morrowSelection(_ selected: Bool) -> some View {
        buttonStyle(MorrowSelectionStyle(selected: selected))
    }
}
