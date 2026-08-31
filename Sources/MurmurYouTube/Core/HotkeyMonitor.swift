import AppKit
import Carbon.HIToolbox
import Foundation

/// Which modifier key holds the mic open.
enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightOption
    case fn
    case rightCommand

    var keyCode: Int64 {
        switch self {
        case .rightOption: Int64(kVK_RightOption)   // 61
        case .fn: Int64(kVK_Function)               // 63
        case .rightCommand: Int64(kVK_RightCommand) // 54
        }
    }

    /// Device-*dependent* bit for this specific physical key.
    ///
    /// `CGEventFlags.maskAlternate` is the union mask — it's set whenever *either* Option
    /// key is down. Using it means: hold Left ⌥, tap Right ⌥, and the release is invisible
    /// (the union bit is still set by the left key), so `onRelease` never fires. The mic
    /// stays open, the HUD stays up, and the next press is swallowed too.
    ///
    /// These raw values are the NX_DEVICE* masks from IOKit's event system; they carry the
    /// left/right distinction that the public `CGEventFlags` constants discard.
    var flag: CGEventFlags {
        switch self {
        case .rightOption: CGEventFlags(rawValue: 0x40)   // NX_DEVICERALTKEYMASK
        case .rightCommand: CGEventFlags(rawValue: 0x10)  // NX_DEVICERCMDKEYMASK
        case .fn: .maskSecondaryFn                        // no left/right variant exists
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .fn: "fn"
        case .rightCommand: "Right ⌘"
        }
    }

    /// Swallowing `fn` would break fn+arrow, fn+delete and the emoji picker, so we let it
    /// through. Dedicated right-hand modifiers are safe to consume.
    var shouldConsumeEvent: Bool { self != .fn }

    func binding(gesture: HotkeyGesture) -> HotkeyBinding {
        HotkeyBinding(
            keyCode: keyCode,
            requiredFlags: flag.rawValue,
            side: self == .fn ? nil : .right,
            gesture: gesture,
            consumption: shouldConsumeEvent ? .suppress : .observe,
            label: displayName
        )
    }
}

/// Watches for a held modifier key using a `CGEventTap`.
///
/// A tap is required rather than `NSEvent.addGlobalMonitor` because `fn` and left/right
/// modifier discrimination don't surface through the higher-level APIs. This needs
/// Accessibility permission; without it `CGEvent.tapCreate` returns nil.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private lazy var callbackContext = HotkeyCallbackContext(monitor: self)

    var binding = PushToTalkKey.rightOption.binding(gesture: .hold)
    var handsFreeBinding: HotkeyBinding?
    var commandModeBinding: HotkeyBinding?
    var handsFreeSessionIsActive = false {
        didSet { callbackContext.router.handsFreeSessionIsActive = handsFreeSessionIsActive }
    }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onHandsFreeToggle: (() -> Void)?
    var onHandsFreeFinish: (() -> Void)?
    var onHandsFreeCancel: (() -> Void)?
    var onCommandModePress: (() -> Void)?
    var onCommandModeRelease: (() -> Void)?

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        callbackContext.router.configure(
            binding: binding,
            handsFreeBinding: handsFreeBinding,
            commandModeBinding: commandModeBinding,
            handsFreeSessionIsActive: handsFreeSessionIsActive
        )
        let refcon = Unmanaged.passUnretained(callbackContext).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<HotkeyCallbackContext>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                let consume = context.handle(
                    type: type,
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    flags: event.flags
                )
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for \(self.binding.label)")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        callbackContext.router.reset()
    }

    fileprivate func perform(_ action: HotkeyTapAction) {
        switch action {
        case .press: onPress?()
        case .release: onRelease?()
        case .handsFreeToggle: onHandsFreeToggle?()
        case .handsFreeFinish: onHandsFreeFinish?()
        case .handsFreeCancel: onHandsFreeCancel?()
        case .commandModePress: onCommandModePress?()
        case .commandModeRelease: onCommandModeRelease?()
        case .reenable:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
    }
}

enum HotkeyTapAction: Sendable, Equatable {
    case press
    case release
    case handsFreeToggle
    case handsFreeFinish
    case handsFreeCancel
    case commandModePress
    case commandModeRelease
    case reenable
}

