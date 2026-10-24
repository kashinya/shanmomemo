import AppKit

/// 1 ウィンドウ = 1 文書。タブなし、自動保存なし、自動復元なし。
final class EditorWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation, RulerSource {

    static let minZoom = 10
    static let maxZoom = 500
    private static let unlimited = CGFloat(Float.greatestFiniteMagnitude)
    private static let completeSelector = NSSelectorFromString("complete:")
    private static let cancelSelector = NSSelectorFromString("cancelOperation:")

    let window: EditorWindow
    let textView: EditorTextView
    private let scrollView: NSScrollView
    private let statusBar: StatusBarView
    private let rootView = EditorRootView()
    private let backgroundView = EditorBackgroundView()
    // SEDIT 風のときだけ出す部品
    private let seditLine = SeditStatusLine()
    private let functionBar = SeditFunctionBar()
    private var totalLinesCache: Int?
    private var characterCountCache: Int?
    // ［表示］→［行番号］［桁ルーラー］
    private lazy var lineRuler: LineNumberRuler = {
        let ruler = LineNumberRuler(scrollView: scrollView)
        ruler.source = self
        ruler.clientView = textView
        return ruler
    }()
    private lazy var columnRuler: ColumnRuler = {
        let ruler = ColumnRuler(scrollView: scrollView)
        ruler.source = self
        ruler.clientView = textView
        return ruler
    }()
    // Windows 2000 風のときだけ出す部品
    private let titleBar = ClassicTitleBar()
    private let menuBar = ClassicMenuBar()
    private let verticalBar = ClassicScrollBar(orientation: .vertical)
    private let horizontalBar = ClassicScrollBar(orientation: .horizontal)
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
    private var rulerLineCache: (location: Int, line: Int)?
    private var characterCountScheduled = false
    private var statusUpdateScheduled = false
    private var classicAfterFullScreenExit = false

    // MARK: - 生成

