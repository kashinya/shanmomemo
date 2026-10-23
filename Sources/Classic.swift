import AppKit

/// Windows 2000 風の見た目（［表示］→［Windows 2000 風］）。
/// Windows の 1 ピクセルを 1pt で描く（Retina ではちょうど 2 倍）。部品はどれも isFlipped（上が y = 0）で描く。
enum Classic {
    static let face = NSColor(srgbRed: 0xD4 / 255, green: 0xD0 / 255, blue: 0xC8 / 255, alpha: 1)
    static let highlight = NSColor.white
    static let shadow = NSColor(srgbRed: 0x80 / 255, green: 0x80 / 255, blue: 0x80 / 255, alpha: 1)
    static let darkShadow = NSColor(srgbRed: 0x40 / 255, green: 0x40 / 255, blue: 0x40 / 255, alpha: 1)
    static let activeCaption = (NSColor(srgbRed: 0x0A / 255, green: 0x24 / 255, blue: 0x6A / 255, alpha: 1),
                                NSColor(srgbRed: 0xA6 / 255, green: 0xCA / 255, blue: 0xF0 / 255, alpha: 1))
    static let inactiveCaption = (NSColor(srgbRed: 0x80 / 255, green: 0x80 / 255, blue: 0x80 / 255, alpha: 1),
                                  NSColor(srgbRed: 0xC0 / 255, green: 0xC0 / 255, blue: 0xC0 / 255, alpha: 1))

    static let frameWidth: CGFloat = 4
    static let captionHeight: CGFloat = 18
    static let menuBarHeight: CGFloat = 19
    static let scrollBarSize: CGFloat = 16

    static let uiFont = NSFont.systemFont(ofSize: 12)
    static let captionFont = NSFont.boldSystemFont(ofSize: 12)

    /// 立体の縁。外側から順に (左上の色, 右下の色) を 1pt ずつ
    typealias Edge = [(NSColor, NSColor)]
    static let raised: Edge = [(Classic.face, Classic.darkShadow), (Classic.highlight, Classic.shadow)]    // ボタン・ウィンドウの外枠
    static let pressed: Edge = [(Classic.darkShadow, Classic.highlight), (Classic.shadow, Classic.face)]   // 押したボタン
    static let sunken: Edge = [(Classic.shadow, Classic.highlight), (Classic.darkShadow, Classic.face)]    // 本文まわり
    static let thinRaised: Edge = [(Classic.highlight, Classic.shadow)]   // メニューにマウスが乗ったとき
    static let thinSunken: Edge = [(Classic.shadow, Classic.highlight)]   // メニューを開いたとき・ステータスバーの欄

    static func drawEdge(_ rect: NSRect, _ edge: Edge) {
        var r = rect
        for (topLeft, bottomRight) in edge {
            guard r.width >= 2, r.height >= 2 else { return }
            bottomRight.setFill()
            NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
            NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
            topLeft.setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width - 1, height: 1).fill()
            NSRect(x: r.minX, y: r.minY, width: 1, height: r.height - 1).fill()
            r = r.insetBy(dx: 1, dy: 1)
        }
    }

    /// スクロールバーの溝の網目（白とボタン色の市松）
    static let trackColor: NSColor = {
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { _ in
            Classic.face.setFill()
            NSRect(x: 0, y: 0, width: 2, height: 2).fill()
            Classic.highlight.setFill()
            NSRect(x: 0, y: 0, width: 1, height: 1).fill()
            NSRect(x: 1, y: 1, width: 1, height: 1).fill()
            return true
        }
        return NSColor(patternImage: image)
    }()
}

/// 本文のウィンドウ。Windows 2000 風のときは枠なし（四角い角）にして、タイトルバーやボタンは自分で描く
final class EditorWindow: NSWindow {
    private var restoreFrame: NSRect?

    /// 枠なし = Windows 2000 風
    var isClassic: Bool { return !styleMask.contains(.titled) }
    var isClassicMaximized: Bool { return restoreFrame != nil }

