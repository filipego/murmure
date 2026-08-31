import AppKit
import SwiftUI

struct ShortcutRecorderSheet: View {
    let title: String
    let gesture: HotkeyGesture
    let onCapture: (HotkeyBinding) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            Text("Press a modifier by itself, or hold modifiers and press another key. Escape cancels.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ShortcutCaptureView(
                gesture: gesture,
                onCapture: onCapture,
                onCancel: onCancel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            }
        }
        .padding(DS.Space.panel)
        .frame(
            width: DS.Size.shortcutRecorderWidth,
            height: DS.Size.shortcutRecorderHeight
        )
        .background(DS.Color.canvas)
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let gesture: HotkeyGesture
    let onCapture: (HotkeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        CaptureView(
            gesture: gesture,
            onCapture: onCapture,
            onCancel: onCancel
        )
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.gesture = gesture
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    }
}

private final class CaptureView: NSView {
    var gesture: HotkeyGesture
    var onCapture: (HotkeyBinding) -> Void
    var onCancel: () -> Void
    private var pendingModifier: HotkeyBinding?

    init(
        gesture: HotkeyGesture,
        onCapture: @escaping (HotkeyBinding) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.gesture = gesture
        self.onCapture = onCapture
        self.onCancel = onCancel
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { self.window?.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
            return
        }
        pendingModifier = nil
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let portable = flags.intersection([.command, .control, .option, .shift, .function])
        onCapture(HotkeyBinding(
            keyCode: Int64(event.keyCode),
            requiredFlags: UInt64(portable.rawValue),
            side: nil,
            gesture: gesture,
            consumption: .suppress,
            label: Self.label(for: event, flags: portable)
        ))
    }

    override func flagsChanged(with event: NSEvent) {
        guard let candidate = Self.modifierBinding(
            keyCode: event.keyCode,
            gesture: gesture
        ) else { return }

        let pressed = event.modifierFlags.rawValue & UInt(candidate.requiredFlags) != 0
        if pressed {
            pendingModifier = candidate
        } else if pendingModifier?.keyCode == candidate.keyCode {
            pendingModifier = nil
            onCapture(candidate)
        }
    }

    private static func modifierBinding(
        keyCode: UInt16,
        gesture: HotkeyGesture
    ) -> HotkeyBinding? {
        if let preset = PushToTalkKey.allCases.first(where: { $0.keyCode == Int64(keyCode) }) {
            return preset.binding(gesture: gesture)
        }

        let details: (UInt64, ModifierSide, String)? = switch keyCode {
        case 55: (0x8, .left, "Left ⌘")
        case 58: (0x20, .left, "Left ⌥")
        case 59: (0x1, .left, "Left ⌃")
        case 62: (0x2000, .right, "Right ⌃")
        case 56: (0x2, .left, "Left ⇧")
        case 60: (0x4, .right, "Right ⇧")
        default: nil
        }
        guard let details else { return nil }
        return HotkeyBinding(
            keyCode: Int64(keyCode),
            requiredFlags: details.0,
            side: details.1,
            gesture: gesture,
            consumption: .suppress,
            label: details.2
        )
    }

    private static func label(
        for event: NSEvent,
        flags: NSEvent.ModifierFlags
    ) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        if flags.contains(.function) { result += "fn " }
        result += keyName(event)
        return result
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 36: "Return"
        case 48: "Tab"
        case 49: "Space"
        case 51: "Delete"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default:
            event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        }
    }
}
