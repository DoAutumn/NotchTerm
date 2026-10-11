import Foundation

@MainActor
final class TerminalTaskMonitor: ObservableObject {
    @Published private(set) var tasks: [TerminalTask] = []
    @Published private(set) var lastCompletion: TaskCompletionEvent?

    private var timer: Timer?
    private var pollInterval: TimeInterval = 1.2
    private var known: [String: TrackedTask] = [:]
    private var completionClearWork: DispatchWorkItem?

    private struct TrackedTask {
        var pid: Int32
        var kind: TerminalTaskKind
        var command: String
        var title: String
        var tty: String?
        var workingDirectory: URL?
        var startedAt: Date
        var wasBusy: Bool
        var state: TerminalTaskState
        var elapsed: String
        var completionEmitted: Bool
    }

    func start(interval: TimeInterval) {
        pollInterval = interval
        timer?.invalidate()
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.25
        self.timer = timer
    }

    func setInterval(_ interval: TimeInterval) {
        guard abs(pollInterval - interval) > 0.05 else { return }
        start(interval: interval)
    }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    func resume() {
        start(interval: pollInterval)
    }

    func clearCompletionBanner() {
        lastCompletion = nil
        completionClearWork?.cancel()
    }

    func refresh() {
        let snapshot = Self.collect()
        apply(snapshot)
    }

    // MARK: - Apply

    private func apply(_ snapshot: [RawProcess]) {
        var nextKnown: [String: TrackedTask] = [:]
        var completions: [TaskCompletionEvent] = []
        let now = Date()

        for process in snapshot {
            let id = "pid-\(process.pid)"
            var tracked = known[id] ?? TrackedTask(
                pid: process.pid,
                kind: process.kind,
                command: process.command,
                title: process.title,
                tty: process.tty,
                workingDirectory: process.workingDirectory,
                startedAt: now,
                wasBusy: process.isBusy,
                state: process.isBusy ? .running : (process.kind == .agent ? .idle : .running),
                elapsed: process.elapsed,
                completionEmitted: false
            )

            tracked.command = process.command
            tracked.title = process.title
            tracked.tty = process.tty ?? tracked.tty
            tracked.workingDirectory = process.workingDirectory ?? tracked.workingDirectory
            tracked.elapsed = process.elapsed
            tracked.kind = process.kind

            if process.kind == .agent {
                if process.isBusy {
                    tracked.wasBusy = true
                    tracked.state = .running
                } else if tracked.wasBusy && !tracked.completionEmitted {
                    tracked.state = .idle
                    tracked.completionEmitted = true
                    completions.append(
                        TaskCompletionEvent(
                            id: UUID(),
                            taskID: id,
                            title: tracked.title,
                            subtitle: "Agent finished output",
                            kind: .agent
                        )
                    )
                } else {
                    tracked.state = .idle
                }
            } else {
                tracked.state = .running
                tracked.wasBusy = true
            }

            nextKnown[id] = tracked
        }

        // Processes that disappeared → completed (non-agent always; agent session ended)
        for (id, previous) in known where nextKnown[id] == nil {
            if previous.kind != .agent || previous.wasBusy {
                completions.append(
                    TaskCompletionEvent(
                        id: UUID(),
                        taskID: id,
                        title: previous.title,
                        subtitle: previous.kind == .agent ? "Agent session ended" : "Finished",
                        kind: previous.kind
                    )
                )
            }
        }

        known = nextKnown
        tasks = nextKnown.values
            .map { tracked in
                TerminalTask(
                    id: "pid-\(tracked.pid)",
                    pid: tracked.pid,
                    kind: tracked.kind,
                    title: tracked.title,
                    subtitle: subtitle(for: tracked),
                    command: tracked.command,
                    tty: tracked.tty,
                    workingDirectory: tracked.workingDirectory,
                    state: tracked.state,
                    elapsed: tracked.elapsed,
                    startedAt: tracked.startedAt
                )
            }
            .sorted { lhs, rhs in
                let order: [TerminalTaskState: Int] = [.running: 0, .completed: 1, .idle: 2]
                let l = (order[lhs.state] ?? 9, lhs.startedAt)
                let r = (order[rhs.state] ?? 9, rhs.startedAt)
                return l < r
            }

        if let event = completions.first {
            present(event)
        }
    }

    private func subtitle(for tracked: TrackedTask) -> String {
        switch tracked.state {
        case .running:
            return "Running · \(tracked.elapsed)"
        case .idle:
            return "Waiting for input"
        case .completed:
            return "Done"
        }
    }

