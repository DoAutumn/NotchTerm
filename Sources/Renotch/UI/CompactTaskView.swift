import SwiftUI

struct CompactTaskView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let completion = model.monitor.lastCompletion {
                CompletionBadge(kind: completion.kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(completion.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(completion.subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("DONE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.green.opacity(0.9))
            } else if let task = model.selectedTask {
                TaskGlyph(kind: task.kind, spinning: task.state == .running)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(task.subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                OverflowChip(count: model.overflowTasks.count)
                StateChip(state: task.state)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                Text("No terminal tasks")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TaskGlyph: View {
    let kind: TerminalTaskKind
    var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.18))
                .frame(width: 22, height: 22)
            Group {
                if spinning {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                        Image(systemName: kind.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                            .rotationEffect(
                                .degrees(context.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: 1.2) / 1.2 * 360)
                            )
                    }
                } else {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
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

struct CompletionBadge: View {
    let kind: TerminalTaskKind
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(pulse ? 0.35 : 0.15))
                .frame(width: 22, height: 22)
                .scaleEffect(pulse ? 1.15 : 1)
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.green)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct StateChip: View {
    let state: TerminalTaskState

    var body: some View {
        Text(state.label.uppercased())
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var color: Color {
        switch state {
        case .running: return Color(red: 0.55, green: 0.72, blue: 1.0)
        case .idle: return Color.orange.opacity(0.95)
        case .completed: return .green
        }
    }
}

struct OverflowChip: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("+\(count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
    }
}
