import AppKit
import SpinnetCore
import SwiftUI

/// A page's AppKit views that take the keyboard: its text fields, choice
/// fields and the collection's key view. The page model moves the focus
/// between them directly, and each tells the model when the user gave it
/// the keyboard.
protocol PluginPageFocusTarget: NSView {
    var component: String { get }
}

extension PluginPageModel {
    /// Gives `view` the keyboard if it is in a window.
    static func focus(_ view: NSView?) {
        guard let view, let window = view.window, window.firstResponder !== view,
              (window.firstResponder as? NSText)?.delegate as? NSView !== view else { return }
        window.makeFirstResponder(view)
    }
}

// MARK: - Text field

/// A one-line text field whose text, caret and input-method composition are
/// the Host's: the Plugin's answers never write into it, except to start it
/// again when it is new or reset. Up and Down, Return and Tab go to the
/// page's keyboard roles only when no composition is open, because the
/// input method sees every key first.
struct PageTextField: NSViewRepresentable {
    let model: PluginPageModel
    let field: PluginPageTextField
    /// Changes when the Host replaces the field's text.
    let revision: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model, id: field.id) }

    func makeNSView(context: Context) -> PageNSTextField {
        let view = PageNSTextField(string: model.text(of: field.id))
        view.component = field.id
        view.model = model
        view.isBordered = false
        view.drawsBackground = false
        view.focusRingType = .none
        view.usesSingleLineMode = true
        view.cell?.isScrollable = true
        view.cell?.wraps = false
        view.lineBreakMode = .byClipping
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.revision = revision
        model.register(view)
        let id = field.id
        model.registerCaret(of: id) { [weak view] in
            guard let editor = view?.currentEditor() else { return nil }
            let range = editor.selectedRange
            return PluginPageCaret(location: range.location, length: range.length)
        }
        return view
    }

    func updateNSView(_ view: PageNSTextField, context: Context) {
        view.placeholderString = field.placeholder
        view.setAccessibilityLabel(field.title)
        view.setAccessibilityHelp(field.status)
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        // A composition is never replaced; the memory already kept the text.
        if let editor = view.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        let text = model.text(of: field.id)
        guard view.stringValue != text else { return }
        view.stringValue = text
        if let editor = view.currentEditor() {
            let caret = model.caret(of: field.id) ?? .end(of: text)
            editor.selectedRange = NSRange(location: min(caret.location, text.utf16.count), length: 0)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: PluginPageModel
        let id: String
        var revision = 0

        init(model: PluginPageModel, id: String) {
            self.model = model
            self.id = id
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else { return }
            if let editor = view.currentEditor() as? NSTextView, editor.hasMarkedText() {
                model.compositionChanged(id, isComposing: true)
                return
            }
            let range = view.currentEditor()?.selectedRange
            model.textChanged(id, to: view.stringValue,
                              caret: range.map { PluginPageCaret(location: $0.location, length: $0.length) })
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // The input method has every key first; a command reaching here
            // with marked text left is the input method's business too.
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)) where model.searchesCollection(id):
                return model.moveSelection(.up)
            case #selector(NSResponder.moveDown(_:)) where model.searchesCollection(id):
                return model.moveSelection(.down)
            case #selector(NSResponder.insertNewline(_:)):
                model.returnPressed(in: id)
                return true
            case #selector(NSResponder.insertTab(_:)):
                model.moveFocus(from: id, forward: true)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                model.moveFocus(from: id, forward: false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                model.close()
                return true
            default:
                return false
            }
        }
    }
}

final class PageNSTextField: NSTextField, PluginPageFocusTarget {
    var component = ""
    weak var model: PluginPageModel?

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        model?.didFocus(component)
        // Coming back to the field keeps its caret instead of selecting all.
        if let editor = currentEditor(), let model {
            let caret = model.caret(of: component) ?? .end(of: stringValue)
            let length = stringValue.utf16.count
            let location = min(caret.location, length)
            editor.selectedRange = NSRange(location: location, length: min(caret.length, length - location))
        }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        model?.viewAppeared(self)
    }
}