    private func present(_ event: TaskCompletionEvent) {
        completionClearWork?.cancel()
        lastCompletion = event
        let work = DispatchWorkItem { [weak self] in
            if self?.lastCompletion?.id == event.id {
                self?.lastCompletion = nil
            }
        }
        completionClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    // MARK: - Collection

    private struct RawProcess {
        let pid: Int32
        let kind: TerminalTaskKind
        let command: String
        let title: String
        let tty: String?
        let workingDirectory: URL?
        let elapsed: String
        let isBusy: Bool
    }

    nonisolated private static func collect() -> [RawProcess] {
        let sessions = ITermController.listSessions()
        let sessionByTTY = Dictionary(uniqueKeysWithValues: sessions.map { ($0.tty, $0) })
        let iTermPIDs = iTermProcessIDs()
        let processes = runningProcesses()

        var results: [RawProcess] = []
        for process in processes {
            guard let kind = classify(process.command) else { continue }

            let tty = process.tty.map(ITermController.normalizedTTY)
            let session = tty.flatMap { sessionByTTY[$0] }
            let underITerm = isUnderITerm(pid: process.pid, iTermRoots: iTermPIDs)
            guard underITerm || session != nil else { continue }
            let childCount = childProcessCount(pid: process.pid)
            let isBusy: Bool
            if kind == .agent {
                isBusy = ITermController.isAgentBusy(
                    tail: session?.tail ?? "",
                    cpu: process.cpu,
                    childCount: childCount
                )
            } else {
                isBusy = true
            }

            results.append(
                RawProcess(
                    pid: process.pid,
                    kind: kind,
                    command: process.command,
                    title: displayTitle(kind: kind, command: process.command, sessionName: session?.name),
                    tty: tty,
                    workingDirectory: workingDirectory(pid: process.pid),
                    elapsed: process.elapsed,
                    isBusy: isBusy
                )
            )
        }
        return results
    }

    nonisolated private static func classify(_ command: String) -> TerminalTaskKind? {
        let value = command.lowercased()

        if value.contains(".local/bin/agent")
            || value.contains("cursor-agent")
            || value.contains("share/cursor-agent/")
        {
            return .agent
        }

        if value.range(
            of: #"\bgit(\s+|-)(clone|fetch|pull)\b"#,
            options: .regularExpression
        ) != nil {
            return .git
        }

        let packageMarkers = [
            "npm run build", "npm run test", "npm install", "npm i ",
            "pnpm build", "pnpm test", "pnpm install", "pnpm i ",
            "yarn build", "yarn test", "yarn install",
            "bun run build", "bun run test", "bun install", "bun i "
        ]
        if packageMarkers.contains(where: { value.contains($0) }) {
            return .npm
        }
        if value.range(of: #"\bnpm\s+i\b"#, options: .regularExpression) != nil
            || value.range(of: #"\bpnpm\s+i\b"#, options: .regularExpression) != nil
            || value.range(of: #"\bbun\s+i\b"#, options: .regularExpression) != nil
        {
            return .npm
        }
        return nil
    }

    nonisolated private static func displayTitle(
        kind: TerminalTaskKind,
        command: String,
        sessionName: String?
    ) -> String {
        if let sessionName, !sessionName.isEmpty, kind == .agent {
            let cleaned = sessionName
                .replacingOccurrences(of: "(agent)", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        switch kind {
        case .agent:
            return "Cursor Agent"
        case .git:
            if command.lowercased().contains("clone") { return "git clone" }
            if command.lowercased().contains("fetch") { return "git fetch" }
            return "git pull"
        case .npm:
            let tokens = command.split(separator: " ").suffix(4).joined(separator: " ")
            return tokens.isEmpty ? "Package task" : tokens
        }
    }

    private struct ProcRow {
        let pid: Int32
        let ppid: Int32
        let tty: String?
        let cpu: Double
        let elapsed: String
        let command: String
    }

    nonisolated private static func runningProcesses() -> [ProcRow] {
        let output = ShellCommand.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,%cpu=,etime=,command="])
        return output.split(separator: "\n").compactMap { line -> ProcRow? in
            let parts = line.split(maxSplits: 5, whereSeparator: \Character.isWhitespace).map(String.init)
            guard parts.count == 6,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let cpu = Double(parts[3]) else { return nil }
            let ttyRaw = parts[2]
            let tty = (ttyRaw == "??" || ttyRaw.isEmpty) ? nil : ITermController.normalizedTTY(ttyRaw)
            return ProcRow(
                pid: pid,
                ppid: ppid,
                tty: tty,
                cpu: cpu,
                elapsed: parts[4],
                command: parts[5]
            )
        }
    }

    nonisolated private static func iTermProcessIDs() -> Set<Int32> {
        let output = ShellCommand.run("/bin/ps", ["-axo", "pid=,command="])
        var ids = Set<Int32>()
        for line in output.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(String.init)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let command = parts[1]
            if command.contains("iTerm2") || command.contains("iTerm.app") || command.contains("iTermServer") {
                ids.insert(pid)
            }
        }
        return ids
    }

    nonisolated private static func isUnderITerm(pid: Int32, iTermRoots: Set<Int32>) -> Bool {
        guard !iTermRoots.isEmpty else { return true }
        var current = pid
        var guardCount = 0
        let map = parentMap()
        while guardCount < 32 {
            if iTermRoots.contains(current) { return true }
            guard let parent = map[current], parent > 0, parent != current else { return false }
            current = parent
            guardCount += 1
        }
        return false
    }

    nonisolated private static func parentMap() -> [Int32: Int32] {
        let output = ShellCommand.run("/bin/ps", ["-axo", "pid=,ppid="])
        var map: [Int32: Int32] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard parts.count >= 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            map[pid] = ppid
        }
        return map
    }

    nonisolated private static func childProcessCount(pid: Int32) -> Int {
        let output = ShellCommand.run("/bin/ps", ["-axo", "ppid="])
        return output.split(whereSeparator: \Character.isWhitespace)
            .compactMap { Int32($0) }
            .filter { $0 == pid }
            .count
    }

    nonisolated private static func workingDirectory(pid: Int32) -> URL? {
        let output = ShellCommand.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        guard let pathLine = output.split(separator: "\n").first(where: { $0.first == "n" }) else {
            return nil
        }
        return URL(fileURLWithPath: String(pathLine.dropFirst()), isDirectory: true)
    }
}

enum ShellCommand {
    static func run(_ executable: String, _ arguments: [String]) -> String {
        String(data: runData(executable, arguments), encoding: .utf8) ?? ""
    }

    static func runData(_ executable: String, _ arguments: [String]) -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return Data() }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        } catch {
            return Data()
        }
    }
}
