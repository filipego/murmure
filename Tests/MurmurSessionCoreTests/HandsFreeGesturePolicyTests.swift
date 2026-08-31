import Testing
@testable import MurmurSessionCore

@Suite("Hands-free gesture policy")
struct HandsFreeGesturePolicyTests {
    @Test("the dedicated binding starts and then finishes one session")
    func bindingToggles() {
        var policy = HandsFreeGesturePolicy()

        #expect(policy.handle(.bindingPressed) == .start)
        #expect(policy.handle(.bindingPressed) == .finish)
        #expect(policy.handle(.bindingPressed) == .ignore)
    }

    @Test("Enter finishes only an active hands-free session")
    func enterFinishesOnlyWhileActive() {
        var policy = HandsFreeGesturePolicy()

        #expect(policy.handle(.enterPressed) == .ignore)
        #expect(policy.handle(.bindingPressed) == .start)
        #expect(policy.handle(.enterPressed) == .finish)
        #expect(policy.handle(.enterPressed) == .ignore)
    }

    @Test("Escape cancels only an active hands-free session")
    func escapeCancelsOnlyWhileActive() {
        var policy = HandsFreeGesturePolicy()

        #expect(policy.handle(.escapePressed) == .ignore)
        #expect(policy.handle(.bindingPressed) == .start)
        #expect(policy.handle(.escapePressed) == .cancel)
        #expect(policy.handle(.escapePressed) == .ignore)
        #expect(policy.isActive == false)
    }

    @Test("completion and failure reset the toggle lifecycle")
    func terminalReset() {
        var policy = HandsFreeGesturePolicy()

        #expect(policy.handle(.bindingPressed) == .start)
        #expect(policy.handle(.sessionEnded) == .ignore)
        #expect(policy.handle(.bindingPressed) == .start)
        #expect(policy.handle(.bindingPressed) == .finish)
        #expect(policy.handle(.sessionEnded) == .ignore)
        #expect(policy.handle(.bindingPressed) == .start)
    }

    @Test("reset cancels pending policy state without issuing a command")
    func explicitReset() {
        var policy = HandsFreeGesturePolicy()

        #expect(policy.handle(.bindingPressed) == .start)
        policy.reset()
        #expect(policy.isActive == false)
        #expect(policy.handle(.enterPressed) == .ignore)
    }
}
