import AppKit
import SwiftUI

/// The same vector artwork as the app icon, with optional once-per-launch motion.
struct MorrowAppIcon: View {
    let size: CGFloat
    var launch: LogoLaunchState? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coral = 1.0
    @State private var peach = 1.0

    var body: some View {
        RevealSymbol(coralProgress: reduceMotion ? 1 : coral, peachProgress: reduceMotion ? 1 : peach)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task {
                guard let launch, launch.claim(reduceMotion: reduceMotion) else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { coral = 0; peach = 0 }
                // Allow the initial pose to render; this task never holds up the app or search.
                do { try await Task.sleep(for: .milliseconds(32)) }
                catch { withTransaction(instant) { coral = 1; peach = 1 }; return }
                guard !reduceMotion else {
                    withTransaction(instant) { coral = 1; peach = 1 }
                    return
                }
                withAnimation(MorrowMotion.reveal) { coral = 1 }
                withAnimation(MorrowMotion.reveal.delay(0.06)) { peach = 1 }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced {
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { coral = 1; peach = 1 }
                }
            }
    }
}
