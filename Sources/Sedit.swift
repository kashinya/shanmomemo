import AppKit

/// ［表示］→［SEDIT 風］。PC-98 の MS-DOS 5 に付いてた SEDIT（Ver. 1.03）の画面:
/// 黒地に白、一番上にファイル名と位置の行、改行に黄色い ↓、最後に [EOF]、下にファンクションキーの欄。
/// SEDIT の 1 ドットを 1pt で描く（PC-9800 フォント 16pt = 1 行 16 ドット、半角 8 ドット）。ズームすると上の行と下の欄も一緒に大きくなる
enum Sedit {
    // PC-98 のデジタル 8 色
    static let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let cyan = NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)
    static let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    static let yellow = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
    static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    /// ズーム 100% のときの 1 行の高さと半角 1 桁の幅（ズームするとこれに倍率を掛ける）
    static let rowHeight: CGFloat = 16
    static let cellWidth: CGFloat = 8
    /// 本文のまわりのすき間（Mac のときの 6pt＝4pt＋余白 2pt より少し狭く、半角の半分）。
    /// 行番号を出してないときの左と、ファンクションキーの欄の上に取る
    static let editorMargin: CGFloat = 4

    private static var fontCache: [CGFloat: NSFont] = [:]

    /// scale: ズームの倍率（100% = 1）
    static func font(scale: CGFloat = 1) -> NSFont {
        if let font = fontCache[scale] {
            return font
        }
        let size = 16 * scale
        let font = NSFont(name: Settings.pc98FontName, size: size)
            ?? NSFont(descriptor: Settings.monospaceFont.fontDescriptor, size: size) ?? Settings.monospaceFont
        fontCache[scale] = font
        return font
    }

    static let theme = EditorTheme(id: "sedit", name: "SEDIT", appearanceName: .darkAqua,
                                   text: Sedit.white, background: Sedit.black, selection: Sedit.white,
                                   cursor: Sedit.white, selectionText: Sedit.black)

    /// アンチエイリアスを切ってもドットが揃う大きさか。dot: 1 ドットの大きさ（pt）。
    /// 1 ドットがちょうど 1pt・2pt・3pt（ズーム 100%・200%・300%）のときだけ切る。半端な大きさで切ると、
    /// ドットの太さが 1 ピクセルと 2 ピクセルで混ざってガタガタになる。
    /// 1 ドットが画面の 1 ピクセルより小さいときも、線が消えるので切らない
    static func dotsAreCrisp(dot: CGFloat, in context: CGContext) -> Bool {
        guard dot >= 1, abs(dot - dot.rounded()) < 0.001 else { return false }
        return abs(context.convertToDeviceSpace(CGSize(width: dot, height: dot)).width) >= 0.99
    }

    /// PC-9800 フォントのときは、ドットが揃う大きさならアンチエイリアスを切って描く
    static func drawPixelText(dot: CGFloat = 1, _ body: () -> Void) {
        guard NSFont(name: Settings.pc98FontName, size: 16) != nil, let context = NSGraphicsContext.current?.cgContext,
              dotsAreCrisp(dot: dot, in: context) else {
            body()
            return
        }
        context.saveGState()
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        body()
        context.restoreGState()
        context.setAllowsAntialiasing(true)
    }

    /// 地の色を塗って、その上に黒い字。右端の x を返す
    @discardableResult
    static func drawCell(_ text: String, at x: CGFloat, height: CGFloat, background: NSColor,
                         foreground: NSColor = black, scale: CGFloat = 1) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font(scale: scale), .foregroundColor: foreground]
        let width = ceil((text as NSString).size(withAttributes: attributes).width)
        background.setFill()
        NSRect(x: x, y: 0, width: width, height: height).fill()
        (text as NSString).draw(at: NSPoint(x: x, y: ((height - rowHeight * scale) / 2).rounded()), withAttributes: attributes)
        return x + width
    }

    static func textWidth(_ text: String, scale: CGFloat = 1) -> CGFloat {
        return ceil((text as NSString).size(withAttributes: [.font: font(scale: scale)]).width)
    }

    /// 改行の印「↓」のドット（8×16 の升の中、SEDIT の画面から写した）
    static let newlineArrowDots: [(CGFloat, CGFloat)] = {
        let stem: [(CGFloat, CGFloat)] = (2...13).map { (4, CGFloat($0)) }
        let head: [(CGFloat, CGFloat)] = [(2, 8), (6, 8), (2, 9), (6, 9), (3, 10), (5, 10), (3, 11), (5, 11)]
        return stem + head
    }()
}

