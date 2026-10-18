import SwiftUI

struct CompactTaskView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        CompactBody(model: model, monitor: model.monitor)
    }
}

private struct CompactBody: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: TerminalTaskMonitor
    @ObservedObject private var nowPlaying: NowPlayingMonitor

    init(model: AppModel, monitor: TerminalTaskMonitor) {
        self.model = model
        self.monitor = monitor
        _nowPlaying = ObservedObject(wrappedValue: model.nowPlaying)
    }

    /// Prefer the newest running task in the compact strip.
    private var displayTask: TerminalTask? {
        monitor.tasks.last(where: { $0.state == .running }) ?? model.selectedTask
    }

    private var overflowTasks: [TerminalTask] {
        guard let display = displayTask else { return monitor.tasks }
        return monitor.tasks.filter { $0.id != display.id }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let completion = monitor.lastCompletion {
                Button {
                    model.focusCompletionInITerm(completion)
                } label: {
                    HStack(spacing: 6) {
                        titleChip(title: completion.title, dot: .green)
                        Spacer(minLength: 4)
                        Text("DONE")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.green.opacity(0.9))
                        CompletionBadge()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jump to iTerm")
            } else if let task = displayTask {
                titleChip(title: task.title, dot: dotColor(for: task.state))

                if overflowTasks.count > 0 {
                    Menu {
                        ForEach(overflowTasks) { other in
                            Button {
                                model.selectTask(other.id)
                            } label: {
                                Text("\(other.title) · \(other.state.label)")
                            }
                        }
                    } label: {
                        Text("+\(overflowTasks.count)")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .menuStyle(.borderlessButton)
                }

                Spacer(minLength: 4)

                if task.state == .running {
                    TaskGlyph(kind: task.kind, spinning: true)
                } else {
                    StateChip(state: task.state, compact: true)
                }
            } else if nowPlaying.showsInNotch {
                HStack(spacing: 6) {
                    Circle()
                        .fill(SoundWaveView.color)
                        .frame(width: 5, height: 5)
                    Text(nowPlaying.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                SoundWaveView()
            } else {
                Color.clear
            }
        }
        .padding(.horizontal, NotchChrome.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func titleChip(title: String, dot: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: 4, height: 4)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    private func dotColor(for state: TerminalTaskState) -> Color {
        switch state {
        case .running: return Color(red: 0.55, green: 0.72, blue: 1.0)
        case .idle: return .orange
        case .completed: return .green
        }
    }
}

struct TaskGlyph: View {
    let kind: TerminalTaskKind
    var spinning = false

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.22), lineWidth: 1.5)
                .frame(width: 12, height: 12)
            Circle()
                .trim(from: 0.1, to: 0.7)
                .stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: 14, height: 14)
        .onAppear { syncSpin() }
        .onChange(of: spinning) { _ in syncSpin() }
    }

    private func syncSpin() {
        if spinning {
            rotation = 0
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            rotation = 0
        }
    }

    private var accent: Color {
        switch kind {
        case .git: return Color(red: 0.95, green: 0.45, blue: 0.35)
        case .npm: return Color(red: 0.35, green: 0.75, blue: 0.55)
        case .agent: return Color(red: 0.55, green: 0.72, blue: 1.0)
        }
    }
}

struct SoundWaveView: View {
    static let color = Color(red: 0.45, green: 0.85, blue: 0.62)
    private let barCount = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Self.color)
                        .frame(width: 2.5, height: height(index: index, time: time))
                }
            }
            .frame(width: 16, height: 14, alignment: .center)
        }
    }

    /// Irregular equalizer: each bar eases between fresh heights instead of looping two sizes.
    private func height(index: Int, time: Double) -> CGFloat {
        let slot = time / 0.28
        let step = floor(slot)
        let fraction = slot - step
        let eased = fraction * fraction * (3 - 2 * fraction)
        let from = level(index: index, step: step)
        let to = level(index: index, step: step + 1)
        return from + (to - from) * eased
    }

    private func level(index: Int, step: Double) -> CGFloat {
        var mix = UInt64(index &* 97) &+ UInt64(step) &* 0x9E37_79B9_7F4A_7C15
        mix ^= mix >> 30
        mix &*= 0xBF58_476D_1CE4_E5B9
        mix ^= mix >> 27
        let unit = CGFloat(mix % 10_000) / 10_000
        return 3.5 + unit * 10.5
    }
}

struct CompletionBadge: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(pulse ? 0.35 : 0.15))
                .frame(width: 12, height: 12)
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.green)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct StateChip: View {
    let state: TerminalTaskState
    var compact = false

    var body: some View {
        Text(compact ? shortLabel : state.label.uppercased())
            .font(.system(size: compact ? 7.5 : 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var shortLabel: String {
        switch state {
        case .running: return "RUN"
        case .idle: return "IDLE"
        case .completed: return "DONE"
        }
    }

    private var color: Color {
        switch state {
        case .running: return Color(red: 0.55, green: 0.72, blue: 1.0)
        case .idle: return Color.orange.opacity(0.95)
        case .completed: return .green
        }
    }
}

struct TabCapsule: View {
    let task: TerminalTask
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                Text(task.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.white.opacity(selected ? 0.16 : 0.07))
            )
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        switch task.state {
        case .running: return Color(red: 0.55, green: 0.72, blue: 1.0)
        case .idle: return .orange
        case .completed: return .green
        }
    }
}
