import AppKit

/// 行番号（本文の左）と桁ルーラー（本文の上、MIFES の「....+....1....+....2」）の見た目
enum RulerStyle {
    case mac       // 薄い帯に灰色の数字と目盛り
    case classic   // Windows 2000 のボタン色の帯に黒い字
    case sedit     // 黒地に水色の字、カーソルのところは黄色
}

/// ルーラーが本文の様子を聞く先（EditorWindowController）
protocol RulerSource: AnyObject {
    var rulerStyle: RulerStyle { get }
    /// 本文のフォント（ズーム込み）
    var rulerFont: NSFont { get }
    /// 本文の地の色（不透明度込み）と字の色
    var rulerBackground: NSColor { get }
    var rulerText: NSColor { get }
    var currentLineNumber: Int { get }
    var totalLineCount: Int { get }
    /// カーソルの左端の x（本文の View の座標）
    var caretX: CGFloat? { get }
    /// 行番号のルーラー用（カーソルの行の数え直しと取り合いにならんよう、別に覚えておく）
    func rulerLineNumber(at location: Int) -> Int
}

private extension RulerSource {
    /// Mac と Windows 2000 の数字は、本文より少し小さい等幅数字
    var smallNumberFont: NSFont {
        return NSFont.monospacedDigitSystemFont(ofSize: max(9, min(18, (rulerFont.pointSize * 0.8).rounded())), weight: .regular)
    }
}

private let navy = NSColor(srgbRed: 0x0A / 255, green: 0x24 / 255, blue: 0x6A / 255, alpha: 1)

/// 左の行番号。折り返した続きの行には番号を付けない（MIFES と同じ）
final class LineNumberRuler: NSRulerView {
    weak var source: RulerSource?

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = 40
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// 上が y = 0 で描く（目印は使ってないので、ルーラー本来の向きは関係ない）
    override var isFlipped: Bool { return true }

