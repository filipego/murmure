import AppKit
import SwiftUI

/// Shared visual language for the Murmure command center.
///
/// Surfaces are quiet and warm, navigation is charcoal, and the record accent is reserved for
/// an active capture. The older equipment views still use these names, so keeping the tokens in
/// one place lets the main hub evolve without changing any recording behaviour.
enum DS {
    enum Color {
        static let canvas = face(light: 0xF4F1EC, dark: 0x171615)
        static let chassis = face(light: 0xE6E0D8, dark: 0x121110)
        static let rail = face(light: 0x292724, dark: 0x24211F)
        static let railInk = swatch(0xF5F0E9)
        static let railInkSecondary = swatch(0xB4ACA2)
        static let panel = face(light: 0xFFFCF8, dark: 0x252220)
        static let panelHighlight = face(light: 0xFFFFFF, dark: 0x332F2B)
        static let panelShade = face(light: 0xD4CCC3, dark: 0x191715)
        static let well = face(light: 0xECE7E0, dark: 0x1C1917)
        static let deck = face(light: 0xF8F5F0, dark: 0x141210)
        static let cap = face(light: 0xFFFFFF, dark: 0x302B28)
        static let seam = face(light: 0xD3CCC4, dark: 0x403A35)

        static let ink = face(light: 0x25211E, dark: 0xF1EBE2)
        static let inkSecondary = face(light: 0x716961, dark: 0xB5ACA1)
        static let silkscreen = face(light: 0x5E554D, dark: 0xC2B9AF)
        static let inkOnDeck = face(light: 0x302A26, dark: 0xEFE7DD)

        /// The only action accent. It appears for recording and recording-related status.
        static let record = face(light: 0xB44732, dark: 0xB44732)
        static let recordIdle = face(light: 0xBDA197, dark: 0x623A31)
        static let accent = record
        static let success = face(light: 0x527257, dark: 0x9AB39A)
        static let warning = face(light: 0x8A5A2E, dark: 0xD59A63)
        static let selection = face(light: 0xE8DED4, dark: 0x3A312B)
        static let selectionEdge = face(light: 0xC0A99A, dark: 0x665146)
        static let focusRing = swatch(0xC0785B)
        static let hover = face(light: 0xF0E9E1, dark: 0x302A26)

        // Instrumentation only. These values never serve as navigation or button chrome.
        static let meterFace = swatch(0xD8CFB4)
        static let meterLamp = swatch(0xE8B860)
        static let meterNeedle = swatch(0x1C1A17)
        static let meterGreen = swatch(0x6F9E45)
        static let meterAmber = swatch(0xD39A2E)
        static let meterRed = swatch(0xC0392B)

        private static func swatch(_ hex: UInt32) -> SwiftUI.Color { SwiftUI.Color(hex: hex) }

        private static func face(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
        }
    }

    enum Font {
        static let eyebrow = SwiftUI.Font.system(size: 10, weight: .semibold, design: .rounded)
        static let silkscreen = eyebrow
        static let silkscreenLarge = SwiftUI.Font.system(size: 12, weight: .semibold, design: .rounded)
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        static let label = SwiftUI.Font.system(size: 12, weight: .regular)
        static let body = SwiftUI.Font.system(size: 14, weight: .regular)
        static let bodyEmphasis = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold, design: .rounded)
        static let display = SwiftUI.Font.system(size: 30, weight: .semibold, design: .rounded)
        static let counter = SwiftUI.Font.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit()
        static let counterLarge = SwiftUI.Font.system(size: 26, weight: .medium, design: .monospaced).monospacedDigit()
        static let silkscreenTracking: CGFloat = 0.8
    }

    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 6
        static let snug: CGFloat = 10
        static let base: CGFloat = 14
        static let roomy: CGFloat = 18
        static let wide: CGFloat = 24
        static let panel: CGFloat = 28
        static let rail: CGFloat = 20
    }

    enum Radius {
        static let none: CGFloat = 0
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let panel: CGFloat = 12
        static let window: CGFloat = 16
    }

    enum Border {
        static let hairline: CGFloat = 1
        static let seam: CGFloat = 1
        static let bevel: CGFloat = 1
    }

    enum Size {
        static let settingsCategoryRailWidth: CGFloat = 214
        static let settingsCategoryIconWidth: CGFloat = 18
        static let settingsPickerMaxWidth: CGFloat = 260
        static let settingsTimingPickerWidth: CGFloat = 440
        static let correctionSheetWidth: CGFloat = 560
        static let correctionSheetMinHeight: CGFloat = 520
        static let correctionTextEditorHeight: CGFloat = 112
        static let correctionOriginalMaxHeight: CGFloat = 96
        static let microphoneTestMeterHeight: CGFloat = 72
        static let shortcutRecorderWidth: CGFloat = 440
        static let shortcutRecorderHeight: CGFloat = 180
        static let onboardingWidth: CGFloat = 680
        static let onboardingHeight: CGFloat = 560
        static let diagnosticsWidth: CGFloat = 680
        static let diagnosticsHeight: CGFloat = 520
        static let commandModeWidth: CGFloat = 760
        static let commandModeHeight: CGFloat = 560
    }

    enum Shadow {
        static let raised = Spec(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
        static let pressed = Spec(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        static let panel = Spec(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        static let window = Spec(color: .black.opacity(0.18), radius: 28, x: 0, y: 10)

        struct Spec {
            let color: SwiftUI.Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }

    enum Material {
        static let grainLight: Double = 0.02
        static let grainDark: Double = 0.025
        static let grainPitch: CGFloat = 3
        static let grainAngle: Angle = .degrees(0)
        static let screwSize: CGFloat = 8
        static let screwInset: CGFloat = 10
        static let ventSlotWidth: CGFloat = 3
        static let ventSlotHeight: CGFloat = 18
        static let ventSlotGap: CGFloat = 4
        static let ventRadius: CGFloat = 1.5
        static let lampSize: CGFloat = 7
        static let lampSpecular: Double = 0.35
        static let lampUnlitOpacity: Double = 0.18
        static let segmentThickness: CGFloat = 3
        static let segmentGap: CGFloat = 1
        static let segmentGhostOpacity: Double = 0.12
        static let keyHeight: CGFloat = 34
        static let keyMinWidth: CGFloat = 52
        static let keyTravel: CGFloat = 1.5
        static let needleSweep: Angle = .degrees(96)
        static let needleWidth: CGFloat = 1.5
        static let meterZeroPoint: Double = 0.72
    }

    enum Motion {
        static let press = Animation.easeOut(duration: 0.06)
        static let release = Animation.easeOut(duration: 0.12)
        static let panel = Animation.easeInOut(duration: 0.18)
        static let lamp = Animation.easeOut(duration: 0.08)
        static let needleAttack: TimeInterval = 0.30
        static let needleRelease: TimeInterval = 0.42
        static let needleOvershoot: Double = 0.06
    }
}

private extension SwiftUI.Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
