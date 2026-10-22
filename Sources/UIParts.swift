import AppKit

/// 左上原点で部品を並べたいとき用
final class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

/// 和文フォールバック（ヒラギノ等）が混じっても行の高さを揃える
final class FixedLineHeightDelegate: NSObject, NSLayoutManagerDelegate {
    private(set) var lineHeight: CGFloat = 0
    private(set) var baselineOffset: CGFloat = 0

    func update(for font: NSFont, layoutManager: NSLayoutManager) {
        lineHeight = layoutManager.defaultLineHeight(for: font)
        baselineOffset = layoutManager.defaultBaselineOffset(for: font)
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard lineHeight > 0 else { return false }
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee = self.baselineOffset
        return true
    }
}

/// 本文の文字を描く NSLayoutManager。PC-9800 フォントのときはアンチエイリアスを切って、ドットのギザギザをそのまま出す。
/// NSTextView の draw で切っても途中で戻されることがあるので、グリフを描くところで CGContext ごと切る。
final class EditorLayoutManager: NSLayoutManager {
    /// PC-9800 フォントの 1 ドットの大きさ（pt、1/16 em）。nil = 普通に描く
    var pixelFontDotSize: CGFloat?

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // 1 ドットが画面の 1 ピクセルより小さいと、アンチエイリアスなしでは線ごと消える（三が二になる）ので、そのときは切らない。
        // 描くたびに測るので、Retina と普通の画面のあいだでウィンドウを動かしても合う
        guard let dot = pixelFontDotSize, let context = NSGraphicsContext.current?.cgContext else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let devicePixels = context.convertToDeviceSpace(CGSize(width: dot, height: dot))
        guard min(abs(devicePixels.width), abs(devicePixels.height)) >= 0.99 else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        context.saveGState()
        context.setAllowsAntialiasing(false)   // グラフィックス状態に含まれへんので、下で手で戻す
        context.setShouldAntialias(false)
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        context.restoreGState()
        context.setAllowsAntialiasing(true)
    }
}

/// Windows 10 のメモ帳風ステータスバー:  行 1、列 1 | 100% | Windows (CRLF) | UTF-8
final class StatusBarView: NSView {
    static let height: CGFloat = 22

    private let positionLabel = StatusBarView.makeLabel()
    private let zoomLabel = StatusBarView.makeLabel()
    private let lineEndingLabel = StatusBarView.makeLabel()
    private let encodingLabel = StatusBarView.makeLabel()

    private static let labelFont = NSFont.systemFont(ofSize: 11)

    /// 左から 位置 / ズーム / 改行 / 文字コード の欄幅（右寄せで並べる）。
    /// それぞれ出しうるいちばん長い表示に合わせて詰めてあるので、本文 500pt 幅のウィンドウでも左はじにロゴが入る
    private let columnWidths: [CGFloat] = {
        let attributes: [NSAttributedString.Key: Any] = [.font: StatusBarView.labelFont]
        func width(_ samples: [String]) -> CGFloat {
            let widest = samples.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
            return ceil(widest) + 20   // 区切り線からの余白 10 + 右の余白 4 + ラベル内側の余白 6
        }
        return [
            width(["行 99999、列 9999"]),
            width(["500%"]),
            width(LineEnding.allCases.map { $0.displayName }),
            width(TextEncoding.allCases.map { $0.displayName }),
        ]
    }()

    /// 左はじの SHANMO ロゴ（Resources/StatusLogo.png）
    private let logoView: NSImageView? = {
        guard let image = NSImage(named: "StatusLogo"), image.size.height > 0 else { return nil }
        let height: CGFloat = 16
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.frame = NSRect(x: 8, y: 3, width: (height * image.size.width / image.size.height).rounded(), height: height)
        view.autoresizingMask = [.maxXMargin]
        return view
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let labels = [positionLabel, zoomLabel, lineEndingLabel, encodingLabel]
        var x = frameRect.width
        for index in stride(from: labels.count - 1, through: 0, by: -1) {
            x -= columnWidths[index]
            let label = labels[index]
            label.frame = NSRect(x: x + 10, y: 3, width: columnWidths[index] - 14, height: 16)
            label.autoresizingMask = [.minXMargin]
            addSubview(label)
        }
        if let logoView = logoView {
            addSubview(logoView)
            updateLogoVisibility()
        }
    }

