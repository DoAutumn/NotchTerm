import Darwin
import Foundation

/// Hook-driven tasks only (Cursor agent-state + zsh task-state). No `ps` / `lsof` scans.
@MainActor
final class TerminalTaskMonitor: ObservableObject {
    @Published private(set) var tasks: [TerminalTask] = []
    @Published private(set) var lastCompletion: TaskCompletionEvent?

    private var known: [String: TrackedTask] = [:]
    private var completionClearWork: DispatchWorkItem?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var refreshPending = false
    private var pendingRefreshWork: DispatchWorkItem?
    private var sessionNameCache: [String: String] = [:]
    private var titleRefreshTask: Task<Void, Never>?
    /// After empty/useless osascript, wait before retrying the same candidates.
    private var titleRefreshCooldownUntil = Date.distantPast
    private var titleRefreshLastCandidateKeys: Set<String> = []
    private var watchers: [DirectoryWatcher] = []
    private var aliveCheckTimer: Timer?

    private let aliveCheckInterval: TimeInterval = 45
    /// Coalesce hook FS bursts (agent can write many times per turn).
    private let hookDebounceInterval: TimeInterval = 0.5
    private let hookFollowUpInterval: TimeInterval = 0.2
    private let titleRefreshFailureCooldown: TimeInterval = 60

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
        var completionEmitted: Bool
    }

    private final class DirectoryWatcher {
        let source: DispatchSourceFileSystemObject
        let fd: CInt
        init(source: DispatchSourceFileSystemObject, fd: CInt) {
            self.source = source
            self.fd = fd
        }
    }

    func start() {
        pause()
        startDirectoryWatchers()
        startAliveCheckTimer()
        refresh(force: true)
    }

    func pause() {
        aliveCheckTimer?.invalidate()
        aliveCheckTimer = nil
        pendingRefreshWork?.cancel()
        pendingRefreshWork = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration &+= 1
        refreshPending = false
        stopDirectoryWatchers()
        titleRefreshTask?.cancel()
        titleRefreshTask = nil
        titleRefreshCooldownUntil = Date.distantPast
        titleRefreshLastCandidateKeys = []
    }

    func resume() {
        start()
    }

    func clearCompletionBanner() {
        lastCompletion = nil
        completionClearWork?.cancel()
    }

    func refresh(force: Bool = false) {
        if refreshTask != nil {
            refreshPending = true
            return
        }

        if !force {
            refreshPending = true
            schedulePendingRefresh(after: hookDebounceInterval)
            return
        }

        let generation = refreshGeneration
        let namesForTitles = sessionNameCache

        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                AgentHookService.pruneStaleStateFiles()
                ShellHookService.pruneStaleStateFiles()
                return Self.collectFromHooks(sessionNameCache: namesForTitles)
            }.value

            guard let self else { return }
            guard generation == self.refreshGeneration else { return }
            if Task.isCancelled {
                self.finishRefresh(runAgain: false, generation: generation)
                return
            }
            self.apply(snapshot)
            self.finishRefresh(runAgain: true, generation: generation)
            self.scheduleTitleRefreshIfNeeded()
        }
    }

    // MARK: - Timers / watchers

    private func startAliveCheckTimer() {
        aliveCheckTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: aliveCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
        timer.tolerance = 5
        aliveCheckTimer = timer
    }

    private func startDirectoryWatchers() {
        stopDirectoryWatchers()
        for dir in [AgentHookService.stateDirectory, ShellHookService.stateDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.refresh(force: false)
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            watchers.append(DirectoryWatcher(source: source, fd: fd))
        }
    }

    private func stopDirectoryWatchers() {
        for watcher in watchers {
            watcher.source.cancel()
        }
        watchers = []
    }

    private func schedulePendingRefresh(after delay: TimeInterval) {
        pendingRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefreshWork = nil
            guard self.refreshPending, self.refreshTask == nil else { return }
            self.refreshPending = false
            self.refresh(force: true)
        }
        pendingRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, delay), execute: work)
    }

    private func finishRefresh(runAgain: Bool, generation: UInt64) {
        guard generation == refreshGeneration else { return }
        refreshTask = nil
        let again = runAgain && refreshPending
        refreshPending = false
        guard again else { return }
        schedulePendingRefresh(after: hookFollowUpInterval)
        refreshPending = true
    }

    /// iTerm titles only for *running* agents that have a tty and still need a name.
    private func scheduleTitleRefreshIfNeeded() {
        guard titleRefreshTask == nil else { return }

        let candidates = known.values.filter { tracked in
            guard tracked.kind == .agent, tracked.state == .running else { return false }
            guard let tty = tracked.tty, !tty.isEmpty else { return false }
            let needsFallbackTitle = tracked.title.isEmpty || tracked.title == "Cursor Agent"
            let missingCache = sessionNameCache[tty] == nil
            return needsFallbackTitle || missingCache
        }
        guard !candidates.isEmpty else { return }

        let keys = Set(candidates.map { "\($0.pid):\($0.tty ?? "")" })
        // Same set still unresolved → honor cooldown (empty Automation result, etc.).
        if Date() < titleRefreshCooldownUntil, keys.isSubset(of: titleRefreshLastCandidateKeys) {
            return
        }
        titleRefreshLastCandidateKeys = keys

        titleRefreshTask = Task { [weak self] in
            let names = await Task.detached(priority: .utility) {
                Self.uniqueTTYNames(ITermController.listSessionSummaries())
            }.value
            guard let self else { return }
            defer { self.titleRefreshTask = nil }
            guard !Task.isCancelled else { return }

            if names.isEmpty {
                // iTerm down / Automation denied — don't hammer osascript.
                self.titleRefreshCooldownUntil = Date().addingTimeInterval(self.titleRefreshFailureCooldown)
                return
            }

            if names != self.sessionNameCache {
                self.sessionNameCache = names
            }
            self.applyTitlesFromCache()

            let stillNeed = self.known.values.contains { tracked in
                guard tracked.kind == .agent, tracked.state == .running else { return false }
                guard let tty = tracked.tty, !tty.isEmpty else { return false }
                return tracked.title.isEmpty || tracked.title == "Cursor Agent"
            }
            if stillNeed {
                // Got a session list but these ttys still have no usable name.
                self.titleRefreshCooldownUntil = Date().addingTimeInterval(self.titleRefreshFailureCooldown)
            } else {
                self.titleRefreshCooldownUntil = Date.distantPast
            }
        }
    }

    private func applyTitlesFromCache() {
        var changed = false
        for id in known.keys {
            guard var tracked = known[id], tracked.kind == .agent,
                  let tty = tracked.tty,
                  let name = sessionNameCache[tty],
                  !name.isEmpty
            else { continue }
            let cleaned = Self.cleanedSessionTitle(name)
            if !cleaned.isEmpty, tracked.title != cleaned {
                tracked.title = cleaned
                known[id] = tracked
                changed = true
            }
        }
        if changed {
            publishTasks()
        }
    }

    nonisolated private static func uniqueTTYNames(_ sessions: [ITermSession]) -> [String: String] {
        var names: [String: String] = [:]
        for session in sessions where !session.tty.isEmpty {
            names[session.tty] = session.name
        }
        return names
    }

    nonisolated private static func cleanedSessionTitle(_ sessionName: String) -> String {
        sessionName
            .replacingOccurrences(
                of: #"\s*\(agent\)\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Collect

    private struct HookSnapshot: Sendable {
        let rows: [HookRow]
    }

    private struct HookRow: Sendable {
        let pid: Int32
        let kind: TerminalTaskKind
        let state: String
        let command: String
        let title: String
        let cwd: String?
        let tty: String?
        let conversationId: String?
        let alive: Bool
    }

    nonisolated private static func collectFromHooks(
        sessionNameCache: [String: String]
    ) -> HookSnapshot {
        var rows: [HookRow] = []

        for (pid, hook) in AgentHookService.loadStatesByPID() {
            let alive = kill(pid, 0) == 0
            let tty = hook.tty.map(ITermController.normalizedTTY)
            let sessionName = tty.flatMap { sessionNameCache[$0] }
            let title: String = {
                if let sessionName, !sessionName.isEmpty {
                    let cleaned = cleanedSessionTitle(sessionName)
                    if !cleaned.isEmpty { return cleaned }
                }
                return "Cursor Agent"
            }()
            rows.append(
                HookRow(
                    pid: pid,
                    kind: .agent,
                    state: hook.state.rawValue,
                    command: hook.conversationId.map { "agent --resume \($0)" } ?? "agent",
                    title: title,
                    cwd: hook.cwd,
                    tty: tty,
                    conversationId: hook.conversationId,
                    alive: alive
                )
            )
        }

        for (pid, task) in ShellHookService.loadStatesByPID() {
            let alive = kill(pid, 0) == 0
            let tty = task.tty.map(ITermController.normalizedTTY)
            rows.append(
                HookRow(
                    pid: pid,
                    kind: task.kind,
                    state: task.state.rawValue,
                    command: task.command,
                    title: task.title.isEmpty ? task.kind.title : task.title,
                    cwd: task.cwd,
                    tty: tty,
                    conversationId: nil,
                    alive: alive
                )
            )
        }

        return HookSnapshot(rows: rows)
    }

    // MARK: - Apply

    private func apply(_ snapshot: HookSnapshot) {
        var nextKnown: [String: TrackedTask] = [:]
        var completions: [TaskCompletionEvent] = []
        let now = Date()

        for row in snapshot.rows {
            let id = "\(row.kind.rawValue)-\(row.pid)"
            let isBusy = row.state == "running"

            if !row.alive {
                if let previous = known[id], previous.wasBusy {
                    completions.append(
                        TaskCompletionEvent(
                            id: UUID(),
                            taskID: id,
                            title: previous.title,
                            subtitle: previous.kind == .agent ? "Agent session ended" : "Finished",
                            kind: previous.kind,
                            tty: previous.tty
                        )
                    )
                }
                continue
            }

            // git/npm: idle means the command finished — emit DONE, don't keep tracking.
            if row.kind != .agent, !isBusy {
                if let previous = known[id], previous.wasBusy, !previous.completionEmitted {
                    completions.append(
                        TaskCompletionEvent(
                            id: UUID(),
                            taskID: id,
                            title: previous.title.isEmpty ? row.title : previous.title,
                            subtitle: "Finished",
                            kind: previous.kind,
                            tty: previous.tty ?? row.tty
                        )
                    )
                }
                continue
            }

            var tracked = known[id] ?? TrackedTask(
                pid: row.pid,
                kind: row.kind,
                command: row.command,
                title: row.title,
                tty: row.tty,
                workingDirectory: row.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
                startedAt: now,
                wasBusy: false,
                state: row.kind == .agent ? .idle : .running,
                completionEmitted: false
            )

            tracked.kind = row.kind
            tracked.command = row.command
            tracked.pid = row.pid
            if row.kind == .agent {
                if row.title != "Cursor Agent" || tracked.title.isEmpty || tracked.title == "Cursor Agent" {
                    tracked.title = row.title
                }
            } else {
                tracked.title = row.title
            }
            tracked.tty = row.tty ?? tracked.tty
            if let cwd = row.cwd {
                tracked.workingDirectory = URL(fileURLWithPath: cwd, isDirectory: true)
            }

            if isBusy {
                if tracked.state != .running {
                    tracked.startedAt = now
                }
                tracked.wasBusy = true
                tracked.state = .running
                tracked.completionEmitted = false
                nextKnown[id] = tracked
            } else {
                // Agent idle: keep internally for DONE, hide from tabs via publish filter.
                let becomingIdle = tracked.state != .idle
                tracked.state = .idle
                if tracked.wasBusy, becomingIdle, !tracked.completionEmitted {
                    tracked.completionEmitted = true
                    completions.append(
                        TaskCompletionEvent(
                            id: UUID(),
                            taskID: id,
                            title: tracked.title,
                            subtitle: "Agent finished output",
                            kind: .agent,
                            tty: tracked.tty
                        )
                    )
                }
                nextKnown[id] = tracked
            }
        }

        for (id, previous) in known where nextKnown[id] == nil {
            // Still present as idle git/npm file handled above; true drop = process gone / pruned.
            if previous.wasBusy, previous.kind == .agent || previous.state == .running {
                let already = completions.contains { $0.taskID == id }
                if !already {
                    completions.append(
                        TaskCompletionEvent(
                            id: UUID(),
                            taskID: id,
                            title: previous.title,
                            subtitle: previous.kind == .agent ? "Agent session ended" : "Finished",
                            kind: previous.kind,
                            tty: previous.tty
                        )
                    )
                }
            }
        }

        known = nextKnown
        publishTasks()

        if let event = completions.first {
            present(event)
        }
    }

    private func publishTasks() {
        let next = known.values
            .filter { $0.state == .running }
            .map { tracked -> TerminalTask in
                TerminalTask(
                    id: "\(tracked.kind.rawValue)-\(tracked.pid)",
                    pid: tracked.pid,
                    kind: tracked.kind,
                    title: tracked.title,
                    subtitle: "Running · \(Self.formatElapsed(since: tracked.startedAt))",
                    command: tracked.command,
                    tty: tracked.tty,
                    workingDirectory: tracked.workingDirectory,
                    state: tracked.state,
                    elapsed: Self.formatElapsed(since: tracked.startedAt),
                    startedAt: tracked.startedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                return lhs.pid < rhs.pid
            }

        if next != tasks {
            tasks = next
        }
    }

    nonisolated private static func formatElapsed(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
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
}

enum ShellCommand {
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 2.0
    ) -> String {
        String(data: runData(executable, arguments, timeout: timeout), encoding: .utf8) ?? ""
    }

    static func runData(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 2.0
    ) -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return Data() }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let stdout = output.fileHandleForReading
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            var chunks = Data()
            do {
                while true {
                    guard let chunk = try stdout.read(upToCount: 64 * 1024) else { break }
                    if chunk.isEmpty { break }
                    chunks.append(chunk)
                }
            } catch {}
            box.append(chunks)
        }

        do {
            try process.run()
        } catch {
            try? stdout.close()
            _ = group.wait(timeout: .now() + 0.2)
            return box.data
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.015)
        }

        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.2)
            while process.isRunning, Date() < grace {
                Thread.sleep(forTimeInterval: 0.015)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let hard = Date().addingTimeInterval(0.2)
                while process.isRunning, Date() < hard {
                    Thread.sleep(forTimeInterval: 0.015)
                }
            }
        }

        if group.wait(timeout: .now() + 0.25) == .timedOut {
            try? stdout.close()
            _ = group.wait(timeout: .now() + 0.25)
        }
        return box.data
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(data)
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
