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

/// Windows のメモ帳がレジストリに覚えてた程度のことだけ覚える（と、ファイルごとのウィンドウの位置と大きさ）。
/// 開いてた文書やウィンドウの中身は保存しない（落ちたとき用の控えは別: Recovery）。
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
        static let seditMode = "SeditMode"
        static let showLineNumbers = "ShowLineNumbers"
        static let showColumnRuler = "ShowColumnRuler"
        static let showCharacterCount = "ShowCharacterCount"
        static let zoomPercent = "ZoomPercent"
        static let recentFiles = "RecentFiles"
        static let imeLog = "IMELog"
    }

    /// このアプリが覚えてることを全部消して、入れたときの状態に戻す（ファイルごとのウィンドウの位置・背景画像も）。
    /// macOS が置いてるもの（システム設定で付けたこのアプリのキーボードショートカット NSUserKeyEquivalents や、
    /// アプリごとの言語 AppleLanguages など、NS・Apple で始まるもの）は残す
    func resetAll() {
        if let domain = Bundle.main.bundleIdentifier, let stored = defaults.persistentDomain(forName: domain) {
            for key in stored.keys where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("com.apple") {
                defaults.removeObject(forKey: key)
            }
        }
        BackgroundImage.remove()
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
            Key.seditMode: false,
            Key.showLineNumbers: false,
            Key.showColumnRuler: false,
            Key.showCharacterCount: false,
            Key.zoomPercent: 100,
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
        if let osaka = osakaMono(size: size) { return osaka }
        if let fixed = NSFont.userFixedPitchFont(ofSize: size) { return fixed }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var defaultFont: NSFont {
        let size: CGFloat = 13
        // Osaka−等幅が入ってたら半角:全角がきっちり 1:2 になるので優先
        if let osaka = osakaMono(size: size) { return osaka }
        if let fixed = NSFont.userFixedPitchFont(ofSize: size) { return fixed }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Osaka−等幅は、Mac に入ってる（ダウンロード済みの）ときだけ使う。
    /// macOS の「あとから落とせるフォント」なので、入ってないのに名前で引くと、macOS が落としに行って待たされる
    /// （ネットにつながらん Mac では返ってこず、起動が止まる。CI で 20 秒以上返ってこんかった）
    private static let isOsakaMonoInstalled: Bool = {
        let names = (CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? []
        return names.contains("Osaka-Mono")
    }()

    private static func osakaMono(size: CGFloat) -> NSFont? {
        return isOsakaMonoInstalled ? NSFont(name: "Osaka-Mono", size: size) : nil
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
    /// ズーム（%）。最後に変えたズームを、次に開くウィンドウに使う
    var zoomPercent: Int {
        get {
            let value = defaults.integer(forKey: Key.zoomPercent)
            return max(EditorWindowController.minZoom, min(EditorWindowController.maxZoom, value == 0 ? 100 : value))
        }
        set { defaults.set(newValue, forKey: Key.zoomPercent) }
    }

    /// ［ファイル］→［最近使ったファイル］（新しい順のパス、10 個まで）
    var recentFiles: [String] {
        get { return defaults.stringArray(forKey: Key.recentFiles) ?? [] }
        set { defaults.set(Array(newValue.prefix(10)), forKey: Key.recentFiles) }
    }

    /// 隠し設定: 変換候補の窓の位置を調べるため、IME とのやりとりを ~/Library/Logs/local.memocho-ime.log に書く
    var imeLog: Bool {
        return defaults.bool(forKey: Key.imeLog)
    }

    var editorFont: NSFont {
        return monospaceMode || seditMode ? Settings.monospaceFont : font
    }

    /// ［表示］→［行番号］
    var showLineNumbers: Bool {
        get { return defaults.bool(forKey: Key.showLineNumbers) }
        set { defaults.set(newValue, forKey: Key.showLineNumbers) }
    }

    /// ［表示］→［桁ルーラー］
    var showColumnRuler: Bool {
        get { return defaults.bool(forKey: Key.showColumnRuler) }
        set { defaults.set(newValue, forKey: Key.showColumnRuler) }
    }

    /// ［表示］→［文字数］
    var showCharacterCount: Bool {
        get { return defaults.bool(forKey: Key.showCharacterCount) }
        set { defaults.set(newValue, forKey: Key.showCharacterCount) }
    }

    /// ［表示］→［SEDIT 風］
    var seditMode: Bool {
        get { return defaults.bool(forKey: Key.seditMode) }
        set { defaults.set(newValue, forKey: Key.seditMode) }
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
    static let lineSpacingChoices = [100, 110, 115, 120, 130, 150, 200]

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