    /// ウィンドウが狭くて欄とぶつかるときはロゴを隠す
    private func updateLogoVisibility() {
        guard let logoView = logoView else { return }
        let columnsLeft = bounds.width - columnWidths.reduce(0, +)
        logoView.isHidden = logoView.frame.maxX + 8 > columnsLeft
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isOpaque: Bool { return true }

    /// 上が y = 0（ラベルとロゴは上下の真ん中なので、どっち向きでも同じ位置）
    override var isFlipped: Bool { return true }

    /// Windows 2000 風: ボタン色の地に、へこんだ欄を並べる
    var classic = false {
        didSet {
            for label in [positionLabel, zoomLabel, lineEndingLabel, encodingLabel] {
                label.textColor = classic ? .black : .secondaryLabelColor
            }
            needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLogoVisibility()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if classic {
            Classic.face.setFill()
            bounds.fill()
            var x = bounds.width
            for width in columnWidths.reversed() {
                x -= width
                Classic.drawEdge(NSRect(x: x + 2, y: 2, width: width - 2, height: bounds.height - 2), Classic.thinSunken)
            }
            Classic.drawEdge(NSRect(x: 0, y: 2, width: max(0, x), height: bounds.height - 2), Classic.thinSunken)
            return
        }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        var x = bounds.width
        for width in columnWidths.reversed() {
            x -= width
            NSRect(x: x, y: 5, width: 1, height: bounds.height - 9).fill()
        }
    }

    func update(line: Int, column: Int, zoom: Int, lineEnding: LineEnding, encoding: TextEncoding) {
        positionLabel.stringValue = "行 \(line)、列 \(column)"
        zoomLabel.stringValue = "\(zoom)%"
        lineEndingLabel.stringValue = lineEnding.displayName
        encodingLabel.stringValue = encoding.displayName
    }

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = StatusBarView.labelFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

/// 開く／保存ダイアログの下に付ける「文字コード」「改行コード」
final class EncodingAccessoryView: NSView {
    private let encodingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var lineEndingPopUp: NSPopUpButton?

    /// encoding が nil なら「自動検出」付き（開く用）。lineEnding が nil なら改行欄なし。
    init(encoding: TextEncoding?, lineEnding: LineEnding?, offersAutoDetect: Bool) {
        let width: CGFloat = lineEnding == nil ? 320 : 580
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 44))

        let label = NSTextField(labelWithString: "文字コード:")
        label.alignment = .right
        label.frame = NSRect(x: 8, y: 14, width: 92, height: 17)
        addSubview(label)

        encodingPopUp.frame = NSRect(x: 104, y: 9, width: 190, height: 26)
        if offersAutoDetect {
            encodingPopUp.addItem(withTitle: "自動検出")
            encodingPopUp.lastItem?.tag = -1
            encodingPopUp.menu?.addItem(NSMenuItem.separator())
        }
        for candidate in TextEncoding.allCases {
            encodingPopUp.addItem(withTitle: candidate.displayName)
            encodingPopUp.lastItem?.tag = candidate.rawValue
        }
        encodingPopUp.selectItem(withTag: encoding?.rawValue ?? -1)
        addSubview(encodingPopUp)

        if let lineEnding = lineEnding {
            let label2 = NSTextField(labelWithString: "改行コード:")
            label2.alignment = .right
            label2.frame = NSRect(x: 304, y: 14, width: 92, height: 17)
            addSubview(label2)

            let popUp = NSPopUpButton(frame: NSRect(x: 400, y: 9, width: 170, height: 26), pullsDown: false)
            for candidate in LineEnding.allCases {
                popUp.addItem(withTitle: candidate.displayName)
                popUp.lastItem?.tag = candidate.rawValue
            }
            popUp.selectItem(withTag: lineEnding.rawValue)
            addSubview(popUp)
            lineEndingPopUp = popUp
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// nil = 自動検出
    var selectedEncoding: TextEncoding? {
        return TextEncoding(rawValue: encodingPopUp.selectedTag())
    }

    var selectedLineEnding: LineEnding? {
        guard let popUp = lineEndingPopUp else { return nil }
        return LineEnding(rawValue: popUp.selectedTag())
    }
}

struct OpenChoice {
    let url: URL
    let encoding: TextEncoding?
}

struct SaveChoice {
    let url: URL
    let encoding: TextEncoding
    let lineEnding: LineEnding
}

enum FilePanels {
    static func runOpen() -> OpenChoice? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        let accessory = EncodingAccessoryView(encoding: nil, lineEnding: nil, offersAutoDetect: true)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return OpenChoice(url: url, encoding: accessory.selectedEncoding)
    }

    static func runSave(suggestedName: String, directory: URL?,
                        encoding: TextEncoding, lineEnding: LineEnding) -> SaveChoice? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        if let directory = directory {
            panel.directoryURL = directory
        }
        let accessory = EncodingAccessoryView(encoding: encoding, lineEnding: lineEnding, offersAutoDetect: false)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return SaveChoice(url: url,
                          encoding: accessory.selectedEncoding ?? encoding,
                          lineEnding: accessory.selectedLineEnding ?? lineEnding)
    }
}

/// 印刷用。画面の折り返しやズームに関係なく、用紙の幅で折り返して黒文字で刷る。
final class PrintTextView: NSTextView {
    private var jobTitleText = ""
    private var retainedStorage: NSTextStorage?
    private var retainedLineHeight: FixedLineHeightDelegate?

    override var printJobTitle: String {
        return jobTitleText
    }

    static func make(text: String, title: String, width: CGFloat) -> PrintTextView {
        let font = Settings.shared.editorFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: EditorWindowController.paragraphStyle(for: font),
            .foregroundColor: NSColor.black,
        ]
        let storage = NSTextStorage(string: text, attributes: attributes)
        let layoutManager = NSLayoutManager()
        let lineHeight = FixedLineHeightDelegate()
        lineHeight.update(for: font, layoutManager: layoutManager)
        layoutManager.delegate = lineHeight
        storage.addLayoutManager(layoutManager)

        let unlimited = CGFloat(Float.greatestFiniteMagnitude)
        let container = NSTextContainer(size: NSSize(width: width, height: unlimited))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let view = PrintTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        view.retainedStorage = storage
        view.retainedLineHeight = lineHeight
        view.jobTitleText = title
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: width, height: 0)
        view.maxSize = NSSize(width: width, height: unlimited)

        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        view.setFrameSize(NSSize(width: width, height: max(ceil(used.height), 1)))
        return view
    }
}