// MARK: - Choice field

/// A pop-up of choices that is a Tab stop of the page.
struct PageChoiceField: NSViewRepresentable {
    let model: PluginPageModel
    let field: PluginPageChoiceField
    let value: String

    func makeNSView(context: Context) -> PagePopUpButton {
        let view = PagePopUpButton(frame: .zero, pullsDown: false)
        view.component = field.id
        view.model = model
        view.controlSize = .regular
        view.target = view
        view.action = #selector(PagePopUpButton.chose(_:))
        view.setContentHuggingPriority(.required, for: .horizontal)
        model.register(view)
        return view
    }

    func updateNSView(_ view: PagePopUpButton, context: Context) {
        let titles = field.choices.map(\.title)
        if view.itemTitles != titles {
            view.removeAllItems()
            view.addItems(withTitles: titles)
        }
        view.values = field.choices.map(\.value)
        if let index = field.choices.firstIndex(where: { $0.value == value }), view.indexOfSelectedItem != index {
            view.selectItem(at: index)
        }
        view.setAccessibilityLabel(field.title)
    }
}

final class PagePopUpButton: NSPopUpButton, PluginPageFocusTarget {
    var component = ""
    var values: [String] = []
    weak var model: PluginPageModel?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        model?.didFocus(component)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            model?.moveFocus(from: component, forward: !event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func chose(_ sender: Any?) {
        guard values.indices.contains(indexOfSelectedItem) else { return }
        model?.choose(values[indexOfSelectedItem], in: component)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        model?.viewAppeared(self)
    }
}

// MARK: - Collection keys

/// The collection's keyboard: an invisible view behind the items that takes
/// the keyboard when the collection is focused. Arrows, Page and Home/End
/// move the selection, Return performs the default item action, ⌘C the
/// Copy item action, Tab moves between the page's fields, Escape closes,
/// and a typed key goes to the search field when that is safe.
struct CollectionKeyView: NSViewRepresentable {
    let model: PluginPageModel
    let collection: String

    func makeNSView(context: Context) -> CollectionKeyNSView {
        let view = CollectionKeyNSView()
        view.component = collection
        view.model = model
        model.register(view)
        return view
    }

    func updateNSView(_ view: CollectionKeyNSView, context: Context) {
        view.component = collection
    }
}

final class CollectionKeyNSView: NSView, PluginPageFocusTarget, NSMenuItemValidation {
    var component = ""
    weak var model: PluginPageModel?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        model?.didFocus(component)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        model?.viewAppeared(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let move: PluginPageCollection.Move?
        switch event.keyCode {
        case 126: move = .up
        case 125: move = .down
        case 123: move = .left
        case 124: move = .right
        case 116: move = .pageUp
        case 121: move = .pageDown
        case 115: move = .home
        case 119: move = .end
        default: move = nil
        }
        if let move, flags.isDisjoint(with: [.command, .control, .option]) {
            model.moveSelection(move)
            return
        }
        switch event.keyCode {
        case 36, 76:
            model.returnPressedInCollection()
            return
        case 48:
            model.moveFocus(from: component, forward: !flags.contains(.shift))
            return
        case 53:
            model.close()
            return
        default:
            break
        }
        if flags.isDisjoint(with: [.command, .control]), let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            // A typed key goes to the search field, which takes it as if
            // typed there; with an input method selected it is ignored
            // (C3), and so is a dead key, which types no character yet.
            if let field = model.fieldForTypedKey().flatMap({ model.focusTarget($0) }), let window {
                PluginPageModel.focus(field)
                // The field's editor now has the keyboard and takes the key
                // through its own input handling.
                if window.firstResponder !== self { window.sendEvent(event) }
            }
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard model?.copySelection() == true else { return NSSound.beep() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return true }
        return model?.collection?.copyAction != nil
    }
}
