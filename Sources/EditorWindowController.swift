import AppKit

/// 1 ウィンドウ = 1 文書。タブなし、自動保存なし、自動復元なし。
final class EditorWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {

    static let minZoom = 10
    static let maxZoom = 500
    private static let unlimited = CGFloat(Float.greatestFiniteMagnitude)
    private static let completeSelector = NSSelectorFromString("complete:")
    private static let cancelSelector = NSSelectorFromString("cancelOperation:")

    let window: NSWindow
    let textView: EditorTextView
    private let scrollView: NSScrollView
    private let statusBar: StatusBarView
    private let textStorage: NSTextStorage
    private let layoutManager: EditorLayoutManager
    private let textContainer: NSTextContainer
    private let lineHeightDelegate = FixedLineHeightDelegate()

    private(set) var fileURL: URL?
    private(set) var encoding: TextEncoding = .utf8
    private(set) var lineEnding: LineEnding = .lf
    private(set) var isDirty = false

    private var zoomPercent = 100
    private var textAttributes: [NSAttributedString.Key: Any] = [:]
    private var caretLocation = 0
    private var lineCache: (location: Int, line: Int)?
    private var statusUpdateScheduled = false

    // MARK: - 生成

    override init() {
        // TextKit 1 で組む（大きいファイルと「折り返さない」表示が素直に動く）
        let storage = NSTextStorage()
        let manager = EditorLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: EditorWindowController.unlimited))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)

        let contentRect = NSRect(x: 0, y: 0, width: 760, height: 520)
        let newWindow = NSWindow(contentRect: contentRect,
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered,
                                 defer: false)

        let barHeight = StatusBarView.height
        let scroll = NSScrollView(frame: NSRect(x: 0, y: barHeight,
                                                width: contentRect.width,
                                                height: contentRect.height - barHeight))
        let editorView = EditorTextView(frame: NSRect(origin: .zero, size: scroll.contentSize),
                                        textContainer: container)
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight))

        textStorage = storage
        layoutManager = manager
        textContainer = container
        window = newWindow
        scrollView = scroll
        textView = editorView
        statusBar = bar

        super.init()

        setUpWindow()
        setUpTextView()
        applyFont()
        applyWordWrap()
        applyStatusBarVisibility()
        updateTitle()
    }

    private func setUpWindow() {
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed      // タブ化させない
        window.isRestorable = false           // 次回起動時に復元させない
        window.minSize = NSSize(width: 360, height: 200)
        window.delegate = self

        if let content = window.contentView {
            content.autoresizesSubviews = true
            scrollView.autoresizingMask = [.width, .height]
            statusBar.autoresizingMask = [.width, .maxYMargin]
            content.addSubview(scrollView)
            content.addSubview(statusBar)
        }
        window.initialFirstResponder = textView
    }

    private func setUpTextView() {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView

        textView.editor = self
        textView.delegate = self

        // ただのテキスト。賢い置換や補完は全部切る。
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.enabledTextCheckingTypes = 0
        textView.allowsDocumentBackgroundColorChange = false
        disableIfAvailable("setInlinePredictionType:", key: "inlinePredictionType", value: 1)   // macOS 14+
        disableIfAvailable("setWritingToolsBehavior:", key: "writingToolsBehavior", value: -1)  // macOS 15+

        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: EditorWindowController.unlimited, height: EditorWindowController.unlimited)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textContainer.lineFragmentPadding = 2

        layoutManager.delegate = lineHeightDelegate
        layoutManager.allowsNonContiguousLayout = true

        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clipViewFrameDidChange(_:)),
                                               name: NSView.frameDidChangeNotification,
                                               object: scrollView.contentView)
    }

    private func disableIfAvailable(_ setter: String, key: String, value: Int) {
        if textView.responds(to: NSSelectorFromString(setter)) {
            textView.setValue(NSNumber(value: value), forKey: key)
        }
    }

    // MARK: - 表示まわり（フォント・折り返し・ステータスバー・ズーム）

    static func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        style.tabStops = []
        style.defaultTabInterval = max(1, spaceWidth * CGFloat(Settings.shared.tabWidth))
        return style
    }

    func applyFont() {
        let base = Settings.shared.editorFont
        let size = max(2, base.pointSize * CGFloat(zoomPercent) / 100)
        let font = NSFont(descriptor: base.fontDescriptor, size: size) ?? base
        lineHeightDelegate.update(for: font, layoutManager: layoutManager)
        layoutManager.antialiasesText = font.fontName != Settings.pc98FontName
        textView.needsDisplay = true

        let style = EditorWindowController.paragraphStyle(for: font)
        textAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.textColor]
        textView.defaultParagraphStyle = style
        textView.typingAttributes = textAttributes

        textStorage.beginEditing()
        textStorage.setAttributes(textAttributes, range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
    }

    func applyWordWrap() {
        let size = scrollView.contentSize
        if Settings.shared.wordWrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textContainer.widthTracksTextView = true
            textView.setFrameSize(NSSize(width: size.width, height: textView.frame.height))
            let inset = textView.textContainerInset.width * 2
            textContainer.size = NSSize(width: max(0, size.width - inset), height: EditorWindowController.unlimited)
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            // ウィンドウを狭めても本文の幅は縮めない（縮めると長い行の右側にスクロールできなくなる）
            textView.autoresizingMask = []
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(width: EditorWindowController.unlimited, height: EditorWindowController.unlimited)
        }
        updateTextViewMinSize()
        textView.sizeToFit()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// 本文が短くてもウィンドウいっぱいをクリックできるようにしておく
    private func updateTextViewMinSize() {
        let size = scrollView.contentSize
        let wrap = Settings.shared.wordWrap
        textView.minSize = NSSize(width: wrap ? 0 : size.width, height: size.height)
        var frameSize = textView.frame.size
        var changed = false
        if frameSize.height < size.height {
            frameSize.height = size.height
            changed = true
        }
        if !wrap && frameSize.width < size.width {
            frameSize.width = size.width
            changed = true
        }
        if changed {
            textView.setFrameSize(frameSize)
        }
    }

    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        updateTextViewMinSize()
    }

    func applyStatusBarVisibility() {
        guard let content = window.contentView else { return }
        let show = Settings.shared.showStatusBar
        let bounds = content.bounds
        let barHeight = show ? StatusBarView.height : 0
        statusBar.isHidden = !show
        statusBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: StatusBarView.height)
        scrollView.frame = NSRect(x: 0, y: barHeight, width: bounds.width, height: bounds.height - barHeight)
        if show {
            updateStatusNow()
        }
    }

    func zoom(by delta: Int) {
        setZoom(zoomPercent + delta)
    }

    private func setZoom(_ value: Int) {
        let clamped = max(EditorWindowController.minZoom, min(EditorWindowController.maxZoom, value))
        guard clamped != zoomPercent else { return }
        zoomPercent = clamped
        applyFont()
        updateStatusNow()
    }

    // MARK: - タイトル・状態

    var displayName: String {
        return fileURL?.lastPathComponent ?? "無題"
    }

    var isPristine: Bool {
        return fileURL == nil && !isDirty && textStorage.length == 0
    }

    private func updateTitle() {
        window.title = (isDirty ? "*" : "") + displayName + " - " + AppInfo.name
        window.representedURL = fileURL
        window.isDocumentEdited = isDirty
    }

    private func setDirty(_ dirty: Bool) {
        guard isDirty != dirty else { return }
        isDirty = dirty
        updateTitle()
    }

    // MARK: - 読み込み

    @discardableResult
    func load(_ url: URL, encoding forced: TextEncoding?) -> Bool {
        let loaded: FileIO.Loaded
        do {
            loaded = try FileIO.load(url, encoding: forced)
        } catch {
            showError("「\(url.lastPathComponent)」を開けませんでした。", error)
            return false
        }

        var text = loaded.text
        var appendedLog = false
        if EditorWindowController.isLogFile(text) {
            // .LOG で始まるファイルは、開くたびに末尾へ日時を足す（Windows のメモ帳の隠し機能）
            if !text.hasSuffix("\n") { text += "\n" }
            text += EditorWindowController.timestamp() + "\n"
            appendedLog = true
        }

        replaceAllText(with: text)
        fileURL = url
        encoding = loaded.encoding
        lineEnding = loaded.lineEnding
        isDirty = appendedLog
        updateTitle()

        let caret = appendedLog ? (text as NSString).length : 0
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
        caretLocation = caret
        updateStatusNow()

        if loaded.lossy {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "一部の文字を正しく読み込めませんでした。"
            alert.informativeText = "\(loaded.encoding.displayName) として開いています。文字化けしている場合は、［ファイル］→［文字コードを指定して開き直す］を試してください。このまま保存すると、読めなかった部分は元に戻りません。"
            alert.runModal()
        }
        return true
    }

    private static func isLogFile(_ text: String) -> Bool {
        guard text.hasPrefix(".LOG") else { return false }
        let string = text as NSString
        return string.length == 4 || string.character(at: 4) == 10
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "H:mm yyyy/MM/dd"
        return formatter.string(from: Date())
    }

    private func replaceAllText(with text: String) {
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        textStorage.setAttributes(textAttributes, range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
        textView.undoManager?.removeAllActions()
        lineCache = nil
        updateTextViewMinSize()
    }

    func openDroppedFile(_ url: URL) {
        if let other = AppDelegate.shared.controller(showing: url) {
            other.window.makeKeyAndOrderFront(nil)
            return
        }
        guard confirmDiscardIfNeeded() else { return }
        load(url, encoding: nil)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 保存

    /// 変更があれば「保存しますか?」。続行してよければ true。
    func confirmDiscardIfNeeded() -> Bool {
        guard isDirty else { return true }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(displayName) への変更内容を保存しますか?"
        alert.addButton(withTitle: "保存する")
        let dontSave = alert.addButton(withTitle: "保存しない")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        let cancel = alert.addButton(withTitle: "キャンセル")
        cancel.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        return write(to: url, encoding: encoding, lineEnding: lineEnding)
    }

    @discardableResult
    func saveAs() -> Bool {
        let suggested = fileURL?.lastPathComponent ?? "無題.txt"
        guard let choice = FilePanels.runSave(suggestedName: suggested,
                                              directory: fileURL?.deletingLastPathComponent(),
                                              encoding: encoding,
                                              lineEnding: lineEnding) else { return false }
        return write(to: choice.url, encoding: choice.encoding, lineEnding: choice.lineEnding)
    }

    private func write(to url: URL, encoding requested: TextEncoding, lineEnding ending: LineEnding) -> Bool {
        var chosenEncoding = requested
        let text = LineEndings.convert(textView.string, to: ending)
        var data = chosenEncoding.encode(text, allowLossy: false)

        if data == nil {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(requested.displayName) では保存できない文字が含まれています。"
            alert.informativeText = "そのまま保存すると、それらの文字は「?」に置き換わって失われます。"
            alert.addButton(withTitle: "UTF-8 で保存")
            alert.addButton(withTitle: "そのまま保存")
            alert.addButton(withTitle: "キャンセル").keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                chosenEncoding = .utf8
                data = chosenEncoding.encode(text, allowLossy: false)
            case .alertSecondButtonReturn:
                data = chosenEncoding.encode(text, allowLossy: true)
            default:
                return false
            }
        }
        guard let bytes = data else { return false }

        do {
            try FileIO.write(bytes, to: url)
        } catch {
            showError("「\(url.lastPathComponent)」を保存できませんでした。", error)
            return false
        }
        fileURL = url
        encoding = chosenEncoding
        lineEnding = ending
        isDirty = false
        updateTitle()
        updateStatusNow()
        return true
    }

    private func showError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - メニューの処理（ファイル）

    @objc func fileNew(_ sender: Any?) {
        guard confirmDiscardIfNeeded() else { return }
        replaceAllText(with: "")
        fileURL = nil
        encoding = .utf8
        lineEnding = .lf
        isDirty = false
        caretLocation = 0
        updateTitle()
        updateStatusNow()
    }

    @objc func fileOpen(_ sender: Any?) {
        guard confirmDiscardIfNeeded() else { return }
        guard let choice = FilePanels.runOpen() else { return }
        if let other = AppDelegate.shared.controller(showing: choice.url), other !== self {
            other.window.makeKeyAndOrderFront(nil)
            return
        }
        load(choice.url, encoding: choice.encoding)
    }

    @objc func fileSave(_ sender: Any?) {
        save()
    }

    @objc func fileSaveAs(_ sender: Any?) {
        saveAs()
    }

    @objc func filePrint(_ sender: Any?) {
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.dictionary().setObject(NSNumber(value: true), forKey: NSString(string: "NSPrintHeaderAndFooter"))

        let width = max(72, printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin)
        let view = PrintTextView.make(text: textView.string, title: displayName, width: width)
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.jobTitle = displayName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func reopenWithEncoding(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let chosen = TextEncoding(rawValue: item.tag),
              let url = fileURL else { return }
        guard confirmDiscardIfNeeded() else { return }
        load(url, encoding: chosen)
    }

    // MARK: - メニューの処理（書式）

    @objc func setSaveEncoding(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let chosen = TextEncoding(rawValue: item.tag) else { return }
        guard chosen != encoding else { return }
        encoding = chosen
        setDirty(true)
        updateStatusNow()
    }

    @objc func setSaveLineEnding(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let chosen = LineEnding(rawValue: item.tag) else { return }
        guard chosen != lineEnding else { return }
        lineEnding = chosen
        setDirty(true)
        updateStatusNow()
    }

    // MARK: - メニューの処理（編集）

    @objc func showFindPanel(_ sender: Any?) {
        FindPanelController.shared.show(.find, for: self)
    }

    @objc func showReplacePanel(_ sender: Any?) {
        FindPanelController.shared.show(.replace, for: self)
    }

    @objc func findNextMatch(_ sender: Any?) {
        FindPanelController.shared.findNext(in: self, backwards: false)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        FindPanelController.shared.findNext(in: self, backwards: true)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        FindPanelController.shared.useSelection(of: self)
    }

    @objc func insertDateTime(_ sender: Any?) {
        textView.insertText(EditorWindowController.timestamp(), replacementRange: textView.selectedRange())
    }

    @objc func goToLine(_ sender: Any?) {
        let total = countNewlines(in: NSRange(location: 0, length: textStorage.length)) + 1
        let alert = NSAlert()
        alert.messageText = "行へ移動"
        alert.informativeText = "行番号 (1〜\(total)):"
        alert.addButton(withTitle: "移動")
        alert.addButton(withTitle: "キャンセル").keyEquivalent = "\u{1b}"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(lineNumber(at: caretLocation))
        alert.accessoryView = field
        alert.layout()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        guard let line = Int(digits), line >= 1, line <= total else {
            let error = NSAlert()
            error.messageText = "行番号が行の総数を超えています。"
            error.runModal()
            return
        }
        let location = self.location(ofLine: line)
        let range = NSRange(location: location, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        window.makeFirstResponder(textView)
    }

    // MARK: - メニューの処理（表示）

    @objc func editorZoomIn(_ sender: Any?) {
        setZoom(zoomPercent + 10)
    }

    @objc func editorZoomOut(_ sender: Any?) {
        setZoom(zoomPercent - 10)
    }

    @objc func editorZoomReset(_ sender: Any?) {
        setZoom(100)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        switch action {
        case #selector(setSaveEncoding(_:)):
            menuItem.state = menuItem.tag == encoding.rawValue ? .on : .off
        case #selector(setSaveLineEnding(_:)):
            menuItem.state = menuItem.tag == lineEnding.rawValue ? .on : .off
        case #selector(reopenWithEncoding(_:)):
            return fileURL != nil
        case #selector(editorZoomIn(_:)):
            return zoomPercent < EditorWindowController.maxZoom
        case #selector(editorZoomOut(_:)):
            return zoomPercent > EditorWindowController.minZoom
        default:
            break
        }
        return true
    }

    // MARK: - 検索・置換（FindPanelController から呼ばれる）

    func find(_ target: String, backwards: Bool, matchCase: Bool, wrap: Bool) -> NSRange? {
        let string = textStorage.mutableString
        let length = string.length
        let selection = textView.selectedRange()
        var options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
        let first: NSRange
        let second: NSRange
        if backwards {
            options.insert(.backwards)
            first = NSRange(location: 0, length: selection.location)
            second = NSRange(location: selection.location, length: length - selection.location)
        } else {
            let start = min(NSMaxRange(selection), length)
            first = NSRange(location: start, length: length - start)
            second = NSRange(location: 0, length: start)
        }
        var found = string.range(of: target, options: options, range: first)
        if found.location == NSNotFound && wrap {
            found = string.range(of: target, options: options, range: second)
        }
        return found.location == NSNotFound ? nil : found
    }

    func select(_ range: NSRange) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    func selectedText() -> String? {
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return nil }
        return textStorage.mutableString.substring(with: selection)
    }

    func singleLineSelection() -> String? {
        guard let text = selectedText(), !text.contains("\n"), text.count <= 256 else { return nil }
        return text
    }

    func replaceSelectionIfMatches(_ target: String, with replacement: String, matchCase: Bool) {
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return }
        let selected = textStorage.mutableString.substring(with: selection)
        let options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
        guard selected.compare(target, options: options) == .orderedSame else { return }
        guard textView.shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage.replaceCharacters(in: selection, with: replacement)
        let newLength = (replacement as NSString).length
        textStorage.setAttributes(textAttributes, range: NSRange(location: selection.location, length: newLength))
        textView.didChangeText()
        textView.undoManager?.setActionName("置換")
        textView.setSelectedRange(NSRange(location: selection.location + newLength, length: 0))
    }

    /// 置き換えた数を返す。元に戻すは 1 回でまとめて戻る。
    func replaceAll(_ target: String, with replacement: String, matchCase: Bool) -> Int {
        let string = textStorage.mutableString
        let options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
        var ranges: [NSValue] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let found = string.range(of: target, options: options, range: searchRange)
            if found.location == NSNotFound || found.length == 0 { break }
            ranges.append(NSValue(range: found))
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: string.length - next)
        }
        guard !ranges.isEmpty else { return 0 }

        let replacements = [String](repeating: replacement, count: ranges.count)
        guard textView.shouldChangeText(inRanges: ranges, replacementStrings: replacements) else { return 0 }
        textStorage.beginEditing()
        for value in ranges.reversed() {
            textStorage.replaceCharacters(in: value.rangeValue, with: replacement)
        }
        textStorage.setAttributes(textAttributes, range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName("すべて置換")
        lineCache = nil
        return ranges.count
    }

    // MARK: - 行・列の計算

    private func countNewlines(in range: NSRange) -> Int {
        let string = textStorage.mutableString
        let end = min(NSMaxRange(range), string.length)
        var position = max(0, range.location)
        var count = 0
        let chunk = 16384
        var buffer = [unichar](repeating: 0, count: chunk)
        while position < end {
            let length = min(chunk, end - position)
            buffer.withUnsafeMutableBufferPointer { pointer in
                string.getCharacters(pointer.baseAddress!, range: NSRange(location: position, length: length))
                for i in 0..<length where pointer[i] == 10 {
                    count += 1
                }
            }
            position += length
        }
        return count
    }

    private func lineNumber(at location: Int) -> Int {
        let target = max(0, min(location, textStorage.length))
        let line: Int
        if let cache = lineCache {
            if target >= cache.location {
                line = cache.line + countNewlines(in: NSRange(location: cache.location, length: target - cache.location))
            } else {
                line = cache.line - countNewlines(in: NSRange(location: target, length: cache.location - target))
            }
        } else {
            line = 1 + countNewlines(in: NSRange(location: 0, length: target))
        }
        lineCache = (location: target, line: line)
        return line
    }

    private func columnNumber(at location: Int) -> Int {
        let string = textStorage.mutableString
        let target = max(0, min(location, string.length))
        let newline = string.range(of: "\n", options: [.backwards, .literal],
                                   range: NSRange(location: 0, length: target))
        let lineStart = newline.location == NSNotFound ? 0 : newline.location + 1
        return target - lineStart + 1
    }

    private func location(ofLine target: Int) -> Int {
        if target <= 1 { return 0 }
        let string = textStorage.mutableString
        let length = string.length
        var line = 1
        var position = 0
        let chunk = 16384
        var buffer = [unichar](repeating: 0, count: chunk)
        while position < length {
            let size = min(chunk, length - position)
            var found: Int?
            buffer.withUnsafeMutableBufferPointer { pointer in
                string.getCharacters(pointer.baseAddress!, range: NSRange(location: position, length: size))
                for i in 0..<size where pointer[i] == 10 {
                    line += 1
                    if line == target {
                        found = position + i + 1
                        break
                    }
                }
            }
            if let found = found { return found }
            position += size
        }
        return length
    }

    private func scheduleStatusUpdate() {
        if statusUpdateScheduled { return }
        statusUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusUpdateScheduled = false
            self.updateStatusNow()
        }
    }

    func updateStatusNow() {
        guard Settings.shared.showStatusBar else { return }
        statusBar.update(line: lineNumber(at: caretLocation),
                         column: columnNumber(at: caretLocation),
                         zoom: zoomPercent,
                         lineEnding: lineEnding,
                         encoding: encoding)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let cache = lineCache, affectedCharRange.location < cache.location {
            lineCache = nil
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        if let undoManager = textView.undoManager, undoManager.isUndoing || undoManager.isRedoing {
            lineCache = nil
        }
        setDirty(true)
        scheduleStatusUpdate()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let selection = textView.selectedRange()
        if selection.length == 0 {
            caretLocation = selection.location
        } else if let old = (notification.userInfo?["NSOldSelectedCharacterRange"] as? NSValue)?.rangeValue {
            // Shift+矢印で伸ばしてる側をキャレットとみなす
            if NSMaxRange(old) == NSMaxRange(selection) && old.location != selection.location {
                caretLocation = selection.location
            } else {
                caretLocation = NSMaxRange(selection)
            }
        } else {
            caretLocation = NSMaxRange(selection)
        }
        scheduleStatusUpdate()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Esc や F5 で単語補完のポップアップを出さない
        if commandSelector == EditorWindowController.completeSelector
            || commandSelector == EditorWindowController.cancelSelector {
            return true
        }
        return false
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return confirmDiscardIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        Settings.shared.windowFrame = window.frame
        AppDelegate.shared.controllerWillClose(self)
    }

    func windowDidMove(_ notification: Notification) {
        Settings.shared.windowFrame = window.frame
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        Settings.shared.windowFrame = window.frame
    }
}
