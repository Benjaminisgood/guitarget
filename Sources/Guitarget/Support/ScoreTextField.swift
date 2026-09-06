import SwiftUI
import AppKit

/// Score fields use the editor's history while retaining native text input.
/// The window's FileDocument manager remains responsible for document bookkeeping.
struct ScoreTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let editor: ScoreEditorState
    var maximumLines = 1
    var acceptsText: (String) -> Bool = { _ in true }
    var validationMessage: String? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScoreTextControl {
        let control = ScoreTextControl(frame: .zero)
        control.cell = ScoreTextCell(textCell: "")
        control.isEditable = true
        control.isSelectable = true
        control.isBezeled = true
        control.bezelStyle = .roundedBezel
        control.font = .systemFont(ofSize: NSFont.systemFontSize)
        control.focusRingType = .default
        control.delegate = context.coordinator
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(control)
        return control
    }

    func updateNSView(_ control: ScoreTextControl, context: Context) { configure(control) }

    private func configure(_ control: ScoreTextControl) {
        control.scoreEditor = editor
        control.modelText = { text }
        control.acceptText = { value in
            guard acceptsText(value) else { return false }
            text = value
            return true
        }
        control.validationMessage = validationMessage
        control.placeholderString = placeholder
        control.isEnabled = isEnabled
        control.maximumNumberOfLines = maximumLines
        control.cell?.allowsUndo = false
        control.cell?.usesSingleLineMode = maximumLines == 1
        control.cell?.wraps = maximumLines > 1
        control.cell?.lineBreakMode = maximumLines > 1 ? .byWordWrapping : .byClipping
        control.setAccessibilityLabel(placeholder)
        control.synchronizeText()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScoreTextControl, context: Context) -> CGSize? {
        let width = proposal.width ?? 230
        guard maximumLines > 1 else { return CGSize(width: width, height: 24) }
        let font = nsView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let bounds = (nsView.stringValue.isEmpty ? " " : nsView.stringValue) as NSString
        let height = bounds.boundingRect(with: CGSize(width: max(40, width - 12), height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        return CGSize(width: width, height: min(CGFloat(maximumLines) * 18 + 10, max(28, ceil(height) + 10)))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        func controlTextDidChange(_ notification: Notification) {
            guard let control = notification.object as? ScoreTextControl else { return }
            control.commitText(control.stringValue, hasMarkedText: (control.currentEditor() as? NSTextView)?.hasMarkedText() == true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let control = notification.object as? ScoreTextControl else { return }
            if !control.commitText(control.stringValue, hasMarkedText: false), let message = control.validationMessage {
                control.scoreEditor?.error = message
            }
            control.synchronizeText(force: true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)),
               let field = control as? ScoreTextControl, field.maximumNumberOfLines > 1 {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            return false
        }
    }
}

final class ScoreTextControl: NSTextField {
    weak var scoreEditor: ScoreEditorState?
    var modelText: () -> String = { "" }
    var acceptText: (String) -> Bool = { _ in false }
    var validationMessage: String?
    private var lastModelText: String?
    private var unacceptedDraft: String?
    var hasUnacceptedDraft: Bool {
        guard unacceptedDraft != nil else { return false }
        let visibleText = (currentEditor() as? NSTextView)?.string ?? stringValue
        return visibleText != modelText()
    }

    @discardableResult
    func commitText(_ text: String, hasMarkedText: Bool) -> Bool {
        // Marked text belongs to the input method until composition commits.
        guard !hasMarkedText, acceptText(text) else {
            unacceptedDraft = text
            return false
        }
        unacceptedDraft = nil
        lastModelText = modelText()
        return true
    }

    func synchronizeText(force: Bool = false) {
        let value = modelText()
        let modelChanged = lastModelText != value
        lastModelText = value
        let fieldEditor = currentEditor() as? NSTextView
        guard fieldEditor?.hasMarkedText() != true else { return }
        // A partial BPM entry stays in the field while editing; only a valid
        // number reaches the score. External edits/undo still update immediately.
        guard force || modelChanged || fieldEditor == nil else { return }
        unacceptedDraft = nil
        if stringValue != value { stringValue = value }
        if let fieldEditor, fieldEditor.string != value {
            let caret = min(fieldEditor.selectedRange().location, (value as NSString).length)
            fieldEditor.string = value
            fieldEditor.setSelectedRange(NSRange(location: caret, length: 0))
        }
    }
}

final class ScoreTextCell: NSTextFieldCell {
    private let scoreFieldEditor = ScoreTextUndoView(frame: .zero)

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard let control = controlView as? ScoreTextControl else { return nil }
        scoreFieldEditor.control = control
        scoreFieldEditor.isFieldEditor = true
        scoreFieldEditor.isRichText = false
        scoreFieldEditor.allowsUndo = false
        return scoreFieldEditor
    }
}

final class ScoreTextUndoView: NSTextView {
    weak var control: ScoreTextControl?
    // AppKit can still register NSTextStorage character inverses despite the
    // field's allowsUndo setting. Never expose score snapshots to that storage:
    // a later field replacement would leave its character ranges invalid.
    override var undoManager: UndoManager? { nil }
    private var scoreUndoManager: UndoManager? { control?.scoreEditor?.undoManager }

    @objc func undo(_ sender: Any?) { routeUndo(redo: false) }
    @objc func redo(_ sender: Any?) { routeUndo(redo: true) }

    private func routeUndo(redo: Bool) {
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        } else if control?.hasUnacceptedDraft == true {
            // This visible input has no score inverse. Both Undo and Redo first
            // discard it, leaving the prior score history and redo stack intact.
            control?.synchronizeText(force: true)
            return
        } else if redo {
            control?.scoreEditor?.performRedo()
        } else {
            control?.scoreEditor?.performUndo()
        }
        control?.synchronizeText(force: true)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "z" else { return super.performKeyEquivalent(with: event) }
        routeUndo(redo: event.modifierFlags.contains(.shift))
        return true
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            if control?.hasUnacceptedDraft == true { menuItem.title = "撤销未提交输入"; return true }
            let name = scoreUndoManager?.undoActionName ?? ""
            menuItem.title = name.isEmpty ? "撤销" : "撤销" + name
            return hasMarkedText() || scoreUndoManager?.canUndo == true
        case #selector(redo(_:)):
            if control?.hasUnacceptedDraft == true { menuItem.title = "清除未提交输入"; return true }
            let name = scoreUndoManager?.redoActionName ?? ""
            menuItem.title = name.isEmpty ? "重做" : "重做" + name
            return hasMarkedText() || scoreUndoManager?.canRedo == true
        default: return super.validateMenuItem(menuItem)
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return hasMarkedText() || control?.hasUnacceptedDraft == true || scoreUndoManager?.canUndo == true
        case #selector(redo(_:)): return hasMarkedText() || control?.hasUnacceptedDraft == true || scoreUndoManager?.canRedo == true
        default: return super.validateUserInterfaceItem(item)
        }
    }
}
