public struct HandsFreeGesturePolicy: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case bindingPressed
        case enterPressed
        case escapePressed
        case sessionEnded
    }

    public enum Command: Sendable, Equatable {
        case start
        case finish
        case cancel
        case ignore
    }

    private enum State: Sendable, Equatable {
        case idle
        case active
        case finishing
    }

    private var state: State = .idle

    public init() {}

    /// Whether Return and Escape belong to Murmure right now. Once finishing begins they
    /// pass through again, while repeated finish commands remain suppressed by `finishing`.
    public var isActive: Bool { state == .active }

    public mutating func handle(_ event: Event) -> Command {
        switch (state, event) {
        case (.idle, .bindingPressed):
            state = .active
            return .start

        case (.active, .bindingPressed), (.active, .enterPressed):
            state = .finishing
            return .finish

        case (.active, .escapePressed):
            state = .idle
            return .cancel

        case (_, .sessionEnded):
            state = .idle
            return .ignore

        default:
            return .ignore
        }
    }

    public mutating func reset() {
        state = .idle
    }
}
