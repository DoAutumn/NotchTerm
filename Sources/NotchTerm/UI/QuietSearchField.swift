import AppKit
import SwiftUI

/// AppKit 单行搜索：图标与文字垂直居中对齐；不自带底色（避免和 Form 叠两层）。
struct QuietSearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
            PlainSearchTextField(text: $text, placeholder: placeholder)
                .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
        }
        .frame(height: 22)
    }
}

private struct PlainSearchTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        // 垂直居中：去掉多余 inset，由固定高度 frame 保证与放大镜对齐。
        if let cell = field.cell as? NSTextFieldCell {
            cell.isScrollable = true
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        let editing = field.currentEditor() != nil
        guard !editing, field.stringValue != text else { return }
        field.stringValue = text
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}
