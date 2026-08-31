import Foundation

enum HotkeyGesture: String, CaseIterable, Codable, Sendable, Hashable {
    case hold
    case doubleTapHold
    case toggle

    var displayName: String {
        switch self {
        case .hold: "Hold"
        case .doubleTapHold: "Double-tap and hold"
        case .toggle: "Press to start/stop"
        }
    }
}

enum EventConsumptionPolicy: String, Codable, Sendable, Hashable {
    case observe
    case suppress
}

enum ModifierSide: String, Codable, Sendable, Hashable {
    case left
    case right
}

enum HotkeyModifier: UInt64, CaseIterable, Sendable {
    case shift = 0x0002_0000
    case control = 0x0004_0000
    case option = 0x0008_0000
    case command = 0x0010_0000
    case function = 0x0080_0000
}

struct HotkeyBinding: Codable, Sendable, Hashable, Identifiable {
    let keyCode: Int64
    let requiredFlags: UInt64
    let side: ModifierSide?
    let gesture: HotkeyGesture
    let consumption: EventConsumptionPolicy
    let label: String

    var id: String {
        "\(keyCode):\(requiredFlags):\(side?.rawValue ?? "any")"
    }

    var isModifierOnly: Bool {
        [54, 55, 56, 60, 58, 61, 59, 62, 63].contains(keyCode)
    }

    func withGesture(_ gesture: HotkeyGesture) -> Self {
        Self(
            keyCode: keyCode,
            requiredFlags: requiredFlags,
            side: side,
            gesture: gesture,
            consumption: consumption,
            label: label
        )
    }
}

struct HotkeyBindingIssue: Equatable, Sendable {
    enum Severity: Sendable {
        case warning
        case error
    }

    enum Code: Sendable {
        case bareKey
        case duplicate
        case systemReserved
        case internationalLayout
    }

    let severity: Severity
    let code: Code
    let message: String
}

enum HotkeyBindingValidator {
    static func validate(
        primary: HotkeyBinding,
        handsFree: HotkeyBinding?
    ) -> [HotkeyBindingIssue] {
        var result = issues(for: primary)
        if let handsFree {
            result.append(contentsOf: issues(for: handsFree))
            if primary.id == handsFree.id {
                result.append(HotkeyBindingIssue(
                    severity: .error,
                    code: .duplicate,
                    message: "Hold-to-talk and hands-free cannot use the same shortcut."
                ))
            }
        }
        return result
    }

    static func issues(for binding: HotkeyBinding) -> [HotkeyBindingIssue] {
        var result: [HotkeyBindingIssue] = []
        if !binding.isModifierOnly, binding.requiredFlags == 0 {
            result.append(HotkeyBindingIssue(
                severity: .error,
                code: .bareKey,
                message: "Use at least one modifier with an ordinary key."
            ))
        }

        let command = HotkeyModifier.command.rawValue
        let reservedCommandKeyCodes: Set<Int64> = [4, 12, 46, 48, 49]
        if binding.requiredFlags & command != 0,
           reservedCommandKeyCodes.contains(binding.keyCode) {
            result.append(HotkeyBindingIssue(
                severity: .error,
                code: .systemReserved,
                message: "That shortcut is reserved by macOS."
            ))
        }

        if binding.keyCode == 61, binding.isModifierOnly {
            result.append(HotkeyBindingIssue(
                severity: .warning,
                code: .internationalLayout,
                message: "Right Option is AltGr on many international keyboard layouts."
            ))
        }
        return result
    }
}

struct HotkeyGesturePolicy: Sendable {
    enum Edge: Equatable, Sendable {
        case pressed(at: TimeInterval)
        case released(at: TimeInterval)
    }

    enum Command: Equatable, Sendable {
        case start
        case finish
        case ignore
    }

    private enum DoubleTapState: Sendable {
        case idle
        case waiting(firstPress: TimeInterval)
        case active
    }

    let gesture: HotkeyGesture
    let doubleTapWindow: TimeInterval
    private var isPhysicallyPressed = false
    private var isSessionActive = false
    private var doubleTapState: DoubleTapState = .idle

    init(gesture: HotkeyGesture, doubleTapWindow: TimeInterval = 0.4) {
        self.gesture = gesture
        self.doubleTapWindow = doubleTapWindow
    }

    mutating func handle(_ edge: Edge) -> Command {
        switch edge {
        case .pressed(let time):
            guard !isPhysicallyPressed else { return .ignore }
            isPhysicallyPressed = true
            return press(at: time)
        case .released:
            guard isPhysicallyPressed else { return .ignore }
            isPhysicallyPressed = false
            return release()
        }
    }

    mutating func reset() {
        isPhysicallyPressed = false
        isSessionActive = false
        doubleTapState = .idle
    }

    private mutating func press(at time: TimeInterval) -> Command {
        switch gesture {
        case .hold:
            guard !isSessionActive else { return .ignore }
            isSessionActive = true
            return .start
        case .toggle:
            isSessionActive.toggle()
            return isSessionActive ? .start : .finish
        case .doubleTapHold:
            switch doubleTapState {
            case .idle:
                doubleTapState = .waiting(firstPress: time)
                return .ignore
            case .waiting(let firstPress):
                guard time - firstPress <= doubleTapWindow else {
                    doubleTapState = .waiting(firstPress: time)
                    return .ignore
                }
                doubleTapState = .active
                isSessionActive = true
                return .start
            case .active:
                return .ignore
            }
        }
    }

    private mutating func release() -> Command {
        switch gesture {
        case .hold:
            guard isSessionActive else { return .ignore }
            isSessionActive = false
            return .finish
        case .toggle:
            return .ignore
        case .doubleTapHold:
            guard case .active = doubleTapState else { return .ignore }
            doubleTapState = .idle
            isSessionActive = false
            return .finish
        }
    }
}
