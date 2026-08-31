import SwiftUI

/// Compact voice status pill hosted by the non-activating HUDPanel. It stays high contrast and
/// text-first so the target app keeps focus while the user is speaking.
struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            ZStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                Image(systemName: statusIcon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }

            Waveform(level: controller.level, isActive: controller.state.isActive)
                .frame(width: 64, height: 24)

            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(L10n.text(statusTitle))
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.railInk)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(controller.transcript.isEmpty ? L10n.text(detail) : detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.railInkSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.snug)
        .frame(width: 340, height: 76)
        .background(DS.Color.rail, in: .rect(cornerRadius: DS.Radius.window))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.window)
                .strokeBorder(DS.Color.railInkSecondary.opacity(0.25), lineWidth: DS.Border.hairline)
        }
        .shadow(
            color: DS.Shadow.window.color,
            radius: DS.Shadow.window.radius,
            x: DS.Shadow.window.x,
            y: DS.Shadow.window.y
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text(statusTitle))
        .accessibilityValue(controller.transcript.isEmpty ? L10n.text(detail) : detail)
    }

    private var statusIcon: String {
        switch controller.state {
        case .starting, .listening: "mic.fill"
        case .finishing: "ellipsis"
        case .error: "exclamationmark"
        case .idle: "checkmark"
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .starting, .listening, .finishing: DS.Color.record
        case .error: DS.Color.warning
        case .idle: DS.Color.success
        }
    }

    private var statusTitle: String {
        switch controller.state {
        case .starting: "Starting microphone"
        case .listening: "Listening"
        case .finishing: "Transcribing"
        case .error: "Dictation needs attention"
        case .idle: "Ready"
        }
    }

    private var detail: String {
        switch controller.state {
        case .listening:
            controller.transcript.isEmpty ? "Speak naturally" : controller.transcript
        case .finishing:
            controller.transcript.isEmpty ? "Finishing locally…" : controller.transcript
        case let .error(message): message
        case .starting, .idle: ""
        }
    }
}

private struct Waveform: View {
    let level: Float
    let isActive: Bool

    private static let barCount = 12
    private static let phases: [Double] = (0..<barCount).map { index in
        (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: DS.Space.hair) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(isActive ? DS.Color.record : DS.Color.railInkSecondary)
                        .frame(width: DS.Space.hair, height: height(for: index, at: time))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        let floorHeight: CGFloat = 3
        guard isActive else { return floorHeight }
        let phase = Self.phases[index]
        let wave = sin(time * 6.0 + phase * .pi * 2)
        let amplitude = CGFloat(max(0.04, level))
        return floorHeight + max(0, amplitude * (0.55 + 0.45 * CGFloat(wave))) * 21
    }
}
