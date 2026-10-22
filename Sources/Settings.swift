import AppKit
import CoreText

/// ［表示］→［外観］。Windows 11 のメモ帳と同じく「システム設定に合わせる / ライト / ダーク」
enum AppearanceMode: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2

    var displayName: String {
        switch self {
        case .system: return "システム設定に合わせる"
        case .light: return "ライト"
        case .dark: return "ダーク"
        }
    }

    /// nil = システム設定に合わせる
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

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
        static let windowFrame = "WindowFrame"
        static let matchCase = "FindMatchCase"
        static let wrapAround = "FindWrapAround"
        static let tabWidth = "TabWidth"
        static let monospaceMode = "MonospaceMode"
        static let appearance = "Appearance"
    }

    private init() {
        defaults.register(defaults: [
            Key.wordWrap: false,
            Key.statusBar: true,
            Key.matchCase: false,
            Key.wrapAround: false,
            Key.tabWidth: 8,
            Key.monospaceMode: false,
            Key.appearance: AppearanceMode.system.rawValue,
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

    var appearance: AppearanceMode {
        get { return AppearanceMode(rawValue: defaults.integer(forKey: Key.appearance)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
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

    /// 最後に閉じた（動かした）ウィンドウの位置と大きさ
    var windowFrame: NSRect? {
        get {
            guard let string = defaults.string(forKey: Key.windowFrame) else { return nil }
            let rect = NSRectFromString(string)
            return (rect.width >= 200 && rect.height >= 150) ? rect : nil
        }
        set {
            if let rect = newValue {
                defaults.set(NSStringFromRect(rect), forKey: Key.windowFrame)
            } else {
                defaults.removeObject(forKey: Key.windowFrame)
            }
        }
    }
}