    // 枠なしのウィンドウは、これが無いと文字を打てない
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    // 枠なしやと閉じる・しまうボタンが無いので、標準の動きやと鳴るだけになる
    override func performClose(_ sender: Any?) {
        guard isClassic else { return super.performClose(sender) }
        if delegate?.windowShouldClose?(self) ?? true {
            close()
        }
    }

    override func performMiniaturize(_ sender: Any?) {
        guard isClassic else { return super.performMiniaturize(sender) }
        miniaturize(sender)
    }

    override func performZoom(_ sender: Any?) {
        guard isClassic else { return super.performZoom(sender) }
        toggleClassicMaximize()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if isClassic, let action = menuItem.action,
           [#selector(performClose(_:)), #selector(performMiniaturize(_:)), #selector(performZoom(_:))].contains(action) {
            return true
        }
        return super.validateMenuItem(menuItem)
    }

    /// Windows の「最大化」: 画面いっぱい（メニューバーと Dock を除く）と元の大きさを行き来する
    func toggleClassicMaximize() {
        if let frame = restoreFrame {
            restoreFrame = nil
            setFrame(frame, display: true, animate: true)
        } else if let screen = screen ?? NSScreen.main {
            restoreFrame = frame
            setFrame(screen.visibleFrame, display: true, animate: true)
        }
    }

    /// 最大化のあとに手で大きさを変えたら、元の大きさは忘れる
    func forgetClassicMaximize() {
        restoreFrame = nil
    }

    /// Windows 2000 風をやめるとき用: 最大化してたら元の大きさ、してなければ今の大きさ。最大化は忘れる
    func leaveClassicMaximize() -> NSRect {
        defer { restoreFrame = nil }
        return restoreFrame ?? frame
    }
}

/// ウィンドウの中身の土台。Windows 2000 風のときは外枠と本文まわりのへこみを描いて、外枠のドラッグで大きさを変える
final class EditorRootView: NSView {
    var classic = false {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// 本文まわりのへこんだ枠を描く範囲（Windows 2000 風のとき）
    var clientRect: NSRect = .zero
    /// 塗らずに抜いておく範囲（本文の後ろ。背景を半透明にしたときに透けるように）
    var textRect: NSRect = .zero
    var onLayout: (() -> Void)?

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }
    /// 角として扱う長さ（そこを掴むと縦横両方変わる）
    private static let cornerLength: CGFloat = 16

    override var isFlipped: Bool { return true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard classic else { return }
        Classic.face.setFill()
        bounds.fill()
        Classic.drawEdge(bounds, Classic.raised)
        if !clientRect.isEmpty {
            Classic.drawEdge(clientRect, Classic.sunken)
        }
        // Swift の fill() は重ね塗りなので、透明で「塗り替える」には .copy
        NSColor.clear.setFill()
        textRect.fill(using: .copy)
    }

    private func edges(at point: NSPoint) -> Edges {
        let width = Classic.frameWidth
        let corner = EditorRootView.cornerLength
        var edges: Edges = []
        let nearLeft = point.x < width, nearRight = point.x >= bounds.width - width
        let nearTop = point.y < width, nearBottom = point.y >= bounds.height - width
        guard nearLeft || nearRight || nearTop || nearBottom else { return [] }
        if point.x < corner { edges.insert(.left) }
        if point.x >= bounds.width - corner { edges.insert(.right) }
        if point.y < corner { edges.insert(.top) }
        if point.y >= bounds.height - corner { edges.insert(.bottom) }
        return edges
    }

