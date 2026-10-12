import Darwin
import Foundation

@MainActor
final class TerminalTaskMonitor: ObservableObject {
    @Published private(set) var tasks: [TerminalTask] = []
    @Published private(set) var lastCompletion: TaskCompletionEvent?

    /// Process / hook scan interval (honors settings.pollIntervalSeconds).
    private var processInterval: TimeInterval = 1.2
    private var timer: Timer?
    private var known: [String: TrackedTask] = [:]
    private var completionClearWork: DispatchWorkItem?
    private var refreshTask: Task<Void, Never>?
    /// Bumped on start/pause so a cancelled scan cannot clear a newer refreshTask.
    private var refreshGeneration: UInt64 = 0
    private var refreshPending = false
    private var pendingRefreshWork: DispatchWorkItem?
    private var sessionNameCache: [String: String] = [:]
    private var lastSummaryRefresh = Date.distantPast
    private var lastRefreshStarted = Date.distantPast
    private var forceNextRefresh = false
    private var hookDirWatcher: DispatchSourceFileSystemObject?
    private var hookDirFD: CInt = -1
    private var titleRefreshTask: Task<Void, Never>?

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
        var idleStreak: Int
        var busyStreak: Int
        var lastCLIAt: Date?
        var lastCPU: Double
        var lastChildCount: Int
    }

    func start(interval: TimeInterval = 1.2) {
        processInterval = max(0.35, interval)
        timer?.invalidate()
        pendingRefreshWork?.cancel()
        // Invalidate in-flight scans; generation stops a late finishRefresh from
        // nil-ing a newer refreshTask (cancel alone does not stop Task.detached).
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration &+= 1
        refreshPending = false
        startHookDirectoryWatcher()
        refresh(force: true)
        let timer = Timer.scheduledTimer(withTimeInterval: processInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = min(0.2, processInterval * 0.2)
        self.timer = timer
    }

    func setInterval(_ interval: TimeInterval) {
        let next = max(0.35, interval)
        guard abs(next - processInterval) > 0.01 else { return }
        processInterval = next
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: processInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = min(0.2, processInterval * 0.2)
        self.timer = timer
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        pendingRefreshWork?.cancel()
        pendingRefreshWork = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration &+= 1
        refreshPending = false
        stopHookDirectoryWatcher()
        titleRefreshTask?.cancel()
        titleRefreshTask = nil
    }

    func resume() {
        start(interval: processInterval)
    }

    func clearCompletionBanner() {
        lastCompletion = nil
        completionClearWork?.cancel()
    }

    /// - Parameter force: bypass the min-interval floor (hook file writes).
    func refresh(force: Bool = false) {
        if force { forceNextRefresh = true }

        if refreshTask != nil {
            refreshPending = true
            return
        }

        // Floor interval so a slow collect cannot chain into a busy-loop.
        // Hook-directory events set `force` so RUNNING appears immediately.
        let sinceLast = Date().timeIntervalSince(lastRefreshStarted)
        if !forceNextRefresh, sinceLast < processInterval * 0.5 {
            refreshPending = true
            schedulePendingRefresh(after: processInterval * 0.5 - sinceLast)
            return
        }
        forceNextRefresh = false

        lastRefreshStarted = Date()
        let namesForCollect = sessionNameCache
        let generation = refreshGeneration

        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                AgentHookService.pruneStaleStateFiles()
                let hookStates = AgentHookService.loadStatesByPID()
                return Self.collect(
                    sessionNameCache: namesForCollect,
                    hookStates: hookStates
                )
            }.value

            guard let self else { return }
            // Stale generation: a newer start/pause/refresh owns the slot.
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

    /// Titles via timed `osascript` off the main actor — never blocks busy/idle.
    private func scheduleTitleRefreshIfNeeded() {
        let stale = Date().timeIntervalSince(lastSummaryRefresh) > 3.0 || sessionNameCache.isEmpty
        guard stale, titleRefreshTask == nil else { return }
        titleRefreshTask = Task { [weak self] in
            let names = await Task.detached(priority: .utility) {
                Self.uniqueTTYNames(ITermController.listSessionSummaries())
            }.value
            guard let self else { return }
            defer { self.titleRefreshTask = nil }
            guard !Task.isCancelled else { return }
            self.lastSummaryRefresh = Date()
            if !names.isEmpty, names != self.sessionNameCache {
                self.sessionNameCache = names
                self.refresh(force: true)
            }
        }
    }

    private func startHookDirectoryWatcher() {
        stopHookDirectoryWatcher()
        let dir = AgentHookService.stateDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        hookDirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Hook script just wrote running/idle — scan immediately.
            self?.refresh(force: true)
        }
        source.setCancelHandler {
            close(fd)
        }
        hookDirWatcher = source
        source.resume()
    }

    private func stopHookDirectoryWatcher() {
        hookDirWatcher?.cancel()
        hookDirWatcher = nil
        hookDirFD = -1
    }

    private func schedulePendingRefresh(after delay: TimeInterval) {
        pendingRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefreshWork = nil
            if self.refreshPending, self.refreshTask == nil {
                self.refreshPending = false
                // Preserve hook-driven force so a coalesced wake still bypasses the floor.
                self.refresh(force: self.forceNextRefresh)
            }
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
        let wait = max(0, processInterval * 0.5 - Date().timeIntervalSince(lastRefreshStarted))
        if wait > 0.02 {
            schedulePendingRefresh(after: wait)
            refreshPending = true
        } else {
            refresh(force: true)
        }
    }

    nonisolated private static func uniqueTTYNames(_ sessions: [ITermSession]) -> [String: String] {
        var names: [String: String] = [:]
        for session in sessions where !session.tty.isEmpty {
            names[session.tty] = session.name
        }
        return names
    }

    // MARK: - Apply

    private func apply(_ snapshot: CollectionResult) {
        if let names = snapshot.sessionNames {
            sessionNameCache = names
            lastSummaryRefresh = Date()
        }

        var nextKnown: [String: TrackedTask] = [:]
        var completions: [TaskCompletionEvent] = []
        let now = Date()

        for process in snapshot.processes {
            let id = "pid-\(process.pid)"
            var tracked = known[id] ?? TrackedTask(
                pid: process.pid,
                kind: process.kind,
                command: process.command,
                title: process.title,
                tty: process.tty,
                workingDirectory: process.workingDirectory,
                startedAt: now,
                wasBusy: false,
                // Agents start idle until a hook says otherwise.
                state: process.kind == .agent ? .idle : .running,
                elapsed: process.elapsed,
                completionEmitted: false,
                idleStreak: 0,
                busyStreak: 0,
                lastCLIAt: nil,
                lastCPU: 0,
                lastChildCount: 0
            )

            tracked.command = process.command
            // Prefer a real iTerm session title over kind fallbacks like "Cursor Agent".
            if process.title != kindFallbackTitle(process.kind, command: process.command)
                || tracked.title.isEmpty
                || tracked.title == kindFallbackTitle(tracked.kind, command: tracked.command)
            {
                tracked.title = process.title
            }
            tracked.tty = process.tty ?? tracked.tty
            tracked.workingDirectory = process.workingDirectory ?? tracked.workingDirectory
            tracked.elapsed = process.elapsed
            tracked.kind = process.kind
            tracked.lastCPU = process.cpu
            tracked.lastChildCount = process.childCount
            if process.fromHook {
                tracked.lastCLIAt = now
            }

            if process.kind == .agent {
                if process.isBusy {
                    tracked.busyStreak += 1
                    tracked.idleStreak = 0
                    tracked.wasBusy = true
                    tracked.state = .running
                    // Next turn can emit DONE again after this one goes idle.
                    tracked.completionEmitted = false
                } else {
                    // Hooks (or absence of hooks) → idle. No scrollback/transcript guessing.
                    tracked.busyStreak = 0
                    tracked.idleStreak += 1
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
                }
            } else {
                tracked.state = .running
                tracked.wasBusy = true
                tracked.busyStreak += 1
                tracked.idleStreak = 0
            }

            nextKnown[id] = tracked
        }

        for (id, previous) in known where nextKnown[id] == nil {
            if previous.kind != .agent || previous.wasBusy {
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

        known = nextKnown
        // Publish only active work. Idle agents stay tracked internally (hooks still
        // update them) but drop out of tabs — same mental model as finished git/npm.
        tasks = nextKnown.values
            .filter { tracked in
                tracked.kind != .agent || tracked.state == .running
            }
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
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                return lhs.pid < rhs.pid
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

    private struct CollectionResult: Sendable {
        let processes: [RawProcess]
        let sessionNames: [String: String]?
    }

    private struct RawProcess: Sendable {
        let pid: Int32
        let kind: TerminalTaskKind
        let command: String
        let title: String
        let tty: String?
        let workingDirectory: URL?
        let elapsed: String
        let cpu: Double
        let childCount: Int
        let isBusy: Bool
        let fromHook: Bool
    }

    /// Process scan only — session titles come from a separate AppleScript path.
    nonisolated private static func collect(
        sessionNameCache: [String: String],
        hookStates: [Int32: AgentHookService.HookState]
    ) -> CollectionResult {
        let iTermPIDs = iTermProcessIDs()
        let processes = runningProcesses()
        let parents = parentMap()
        let sessionNames = sessionNameCache

        var results: [RawProcess] = []
        for process in processes {
            guard let kind = classify(process.command) else { continue }

            let tty = process.tty.map(ITermController.normalizedTTY)
            let sessionName = tty.flatMap { sessionNames[$0] }
            let underITerm = isUnderITerm(pid: process.pid, iTermRoots: iTermPIDs, parents: parents)
            // Agents with a live hook match are tracked even if the iTerm parent
            // walk fails (renamed binaries / unusual process trees).
            let hookMatch = kind == .agent && AgentHookService.resolve(
                pid: process.pid,
                resumeID: resumeID(from: process.command),
                tty: tty,
                cwd: nil,
                states: hookStates
            ) != nil
            guard underITerm || sessionName != nil || hookMatch else { continue }

            let childCount = childProcessCount(pid: process.pid, parents: parents)

            var isBusy = true
            var fromHook = false
            var cwd: URL?

            if kind == .agent {
                cwd = workingDirectory(pid: process.pid)
                let resumeID = resumeID(from: process.command)

                // Agent busy/idle comes only from Cursor hooks.
                if let hook = AgentHookService.resolve(
                    pid: process.pid,
                    resumeID: resumeID,
                    tty: tty,
                    cwd: cwd?.path,
                    states: hookStates
                ) {
                    isBusy = hook.state == .running
                    fromHook = true
                } else {
                    // No hook file yet → idle (do not guess via transcript/scrollback).
                    isBusy = false
                    fromHook = false
                }
            }

            results.append(
                RawProcess(
                    pid: process.pid,
                    kind: kind,
                    command: process.command,
                    title: displayTitle(kind: kind, command: process.command, sessionName: sessionName),
                    tty: tty,
                    workingDirectory: cwd,
                    elapsed: process.elapsed,
                    cpu: process.cpu,
                    childCount: childCount,
                    isBusy: isBusy,
                    fromHook: fromHook
                )
            )
        }

        // Safety net: if a hook says RUNNING but the process scan missed the row
        // (truncated `ps`, unusual argv), still surface the agent from the hook file.
        let seen = Set(results.map(\.pid))
        for (pid, hook) in hookStates where hook.state == .running && !seen.contains(pid) {
            guard kill(pid, 0) == 0 else { continue }
            let tty = hook.tty.map(ITermController.normalizedTTY)
            let sessionName = tty.flatMap { sessionNames[$0] }
            let command = "agent --resume \(hook.conversationId ?? "")"
            results.append(
                RawProcess(
                    pid: pid,
                    kind: .agent,
                    command: command,
                    title: displayTitle(kind: .agent, command: command, sessionName: sessionName),
                    tty: tty,
                    workingDirectory: hook.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
                    elapsed: "—",
                    cpu: 0,
                    childCount: 0,
                    isBusy: true,
                    fromHook: true
                )
            )
        }

        return CollectionResult(
            processes: results,
            sessionNames: nil
        )
    }

    private func kindFallbackTitle(_ kind: TerminalTaskKind, command: String) -> String {
        Self.displayTitle(kind: kind, command: command, sessionName: nil)
    }

    nonisolated private static func resumeID(from command: String) -> String? {
        // Agent CLI uses both `--resume <uuid>` and `--resume=<uuid>`.
        guard let regex = try? NSRegularExpression(
            pattern: #"--resume(?:=|\s+)([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"#
        ) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              let idRange = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[idRange]).lowercased()
    }

    nonisolated private static func classify(_ command: String) -> TerminalTaskKind? {
        let value = command.lowercased()

        // Track the Cursor Agent CLI entrypoint only.
        // The child `node …/index.js worker-server` also lives under share/cursor-agent
        // and must not become a second tab with the same iTerm title.
        if value.contains("worker-server") {
            return nil
        }
        if value.contains("/.local/bin/agent")
            || value.contains("/bin/agent --")
            || value.contains("cursor-agent") && value.contains("index.js") && !value.contains("/node ")
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
        if let sessionName, !sessionName.isEmpty {
            let cleaned = sessionName
                .replacingOccurrences(
                    of: #"\s*\(agent\)\s*"#,
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
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

    private struct ProcRow: Sendable {
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
            // Prefer path/binary markers — avoid matching unrelated shell lines that
            // merely mention iTerm in their argv.
            let isITerm =
                command.contains("/Applications/iTerm.app/")
                || command.contains("/iTerm2/iTermServer")
                || command.hasSuffix("/MacOS/iTerm2")
                || command.contains("/MacOS/ShellLauncher")
            if isITerm {
                ids.insert(pid)
            }
        }
        return ids
    }

    nonisolated private static func isUnderITerm(
        pid: Int32,
        iTermRoots: Set<Int32>,
        parents: [Int32: Int32]
    ) -> Bool {
        // If iTerm isn't running, never treat arbitrary processes as supervised.
        guard !iTermRoots.isEmpty else { return false }
        var current = pid
        for _ in 0..<32 {
            if iTermRoots.contains(current) { return true }
            guard let parent = parents[current], parent > 0, parent != current else { return false }
            current = parent
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

    nonisolated private static func childProcessCount(pid: Int32, parents: [Int32: Int32]) -> Int {
        parents.values.filter { $0 == pid }.count
    }

    nonisolated private static func workingDirectory(pid: Int32) -> URL? {
        let output = ShellCommand.run(
            "/usr/sbin/lsof",
            ["-a", "-p", String(pid), "-d", "cwd", "-Fn"],
            timeout: 0.8
        )
        guard let pathLine = output.split(separator: "\n").first(where: { $0.first == "n" }) else {
            return nil
        }
        return URL(fileURLWithPath: String(pathLine.dropFirst()), isDirectory: true)
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

    /// Runs a process with a wall-clock timeout.
    /// Stdout is drained on a background thread *while* the child runs — waiting
    /// for exit before reading deadlocks once output exceeds the pipe buffer
    /// (~64KB). A full `ps -axo …,command=` listing is often larger than that.
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
            // Concurrent drain — returns on EOF when the child closes stdout
            // (or when we close the read end after a hard kill).
            box.append(stdout.readDataToEndOfFile())
            group.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdout.close()
            _ = group.wait(timeout: .now() + 0.2)
            return Data()
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
                // Hard-kill stuck children (e.g. osascript wedged in Apple Events).
                kill(process.processIdentifier, SIGKILL)
                let hard = Date().addingTimeInterval(0.2)
                while process.isRunning, Date() < hard {
                    Thread.sleep(forTimeInterval: 0.015)
                }
            }
        }

        // Unblock a drain that never saw EOF (zombie / stuck writer).
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
            storage.append(data)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
