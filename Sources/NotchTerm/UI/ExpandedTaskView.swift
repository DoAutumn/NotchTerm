import SwiftUI

struct ExpandedTaskView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ExpandedBody(model: model, monitor: model.monitor)
    }
}

private struct ExpandedBody: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: TerminalTaskMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .frame(maxWidth: .infinity)

            if monitor.tasks.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                tabRow
                    .frame(maxWidth: .infinity, alignment: .leading)
                detail
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let status = model.statusMessage {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            // Fixed gap only — no Spacer (it expands and makes the bottom look huge).
            Color.clear.frame(height: NotchChrome.bottomInset)
        }
        .padding(.horizontal, NotchChrome.contentInset)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("终端任务")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Text("\(monitor.tasks.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }

    private var tabRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(monitor.tasks) { task in
                    TabCapsule(
                        task: task,
                        selected: model.selectedTask?.id == task.id
                    ) {
                        model.selectTask(task.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let task = model.selectedTask {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(task.subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    Spacer(minLength: 8)
                    StateChip(state: task.state)
                    if task.state == .running {
                        TaskGlyph(kind: task.kind, spinning: true)
                    }
                }

                if let dir = task.workingDirectory?.path {
                    labeledRow("目录", value: dir)
                }

                Button {
                    model.focusTaskInITerm(task)
                } label: {
                    Label("跳转到 iTerm", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        Color.clear.frame(height: 1)
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
}