    override func resetCursorRects() {
        guard classic else { return }
        let w = Classic.frameWidth, c = EditorRootView.cornerLength, b = bounds
        addCursorRect(NSRect(x: 0, y: c, width: w, height: b.height - c * 2), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.width - w, y: c, width: w, height: b.height - c * 2), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: c, y: 0, width: b.width - c * 2, height: w), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: c, y: b.height - w, width: b.width - c * 2, height: w), cursor: .resizeUpDown)
        // 角は外枠の太さだけの L 字（中のタイトルバーやボタンに掛からんように）
        for x in [0, b.width - c] {
            addCursorRect(NSRect(x: x, y: 0, width: c, height: w), cursor: .crosshair)
            addCursorRect(NSRect(x: x, y: b.height - w, width: c, height: w), cursor: .crosshair)
        }
        for y in [0, b.height - c] {
            addCursorRect(NSRect(x: 0, y: y, width: w, height: c), cursor: .crosshair)
            addCursorRect(NSRect(x: b.width - w, y: y, width: w, height: c), cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard classic, let window = window as? EditorWindow else { return super.mouseDown(with: event) }
        let edges = self.edges(at: convert(event.locationInWindow, from: nil))
        guard !edges.isEmpty else { return super.mouseDown(with: event) }

        let start = NSEvent.mouseLocation
        let startFrame = window.frame
        let minSize = window.minSize
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type != .leftMouseUp {
            if !dragged {
                dragged = true
                window.forgetClassicMaximize()   // クリックしただけでは忘れない
            }
            // 画面の座標は下が y = 0
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x, dy = now.y - start.y
            var frame = startFrame
            if edges.contains(.left) {
                frame.size.width = max(minSize.width, startFrame.width - dx)
                frame.origin.x = startFrame.maxX - frame.width
            }
            if edges.contains(.right) {
                frame.size.width = max(minSize.width, startFrame.width + dx)
            }
            if edges.contains(.top) {
                frame.size.height = max(minSize.height, startFrame.height + dy)
            }
            if edges.contains(.bottom) {
                frame.size.height = max(minSize.height, startFrame.height - dy)
                frame.origin.y = startFrame.maxY - frame.height
            }
            window.setFrame(frame, display: true)
        }
    }
}

