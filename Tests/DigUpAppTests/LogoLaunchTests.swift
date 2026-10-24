import Testing
@testable import DigUpApp

@MainActor @Suite struct LogoLaunchTests {
    @Test func foregroundLaunchPlaysOnlyOnceAcrossAllHosts() {
        let launch = LogoLaunchState(foregroundLaunch: true)
        #expect(launch.claim(reduceMotion: false))
        // Recreated sidebar, reopening the window, or returning to onboarding cannot replay it.
        #expect(!launch.claim(reduceMotion: false))
        #expect(!launch.claim(reduceMotion: false))
    }

    @Test func backgroundLoginDoesNotSaveAnAnimationForLater() {
        let launch = LogoLaunchState(foregroundLaunch: false)
        #expect(!launch.claim(reduceMotion: false))
        #expect(!launch.claim(reduceMotion: false))
    }

    @Test func reducedMotionConsumesTheLaunchWithoutMovementOrLaterReplay() {
        let launch = LogoLaunchState(foregroundLaunch: true)
        #expect(!launch.claim(reduceMotion: true))
        #expect(!launch.claim(reduceMotion: false))
    }

    @Test func aNewProcessGetsItsOwnLaunch() {
        #expect(LogoLaunchState(foregroundLaunch: true).claim(reduceMotion: false))
        #expect(LogoLaunchState(foregroundLaunch: true).claim(reduceMotion: false))
    }
}
