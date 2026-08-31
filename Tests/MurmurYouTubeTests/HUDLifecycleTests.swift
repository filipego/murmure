import Testing

@testable import MurmurYouTube

@Suite("HUD lifecycle")
@MainActor
struct HUDLifecycleTests {
    @Test("the HUD exists only while dictation is active")
    func releasesHUDWhenDismissalFinishes() {
        let factory = HUDFactorySpy()
        let lifecycle = HUDLifecycle(makeHUD: factory.make)

        #expect(!lifecycle.hasHUD)

        lifecycle.setActive(true)

        #expect(lifecycle.hasHUD)
        #expect(factory.makeCount == 1)
        #expect(factory.latest?.presentCount == 1)

        lifecycle.setActive(false)

        #expect(lifecycle.hasHUD)
        #expect(factory.latest?.dismissCount == 1)

        factory.latest?.finishDismissal()

        #expect(!lifecycle.hasHUD)
    }

    @Test("reactivation during fade-out keeps the current HUD alive")
    func reactivationCancelsRelease() {
        let factory = HUDFactorySpy()
        let lifecycle = HUDLifecycle(makeHUD: factory.make)

        lifecycle.setActive(true)
        lifecycle.setActive(false)
        lifecycle.setActive(true)
        factory.latest?.finishDismissal()

        #expect(lifecycle.hasHUD)
        #expect(factory.makeCount == 1)
        #expect(factory.latest?.presentCount == 2)
    }

    @Test("a later dictation creates a fresh HUD surface")
    func createsFreshHUDAfterRelease() {
        let factory = HUDFactorySpy()
        let lifecycle = HUDLifecycle(makeHUD: factory.make)

        lifecycle.setActive(true)
        lifecycle.setActive(false)
        factory.latest?.finishDismissal()
        lifecycle.setActive(true)

        #expect(factory.makeCount == 2)
        #expect(lifecycle.hasHUD)
    }
}

@MainActor
private final class HUDFactorySpy {
    private(set) var makeCount = 0
    private(set) var latest: HUDSpy?

    func make() -> any HUDPresenting {
        makeCount += 1
        let hud = HUDSpy()
        latest = hud
        return hud
    }
}

@MainActor
private final class HUDSpy: HUDPresenting {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private var dismissal: (@MainActor () -> Void)?

    func present() {
        presentCount += 1
    }

    func dismiss(onHidden: @escaping @MainActor () -> Void) {
        dismissCount += 1
        dismissal = onHidden
    }

    func finishDismissal() {
        let completion = dismissal
        dismissal = nil
        completion?()
    }
}
