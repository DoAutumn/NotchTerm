import Foundation

enum TerminalTaskKind: String, Codable, Sendable, CaseIterable {
    case git
    case npm
    case agent

    var title: String {
        switch self {
        case .git: return "Git"
        case .npm: return "包管理"
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

/// Which agent CLI produced the busy/idle signal (agents only).
enum AgentProvider: String, Codable, Sendable {
    case cursor
    case claude

    var defaultTitle: String {
        switch self {
        case .cursor: return "Cursor Agent"
        case .claude: return "Claude"
        }
    }
}

enum TerminalTaskState: String, Codable, Sendable {
    case running
    case idle
    case completed
    case awaitingPermission = "awaiting_permission"
    case awaitingQuestion = "awaiting_question"

    var label: String {
        switch self {
        case .running: return "运行中"
        case .idle: return "空闲"
        case .completed: return "完成"
        case .awaitingPermission: return "等待确认"
        case .awaitingQuestion: return "有提问"
        }
    }

    /// Shown in the notch strip (not idle / DONE).
    var isActiveInNotch: Bool {
        switch self {
        case .running, .awaitingPermission, .awaitingQuestion: return true
        case .idle, .completed: return false
        }
    }

    /// Higher = more urgent for compact-strip / selection priority.
    var attentionRank: Int {
        switch self {
        case .awaitingQuestion: return 3
        case .awaitingPermission: return 2
        case .running: return 1
        case .idle, .completed: return 0
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
    let provider: AgentProvider?
}

struct TaskCompletionEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let taskID: String
    let title: String
    let subtitle: String
    let kind: TerminalTaskKind
    /// Terminal tty at completion time (for Jump from the DONE strip).
    let tty: String?
}

extension Array where Element == TerminalTask {
    /// Shared compact/selection pick: highest attention, then frontmost tty, then newest.
    func preferredForNotch(frontmostTTY: String?) -> TerminalTask? {
        let best = map(\.state.attentionRank).max() ?? 0
        let pool = best > 0 ? filter { $0.state.attentionRank == best } : self
        guard !pool.isEmpty else { return nil }
        if let front = frontmostTTY, !front.isEmpty {
            let normalized = TerminalController.normalizedTTY(front)
            if let match = pool.last(where: {
                $0.tty.map(TerminalController.normalizedTTY) == normalized
            }) {
                return match
            }
        }
        return pool.last ?? pool.first
    }
}