    override init() {
        // TextKit 1 で組む（大きいファイルと「折り返さない」表示が素直に動く）
        let storage = NSTextStorage()
        let manager = EditorLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: EditorWindowController.unlimited))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)

        let contentRect = NSRect(x: 0, y: 0, width: 500, height: 500)
        let newWindow = EditorWindow(contentRect: contentRect,
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
        applyTheme()
        applyWordWrap()
        applyClassicUI()
        applySeditMode()
        applyRulers()
        applyStatusBarVisibility()
        updateTitle()
    }

    private func setUpWindow() {
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed      // タブ化させない
        window.isRestorable = false           // 次回起動時に復元させない
        window.minSize = NSSize(width: 360, height: 200)
        window.delegate = self

        // 中身の並べ方は layoutContent() でまとめて決める
        window.contentView = rootView
        rootView.autoresizesSubviews = true
        rootView.onLayout = { [weak self] in self?.layoutContent() }
        rootView.addSubview(backgroundView)   // 本文の後ろ（背景色・半透明・画像）
        rootView.addSubview(scrollView)
        rootView.addSubview(statusBar)
        functionBar.onPress = { [weak self] number in self?.performSeditFunction(number) }
        window.initialFirstResponder = textView
    }

    private func setUpTextView() {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // 背景は後ろの backgroundView が描く（半透明と画像のため）
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = textView
        // 本文の大きさが変わったのも拾うので、documentView を入れてから
        verticalBar.attach(to: scrollView)
        horizontalBar.attach(to: scrollView)

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

        textView.drawsBackground = false
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
        // スクロールしたら行番号と桁ルーラーも描き直す
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clipViewBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.verticalRulerView = lineRuler
        scrollView.horizontalRulerView = columnRuler
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        refreshRulers()
        textView.updateInsertionPointForRulers()
    }

    // MARK: - 行番号・桁ルーラー（RulerSource）

    /// ［表示］→［行番号］［桁ルーラー］を出す／隠す
    /// 本文のまわりの余白。SEDIT 風は上は 0、左は行番号を出してないときだけ半角 4 桁ぶん（行番号を出してるときくらい）あける
    private func updateTextInsets() {
        let settings = Settings.shared
        let inset: NSSize
        if settings.seditMode {
            inset = NSSize(width: settings.showLineNumbers ? 0 : Sedit.editorMargin, height: 0)
        } else {
            inset = NSSize(width: 4, height: 4)
        }
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }
        let padding: CGFloat = settings.seditMode ? 0 : 2
        if textContainer.lineFragmentPadding != padding {
            textContainer.lineFragmentPadding = padding
        }
    }

    func applyRulers() {
        let settings = Settings.shared
        updateTextInsets()
        updateSeditWrapWidth()
        scrollView.hasVerticalRuler = settings.showLineNumbers
        scrollView.hasHorizontalRuler = settings.showColumnRuler
        scrollView.rulersVisible = settings.showLineNumbers || settings.showColumnRuler
        refreshRulers()
        textView.needsDisplay = true   // ルーラーの下に字を描かんところが変わる（SEDIT 風）
        textView.updateInsertionPointForRulers()
    }

    private func refreshRulers() {
        let settings = Settings.shared
        if settings.showLineNumbers {
            lineRuler.updateThickness()
            lineRuler.needsDisplay = true
        }
        if settings.showColumnRuler {
            columnRuler.updateThickness()
            columnRuler.needsDisplay = true
        }
    }

    var rulerStyle: RulerStyle {
        if Settings.shared.seditMode { return .sedit }
        return Settings.shared.classicUI ? .classic : .mac
    }

    var rulerFont: NSFont {
        return (textAttributes[.font] as? NSFont) ?? Settings.shared.editorFont
    }

    /// ルーラーの地。本文が半透明でもルーラーは透けさせない
    var rulerBackground: NSColor {
        return activeTheme.background.withAlphaComponent(1)
    }

    var rulerText: NSColor {
        return activeTheme.text
    }

    var currentLineNumber: Int {
        return lineNumber(at: caretLocation)
    }

    var totalLineCount: Int {
        if let total = totalLinesCache { return total }
        let total = countNewlines(in: NSRange(location: 0, length: textStorage.length)) + 1
        totalLinesCache = total
        return total
    }

    var caretX: CGFloat? {
        let length = textStorage.length
        let origin = textView.textContainerOrigin
        guard length > 0 else { return origin.x + textContainer.lineFragmentPadding }
        let location = min(caretLocation, length)
        if location == length {
            // いちばん最後: 最後が改行なら次の行の頭、そうでなければ最後の字のうしろ
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty {
                return origin.x + extra.minX + textContainer.lineFragmentPadding
            }
            let last = layoutManager.glyphIndexForCharacter(at: length - 1)
            return origin.x + layoutManager.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: textContainer).maxX
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return origin.x + line.minX + layoutManager.location(forGlyphAt: glyph).x
    }

    // MARK: - 文字数（改行は数えない。絵文字なども見た目どおり 1 文字）

    /// 大きい文書は打つたびに数え直すと重いので、少し落ち着いてから数える（それまでは前の数）
    private var characterCount: Int {
        if let count = characterCountCache { return count }
        if textStorage.length > 1_000_000 {
            scheduleCharacterCount()
            return lastCharacterCount
        }
        return countCharactersNow()
    }

    private var lastCharacterCount = 0

    @discardableResult
    private func countCharactersNow() -> Int {
        let count = max(0, textStorage.string.count - (totalLineCount - 1))
        characterCountCache = count
        lastCharacterCount = count
        return count
    }

    private func scheduleCharacterCount() {
        guard !characterCountScheduled else { return }
        characterCountScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.characterCountScheduled = false
            guard Settings.shared.showCharacterCount, self.characterCountCache == nil else { return }
            self.countCharactersNow()
            self.updateStatusNow()
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func formatted(_ value: Int) -> String {
        return numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 選んでるときは「選んだ数 / 全体」
    private func characterCountText(unit: String) -> String {
        let total = EditorWindowController.formatted(characterCount)
        // ⌥ドラッグの矩形選択などで何か所も選んでるときは足し合わせる
        let ranges = textView.selectedRanges.map { $0.rangeValue }.filter { $0.length > 0 }
        guard !ranges.isEmpty else { return total + unit }
        let count = ranges.reduce(0) { sum, range in
            sum + textStorage.mutableString.substring(with: range).count - countNewlines(in: range)
        }
        return EditorWindowController.formatted(max(0, count)) + " / " + total + unit
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
        lineHeightDelegate.update(for: font, layoutManager: layoutManager, spacing: Settings.shared.lineSpacing)
        scrollView.verticalLineScroll = max(1, lineHeightDelegate.lineHeight)   // スクロールバーの矢印で 1 行ずつ
        layoutManager.pixelFontDotSize = font.fontName == Settings.pc98FontName ? font.pointSize / 16 : nil
        textView.needsDisplay = true

        let style = EditorWindowController.paragraphStyle(for: font)
        textAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: activeTheme.text]
        textView.defaultParagraphStyle = style
        textView.typingAttributes = textAttributes

        textStorage.beginEditing()
        textStorage.setAttributes(textAttributes, range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
        updateTextInsets()
        updateSeditWrapWidth()   // ズームで ↓ の幅が変わる
        refreshRulers()          // 行番号と桁の幅もフォントに合わせる
        // SEDIT 風の上の行と下の欄も、ズームに合わせて大きくする
        if seditLine.scale != seditScale || functionBar.scale != seditScale {
            seditLine.scale = seditScale
            functionBar.scale = seditScale
            if Settings.shared.seditMode {
                layoutContent()
            }
        }
    }

    /// SEDIT 風の上の行と下の欄の倍率（ズーム 100% = 1）
    private var seditScale: CGFloat {
        return CGFloat(zoomPercent) / 100
    }

    func applyWordWrap() {
        let size = scrollView.contentSize
        let classic = Settings.shared.classicUI
        if Settings.shared.wordWrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            // SEDIT 風は右に ↓ の 1 桁を残すので、幅は自分で合わせる
            textContainer.widthTracksTextView = !Settings.shared.seditMode
            textView.setFrameSize(NSSize(width: size.width, height: textView.frame.height))
            let inset = textView.textContainerInset.width * 2
            textContainer.size = NSSize(width: max(0, size.width - inset), height: EditorWindowController.unlimited)
        } else {
            scrollView.hasHorizontalScroller = !classic   // Windows 2000 風のときは自前のスクロールバー
            textView.isHorizontallyResizable = true
            // ウィンドウを狭めても本文の幅は縮めない（縮めると長い行の右側にスクロールできなくなる）
            textView.autoresizingMask = []
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(width: EditorWindowController.unlimited, height: EditorWindowController.unlimited)
        }
        layoutContent()
        updateTextViewMinSize()
        updateSeditWrapWidth()
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
        updateSeditWrapWidth()
    }

    /// SEDIT 風で折り返すとき: 右端に改行の ↓ が入る 1 桁を残して折り返す
    private func updateSeditWrapWidth() {
        guard Settings.shared.seditMode, Settings.shared.wordWrap else { return }
        let font = textView.typingAttributes[.font] as? NSFont
        let reserve = ceil((font?.pointSize ?? 16) / 2)
        // すき間は左だけ（右は ↓ の reserve）
        let width = max(0, scrollView.contentSize.width - textView.textContainerInset.width - reserve)
        let size = NSSize(width: width, height: EditorWindowController.unlimited)
        if textContainer.size != size {
            textContainer.size = size
        }
    }

    func applyStatusBarVisibility() {
        layoutContent()
        if Settings.shared.showStatusBar {
            updateStatusNow()
        }
    }

    /// Windows 2000 風にする／戻す。ウィンドウの外側の大きさは変えない
    func applyClassicUI() {
        let classic = Settings.shared.classicUI
        // Mac の全画面のまま枠を付け外しすると全画面の状態が壊れるので、全画面を抜けてから切り替える
        if window.styleMask.contains(.fullScreen) {
            if !classicAfterFullScreenExit {
                classicAfterFullScreenExit = true
                window.toggleFullScreen(nil)
            }
            return
        }
        // Windows 2000 風（枠なし）のときは Mac の全画面にさせない
        window.collectionBehavior = classic ? [.fullScreenNone] : []
        let leavingClassic = window.isClassic && !classic
        var frame = leavingClassic ? window.leaveClassicMaximize() : window.frame
        window.styleMask = classic ? [.closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable, .resizable]
        if leavingClassic {
            // 枠なしの間は画面のいちばん上まで行ける。Mac のタイトルバーがメニューバーの下に潜らんよう収める
            frame = window.constrainFrameRect(frame, to: window.screen ?? NSScreen.main)
        }
        window.setFrame(frame, display: false)
        window.hasShadow = true
        // まわりの部品だけ Windows 2000 の明るい色に固定する（ウィンドウごと固定すると本文までテーマの明暗に従わなくなる）
        let chromeAppearance = classic ? NSAppearance(named: .aqua) : nil
        for view in [titleBar, menuBar, verticalBar, horizontalBar, statusBar] as [NSView] {
            view.appearance = chromeAppearance
        }
        updateWindowBackground()

        rootView.classic = classic
        for view in [titleBar, menuBar, verticalBar, horizontalBar] as [NSView] {
            if !classic {
                view.removeFromSuperview()
            } else if view.superview == nil {
                rootView.addSubview(view)
            }
        }
        if classic {
            menuBar.reload()
        }
        updateWindowAppearance()
        scrollView.hasVerticalScroller = !classic
        scrollView.hasHorizontalScroller = !classic && !Settings.shared.wordWrap
        statusBar.classic = classic
        refreshRulers()
        layoutContent()
        updateTitle()
        window.makeFirstResponder(textView)
    }

    /// SEDIT 風のときは SEDIT の色（黒地に白）、そうでなければ［テーマ］
    private var activeTheme: EditorTheme {
        return Settings.shared.seditMode ? Sedit.theme : Settings.shared.theme
    }

    /// SEDIT 風にする／戻す
    func applySeditMode() {
        let sedit = Settings.shared.seditMode
        for view in [seditLine, functionBar] as [NSView] {
            if !sedit {
                view.removeFromSuperview()
            } else if view.superview == nil {
                rootView.addSubview(view)
            }
        }
        textView.showsSeditMarks = sedit
        textView.avoidsRulers = sedit   // SEDIT 風のルーラーは透かして背景を見せる
        totalLinesCache = nil
        updateWindowAppearance()
        applyTheme()      // 色と PC-9800 フォント（ルーラーの見た目も変わる）
        applyWordWrap()   // 余白が変わったので、折り返しの幅と並べ方を合わせ直す
        updateStatusNow()
    }

    /// SEDIT 風を Mac の枠で出すときは、スクロールバーなども暗くする
    private func updateWindowAppearance() {
        let settings = Settings.shared
        window.appearance = settings.seditMode && !settings.classicUI ? NSAppearance(named: .darkAqua) : nil
    }

    /// テーマ（文字・背景・選択・カーソルの色）と背景の不透明度・画像を反映する
    func applyTheme() {
        let theme = activeTheme
        textView.insertionPointColor = theme.cursor
        var selection: [NSAttributedString.Key: Any] = [.backgroundColor: theme.selection]
        if let selectionText = theme.selectionText {
            selection[.foregroundColor] = selectionText
        }
        textView.selectedTextAttributes = selection
        backgroundView.color = theme.background
        applyBackground()
        applyFont()   // 文字の色
    }

    /// 背景の不透明度と画像だけ
    func applyBackground() {
        let settings = Settings.shared
        backgroundView.opacity = settings.backgroundOpacity
        backgroundView.image = BackgroundImage.image
        backgroundView.imageOpacity = settings.backgroundImageOpacity
        updateWindowBackground()
        refreshRulers()
    }

    private func updateWindowBackground() {
        let opaque = Settings.shared.backgroundOpacity >= 1
        window.isOpaque = opaque
        window.backgroundColor = opaque ? (Settings.shared.classicUI ? Classic.face : .windowBackgroundColor) : .clear
        window.invalidateShadow()
    }

    /// 本文・ステータスバー・（Windows 2000 風のときは）タイトルバー・メニューバー・スクロールバーを並べる。上が y = 0
    private func layoutContent() {
        let bounds = rootView.bounds
        let sedit = Settings.shared.seditMode
        let showStatus = Settings.shared.showStatusBar && !sedit   // SEDIT 風は上の行に出す
        let statusHeight = showStatus ? StatusBarView.height : 0
        statusBar.isHidden = !showStatus

        /// SEDIT 風なら、いちばん上の行とファンクションキーの欄を取って、残りを返す
        func carveSeditRows(_ area: NSRect) -> NSRect {
            guard sedit else { return area }
            let row = (Sedit.rowHeight * seditScale).rounded()
            seditLine.frame = NSRect(x: area.minX, y: area.minY, width: area.width, height: row)
            functionBar.frame = NSRect(x: area.minX, y: max(area.minY, area.maxY - row), width: area.width, height: row)
            return NSRect(x: area.minX, y: area.minY + row, width: area.width, height: max(0, area.height - row * 2))
        }
        /// 本文の欄から、スクロールする部分を取る。SEDIT 風はファンクションキーの欄の上にすき間をあける
        /// （本文の背景はすき間にも敷くので、テーマの色・半透明・背景画像はそのままつながる）
        func scrollFrame(in text: NSRect) -> NSRect {
            guard sedit else { return text }
            return NSRect(x: text.minX, y: text.minY, width: text.width, height: max(0, text.height - Sedit.editorMargin))
        }

        guard Settings.shared.classicUI else {
            rootView.clientRect = .zero
            statusBar.frame = NSRect(x: 0, y: bounds.height - StatusBarView.height, width: bounds.width, height: StatusBarView.height)
            let text = carveSeditRows(NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - statusHeight)))
            scrollView.frame = scrollFrame(in: text)
            backgroundView.frame = text
            return
        }

        let border = Classic.frameWidth
        let innerWidth = max(0, bounds.width - border * 2)
        titleBar.frame = NSRect(x: border, y: border, width: innerWidth, height: Classic.captionHeight)
        menuBar.frame = NSRect(x: border, y: titleBar.frame.maxY + 1, width: innerWidth, height: Classic.menuBarHeight)
        statusBar.frame = NSRect(x: border, y: bounds.height - border - StatusBarView.height, width: innerWidth, height: StatusBarView.height)

        // 本文のまわりは 2pt のへこみ（Windows の WS_EX_CLIENTEDGE）
        let client = NSRect(x: border, y: menuBar.frame.maxY, width: innerWidth,
                            height: max(0, bounds.height - border - statusHeight - menuBar.frame.maxY))
        rootView.clientRect = client
        let inner = carveSeditRows(client.insetBy(dx: 2, dy: 2))
        let barSize = Classic.scrollBarSize
        let showHorizontal = !Settings.shared.wordWrap
        let text = NSRect(x: inner.minX, y: inner.minY, width: max(0, inner.width - barSize),
                          height: max(0, inner.height - (showHorizontal ? barSize : 0)))
        scrollView.frame = scrollFrame(in: text)
        backgroundView.frame = text
        rootView.textRect = text
        verticalBar.frame = NSRect(x: text.maxX, y: text.minY, width: barSize, height: text.height)
        horizontalBar.isHidden = !showHorizontal
        horizontalBar.frame = NSRect(x: text.minX, y: text.maxY, width: text.width, height: barSize)
        rootView.needsDisplay = true
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

    /// マクロの記録を始めた／やめたとき
    func refreshTitle() {
        updateTitle()
        updateStatusNow()
    }

    private func updateTitle() {
        let recording = MacroRecorder.shared.isRecording ? "  [マクロ記録中]" : ""
        window.title = (isDirty ? "*" : "") + displayName + " - " + AppInfo.name + recording
        window.representedURL = fileURL
        window.isDocumentEdited = isDirty
        titleBar.refresh()
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
        rulerLineCache = nil
        totalLinesCache = nil
        characterCountCache = nil
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

    /// directory: 保存ダイアログを開く場所（nil = 今のファイルのあるところ）
    @discardableResult
    func saveAs(in directory: URL? = nil) -> Bool {
        let suggested = fileURL?.lastPathComponent ?? "無題.txt"
        guard let choice = FilePanels.runSave(suggestedName: suggested,
                                              directory: directory ?? fileURL?.deletingLastPathComponent(),
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

    /// ［ファイル］→［iCloud Drive から開く…］: 開くダイアログを iCloud Drive で開く
    @objc func fileOpenFromICloud(_ sender: Any?) {
        openWithPanel(directory: FilePanels.iCloudDrive)
    }

    /// ［ファイル］→［iCloud Drive に保存…］: 保存ダイアログを iCloud Drive で開く（iPad の「ファイル」からも開ける）
    @objc func fileSaveToICloud(_ sender: Any?) {
        saveAs(in: FilePanels.iCloudDrive)
    }

    @objc func fileOpen(_ sender: Any?) {
        openWithPanel(directory: nil)
    }

    private func openWithPanel(directory: URL?) {
        // 「保存しますか?」やダイアログをキャンセルしたとき・開けんかったときは、マクロの再生もそこでやめる
        guard confirmDiscardIfNeeded(), let choice = FilePanels.runOpen(directory: directory) else {
            MacroRecorder.shared.abortIfPlaying()
            return
        }
        if let other = AppDelegate.shared.controller(showing: choice.url), other !== self {
            other.window.makeKeyAndOrderFront(nil)
            return
        }
        if !load(choice.url, encoding: choice.encoding) {
            MacroRecorder.shared.abortIfPlaying()
        }
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
        guard alert.runModal() == .alertFirstButtonReturn else {
            MacroRecorder.shared.abortIfPlaying()
            return
        }

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

    /// ［編集］→［ファイルを挿入…］（SEDIT の f・4）: 選んだファイルの中身をカーソルの位置に入れる
    @objc func insertFile(_ sender: Any?) {
        guard let choice = FilePanels.runOpen() else {
            MacroRecorder.shared.abortIfPlaying()
            return
        }
        let loaded: FileIO.Loaded
        do {
            loaded = try FileIO.load(choice.url, encoding: choice.encoding)
        } catch {
            showError("「\(choice.url.lastPathComponent)」を読めませんでした。", error)
            return
        }
        // 打ってた文字とは別の「元に戻す」にする
        let range = textView.selectedRange()
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: loaded.text) else { return }
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: loaded.text, attributes: textAttributes))
        textView.didChangeText()
        textView.undoManager?.setActionName("ファイルの挿入")
        textView.setSelectedRange(NSRange(location: range.location + (loaded.text as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        if loaded.lossy {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "一部の文字を正しく読み込めませんでした。"
            alert.informativeText = "\(loaded.encoding.displayName) として入れました。文字化けしている場合は、元に戻してから、開くダイアログの「文字コード」を指定して入れ直してください。"
            alert.runModal()
        }
    }

    // MARK: - SEDIT 風のファンクションキー（F1〜F10 と、下の欄のクリック）

    func performSeditFunction(_ number: Int) {
        MacroRecorder.shared.record(.sedit(number))
        switch number {
        case 1: textView.cut(nil)
        case 2: textView.copy(nil)
        case 3: textView.paste(nil)
        case 4: insertFile(nil)
        case 5: popUpControlMenu()
        case 6: showFindPanel(nil)
        case 7: findNextMatch(nil)
        case 8: showReplacePanel(nil)
        case 9: goToLine(nil)
        case 10: window.performClose(nil)
        default: break
        }
    }

    /// ｺﾝﾄﾛｰﾙ: ［ファイル］メニューをその場に出す
    private func popUpControlMenu() {
        // SEDIT 風でないとき（それで記録したマクロを再生したときなど）は、下の欄が無いので出さない
        guard functionBar.window != nil else {
            NSSound.beep()
            return
        }
        guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "ファイル" })?.submenu,
              let menu = fileMenu.copy() as? NSMenu else { return }
        let rect = functionBar.itemRect(4)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY), in: functionBar)
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
        rulerLineCache = nil
        totalLinesCache = nil
        characterCountCache = nil
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

    func lineNumber(at location: Int) -> Int {
        return lineNumber(at: location, cache: &lineCache)
    }

    func rulerLineNumber(at location: Int) -> Int {
        return lineNumber(at: location, cache: &rulerLineCache)
    }

    /// 前に数えた位置からの差だけ数える
    private func lineNumber(at location: Int, cache: inout (location: Int, line: Int)?) -> Int {
        let target = max(0, min(location, textStorage.length))
        let line: Int
        if let known = cache {
            if target >= known.location {
                line = known.line + countNewlines(in: NSRange(location: known.location, length: target - known.location))
            } else {
                line = known.line - countNewlines(in: NSRange(location: target, length: known.location - target))
            }
        } else {
            line = 1 + countNewlines(in: NSRange(location: 0, length: target))
        }
        cache = (location: target, line: line)
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
        refreshRulers()
        let settings = Settings.shared
        if settings.seditMode {
            let path = fileURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "無題"
            seditLine.update(path: path, line: lineNumber(at: caretLocation), totalLines: totalLineCount,
                             column: columnNumber(at: caretLocation),
                             characters: settings.showCharacterCount ? characterCountText(unit: "") : nil,
                             isRecording: MacroRecorder.shared.isRecording,
                             encoding: encoding, lineEnding: lineEnding)
            return
        }
        guard settings.showStatusBar else { return }
        statusBar.showsCharacterCount = settings.showCharacterCount
        statusBar.update(line: lineNumber(at: caretLocation),
                         column: columnNumber(at: caretLocation),
                         characters: settings.showCharacterCount ? characterCountText(unit: " 文字") : "",
                         zoom: zoomPercent,
                         lineEnding: lineEnding,
                         encoding: encoding)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let cache = lineCache, affectedCharRange.location < cache.location {
            lineCache = nil
        }
        if let cache = rulerLineCache, affectedCharRange.location < cache.location {
            rulerLineCache = nil
        }
        // 全体の行数は、変わる分の改行だけ数えて足し引きする（1 字打つたびに全部数え直さない）
        if let total = totalLinesCache, let replacement = replacementString {
            let removed = countNewlines(in: affectedCharRange)
            let added = replacement.utf16.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            totalLinesCache = total - removed + added
        } else {
            totalLinesCache = nil
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        characterCountCache = nil
        textView.invalidateEndOfText()
        if let undoManager = textView.undoManager, undoManager.isUndoing || undoManager.isRedoing {
            lineCache = nil
            rulerLineCache = nil
            totalLinesCache = nil   // 元に戻すは shouldChangeTextIn を通らんことがあるので数え直す
            // 元に戻すと、そのときの色や大きさ（テーマやズームを変える前）まで戻ってくるので、今のに揃え直す
            textStorage.beginEditing()
            textStorage.setAttributes(textAttributes, range: NSRange(location: 0, length: textStorage.length))
            textStorage.endEditing()
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
        AppDelegate.shared.controllerWillClose(self)
    }

    // Windows 2000 風のタイトルバーは、アクティブかどうかで色が変わり、最大化でボタンの絵が変わる
    func windowDidBecomeKey(_ notification: Notification) {
        titleBar.refresh()
    }

    func windowDidResignKey(_ notification: Notification) {
        titleBar.refresh()
    }

    func windowDidResize(_ notification: Notification) {
        titleBar.refresh()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard classicAfterFullScreenExit else { return }
        classicAfterFullScreenExit = false
        applyClassicUI()
        // 全画面を抜けると、全画面に入る前の presentationOptions に戻されるので掛け直す
        AppDelegate.shared.applyPresentationOptions()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        classicAfterFullScreenExit = false
    }
}