/// 一番上の行:「ファイル名        <挿入>     1/    12行    1桁  SJIS  CRLF」
final class SeditStatusLine: NSView {
    private var path = "無題"
    private var line = 1
    private var totalLines = 1
    private var column = 1
    private var encoding = ""
    private var lineEnding = ""
    private var characters: String?
    private var isRecording = false

    /// ズームの倍率（100% = 1）
    var scale: CGFloat = 1 {
        didSet {
            if scale != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return true }

    /// characters: 文字数（［表示］→［文字数］のとき）。isRecording: マクロの記録中
    func update(path: String, line: Int, totalLines: Int, column: Int, characters: String?, isRecording: Bool,
                encoding: TextEncoding, lineEnding: LineEnding) {
        self.path = path
        self.line = line
        self.totalLines = totalLines
        self.column = column
        self.characters = characters
        self.isRecording = isRecording
        self.encoding = SeditStatusLine.shortName(encoding)
        self.lineEnding = SeditStatusLine.shortName(lineEnding)
        needsDisplay = true
    }

    private static func shortName(_ encoding: TextEncoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        case .utf16LE: return "UTF-16LE"
        case .utf16BE: return "UTF-16BE"
        case .shiftJIS: return "SJIS"
        case .eucJP: return "EUC"
        }
    }

    private static func shortName(_ ending: LineEnding) -> String {
        switch ending {
        case .crlf: return "CRLF"
        case .lf: return "LF"
        case .cr: return "CR"
        }
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    override func draw(_ dirtyRect: NSRect) {
        Sedit.cyan.setFill()
        bounds.fill()
        let height = bounds.height
        let scale = self.scale
        let cell = Sedit.cellWidth * scale
        // 数字は白地、見出しは水色地（SEDIT と同じ）
        typealias Segment = (String, NSColor, NSColor)   // 文字, 地, 字の色
        var position: [Segment] = []
        if isRecording {
            position.append(("<記録中>", Sedit.red, Sedit.white))
            position.append((" ", Sedit.cyan, Sedit.black))
        }
        position += [
            ("<挿入>  ", Sedit.cyan, Sedit.black),
            (SeditStatusLine.pad(line, 5), Sedit.white, Sedit.black),
            ("/" + SeditStatusLine.pad(totalLines, 6) + "行 ", Sedit.cyan, Sedit.black),
            (SeditStatusLine.pad(column, 4), Sedit.white, Sedit.black),
            ("桁  ", Sedit.cyan, Sedit.black),
        ]
        var characterSegments: [Segment] = []
        if let characters = characters {
            characterSegments = [(" " + characters, Sedit.white, Sedit.black), ("字  ", Sedit.cyan, Sedit.black)]
        }
        var encodingSegments: [Segment] = [(" " + encoding + " ", Sedit.white, Sedit.black)]
        var lineEndingSegments: [Segment] = [(" " + lineEnding + " ", Sedit.cyan, Sedit.black)]
        func width(_ list: [Segment]) -> CGFloat {
            return list.reduce(0) { $0 + Sedit.textWidth($1.0, scale: scale) }
        }
        // 入りきらんときは、文字数 → 文字コード → 改行コード の順に外す（場所は「…」まで縮む）。
        // 左の水色 1 桁・いちばん短い場所「…」・すき間 2 桁のぶんは残す
        let room = bounds.width - cell * 3 - Sedit.textWidth("…", scale: scale)
        if width(position + characterSegments + encodingSegments + lineEndingSegments) > room { characterSegments = [] }
        if width(position + characterSegments + encodingSegments + lineEndingSegments) > room { encodingSegments = [] }
        if width(position + characterSegments + encodingSegments + lineEndingSegments) > room { lineEndingSegments = [] }
        let segments = position + characterSegments + encodingSegments + lineEndingSegments
        let rightWidth = width(segments)
        // 場所が長いときは頭を「…」にして、右の欄を押し出さない
        var shownPath = path
        let available = bounds.width - rightWidth - cell * 3
        while !shownPath.isEmpty, Sedit.textWidth(shownPath, scale: scale) > available {
            shownPath = "…" + shownPath.dropFirst(shownPath.hasPrefix("…") ? 2 : 1)
            if shownPath == "…" { break }
        }
        Sedit.drawPixelText(dot: scale) {
            let pathEnd = Sedit.drawCell(shownPath, at: cell, height: height, background: Sedit.white, scale: scale)   // 左に水色 1 桁
            var x = max(pathEnd + cell * 2, bounds.width - rightWidth)
            for (text, background, foreground) in segments {
                x = Sedit.drawCell(text, at: x, height: height, background: background, foreground: foreground, scale: scale)
            }
        }
    }
}

/// 下のファンクションキーの欄。数字は黄色地、名前は緑地。クリックでも F1〜F10 と同じ
final class SeditFunctionBar: NSView {
    static let labels = ["切取り", " 複写 ", "貼付け", "ﾌｧｲﾙ挿", "ｺﾝﾄﾛｰﾙ", " 検索 ", "次検索", " 置換 ", "ｼﾞｬﾝﾌﾟ", " 終了 "]
    /// 幅が 640 に足りんときの短い名前（4 桁）
    static let shortLabels = ["切取", "複写", "貼付", "挿入", "ｺﾝﾄ", "検索", "次検", "置換", "ｼﾞｬﾝ", "終了"]

