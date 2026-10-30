import AppKit

/// ［表示］→［テーマ］。本文の文字・背景・選択・カーソルの色と、ウィンドウやメニューの明暗
struct EditorTheme {
    let id: String
    let name: String
    /// ウィンドウやメニューの明暗。nil = システム設定に合わせる
    let appearanceName: NSAppearance.Name?
    let text: NSColor
    let background: NSColor
    let selection: NSColor
    let cursor: NSColor
    /// 選択したところの文字の色。nil = そのまま（テーマの文字色）
    var selectionText: NSColor? = nil

    var appearance: NSAppearance? {
        return appearanceName.flatMap { NSAppearance(named: $0) }
    }

    // 標準の 3 つは macOS の色そのまま（ライト／ダークで自動で変わる）
    static let system = EditorTheme(id: "system", name: "システム設定に合わせる", appearanceName: nil,
                                    text: .textColor, background: .textBackgroundColor,
                                    selection: .selectedTextBackgroundColor, cursor: .textColor)
    static let light = EditorTheme(id: "light", name: "ライト", appearanceName: .aqua,
                                   text: .textColor, background: .textBackgroundColor,
                                   selection: .selectedTextBackgroundColor, cursor: .textColor)
    static let dark = EditorTheme(id: "dark", name: "ダーク", appearanceName: .darkAqua,
                                  text: .textColor, background: .textBackgroundColor,
                                  selection: .selectedTextBackgroundColor, cursor: .textColor)

    // Panic の Prompt のテーマから。設定画面の色見本は薄く（約 52%）描かれてるので、そこから元の色を逆算した近似値。
    // 細い縦棒のカーソルで見えにくい色は、文字色に寄せた
    static let panicLight = EditorTheme(id: "panic-light", name: "Panic Light", appearanceName: .aqua,
                                        text: EditorTheme.rgb(0x000000), background: EditorTheme.rgb(0xFFFFFF),
                                        selection: EditorTheme.rgb(0xB7D5FB), cursor: EditorTheme.rgb(0x000000))
    static let panicDark = EditorTheme(id: "panic-dark", name: "Panic Dark", appearanceName: .darkAqua,
                                       text: EditorTheme.rgb(0xFFFFFF), background: EditorTheme.rgb(0x1B1B1B),
                                       selection: EditorTheme.rgb(0x4E4E4E), cursor: EditorTheme.rgb(0x727272))
    static let panicPalette = EditorTheme(id: "panic-palette", name: "Panic Palette", appearanceName: .darkAqua,
                                          text: EditorTheme.rgb(0xF7F9F3), background: EditorTheme.rgb(0x152434),
                                          selection: EditorTheme.rgb(0xD5E9CB, alpha: 0.35), cursor: EditorTheme.rgb(0xF7F9F3))
    static let neon = EditorTheme(id: "neon", name: "Neon", appearanceName: .darkAqua,
                                  text: EditorTheme.rgb(0xB1FFFF), background: EditorTheme.rgb(0x1D112C),
                                  selection: EditorTheme.rgb(0xE746A9, alpha: 0.5), cursor: EditorTheme.rgb(0xB1FFFF))

    static let all: [EditorTheme] = [system, light, dark, panicLight, panicDark, panicPalette, neon]

    static func named(_ id: String) -> EditorTheme? {
        return all.first { $0.id == id }
    }

    private static func rgb(_ value: Int, alpha: CGFloat = 1) -> NSColor {
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: alpha)
    }
}

/// 本文の後ろにうっすら出す画像。~/Library/Application Support/local.memocho.sedit/BackgroundImage に写しを置く
enum BackgroundImage {
    private static var cache: NSImage?
    private static var loaded = false

    private static var fileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.memocho", isDirectory: true)
            .appendingPathComponent("BackgroundImage")
    }

    static var image: NSImage? {
        if !loaded {
            loaded = true
            if let url = fileURL, let data = try? Data(contentsOf: url) {
                cache = NSImage(data: data)
            }
        }
        return cache
    }

    /// 画像ファイルの中身をそのまま写す（JPEG は JPEG のまま）
    static func set(data: Data) throws {
        guard let image = NSImage(data: data), let url = fileURL else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        cache = image
        loaded = true
    }

    /// ドラッグや貼り付けで来た画像は PNG にして写す
    static func set(image: NSImage) throws {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try set(data: png)
    }

    static func remove() {
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        cache = nil
        loaded = true
    }
}

/// 本文の後ろ: テーマの背景色（不透明度つき）と、うっすらの画像。本文をスクロールしても画像は動かない
final class EditorBackgroundView: NSView {
    var color: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
    var opacity: CGFloat = 1 { didSet { needsDisplay = true } }
    var image: NSImage? { didSet { needsDisplay = true } }
    var imageOpacity: CGFloat = 0.15 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        // システムの色は、ここで今のライト／ダークの色に決まる
        let resolved = color.usingColorSpace(.sRGB) ?? color
        resolved.withAlphaComponent(resolved.alphaComponent * opacity).setFill()
        bounds.fill()   // 半透明なら後ろのデスクトップが透ける（この View は不透明やないので、描く前は透明）

        guard let image = image, imageOpacity > 0, image.size.width > 0, image.size.height > 0 else { return }
        // 縦横比を保ったまま、隙間なく敷き詰める（はみ出たところは切れる）
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()   // macOS 14 以降の SDK やと、View は枠の外を自分では切らない
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: imageOpacity,
                   respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// ［表示］→［テーマ］→［テーマの設定…］: テーマ、背景の不透明度、背景の画像とその濃さ
final class ThemePanelController: NSObject {
    static let shared = ThemePanelController()

