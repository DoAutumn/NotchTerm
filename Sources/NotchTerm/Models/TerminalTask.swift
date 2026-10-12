import Foundation

enum TerminalTaskKind: String, Codable, Sendable, CaseIterable {
    case git
    case npm
    case agent

    var title: String {
        switch self {
        case .git: return "Git"
        case .npm: return "Package"
        case .agent: return "Agent"
        }
    }

    var symbol: String {
        switch self {
        case .git: return "arrow.triangle.branch"
        case .npm: return "shippingbox"
        case .agent: return "sparkles"
        }
    }
}

enum TerminalTaskState: String, Codable, Sendable {
    case running
    case idle
    case completed

    var label: String {
        switch self {
        case .running: return "Running"
        case .idle: return "Idle"
        case .completed: return "Done"
        }
    }
}

struct TerminalTask: Identifiable, Equatable, Sendable {
    let id: String
    let pid: Int32
    let kind: TerminalTaskKind
    let title: String
    let subtitle: String
    let command: String
    let tty: String?
    let workingDirectory: URL?
    let state: TerminalTaskState
    let elapsed: String
    let startedAt: Date
}

struct TaskCompletionEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let taskID: String
    let title: String
    let subtitle: String
    let kind: TerminalTaskKind
    /// iTerm tty at completion time (for Jump from the DONE strip).
    let tty: String?
}