    /// 並べ方: 1 つぶんの幅（数字 1 桁 + 名前 + すき間 1 桁）と、5 と 6 のあいだのすき間、左端
    private struct Layout {
        let slot: CGFloat
        let groupGap: CGFloat
        let origin: CGFloat
        let compact: Bool
    }

    /// 80 桁（ズーム 100% で 640pt）入るときは SEDIT と同じ 8 桁ずつを真ん中に。もっと広いときは 1 桁ずつ広げる。
    /// 入らんときは 6 桁ずつ（短い名前）・すき間なしに詰めて、真ん中に
    private var layout: Layout {
        let cell = Sedit.cellWidth * drawScale
        guard bounds.width >= cell * 80 else {
            let span = cell * 6 * 10 - cell   // 最後のキーの後ろのすき間は数えない
            return Layout(slot: cell * 6, groupGap: 0, origin: max(0, ((bounds.width - span) / 2 / cell).rounded() * cell), compact: true)
        }
        let slot = (bounds.width / 10 / cell).rounded(.down) * cell
        let span = slot * 10   // 最後のすき間のぶんを 5 と 6 のあいだに回すので、ちょうど 10 個ぶん
        return Layout(slot: slot, groupGap: cell, origin: ((bounds.width - span) / 2 / cell).rounded() * cell, compact: false)
    }

    /// 押されたキーの番号（1〜10）
    var onPress: ((Int) -> Void)?

    /// ズームの倍率（100% = 1）
    var scale: CGFloat = 1 {
        didSet {
            if scale != oldValue { needsDisplay = true }
        }
    }

    /// 描く倍率。ズームで大きくしたとき、短い名前でも幅に入らんかったら入るところまで小さくする（100% より小さくはせん）
    private var drawScale: CGFloat {
        guard scale > 1 else { return scale }
        let fit = bounds.width / (Sedit.cellWidth * (6 * 10 - 1))
        return min(scale, max(1, fit))
    }

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    /// i 番目のキー（数字 + 名前、すき間は含まない）
    func itemRect(_ index: Int) -> NSRect {
        let layout = self.layout
        let x = layout.origin + CGFloat(index) * layout.slot + (index >= 5 ? layout.groupGap : 0)
        return NSRect(x: x, y: 0, width: layout.slot - Sedit.cellWidth * drawScale, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Sedit.black.setFill()
        bounds.fill()
        let height = bounds.height
        let scale = drawScale
        let cell = Sedit.cellWidth * scale
        let labels = layout.compact ? SeditFunctionBar.shortLabels : SeditFunctionBar.labels
        Sedit.drawPixelText(dot: scale) {
            for (index, label) in labels.enumerated() {
                let rect = itemRect(index)
                Sedit.drawCell(String((index + 1) % 10), at: rect.minX, height: height, background: Sedit.yellow, scale: scale)
                // 名前の欄は広げたぶん緑を伸ばして、字は真ん中に
                let labelRect = NSRect(x: rect.minX + cell, y: 0, width: rect.width - cell, height: height)
                Sedit.green.setFill()
                labelRect.fill()
                let text = label.trimmingCharacters(in: .whitespaces)
                let width = Sedit.textWidth(text, scale: scale)
                // 半端なズームで名前が欄より少し広くなっても、左の数字にかぶせない
                let x = labelRect.minX + max(0, ((labelRect.width - width) / 2 / cell).rounded(.down)) * cell
                Sedit.drawCell(text, at: x, height: height, background: Sedit.green, scale: scale)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = (0..<SeditFunctionBar.labels.count).first(where: { itemRect($0).contains(point) }) else { return }
        onPress?(index + 1)
    }
}