    /// 行数の桁に合わせて幅を変える（最低 3 桁）
    func updateThickness() {
        guard let source = source else { return }
        let digits = CGFloat(max(3, String(source.totalLineCount).count))
        let thickness: CGFloat
        switch source.rulerStyle {
        case .sedit:
            thickness = (digits + 1) * (source.rulerFont.pointSize / 2).rounded()   // 半角で数字ぶん + 1 桁あけ
        case .mac, .classic:
            let digitWidth = ("0" as NSString).size(withAttributes: [.font: source.smallNumberFont]).width
            thickness = ceil(digits * digitWidth + 16)
        }
        if abs(ruleThickness - thickness) > 0.5 {
            ruleThickness = thickness
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let source = source else { return }
        let style = source.rulerStyle
        switch style {
        case .mac:
            // 透けさせない（本文が半透明でも、ルーラーは本文の地の色で塗る）
            source.rulerBackground.setFill()
            bounds.fill()
            source.rulerText.withAlphaComponent(0.05).setFill()
            bounds.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        case .classic:
            Classic.face.setFill()
            bounds.fill()
            Classic.shadow.setFill()
            NSRect(x: bounds.maxX - 2, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
            Classic.highlight.setFill()
            NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        case .sedit:
            // 塗らずに、後ろの背景（黒・半透明・背景画像）を見せる。本文の字はルーラーの下には入らん（EditorScrollView）
            break
        }

        guard let textView = clientView as? NSTextView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let string = textView.textStorage?.mutableString else { return }
        let origin = textView.textContainerOrigin
        let current = source.currentLineNumber
        let font = style == .sedit ? source.rulerFont : source.smallNumberFont

        func drawNumber(_ number: Int, fragment: NSRect) {
            let rect = convert(NSRect(x: 0, y: fragment.minY + origin.y, width: 1, height: fragment.height), from: textView)
            guard rect.maxY >= dirtyRect.minY, rect.minY <= dirtyRect.maxY else { return }
            let isCurrent = number == current
            let color: NSColor
            switch style {
            case .mac: color = isCurrent ? source.rulerText : source.rulerText.withAlphaComponent(0.45)
            case .classic: color = isCurrent ? navy : .black
            case .sedit: color = isCurrent ? Sedit.yellow : Sedit.cyan
            }
            let text = String(number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = text.size(withAttributes: attributes)
            let rightPadding = style == .sedit ? (font.pointSize / 2).rounded() : 8
            let point = NSPoint(x: (bounds.maxX - rightPadding - size.width).rounded(),
                                y: (rect.midY - size.height / 2).rounded(.down))
            if style == .sedit {
                Sedit.drawPixelText(dot: font.pointSize / 16) { text.draw(at: point, withAttributes: attributes) }
            } else {
                text.draw(at: point, withAttributes: attributes)
            }
        }

        // 見えてる行だけ。最初の行の番号だけ数えて、あとは 1 ずつ足す
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        var glyph = glyphRange.location
        var number: Int?
        while glyph < NSMaxRange(glyphRange) {
            var fragmentRange = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentRange)
            guard fragmentRange.length > 0 else { break }
            let character = layoutManager.characterIndexForGlyph(at: fragmentRange.location)
            if character == 0 || string.character(at: character - 1) == 10 {
                let value = number.map { $0 + 1 } ?? source.rulerLineNumber(at: character)
                number = value
                drawNumber(value, fragment: fragment)
            }
            glyph = NSMaxRange(fragmentRange)
        }
        // 最後の改行のあとの空の行
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty {
            drawNumber(source.totalLineCount, fragment: extra)
        }
    }
}

/// 上の桁ルーラー。半角 1 文字ぶんを 1 桁として、カーソルのある桁に印を付ける
final class ColumnRuler: NSRulerView {
    weak var source: RulerSource?

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .horizontalRuler)
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = 18
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    func updateThickness() {
        guard let source = source else { return }
        let thickness: CGFloat
        switch source.rulerStyle {
        case .mac: thickness = 18
        case .classic: thickness = max(16, ceil(source.rulerFont.pointSize) + 2)
        case .sedit: thickness = ceil(source.rulerFont.pointSize)   // SEDIT の 1 行ぶん
        }
        if abs(ruleThickness - thickness) > 0.5 {
            ruleThickness = thickness
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let source = source else { return }
        let style = source.rulerStyle
        switch style {
        case .mac:
            // 透けさせない（本文が半透明でも、ルーラーは本文の地の色で塗る）
            source.rulerBackground.setFill()
            bounds.fill()
            source.rulerText.withAlphaComponent(0.05).setFill()
            bounds.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: dirtyRect.minX, y: bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
        case .classic:
            Classic.face.setFill()
            bounds.fill()
            Classic.shadow.setFill()
            NSRect(x: dirtyRect.minX, y: bounds.maxY - 2, width: dirtyRect.width, height: 1).fill()
            Classic.highlight.setFill()
            NSRect(x: dirtyRect.minX, y: bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
        case .sedit:
            // 塗らずに、後ろの背景（黒・半透明・背景画像）を見せる。本文の字はルーラーの下には入らん（EditorScrollView）
            break
        }

        guard let textView = clientView as? NSTextView, let container = textView.textContainer else { return }
        let font = source.rulerFont
        let cell = (" " as NSString).size(withAttributes: [.font: font]).width
        guard cell > 0.5 else { return }
        let textStart = textView.textContainerOrigin.x + container.lineFragmentPadding
        let x0 = convert(NSPoint(x: textStart, y: 0), from: textView).x
        let first = max(0, Int(((dirtyRect.minX - x0) / cell).rounded(.down)))
        let last = max(first, Int(((dirtyRect.maxX - x0) / cell).rounded(.up)))
        // カーソルはちょうど桁の境目にあるので、割り算の誤差で 1 つ手前にならんよう少し足す
        let caretColumn: Int? = source.caretX.map { Int(((convert(NSPoint(x: $0, y: 0), from: textView).x - x0) / cell + 0.01).rounded(.down)) }

        // 横にスクロールしたとき、行番号の上に目盛りが出んよう、本文の左端から右だけに描く
        if let scrollView = scrollView {
            let clipLeft = convert(scrollView.contentView.frame.origin, from: scrollView).x
            NSBezierPath(rect: NSRect(x: clipLeft, y: bounds.minY, width: max(0, bounds.maxX - clipLeft), height: bounds.height)).addClip()
        }

        // カーソルのある桁
        if let column = caretColumn, column >= 0 {
            let rect = NSRect(x: x0 + CGFloat(column) * cell, y: 0, width: cell, height: bounds.height - (style == .sedit ? 0 : 2))
            switch style {
            case .mac: NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            case .classic: navy.setFill()
            case .sedit: Sedit.yellow.setFill()
            }
            rect.fill()
        }

        switch style {
        case .mac:
            // 1 桁ごとに短い目盛り、5 桁で中くらい、10 桁で長い目盛りと数字
            let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            let tick = source.rulerText.withAlphaComponent(0.45)
            for column in first...last {
                let x = (x0 + CGFloat(column) * cell).rounded(.down)
                let length: CGFloat = column % 10 == 0 ? 7 : (column % 5 == 0 ? 5 : 3)
                tick.setFill()
                NSRect(x: x, y: bounds.maxY - 1 - length, width: 1, height: length).fill()
                if column % 10 == 0, column > 0 {
                    (String(column) as NSString).draw(at: NSPoint(x: x + 2, y: 0),
                                                      withAttributes: [.font: labelFont, .foregroundColor: tick])
                }
            }
        case .classic, .sedit:
            // MIFES と同じ「....+....1....+....2」を、本文と同じフォントで桁に合わせて並べる
            let top = ((bounds.height - (style == .sedit ? 0 : 2) - font.pointSize) / 2).rounded(.down)
            let draw = {
                for column in first...last {
                    let number = column + 1
                    let mark: String
                    if number % 10 == 0 {
                        mark = String((number / 10) % 10)
                    } else {
                        mark = number % 5 == 0 ? "+" : "."
                    }
                    let isCaret = column == caretColumn
                    let color: NSColor
                    switch style {
                    case .classic: color = isCaret ? .white : .black
                    default: color = isCaret ? Sedit.black : Sedit.cyan
                    }
                    (mark as NSString).draw(at: NSPoint(x: x0 + CGFloat(column) * cell, y: top),
                                            withAttributes: [.font: font, .foregroundColor: color])
                }
            }
            if style == .sedit {
                Sedit.drawPixelText(dot: font.pointSize / 16, draw)
            } else {
                draw()
            }
        }
    }
}

/// 本文のスクロール。今の NSScrollView は行番号と桁ルーラーを本文の上に重ねる（クリップビューをルーラーの下まで広げて、
/// contentInsets で本文をずらすだけ。CI で測った）ので、スクロールした字がルーラーの下に入る。
/// クリップビューをルーラーの外に置き直して、字がルーラーの下に入らんようにする（SEDIT 風はルーラーを透かして背景を見せる）
final class EditorScrollView: NSScrollView {
    private var isRetiling = false

    override func tile() {
        super.tile()
        guard !isRetiling else { return }
        isRetiling = true
        defer { isRetiling = false }
        var frame = contentView.frame
        if rulersVisible, hasVerticalRuler, let ruler = verticalRulerView, !ruler.isHidden, ruler.frame.maxX > frame.minX {
            frame.size.width = max(0, frame.maxX - ruler.frame.maxX)
            frame.origin.x = ruler.frame.maxX
        }
        if rulersVisible, hasHorizontalRuler, let ruler = horizontalRulerView, !ruler.isHidden, ruler.frame.maxY > frame.minY {
            frame.size.height = max(0, frame.maxY - ruler.frame.maxY)   // この View は上が y = 0
            frame.origin.y = ruler.frame.maxY
        }
        let insets = contentView.contentInsets
        let hasInsets = insets.top != 0 || insets.left != 0 || insets.bottom != 0 || insets.right != 0
        guard frame != contentView.frame || hasInsets else { return }
        if hasInsets {
            // ルーラーのぶんは、ずらすんやなくてクリップビューを小さくして空ける
            automaticallyAdjustsContentInsets = false
            contentInsets = NSEdgeInsets()
            contentView.contentInsets = NSEdgeInsets()
        }
        contentView.frame = frame
        // スクロールの位置を、余白なしで動ける範囲に収め直す
        let constrained = contentView.constrainBoundsRect(contentView.bounds)
        if constrained.origin != contentView.bounds.origin {
            contentView.scroll(to: constrained.origin)
        }
        reflectScrolledClipView(contentView)
    }
}
