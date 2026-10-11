import SwiftUI

struct ExpandedTaskView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.monitor.tasks.isEmpty {
                emptyState
            } else {
                tabRow
                detail
            }
            if let status = model.statusMessage {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            Text("Terminal Tasks")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Text("\(model.monitor.tasks.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }

    private var tabRow: some View {
        HStack(spacing: 8) {
            if let selected = model.selectedTask {
                TabCapsule(task: selected, selected: true) {
                    model.selectTask(selected.id)
                }
            }

            if !model.overflowTasks.isEmpty {
                Menu {
                    ForEach(model.overflowTasks) { task in
                        Button {
                            model.selectTask(task.id)
                        } label: {
                            Label {
                                Text("\(task.title) · \(task.state.label)")
                            } icon: {
                                Image(systemName: task.kind.symbol)
                            }
                        }
                    }
                } label: {
                    Text("+\(model.overflowTasks.count) more")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.white.opacity(0.08))
                        )
                }
                .menuStyle(.borderlessButton)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let task = model.selectedTask {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TaskGlyph(kind: task.kind, spinning: task.state == .running)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(task.subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    Spacer()
                    StateChip(state: task.state)
                }

                labeledRow("Command", value: shortCommand(task.command))
                if let dir = task.workingDirectory?.path {
                    labeledRow("Directory", value: dir)
                }
                if let tty = task.tty {
                    labeledRow("TTY", value: tty)
                }

                Button {
                    model.focusTaskInITerm(task)
                } label: {
                    Label("Jump to iTerm", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Watching iTerm")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text("Long tasks like git clone, npm run build, and Cursor Agent appear here.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func labeledRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.4))
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func shortCommand(_ command: String) -> String {
        if command.count <= 96 { return command }
        return String(command.prefix(96)) + "…"
    }
}

private struct TabCapsule: View {
    let task: TerminalTask
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(task.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.white.opacity(selected ? 0.14 : 0.06))
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
