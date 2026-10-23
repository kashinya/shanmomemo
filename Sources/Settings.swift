import AppKit
import CoreText

/// メモ帳.app/Contents/Resources/Fonts に入れたフォント（build.sh が PC-9800 フォントを入れる）を、
/// このアプリの中だけで使えるようにする。Mac 全体にはインストールしない。
enum EmbeddedFonts {
    static func register() {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
            _ = CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }
}

enum AppInfo {
    static var name: String {
        let info = Bundle.main.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return "メモ帳"
    }

    static var version: String {
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}

/// Windows のメモ帳がレジストリに覚えてた程度のことだけ覚える。
/// 開いてた文書やウィンドウの中身は一切保存しない。
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let fontName = "FontName"
        static let fontSize = "FontSize"
        static let wordWrap = "WordWrap"
        static let statusBar = "StatusBar"
        static let matchCase = "FindMatchCase"
        static let wrapAround = "FindWrapAround"
        static let tabWidth = "TabWidth"
        static let monospaceMode = "MonospaceMode"
        static let legacyAppearance = "Appearance"   // 前の版の［外観］(0: システム, 1: ライト, 2: ダーク)
        static let theme = "Theme"
        static let backgroundOpacity = "BackgroundOpacity"
        static let backgroundImageOpacity = "BackgroundImageOpacity"
        static let classicUI = "ClassicUI"
        static let hideMacMenuBar = "HideMacMenuBar"
        static let lineSpacing = "LineSpacingPercent"
    }

    private init() {
        defaults.register(defaults: [
            Key.wordWrap: false,
            Key.statusBar: true,
            Key.matchCase: false,
            Key.wrapAround: false,
            Key.tabWidth: 8,
            Key.monospaceMode: false,
            Key.backgroundOpacity: 1.0,
            Key.backgroundImageOpacity: 0.15,
            Key.classicUI: false,
            Key.hideMacMenuBar: true,
            Key.lineSpacing: 100,
        ])
    }

    /// アプリに埋め込んだ PC-9800 フォントの PostScript 名
    static let pc98FontName = "PC_9800"

    static var hasPC98Font: Bool {
        return NSFont(name: pc98FontName, size: 16) != nil
    }

    /// 等幅フォントモードのフォント。PC-9800 フォントなら半角:全角がきっちり 1:2（16 ドット）
    static var monospaceFont: NSFont {
        let size: CGFloat = 16
        if let pc98 = NSFont(name: pc98FontName, size: size) { return pc98 }
        if let osaka = NSFont(name: "Osaka-Mono", size: size) { return osaka }
        if let fixed = NSFont.userFixedPitchFont(ofSize: size) { return fixed }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var defaultFont: NSFont {
        let size: CGFloat = 13
        // Osaka−等幅が入ってたら半角:全角がきっちり 1:2 になるので優先
        if let osaka = NSFont(name: "Osaka-Mono", size: size) { return osaka }
        if let fixed = NSFont.userFixedPitchFont(ofSize: size) { return fixed }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var font: NSFont {
        get {
            let size = defaults.double(forKey: Key.fontSize)
            if let name = defaults.string(forKey: Key.fontName), size >= 1,
               let font = NSFont(name: name, size: CGFloat(size)) {
                return font
            }
            return Settings.defaultFont
        }
        set {
            defaults.set(newValue.fontName, forKey: Key.fontName)
            defaults.set(Double(newValue.pointSize), forKey: Key.fontSize)
        }
    }

    /// 本文に使うフォント。等幅フォントモードのときはフォントパネルで選んだのより優先
    var editorFont: NSFont {
        return monospaceMode ? Settings.monospaceFont : font
    }

    var monospaceMode: Bool {
        get { return defaults.bool(forKey: Key.monospaceMode) }
        set { defaults.set(newValue, forKey: Key.monospaceMode) }
    }

    var theme: EditorTheme {
        get {
            if let id = defaults.string(forKey: Key.theme), let theme = EditorTheme.named(id) {
                return theme
            }
            switch defaults.integer(forKey: Key.legacyAppearance) {
            case 1: return .light
            case 2: return .dark
            default: return .system
            }
        }
        set { defaults.set(newValue.id, forKey: Key.theme) }
    }

    /// 本文の背景の不透明度（20%〜100%）。100% 未満やと後ろのデスクトップが透ける
    var backgroundOpacity: CGFloat {
        get { return CGFloat(min(1, max(0.2, defaults.double(forKey: Key.backgroundOpacity)))) }
        set { defaults.set(Double(newValue), forKey: Key.backgroundOpacity) }
    }

    /// 背景の画像の濃さ（0%〜80%）
    var backgroundImageOpacity: CGFloat {
        get { return CGFloat(min(0.8, max(0, defaults.double(forKey: Key.backgroundImageOpacity)))) }
        set { defaults.set(Double(newValue), forKey: Key.backgroundImageOpacity) }
    }

    /// ［表示］→［Windows 2000 風］
    var classicUI: Bool {
        get { return defaults.bool(forKey: Key.classicUI) }
        set { defaults.set(newValue, forKey: Key.classicUI) }
    }

    /// Windows 2000 風のとき、このアプリを使ってる間は Mac のメニューバー（と Dock）を自動で隠す
    var hideMacMenuBar: Bool {
        get { return defaults.bool(forKey: Key.hideMacMenuBar) }
        set { defaults.set(newValue, forKey: Key.hideMacMenuBar) }
    }

    /// ［書式］→［行間］で選べる倍率（%）
    static let lineSpacingChoices = [100, 115, 130, 150, 200]

    var lineSpacingPercent: Int {
        get { return min(300, max(100, defaults.integer(forKey: Key.lineSpacing))) }
        set { defaults.set(newValue, forKey: Key.lineSpacing) }
    }

    var lineSpacing: CGFloat {
        return CGFloat(lineSpacingPercent) / 100
    }

    var wordWrap: Bool {
        get { return defaults.bool(forKey: Key.wordWrap) }
        set { defaults.set(newValue, forKey: Key.wordWrap) }
    }

    var showStatusBar: Bool {
        get { return defaults.bool(forKey: Key.statusBar) }
        set { defaults.set(newValue, forKey: Key.statusBar) }
    }

    var matchCase: Bool {
        get { return defaults.bool(forKey: Key.matchCase) }
        set { defaults.set(newValue, forKey: Key.matchCase) }
    }

    var wrapAround: Bool {
        get { return defaults.bool(forKey: Key.wrapAround) }
        set { defaults.set(newValue, forKey: Key.wrapAround) }
    }

    /// 隠し設定: defaults write local.memocho TabWidth -int 4
    var tabWidth: Int {
        let width = defaults.integer(forKey: Key.tabWidth)
        return (1...32).contains(width) ? width : 8
    }
}
