// TerminationReplyGate.swift
// Pure single-resolution coordination for asynchronous app shutdown.

enum TerminationResolution: Equatable {
    case graceful
    case timedOut
}

struct TerminationReplyGate {
    private enum State {
        case idle
        case waiting
        case resolved(TerminationResolution)
    }

    private var state: State = .idle

    var resolution: TerminationResolution? {
        guard case let .resolved(resolution) = state else { return nil }
        return resolution
    }

    mutating func begin() -> Bool {
        guard case .idle = state else { return false }
        state = .waiting
        return true
    }

    /// Returns true only for the first terminal result after `begin()`.
    mutating func resolve(_ resolution: TerminationResolution) -> Bool {
        guard case .waiting = state else { return false }
        state = .resolved(resolution)
        return true
    }
}
