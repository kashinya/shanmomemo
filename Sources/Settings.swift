import AppKit

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
    }

    private init() {
        defaults.register(defaults: [
            Key.wordWrap: false,
            Key.statusBar: true,
            Key.matchCase: false,
            Key.wrapAround: false,
            Key.tabWidth: 8,
        ])
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