    private var panel: NSPanel?
    private let themePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacitySlider = NSSlider(value: 100, minValue: 20, maxValue: 100, target: nil, action: nil)
    private let opacityLabel = NSTextField(labelWithString: "")
    private let imageWell = NSImageView()
    private let imageOpacitySlider = NSSlider(value: 15, minValue: 0, maxValue: 80, target: nil, action: nil)
    private let imageOpacityLabel = NSTextField(labelWithString: "")

    func show() {
        let panel = self.panel ?? makePanel()
        syncFromSettings()
        panel.makeKeyAndOrderFront(nil)
    }

    /// メニューからテーマを変えたときなどに、表示を設定に合わせる
    func syncFromSettings() {
        guard panel != nil else { return }
        let settings = Settings.shared
        themePopUp.selectItem(at: EditorTheme.all.firstIndex { $0.id == settings.theme.id } ?? 0)
        opacitySlider.doubleValue = Double(settings.backgroundOpacity * 100)
        imageOpacitySlider.doubleValue = Double(settings.backgroundImageOpacity * 100)
        imageWell.image = BackgroundImage.image
        updateLabels()
    }

    private func updateLabels() {
        opacityLabel.stringValue = "\(Int(opacitySlider.doubleValue.rounded()))%"
        imageOpacityLabel.stringValue = "\(Int(imageOpacitySlider.doubleValue.rounded()))%"
    }

    // MARK: - 操作

    @objc private func themeChanged(_ sender: Any?) {
        let index = themePopUp.indexOfSelectedItem
        guard EditorTheme.all.indices.contains(index) else { return }
        Settings.shared.theme = EditorTheme.all[index]
        AppDelegate.shared.applyThemeToAll()
    }

    @objc private func opacityChanged(_ sender: Any?) {
        Settings.shared.backgroundOpacity = CGFloat(opacitySlider.doubleValue / 100)
        updateLabels()
        AppDelegate.shared.applyBackgroundToAll()
    }

    @objc private func imageOpacityChanged(_ sender: Any?) {
        Settings.shared.backgroundImageOpacity = CGFloat(imageOpacitySlider.doubleValue / 100)
        updateLabels()
        AppDelegate.shared.applyBackgroundToAll()
    }

    /// 画像の枠にドラッグ・貼り付け・削除キーをしたとき
    @objc private func imageWellChanged(_ sender: Any?) {
        if let image = imageWell.image {
            do {
                try BackgroundImage.set(image: image)
            } catch {
                showError(error)
            }
        } else {
            BackgroundImage.remove()
        }
        syncFromSettings()
        AppDelegate.shared.applyBackgroundToAll()
    }

    @objc private func chooseImage(_ sender: Any?) {
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        open.message = "背景に使う画像を選んでください"
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            // 画像でないものや大きすぎるものは、丸ごと読む前に断る
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 100_000_000, NSImage(contentsOf: url) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try BackgroundImage.set(data: Data(contentsOf: url))
        } catch {
            showError(error)
        }
        syncFromSettings()
        AppDelegate.shared.applyBackgroundToAll()
    }

    @objc private func removeImage(_ sender: Any?) {
        BackgroundImage.remove()
        syncFromSettings()
        AppDelegate.shared.applyBackgroundToAll()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "その画像は使えませんでした。"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - 組み立て

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 400, height: 236)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: true)
        panel.title = "テーマの設定"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        let content = FlippedView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = content

        func label(_ text: String, y: CGFloat) {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            field.frame = NSRect(x: 12, y: y, width: 118, height: 17)
            content.addSubview(field)
        }

        label("テーマ:", y: 20)
        for theme in EditorTheme.all {
            themePopUp.addItem(withTitle: theme.name)
        }
        themePopUp.frame = NSRect(x: 136, y: 15, width: 240, height: 26)
        themePopUp.target = self
        themePopUp.action = #selector(themeChanged(_:))
        content.addSubview(themePopUp)

        label("背景の不透明度:", y: 58)
        opacitySlider.frame = NSRect(x: 136, y: 55, width: 190, height: 24)
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        content.addSubview(opacitySlider)
        opacityLabel.frame = NSRect(x: 334, y: 58, width: 50, height: 17)
        content.addSubview(opacityLabel)

        label("背景の画像:", y: 96)
        imageWell.frame = NSRect(x: 136, y: 92, width: 120, height: 84)
        imageWell.isEditable = true
        imageWell.imageFrameStyle = .grayBezel
        imageWell.imageScaling = .scaleProportionallyUpOrDown
        imageWell.target = self
        imageWell.action = #selector(imageWellChanged(_:))
        content.addSubview(imageWell)
        let choose = NSButton(title: "選ぶ…", target: self, action: #selector(chooseImage(_:)))
        choose.frame = NSRect(x: 264, y: 92, width: 110, height: 28)
        content.addSubview(choose)
        let remove = NSButton(title: "消す", target: self, action: #selector(removeImage(_:)))
        remove.frame = NSRect(x: 264, y: 124, width: 110, height: 28)
        content.addSubview(remove)
        let hint = NSTextField(labelWithString: "枠にドラッグ・貼り付けでも")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 264, y: 158, width: 130, height: 14)
        content.addSubview(hint)

        label("画像の濃さ:", y: 196)
        imageOpacitySlider.frame = NSRect(x: 136, y: 193, width: 190, height: 24)
        imageOpacitySlider.isContinuous = true
        imageOpacitySlider.target = self
        imageOpacitySlider.action = #selector(imageOpacityChanged(_:))
        content.addSubview(imageOpacitySlider)
        imageOpacityLabel.frame = NSRect(x: 334, y: 196, width: 50, height: 17)
        content.addSubview(imageOpacityLabel)

        panel.center()
        self.panel = panel
        return panel
    }
}
