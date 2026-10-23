import AppKit

/// ［表示］→［SEDIT 風］。PC-98 の MS-DOS 5 に付いてた SEDIT（Ver. 1.03）の画面:
/// 黒地に白、一番上にファイル名と位置の行、改行に黄色い ↓、最後に [EOF]、下にファンクションキーの欄。
/// SEDIT の 1 ドットを 1pt で描く（PC-9800 フォント 16pt = 1 行 16 ドット、半角 8 ドット）
enum Sedit {
    // PC-98 のデジタル 8 色
    static let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let cyan = NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)
    static let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    static let yellow = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)

    static let rowHeight: CGFloat = 16
    static let cellWidth: CGFloat = 8

    static var font: NSFont {
        return NSFont(name: Settings.pc98FontName, size: 16) ?? Settings.monospaceFont
    }

    static let theme = EditorTheme(id: "sedit", name: "SEDIT", appearanceName: .darkAqua,
                                   text: Sedit.white, background: Sedit.black, selection: Sedit.white,
                                   cursor: Sedit.white, selectionText: Sedit.black)

    /// PC-9800 フォントのときはアンチエイリアスを切って描く。dot: 1 ドットの大きさ（pt）。
    /// 縮小して 1 ドットが画面の 1 ピクセルより小さいときは、線が消えるので切らない
    static func drawPixelText(dot: CGFloat = 1, _ body: () -> Void) {
        guard NSFont(name: Settings.pc98FontName, size: 16) != nil, let context = NSGraphicsContext.current?.cgContext,
              abs(context.convertToDeviceSpace(CGSize(width: dot, height: dot)).width) >= 0.99 else {
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
                         foreground: NSColor = black) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let width = ceil((text as NSString).size(withAttributes: attributes).width)
        background.setFill()
        NSRect(x: x, y: 0, width: width, height: height).fill()
        (text as NSString).draw(at: NSPoint(x: x, y: ((height - rowHeight) / 2).rounded()), withAttributes: attributes)
        return x + width
    }

    static func textWidth(_ text: String) -> CGFloat {
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
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

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return true }

    func update(path: String, line: Int, totalLines: Int, column: Int, encoding: TextEncoding, lineEnding: LineEnding) {
        self.path = path
        self.line = line
        self.totalLines = totalLines
        self.column = column
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
        // 数字は白地、見出しは水色地（SEDIT と同じ）
        let segments: [(String, NSColor)] = [
            ("<挿入>  ", Sedit.cyan),
            (SeditStatusLine.pad(line, 5), Sedit.white),
            ("/" + SeditStatusLine.pad(totalLines, 6) + "行 ", Sedit.cyan),
            (SeditStatusLine.pad(column, 4), Sedit.white),
            ("桁  ", Sedit.cyan),
            (" " + encoding + " ", Sedit.white),
            (" " + lineEnding + " ", Sedit.cyan),
        ]
        let rightWidth = segments.reduce(0) { $0 + Sedit.textWidth($1.0) }
        // 場所が長いときは頭を「…」にして、右の欄を押し出さない
        var shownPath = path
        let available = bounds.width - rightWidth - Sedit.cellWidth * 2
        while !shownPath.isEmpty, Sedit.textWidth(shownPath) > available {
            shownPath = "…" + shownPath.dropFirst(shownPath.hasPrefix("…") ? 2 : 1)
            if shownPath == "…" { break }
        }
        Sedit.drawPixelText {
            let pathEnd = Sedit.drawCell(shownPath, at: 0, height: height, background: Sedit.white)
            var x = max(pathEnd + Sedit.cellWidth * 2, bounds.width - rightWidth)
            for (text, background) in segments {
                x = Sedit.drawCell(text, at: x, height: height, background: background)
            }
        }
    }
}

/// 下のファンクションキーの欄。数字は黄色地、名前は緑地。クリックでも F1〜F10 と同じ
final class SeditFunctionBar: NSView {
    static let labels = ["切取り", " 複写 ", "貼付け", "ﾌｧｲﾙ挿", "ｺﾝﾄﾛｰﾙ", " 検索 ", "次検索", " 置換 ", "ｼﾞｬﾝﾌﾟ", " 終了 "]
    /// 幅が 640 に足りんときの短い名前（4 桁）
    static let shortLabels = ["切取", "複写", "貼付", "挿入", "ｺﾝﾄ", "検索", "次検", "置換", "ｼﾞｬﾝ", "終了"]

    /// SEDIT と同じ 8 桁ずつ（640pt）入るか。入らんときは 6 桁ずつ・すき間なしに詰める
    private var isCompact: Bool {
        return bounds.width < Sedit.cellWidth * 80
    }

    /// 押されたキーの番号（1〜10）
    var onPress: ((Int) -> Void)?

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    /// 1 つ 8 桁（数字 1 + 名前 6 + すき間 1）。5 と 6 のあいだは 1 桁あける。
    /// 狭いときは 6 桁（数字 1 + 短い名前 4 + すき間 1）
    func itemRect(_ index: Int) -> NSRect {
        let cell = Sedit.cellWidth
        if isCompact {
            return NSRect(x: CGFloat(index) * cell * 6, y: 0, width: cell * 5, height: bounds.height)
        }
        let x = CGFloat(index) * cell * 8 + (index >= 5 ? cell : 0)
        return NSRect(x: x, y: 0, width: cell * 7, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Sedit.black.setFill()
        bounds.fill()
        let height = bounds.height
        Sedit.drawPixelText {
            let labels = isCompact ? SeditFunctionBar.shortLabels : SeditFunctionBar.labels
            for (index, label) in labels.enumerated() {
                let rect = itemRect(index)
                let digitEnd = Sedit.drawCell(String((index + 1) % 10), at: rect.minX, height: height, background: Sedit.yellow)
                Sedit.drawCell(label, at: digitEnd, height: height, background: Sedit.green)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = (0..<SeditFunctionBar.labels.count).first(where: { itemRect($0).contains(point) }) else { return }
        onPress?(index + 1)
    }
}
