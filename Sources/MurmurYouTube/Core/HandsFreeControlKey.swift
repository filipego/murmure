enum HandsFreeControlKey {
    enum Action: Equatable {
        case finish
        case cancel
    }

    // Carbon virtual key codes are stable hardware positions on macOS. Keeping the mapping
    // here makes the event-tap adapter a translation boundary instead of a second lifecycle.
    private static let returnKeyCode: Int64 = 36
    private static let keypadEnterKeyCode: Int64 = 76
    private static let escapeKeyCode: Int64 = 53

    static func action(keyCode: Int64, isHandsFreeActive: Bool) -> Action? {
        guard isHandsFreeActive else { return nil }

        switch keyCode {
        case returnKeyCode, keypadEnterKeyCode:
            return .finish
        case escapeKeyCode:
            return .cancel
        default:
            return nil
        }
    }
}
