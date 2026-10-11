import SwiftUI

struct NotchView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            notchBody
                .frame(width: model.currentSize.width, height: model.currentSize.height)
                .background(notchBackground)
                .clipShape(NotchShape(cornerRadius: model.mode == .compact ? 14 : 18))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .contentShape(Rectangle())
                .onHover { model.hoverChanged($0) }
                .onTapGesture { model.notchClicked() }
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.mode)
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.currentSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, NotchLayout.shadowHorizontalPadding)
    }

    @ViewBuilder
    private var notchBody: some View {
        switch model.mode {
        case .compact:
            CompactTaskView()
        case .expanded:
            ExpandedTaskView()
        }
    }

    private var notchBackground: some View {
        RoundedRectangle(cornerRadius: model.mode == .compact ? 14 : 18, style: .continuous)
            .fill(Color.black.opacity(0.92))
            .overlay {
                RoundedRectangle(cornerRadius: model.mode == .compact ? 14 : 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct NotchShape: Shape {
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
    }
}
