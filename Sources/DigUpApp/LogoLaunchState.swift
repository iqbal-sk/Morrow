/// Process-scoped permission for one decorative foreground-launch animation.
/// Kept out of preferences: a fresh app launch gets a fresh permission.
final class LogoLaunchState {
    private var pending: Bool

    init(foregroundLaunch: Bool) {
        pending = foregroundLaunch
    }

    func claim(reduceMotion: Bool) -> Bool {
        let allowed = pending
        pending = false
        return allowed && !reduceMotion
    }
}
