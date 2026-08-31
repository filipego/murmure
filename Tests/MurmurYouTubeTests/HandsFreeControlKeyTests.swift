import Testing
@testable import MurmurYouTube

@Suite("Hands-free control keys")
struct HandsFreeControlKeyTests {
    @Test("Return and keypad Enter finish only while hands-free is active")
    func enterKeys() {
        #expect(HandsFreeControlKey.action(keyCode: 36, isHandsFreeActive: true) == .finish)
        #expect(HandsFreeControlKey.action(keyCode: 76, isHandsFreeActive: true) == .finish)
        #expect(HandsFreeControlKey.action(keyCode: 36, isHandsFreeActive: false) == nil)
    }

    @Test("Escape cancels only while hands-free is active")
    func escapeKey() {
        #expect(HandsFreeControlKey.action(keyCode: 53, isHandsFreeActive: true) == .cancel)
        #expect(HandsFreeControlKey.action(keyCode: 53, isHandsFreeActive: false) == nil)
    }

    @Test("ordinary keys always pass through")
    func ordinaryKey() {
        #expect(HandsFreeControlKey.action(keyCode: 0, isHandsFreeActive: true) == nil)
        #expect(HandsFreeControlKey.action(keyCode: 49, isHandsFreeActive: true) == nil)
    }
}