/// タイトルバー: 紺→水色のグラデーション、左にアイコンと題名、右に「_ □ ×」
final class ClassicTitleBar: NSView {
    private let minimizeButton = ClassicCaptionButton(kind: .minimize)
    private let maximizeButton = ClassicCaptionButton(kind: .maximize)
    private let closeButton = ClassicCaptionButton(kind: .close)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        minimizeButton.action = { [weak self] in self?.window?.miniaturize(nil) }
        maximizeButton.action = { [weak self] in (self?.window as? EditorWindow)?.toggleClassicMaximize() }
        closeButton.action = { [weak self] in self?.window?.performClose(nil) }
        for button in [minimizeButton, maximizeButton, closeButton] {
            addSubview(button)
        }
        layoutButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutButtons()
    }

    private func layoutButtons() {
        let y: CGFloat = 2, width: CGFloat = 16, height: CGFloat = 14
        closeButton.frame = NSRect(x: bounds.width - 2 - width, y: y, width: width, height: height)
        maximizeButton.frame = NSRect(x: closeButton.frame.minX - 2 - width, y: y, width: width, height: height)
        minimizeButton.frame = NSRect(x: maximizeButton.frame.minX - width, y: y, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = window?.isKeyWindow ?? false
        let colors = active ? Classic.activeCaption : Classic.inactiveCaption
        NSGradient(starting: colors.0, ending: colors.1)?.draw(in: bounds, angle: 0)

        if let icon = NSApp.applicationIconImage {
            icon.draw(in: NSRect(x: 2, y: 1, width: 16, height: 16), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Classic.captionFont,
            .foregroundColor: active ? NSColor.white : Classic.face,
            .paragraphStyle: paragraph,
        ]
        let title = (window?.title ?? "") as NSString
        let textHeight = title.size(withAttributes: attributes).height
        let textRect = NSRect(x: 21, y: ((bounds.height - textHeight) / 2).rounded(),
                              width: max(0, minimizeButton.frame.minX - 21 - 4), height: textHeight)
        title.draw(in: textRect, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = window as? EditorWindow else { return }
        if event.clickCount == 2 {
            window.toggleClassicMaximize()
        } else {
            window.performDrag(with: event)
        }
    }

    /// 題名・アクティブかどうか・最大化（ボタンの絵が変わる）が変わったら呼ぶ
    func refresh() {
        needsDisplay = true
        maximizeButton.needsDisplay = true
    }
}

/// タイトルバーの「_」「□」「×」ボタン
final class ClassicCaptionButton: NSView {
    enum Kind {
        case minimize, maximize, close
    }

    let kind: Kind
    var action: (() -> Void)?
    private var isPressed = false

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        Classic.face.setFill()
        bounds.fill()
        Classic.drawEdge(bounds, isPressed ? Classic.pressed : Classic.raised)

        let offset: CGFloat = isPressed ? 1 : 0
        func dot(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: NSColor = .black) {
            color.setFill()
            NSRect(x: x + offset, y: y + offset, width: width, height: height).fill()
        }
        switch kind {
        case .minimize:
            dot(4, 9, 6, 2)
        case .maximize:
            if (window as? EditorWindow)?.isClassicMaximized == true {
                // 「元に戻す」: 重なった 2 枚の窓
                dot(6, 2, 6, 2); dot(6, 4, 1, 3); dot(11, 4, 1, 4); dot(9, 7, 3, 1)
                dot(3, 5, 6, 6, Classic.face)
                dot(3, 5, 6, 2); dot(3, 7, 1, 4); dot(8, 7, 1, 4); dot(3, 10, 6, 1)
            } else {
                dot(3, 2, 9, 2); dot(3, 4, 1, 7); dot(11, 4, 1, 7); dot(3, 10, 9, 1)
            }
        case .close:
            for i in 0..<7 {
                let step = CGFloat(i)
                dot(4 + step, 3 + step, 2, 1)
                dot(10 - step, 3 + step, 2, 1)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        display()
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if isPressed != inside {
                isPressed = inside
                display()
            }
            if next.type == .leftMouseUp { break }
        }
        isPressed = false
        display()
        if inside {
            action?()
        }
    }
}

/// ウィンドウの中のメニューバー「ファイル(F) 編集(E) 書式(O) 表示(V) ヘルプ(H)」。
/// 中身は Mac のメニューと同じもの（開いたときの見た目は Mac のメニューになる）
final class ClassicMenuBar: NSView {
    private struct Item {
        let title: String
        let menu: NSMenu
        let rect: NSRect
    }

    private static let accessKeys = ["ファイル": "F", "編集": "E", "書式": "O", "表示": "V", "ヘルプ": "H"]

    private var items: [Item] = []
    private var hotIndex: Int?
    private var openIndex: Int?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    /// Mac のメニューバーから項目を拾い直す（アプリのメニューとウインドウメニューは Windows に無いので出さない）
    func reload() {
        items = []
        guard let mainMenu = NSApp.mainMenu else { return }
        var x: CGFloat = 2
        for top in mainMenu.items.dropFirst() {
            guard let submenu = top.submenu, let key = ClassicMenuBar.accessKeys[top.title] else { continue }
            let title = "\(top.title)(\(key))"
            let width = ceil((title as NSString).size(withAttributes: [.font: Classic.uiFont]).width) + 12
            items.append(Item(title: title, menu: submenu, rect: NSRect(x: x, y: 1, width: width, height: Classic.menuBarHeight - 2)))
            x += width
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Classic.face.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Classic.uiFont, .foregroundColor: NSColor.black]
        for (index, item) in items.enumerated() {
            let isOpen = openIndex == index
            if isOpen {
                Classic.drawEdge(item.rect, Classic.thinSunken)
            } else if hotIndex == index {
                Classic.drawEdge(item.rect, Classic.thinRaised)
            }
            let size = (item.title as NSString).size(withAttributes: attributes)
            let shift: CGFloat = isOpen ? 1 : 0
            let point = NSPoint(x: item.rect.minX + 6 + shift, y: (item.rect.midY - size.height / 2).rounded() + shift)
            (item.title as NSString).draw(at: point, withAttributes: attributes)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return items.firstIndex { $0.rect.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let index = self.index(at: event)
        if index != hotIndex {
            hotIndex = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hotIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = self.index(at: event) else { return }
        let item = items[index]
        openIndex = index
        hotIndex = nil
        display()
        // メインメニューに付いてるメニューをそのまま出すと取り合いになるので、写しを出す
        let menu = (item.menu.copy() as? NSMenu) ?? item.menu
        menu.popUp(positioning: nil, at: NSPoint(x: item.rect.minX, y: item.rect.maxY), in: self)
        openIndex = nil
        needsDisplay = true
    }
}

/// Windows 2000 のスクロールバー: 両端に矢印ボタン、網目の溝、立体のつまみ
final class ClassicScrollBar: NSView {
    enum Orientation {
        case vertical, horizontal
    }

    private enum Part {
        case decrementArrow, incrementArrow, decrementPage, incrementPage, thumb
    }

    private struct Metrics {
        let documentLength: CGFloat
        let visibleLength: CGFloat
        let position: CGFloat
        var maxPosition: CGFloat { return max(0, documentLength - visibleLength) }
    }

    let orientation: Orientation
    private weak var scrollView: NSScrollView?
    private var pressedPart: Part?

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { return true }

    func attach(to scrollView: NSScrollView) {
        self.scrollView = scrollView
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(scrollStateChanged(_:)), name: NSView.boundsDidChangeNotification, object: clipView)
        center.addObserver(self, selector: #selector(scrollStateChanged(_:)), name: NSView.frameDidChangeNotification, object: clipView)
        if let documentView = scrollView.documentView {
            documentView.postsFrameChangedNotifications = true
            center.addObserver(self, selector: #selector(scrollStateChanged(_:)), name: NSView.frameDidChangeNotification, object: documentView)
        }
    }

    @objc private func scrollStateChanged(_ notification: Notification) {
        needsDisplay = true
    }

    // MARK: - 寸法

    private var axisLength: CGFloat { return orientation == .vertical ? bounds.height : bounds.width }
    private var arrowLength: CGFloat { return min(Classic.scrollBarSize, (axisLength / 2).rounded(.down)) }

    private func axis(_ point: NSPoint) -> CGFloat {
        return orientation == .vertical ? point.y : point.x
    }

    private func rect(from start: CGFloat, length: CGFloat) -> NSRect {
        switch orientation {
        case .vertical: return NSRect(x: 0, y: start, width: bounds.width, height: length)
        case .horizontal: return NSRect(x: start, y: 0, width: length, height: bounds.height)
        }
    }

    private var metrics: Metrics? {
        guard let scrollView = scrollView, let documentView = scrollView.documentView else { return nil }
        let visible = scrollView.contentView.bounds
        let document = documentView.frame
        switch orientation {
        case .vertical: return Metrics(documentLength: document.height, visibleLength: visible.height, position: visible.minY)
        case .horizontal: return Metrics(documentLength: document.width, visibleLength: visible.width, position: visible.minX)
        }
    }

    /// つまみの位置と長さ。スクロールできないときは nil（Windows と同じく、つまみを出さずに矢印を灰色にする）
    private var thumb: (start: CGFloat, length: CGFloat)? {
        guard let metrics = metrics, metrics.maxPosition > 0.5 else { return nil }
        let track = axisLength - arrowLength * 2
        guard track >= 8 else { return nil }
        let length = max(8, (track * metrics.visibleLength / metrics.documentLength).rounded())
        let fraction = min(max(metrics.position / metrics.maxPosition, 0), 1)
        return (arrowLength + ((track - length) * fraction).rounded(), length)
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        Classic.trackColor.setFill()
        bounds.fill()
        let enabled = thumb != nil
        drawArrow(in: rect(from: 0, length: arrowLength), decrement: true,
                  pressed: pressedPart == .decrementArrow, enabled: enabled)
        drawArrow(in: rect(from: axisLength - arrowLength, length: arrowLength), decrement: false,
                  pressed: pressedPart == .incrementArrow, enabled: enabled)
        if let thumb = thumb {
            let thumbRect = rect(from: thumb.start, length: thumb.length)
            Classic.face.setFill()
            thumbRect.fill()
            Classic.drawEdge(thumbRect, Classic.raised)
        }
    }

    private func drawArrow(in r: NSRect, decrement: Bool, pressed: Bool, enabled: Bool) {
        Classic.face.setFill()
        r.fill()
        Classic.drawEdge(r, pressed ? [(Classic.shadow, Classic.shadow)] : Classic.raised)
        let shift: CGFloat = pressed ? 1 : 0
        let cx = r.midX.rounded(.down) + shift, cy = r.midY.rounded(.down) + shift

        func triangle(_ color: NSColor, offset: CGFloat) {
            color.setFill()
            for i in 0..<4 {
                let step = CGFloat(i), size = CGFloat(7 - i * 2)
                let row: NSRect
                switch (orientation, decrement) {
                case (.vertical, true):    // ▲
                    row = NSRect(x: cx - 3 + step, y: cy + 1 - step, width: size, height: 1)
                case (.vertical, false):   // ▼
                    row = NSRect(x: cx - 3 + step, y: cy - 2 + step, width: size, height: 1)
                case (.horizontal, true):  // ◀
                    row = NSRect(x: cx + 1 - step, y: cy - 3 + step, width: 1, height: size)
                case (.horizontal, false): // ▶
                    row = NSRect(x: cx - 2 + step, y: cy - 3 + step, width: 1, height: size)
                }
                row.offsetBy(dx: offset, dy: offset).fill()
            }
        }
        if enabled {
            triangle(.black, offset: 0)
        } else {
            triangle(Classic.highlight, offset: 1)
            triangle(Classic.shadow, offset: 0)
        }
    }

    // MARK: - 操作

    private func part(at position: CGFloat) -> Part? {
        guard let thumb = thumb else { return nil }
        if position < arrowLength { return .decrementArrow }
        if position >= axisLength - arrowLength { return .incrementArrow }
        if position < thumb.start { return .decrementPage }
        if position >= thumb.start + thumb.length { return .incrementPage }
        return .thumb
    }

    override func mouseDown(with event: NSEvent) {
        let start = axis(convert(event.locationInWindow, from: nil))
        guard let pressed = part(at: start) else { return }
        if pressed == .thumb {
            dragThumb(grabbedAt: start)
            return
        }
        pressedPart = pressed
        perform(pressed)
        display()
        // 押しっぱなしで繰り返す（Windows と同じく、少し待ってから速く）
        NSEvent.startPeriodicEvents(afterDelay: 0.35, withPeriod: 0.05)
        var position = start
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged, .periodic]), next.type != .leftMouseUp {
            if next.type == .leftMouseDragged {
                position = axis(convert(next.locationInWindow, from: nil))
            } else if part(at: position) == pressed {
                perform(pressed)
                display()
            }
        }
        NSEvent.stopPeriodicEvents()
        pressedPart = nil
        needsDisplay = true
    }

    private func dragThumb(grabbedAt start: CGFloat) {
        guard let grabbed = thumb else { return }
        let grabOffset = start - grabbed.start
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]), next.type != .leftMouseUp {
            guard let thumb = thumb, let metrics = metrics else { break }
            let travel = axisLength - arrowLength * 2 - thumb.length
            guard travel > 0 else { continue }
            let position = axis(convert(next.locationInWindow, from: nil))
            let fraction = (position - grabOffset - arrowLength) / travel
            scroll(to: fraction * metrics.maxPosition)
            display()
        }
    }

    private func perform(_ part: Part) {
        guard let scrollView = scrollView, let metrics = metrics else { return }
        let line = orientation == .vertical ? scrollView.verticalLineScroll : scrollView.horizontalLineScroll
        let page = max(line, metrics.visibleLength - line)
        switch part {
        case .decrementArrow: scroll(to: metrics.position - line)
        case .incrementArrow: scroll(to: metrics.position + line)
        case .decrementPage: scroll(to: metrics.position - page)
        case .incrementPage: scroll(to: metrics.position + page)
        case .thumb: break
        }
    }

    private func scroll(to position: CGFloat) {
        guard let scrollView = scrollView, let metrics = metrics else { return }
        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        let clamped = min(max(position.rounded(), 0), metrics.maxPosition)
        switch orientation {
        case .vertical: origin.y = clamped
        case .horizontal: origin.x = clamped
        }
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}
