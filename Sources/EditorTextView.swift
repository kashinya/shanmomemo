import AppKit

/// 本文の NSTextView。ファイルのドロップで開く・ピンチでズーム、だけ足してある。
final class EditorTextView: NSTextView {
    weak var editor: EditorWindowController?
    private var pinchAccumulator: CGFloat = 0

    /// SEDIT 風: 改行に黄色い ↓、最後に [EOF] を出す
    var showsSeditMarks = false {
        didSet { needsDisplay = true }
    }

    // MARK: - キーボードマクロの記録

    /// キーを押して入った文字とコマンドだけ覚える（メニューやプログラムから入れた文字は覚えない）
    private var isHandlingKeyDown = false

    override func keyDown(with event: NSEvent) {
        isHandlingKeyDown = true
        defer { isHandlingKeyDown = false }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // 変換中の字がショートカットなどで確定したときは keyDown の外で来るので、変換中だったかでも見る
        if isHandlingKeyDown || hasMarkedText() {
            let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
            if !text.isEmpty {
                MacroRecorder.shared.record(.insert(text))
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func doCommand(by selector: Selector) {
        guard isHandlingKeyDown else {
            super.doCommand(by: selector)
            return
        }
        MacroRecorder.shared.record(.command(NSStringFromSelector(selector)))
        // insertNewline: や insertTab: は中で insertText を呼ぶので、その字は二重に覚えない
        isHandlingKeyDown = false
        defer { isHandlingKeyDown = true }
        super.doCommand(by: selector)
    }

    // MARK: - 変換候補の窓の位置

    /// IME に返す字の四角を、見えてるところに収める。折り返さないときは行の幅が無限大なので、変換中の字が行の終わりにあって
    /// 改行まで含めた問い合わせが来ると、四角が画面の外まで伸びて、候補の窓（2 回目のスペースで出る一覧）が画面の右端へ飛んでた。
    /// 普通の答えはそのまま返し、おかしいときだけ詰める
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let answer = clampedFirstRect(forCharacterRange: range, actualRange: actualRange)
        IMELog.write("firstRect query=\(NSStringFromRange(range)) asked=\(NSStringFromRange(answer.query))"
                     + " answer=\(NSStringFromRect(answer.rect)) appkit=\(NSStringFromRect(answer.appKit))"
                     + " actual=\(actualRange.map { NSStringFromRange($0.pointee) } ?? "-") \(imeState)")
        return answer.rect
    }

    /// query: NSTextView に聞いた範囲（変換中の字の終わりで切ったあと）、appKit: その答え（記録用）
    private func clampedFirstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> (rect: NSRect, appKit: NSRect, query: NSRange) {
        var query = range
        if hasMarkedText(), query.location != NSNotFound {
            let marked = markedRange()
            // 変換中の字から始まって、うしろ（改行・次の行）まではみ出す問い合わせは、変換中の字の終わりで切る
            if query.location >= marked.location, query.location < NSMaxRange(marked), NSMaxRange(query) > NSMaxRange(marked) {
                query.length = NSMaxRange(marked) - query.location
            }
        }
        let rect = super.firstRect(forCharacterRange: query, actualRange: actualRange)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else {
            let caret = query.location == NSNotFound ? selectedRange().location : query.location
            return (super.firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: actualRange), rect, query)
        }
        guard let window = window else { return (rect, rect, query) }
        let visible = window.convertToScreen(convert(visibleRect, to: nil))
        guard !visible.isEmpty, rect.maxX > visible.maxX + 1 else { return (rect, rect, query) }   // 普通はここで帰る
        var fixed = rect
        fixed.origin.x = min(max(rect.minX, visible.minX), visible.maxX - 1)
        fixed.size.width = max(0, min(rect.maxX, visible.maxX) - fixed.minX)
        return (fixed, rect, query)
    }

    // 変換候補の窓がまだ飛ぶので、IME とのやりとりを記録して調べる（IMELog がオンのときだけ）
    override func characterIndex(for point: NSPoint) -> Int {
        let index = super.characterIndex(for: point)
        IMELog.write("characterIndex point=\(NSStringFromPoint(point)) answer=\(index) \(imeState)")
        return index
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        IMELog.write("setMarkedText \"\(text)\" selected=\(NSStringFromRange(selectedRange)) \(imeState)")
    }

    override func unmarkText() {
        super.unmarkText()
        IMELog.write("unmarkText \(imeState)")
    }

    /// 記録用: 変換中の字・選択・見えてるところ（画面の座標）・ウィンドウ・マウスの位置・折り返し
    private var imeState: String {
        guard IMELog.isEnabled else { return "" }
        let visible = window.map { NSStringFromRect($0.convertToScreen(convert(visibleRect, to: nil))) } ?? "-"
        return "marked=\(NSStringFromRange(markedRange())) selected=\(NSStringFromRange(selectedRange()))"
            + " visible=\(visible) window=\(window.map { NSStringFromRect($0.frame) } ?? "-")"
            + " mouse=\(NSStringFromPoint(NSEvent.mouseLocation)) wrap=\(Settings.shared.wordWrap) sedit=\(Settings.shared.seditMode)"
    }

    // MARK: - SEDIT 風の印

    override func draw(_ dirtyRect: NSRect) {
        // 印は字とカーソルより先（下）に描く（[EOF] の水色でカーソルを隠さんように）。背景は後ろの View が描いてる
        drawSeditMarks(in: dirtyRect)
        super.draw(dirtyRect)
    }

    /// SEDIT 風で折り返さないとき、いちばん長い行の ↓ と [EOF] がはみ出さんよう、右に [EOF] の幅だけ足す
    override func setConstrainedFrameSize(_ desiredSize: NSSize) {
        var size = desiredSize
        if showsSeditMarks, isHorizontallyResizable, let layoutManager = layoutManager, let container = textContainer,
           let font = typingAttributes[.font] as? NSFont {
            let reserve = ceil(("[EOF]" as NSString).size(withAttributes: [.font: font]).width)
            size.width = max(size.width, layoutManager.usedRect(for: container).maxX + textContainerInset.width * 2 + reserve)
        }
        super.setConstrainedFrameSize(size)
    }

    private func drawSeditMarks(in dirtyRect: NSRect) {
        guard showsSeditMarks, let layoutManager = layoutManager, let container = textContainer,
              let font = typingAttributes[.font] as? NSFont else { return }
        let origin = textContainerOrigin
        let dot = font.pointSize / 16                 // PC-9800 フォントの 1 ドット
        let cellHeight = font.pointSize

        /// 行の中で、16 ドットの升の上端（行間を広げたときは上下の真ん中）
        func cellTop(_ line: NSRect) -> CGFloat {
            return (origin.y + line.minY + (line.height - cellHeight) / 2).rounded(.down)
        }

        // 改行の ↓（見えてるところだけ）
        guard let string = textStorage?.mutableString else { return }   // .string やと毎回まるごと写すので
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        Sedit.yellow.setFill()
        var index = visibleChars.location
        let end = min(NSMaxRange(visibleChars), string.length)
        while index < end {
            let found = string.range(of: "\n", options: .literal, range: NSRange(location: index, length: end - index))
            if found.location == NSNotFound { break }
            let glyph = layoutManager.glyphIndexForCharacter(at: found.location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = (origin.x + line.minX + layoutManager.location(forGlyphAt: glyph).x).rounded(.down)
            let top = cellTop(line)
            for (dx, dy) in Sedit.newlineArrowDots {
                NSRect(x: x + dx * dot, y: top + dy * dot, width: dot, height: dot).fill()
            }
            index = found.location + 1
        }

        // [EOF]: 最後が改行なら次の行の頭、そうでなければ最後の字のうしろ
        let eofOrigin: NSPoint
        let extra = layoutManager.extraLineFragmentRect
        let glyphCount = layoutManager.numberOfGlyphs
        if glyphCount == 0 || !extra.isEmpty {
            let line = extra.isEmpty ? NSRect(x: 0, y: 0, width: 0, height: cellHeight) : extra
            eofOrigin = NSPoint(x: origin.x + line.minX, y: cellTop(line))
        } else {
            let last = glyphCount - 1
            let line = layoutManager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: container)
            eofOrigin = NSPoint(x: (origin.x + bounds.maxX).rounded(), y: cellTop(line))
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Sedit.black]
        let size = ("[EOF]" as NSString).size(withAttributes: attributes)
        let eofRect = NSRect(x: eofOrigin.x, y: eofOrigin.y, width: ceil(size.width), height: cellHeight)
        guard eofRect.intersects(dirtyRect) else { return }
        Sedit.cyan.setFill()
        eofRect.fill()
        Sedit.drawPixelText(dot: dot) {
            ("[EOF]" as NSString).draw(at: eofOrigin, withAttributes: attributes)
        }
    }

    /// 文字が変わったら、[EOF] が動いた跡が残らんように、最後のあたりを描き直す
    func invalidateEndOfText() {
        guard showsSeditMarks, let layoutManager = layoutManager, let container = textContainer else { return }
        let used = layoutManager.usedRect(for: container)
        let lineHeight = (typingAttributes[.font] as? NSFont)?.pointSize ?? 16
        let top = max(0, textContainerOrigin.y + used.maxY - lineHeight * 3)
        setNeedsDisplay(NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top)))
    }

    // MARK: - Finder からファイルを落としたら開く（Windows のメモ帳と同じ）

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        if !types.contains(.fileURL) {
            types.append(.fileURL)
        }
        return types
    }

    private func droppedFileURL(_ info: NSDraggingInfo) -> URL? {
        // 自分の中で文字をドラッグしてるときは普通の移動・コピー
        guard info.draggingSource == nil else { return nil }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL])?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if droppedFileURL(sender) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if droppedFileURL(sender) != nil { return .copy }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if droppedFileURL(sender) != nil { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = droppedFileURL(sender) {
            // ドラッグ処理中に保存確認ダイアログを出さんよう、一拍おく
            DispatchQueue.main.async { [weak self] in
                self?.editor?.openDroppedFile(url)
            }
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: - トラックパッドのピンチでズーム（Windows の Ctrl+ホイール代わり）

    override func magnify(with event: NSEvent) {
        guard let editor = editor else {
            super.magnify(with: event)
            return
        }
        pinchAccumulator += event.magnification
        if pinchAccumulator >= 0.12 {
            editor.zoom(by: 10)
            pinchAccumulator = 0
        } else if pinchAccumulator <= -0.12 {
            editor.zoom(by: -10)
            pinchAccumulator = 0
        }
        if event.phase == .ended || event.phase == .cancelled {
            pinchAccumulator = 0
        }
    }
}

/// 隠し設定（defaults write local.memocho IMELog -bool YES）のときだけ、IME とのやりとりを
/// ~/Library/Logs/local.memocho-ime.log に書く。変換候補の窓の位置を調べる用。1MB を超えたら空にして書き直す
enum IMELog {
    static var isEnabled: Bool {
        return Settings.shared.imeLog
    }

    private static var fileURL: URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        return library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "local.memocho")-ime.log")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ line: String) {
        guard isEnabled, let url = fileURL, let data = "\(formatter.string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int
        if size.map({ $0 > 1_000_000 }) ?? true {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
        }
        // FileHandle の write はディスクがいっぱいのとき例外で落ちるので、C の fopen で足す（書けんかったら黙って捨てる）
        guard let file = fopen(url.path, "a") else { return }
        _ = data.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) }
        fclose(file)
    }
}