/// The event tap needs a synchronous consume/pass-through answer, while app actions belong
/// on the main actor. This context owns only plain event state, computes that answer, and
/// then schedules the resulting action onto the actor without asserting executor identity.
private final class HotkeyCallbackContext: @unchecked Sendable {
    weak var monitor: HotkeyMonitor?
    let router = HotkeyEventRouter()

    init(monitor: HotkeyMonitor) {
        self.monitor = monitor
    }

    func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        let result = router.route(type: type, keyCode: keyCode, flags: flags)
        if let action = result.action, let monitor {
            Task { @MainActor [weak monitor] in monitor?.perform(action) }
        }
        return result.consume
    }
}

final class HotkeyEventRouter: @unchecked Sendable {
    private var binding = PushToTalkKey.rightOption.binding(gesture: .hold)
    private var handsFreeBinding: HotkeyBinding?
    private var commandModeBinding: HotkeyBinding?
    private var isPressed = false
    private var isHandsFreePressed = false
    private var isCommandModePressed = false
    var handsFreeSessionIsActive = false

    func configure(
        binding: HotkeyBinding,
        handsFreeBinding: HotkeyBinding?,
        commandModeBinding: HotkeyBinding? = nil,
        handsFreeSessionIsActive: Bool
    ) {
        self.binding = binding
        self.handsFreeBinding = handsFreeBinding
        self.commandModeBinding = commandModeBinding
        self.handsFreeSessionIsActive = handsFreeSessionIsActive
        isPressed = false
        isHandsFreePressed = false
        isCommandModePressed = false
    }

    func reset() {
        isPressed = false
        isHandsFreePressed = false
        isCommandModePressed = false
        handsFreeSessionIsActive = false
    }

    func route(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags
    ) -> (consume: Bool, action: HotkeyTapAction?) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return (false, .reenable)
        }

        if type == .keyDown,
           let control = HandsFreeControlKey.action(
               keyCode: keyCode,
               isHandsFreeActive: handsFreeSessionIsActive
           ) {
            return (true, control == .finish ? .handsFreeFinish : .handsFreeCancel)
        }

        if let commandModeBinding,
           let event = physicalEvent(
               for: commandModeBinding,
               type: type,
               keyCode: keyCode,
               flags: flags,
               wasPressed: isCommandModePressed
           ) {
            if event == .press { isCommandModePressed = true }
            if event == .release { isCommandModePressed = false }
            let action: HotkeyTapAction? = switch event {
            case .press: .commandModePress
            case .release: .commandModeRelease
            case .repeatPress: nil
            }
            return (commandModeBinding.consumption == .suppress, action)
        }

        if let handsFreeBinding,
           let event = physicalEvent(
               for: handsFreeBinding,
               type: type,
               keyCode: keyCode,
               flags: flags,
               wasPressed: isHandsFreePressed
           ) {
            if event == .press { isHandsFreePressed = true }
            if event == .release { isHandsFreePressed = false }
            return (
                handsFreeBinding.consumption == .suppress,
                event == .press ? .handsFreeToggle : nil
            )
        }

        guard let event = physicalEvent(
            for: binding,
            type: type,
            keyCode: keyCode,
            flags: flags,
            wasPressed: isPressed
        ) else { return (false, nil) }
        if event == .press { isPressed = true }
        if event == .release { isPressed = false }
        let action: HotkeyTapAction? = switch event {
        case .press: .press
        case .release: .release
        case .repeatPress: nil
        }
        return (
            binding.consumption == .suppress,
            action
        )
    }

    private enum PhysicalEvent {
        case press
        case release
        case repeatPress
    }

    private func physicalEvent(
        for binding: HotkeyBinding,
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        wasPressed: Bool
    ) -> PhysicalEvent? {
        guard keyCode == binding.keyCode else { return nil }

        if binding.isModifierOnly {
            guard type == .flagsChanged else { return nil }
            let nowPressed = flags.rawValue & binding.requiredFlags == binding.requiredFlags
            if nowPressed { return wasPressed ? .repeatPress : .press }
            return wasPressed ? .release : nil
        } else {
            switch type {
            case .keyDown:
                guard flags.rawValue & binding.requiredFlags == binding.requiredFlags else {
                    return nil
                }
                return wasPressed ? .repeatPress : .press
            case .keyUp:
                return wasPressed ? .release : nil
            default:
                return nil
            }
        }
    }
}
