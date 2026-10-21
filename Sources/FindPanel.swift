import AppKit

/// Windows のメモ帳と同じ、浮いてる「検索」「置換」ダイアログ
final class FindPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = FindPanelController()

    enum Mode {
        case find
        case replace
    }

    private(set) var searchText = ""
    private var replaceText = ""
    private var searchUp = false
    private var activeMode: Mode = .find

    private var findPanel: NSPanel?
    private var replacePanel: NSPanel?

    // 検索ダイアログ
    private let findField = NSTextField(string: "")
    private let findMatchCase = NSButton(checkboxWithTitle: "大文字と小文字を区別する", target: nil, action: nil)
    private let findWrap = NSButton(checkboxWithTitle: "折り返しあり", target: nil, action: nil)
    private let upRadio = NSButton(radioButtonWithTitle: "上へ", target: nil, action: nil)
    private let downRadio = NSButton(radioButtonWithTitle: "下へ", target: nil, action: nil)
    private let findNextButton = NSButton(title: "次を検索", target: nil, action: nil)

    // 置換ダイアログ
    private let replaceFindField = NSTextField(string: "")
    private let replaceWithField = NSTextField(string: "")
    private let replaceMatchCase = NSButton(checkboxWithTitle: "大文字と小文字を区別する", target: nil, action: nil)
    private let replaceWrap = NSButton(checkboxWithTitle: "折り返しあり", target: nil, action: nil)
    private let replaceFindNextButton = NSButton(title: "次を検索", target: nil, action: nil)
    private let replaceButton = NSButton(title: "置換して次に", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "すべて置換", target: nil, action: nil)

    // MARK: - 表示

    func show(_ mode: Mode, for editor: EditorWindowController) {
        if let selection = editor.singleLineSelection() {
            searchText = selection
        } else if searchText.isEmpty, let stored = FindPanelController.readFindPasteboard() {
            searchText = stored
        }
        activeMode = mode

        let panel: NSPanel
        let field: NSTextField
        switch mode {
        case .find:
            replacePanel?.orderOut(nil)
            panel = findPanelInstance(near: editor.window)
            field = findField
            findField.stringValue = searchText
        case .replace:
            findPanel?.orderOut(nil)
            panel = replacePanelInstance(near: editor.window)
            field = replaceFindField
            replaceFindField.stringValue = searchText
            replaceWithField.stringValue = replaceText
        }
        syncOptionsToControls()
        updateButtons()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.selectText(nil)
    }

    func closePanels() {
        findPanel?.orderOut(nil)
        replacePanel?.orderOut(nil)
    }

    /// ⌘E「選択範囲を検索に使用」
    func useSelection(of editor: EditorWindowController) {
        guard let text = editor.selectedText(), !text.isEmpty else {
            NSSound.beep()
            return
        }
        searchText = text
        findField.stringValue = text
        replaceFindField.stringValue = text
        FindPanelController.writeFindPasteboard(text)
        updateButtons()
    }

    /// 次を検索 / 前を検索（⌘G・⇧⌘G・F3 からも来る）
    @discardableResult
    func findNext(in editor: EditorWindowController, backwards: Bool) -> Bool {
        if searchText.isEmpty {
            show(.find, for: editor)
            return false
        }
        FindPanelController.writeFindPasteboard(searchText)
        let settings = Settings.shared
        if let range = editor.find(searchText, backwards: backwards,
                                   matchCase: settings.matchCase, wrap: settings.wrapAround) {
            editor.select(range)
            return true
        }
        showNotFound()
        return false
    }

    // MARK: - ボタン

    @objc private func findNextClicked(_ sender: Any?) {
        syncTextFromFields()
        guard let editor = currentEditor() else {
            NSSound.beep()
            return
        }
        findNext(in: editor, backwards: activeMode == .find ? searchUp : false)
    }

    @objc private func replaceClicked(_ sender: Any?) {
        syncTextFromFields()
        guard let editor = currentEditor(), !searchText.isEmpty else {
            NSSound.beep()
            return
        }
        editor.replaceSelectionIfMatches(searchText, with: replaceText, matchCase: Settings.shared.matchCase)
        findNext(in: editor, backwards: false)
    }

    @objc private func replaceAllClicked(_ sender: Any?) {
        syncTextFromFields()
        guard let editor = currentEditor(), !searchText.isEmpty else {
            NSSound.beep()
            return
        }
        let count = editor.replaceAll(searchText, with: replaceText, matchCase: Settings.shared.matchCase)
        if count == 0 {
            showNotFound()
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        (sender as? NSView)?.window?.orderOut(nil)
    }

    @objc private func optionChanged(_ sender: NSButton) {
        let isOn = sender.state == .on
        if sender === findMatchCase || sender === replaceMatchCase {
            Settings.shared.matchCase = isOn
        } else {
            Settings.shared.wrapAround = isOn
        }
        syncOptionsToControls()
    }

    @objc private func directionChanged(_ sender: NSButton) {
        searchUp = (sender === upRadio)
        syncOptionsToControls()
    }

    func controlTextDidChange(_ obj: Notification) {
        syncTextFromFields()
        updateButtons()
    }

    // MARK: - 中身

    private func currentEditor() -> EditorWindowController? {
        return NSApp.mainWindow?.delegate as? EditorWindowController
    }

    private func syncTextFromFields() {
        switch activeMode {
        case .find:
            searchText = findField.stringValue
        case .replace:
            searchText = replaceFindField.stringValue
            replaceText = replaceWithField.stringValue
        }
    }

    private func syncOptionsToControls() {
        let settings = Settings.shared
        findMatchCase.state = settings.matchCase ? .on : .off
        replaceMatchCase.state = settings.matchCase ? .on : .off
        findWrap.state = settings.wrapAround ? .on : .off
        replaceWrap.state = settings.wrapAround ? .on : .off
        upRadio.state = searchUp ? .on : .off
        downRadio.state = searchUp ? .off : .on
    }

    private func updateButtons() {
        let enabled = !searchText.isEmpty
        findNextButton.isEnabled = enabled
        replaceFindNextButton.isEnabled = enabled
        replaceButton.isEnabled = enabled
        replaceAllButton.isEnabled = enabled
    }

    private func showNotFound() {
        var shown = searchText
        if shown.count > 40 { shown = String(shown.prefix(40)) + "…" }
        let alert = NSAlert()
        alert.messageText = "「\(shown)」が見つかりません。"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func readFindPasteboard() -> String? {
        guard let text = NSPasteboard(name: .find).string(forType: .string), !text.isEmpty else { return nil }
        return text.contains("\n") ? nil : text
    }

    private static func writeFindPasteboard(_ text: String) {
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - ダイアログを組む

    private func findPanelInstance(near window: NSWindow) -> NSPanel {
        if let panel = findPanel { return panel }
        let panel = makePanel(title: "検索", size: NSSize(width: 448, height: 136))
        guard let content = panel.contentView else { return panel }

        addLabel("検索する文字列:", to: content, frame: NSRect(x: 16, y: 18, width: 110, height: 17))
        configure(field: findField)
        findField.frame = NSRect(x: 130, y: 15, width: 182, height: 22)
        content.addSubview(findField)

        configure(button: findNextButton, action: #selector(findNextClicked(_:)))
        findNextButton.keyEquivalent = "\r"
        findNextButton.frame = NSRect(x: 326, y: 11, width: 108, height: 28)
        content.addSubview(findNextButton)

        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 326, y: 43, width: 108, height: 28)
        content.addSubview(cancel)

        addLabel("方向:", to: content, frame: NSRect(x: 16, y: 53, width: 44, height: 17))
        upRadio.target = self
        upRadio.action = #selector(directionChanged(_:))
        upRadio.frame = NSRect(x: 62, y: 52, width: 70, height: 18)
        content.addSubview(upRadio)
        downRadio.target = self
        downRadio.action = #selector(directionChanged(_:))
        downRadio.frame = NSRect(x: 134, y: 52, width: 70, height: 18)
        content.addSubview(downRadio)

        findMatchCase.target = self
        findMatchCase.action = #selector(optionChanged(_:))
        findMatchCase.frame = NSRect(x: 16, y: 82, width: 296, height: 18)
        content.addSubview(findMatchCase)
        findWrap.target = self
        findWrap.action = #selector(optionChanged(_:))
        findWrap.frame = NSRect(x: 16, y: 106, width: 296, height: 18)
        content.addSubview(findWrap)

        panel.initialFirstResponder = findField
        position(panel, near: window)
        findPanel = panel
        return panel
    }

    private func replacePanelInstance(near window: NSWindow) -> NSPanel {
        if let panel = replacePanel { return panel }
        let panel = makePanel(title: "置換", size: NSSize(width: 472, height: 152))
        guard let content = panel.contentView else { return panel }

        addLabel("検索する文字列:", to: content, frame: NSRect(x: 16, y: 18, width: 110, height: 17))
        configure(field: replaceFindField)
        replaceFindField.frame = NSRect(x: 130, y: 15, width: 182, height: 22)
        content.addSubview(replaceFindField)

        addLabel("置換後の文字列:", to: content, frame: NSRect(x: 16, y: 48, width: 110, height: 17))
        configure(field: replaceWithField)
        replaceWithField.frame = NSRect(x: 130, y: 45, width: 182, height: 22)
        content.addSubview(replaceWithField)

        configure(button: replaceFindNextButton, action: #selector(findNextClicked(_:)))
        replaceFindNextButton.keyEquivalent = "\r"
        replaceFindNextButton.frame = NSRect(x: 326, y: 11, width: 132, height: 28)
        content.addSubview(replaceFindNextButton)

        configure(button: replaceButton, action: #selector(replaceClicked(_:)))
        replaceButton.frame = NSRect(x: 326, y: 43, width: 132, height: 28)
        content.addSubview(replaceButton)

        configure(button: replaceAllButton, action: #selector(replaceAllClicked(_:)))
        replaceAllButton.frame = NSRect(x: 326, y: 75, width: 132, height: 28)
        content.addSubview(replaceAllButton)

        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 326, y: 107, width: 132, height: 28)
        content.addSubview(cancel)

        replaceMatchCase.target = self
        replaceMatchCase.action = #selector(optionChanged(_:))
        replaceMatchCase.frame = NSRect(x: 16, y: 86, width: 296, height: 18)
        content.addSubview(replaceMatchCase)
        replaceWrap.target = self
        replaceWrap.action = #selector(optionChanged(_:))
        replaceWrap.frame = NSRect(x: 16, y: 110, width: 296, height: 18)
        content.addSubview(replaceWrap)

        panel.initialFirstResponder = replaceFindField
        position(panel, near: window)
        replacePanel = panel
        return panel
    }

    private func makePanel(title: String, size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: true)
        panel.title = title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.autorecalculatesKeyViewLoop = true
        panel.delegate = self
        panel.contentView = FlippedView(frame: NSRect(origin: .zero, size: size))
        return panel
    }

    private func position(_ panel: NSPanel, near window: NSWindow) {
        let frame = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 24,
                                     y: frame.maxY - size.height - 72))
    }

    private func addLabel(_ text: String, to view: NSView, frame: NSRect) {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        view.addSubview(label)
    }

    private func configure(field: NSTextField) {
        field.delegate = self
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
    }

    private func configure(button: NSButton, action: Selector) {
        button.target = self
        button.action = action
    }
}
