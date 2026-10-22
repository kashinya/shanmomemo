import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    static private(set) var shared: AppDelegate!

    private(set) var controllers: [EditorWindowController] = []

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    // MARK: - 起動・終了

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false   // 「タブで開く」系をアプリごと封印
        EmbeddedFonts.register()                        // メニューを作る前に（等幅フォントの名前が変わる）
        NSApp.appearance = Settings.shared.appearance.appearance
        NSApp.mainMenu = MainMenu.make()
        // フォントパネルの変更は本文ビューやなくて、ここで受けて全ウィンドウに反映する
        NSFontManager.shared.action = #selector(AppDelegate.fontPanelChangedFont(_:))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 念のため。起動時に何も開かれへんかったら「無題」を 1 枚出す
        DispatchQueue.main.async {
            if self.controllers.isEmpty {
                self.newWindow()
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if controllers.isEmpty {
            newWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            open(url, encoding: nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let minimized = controllers.first(where: { $0.window.isMiniaturized }) {
            minimized.window.deminiaturize(nil)
            return false
        }
        return true
    }

    /// Windows と同じく、最後のウィンドウを閉じたら終了
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllers where controller.isDirty {
            if !controller.confirmDiscardIfNeeded() {
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "新しいウィンドウ", action: #selector(fileNewWindow(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    // MARK: - ウィンドウ管理

    @discardableResult
    func newWindow() -> EditorWindowController {
        let controller = EditorWindowController()
        place(controller.window)
        controllers.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
        controller.window.makeFirstResponder(controller.textView)
        return controller
    }

    func open(_ url: URL, encoding: TextEncoding?) {
        if let existing = controller(showing: url) {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        // 起動直後の空の「無題」が残ってたら、それを使う
        let pristine = controllers.first(where: { $0.isPristine && $0.window.isMainWindow })
            ?? controllers.first(where: { $0.isPristine })
        let target = pristine ?? newWindow()
        target.load(url, encoding: encoding)
        target.window.makeKeyAndOrderFront(nil)
    }

    func controller(showing url: URL) -> EditorWindowController? {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        for controller in controllers {
            if let fileURL = controller.fileURL,
               fileURL.standardizedFileURL.resolvingSymlinksInPath() == key {
                return controller
            }
        }
        return nil
    }

    func controllerWillClose(_ controller: EditorWindowController) {
        let remaining = controllers.filter { $0 !== controller }
        if remaining.isEmpty {
            FindPanelController.shared.closePanels()
            if NSFontPanel.sharedFontPanelExists {
                NSFontPanel.shared.orderOut(nil)
            }
        }
        // 閉じてる最中に解放せんよう、一拍おいてから外す
        DispatchQueue.main.async {
            self.controllers.removeAll { $0 === controller }
        }
    }

    private func place(_ window: NSWindow) {
        let visible = controllers.map { $0.window }.filter { $0.isVisible && !$0.isMiniaturized }
        if let reference = visible.first(where: { $0.isMainWindow }) ?? visible.last {
            var frame = reference.frame
            frame.origin.x += 24
            frame.origin.y -= 24
            if let screen = (reference.screen ?? NSScreen.main)?.visibleFrame {
                if frame.maxX > screen.maxX { frame.origin.x = screen.minX + 24 }
                if frame.minY < screen.minY { frame.origin.y = screen.maxY - frame.height }
            }
            window.setFrame(frame, display: false)
        } else {
            window.setFrame(defaultFrame(for: window), display: false)
        }
    }

    /// 1 枚目のウィンドウの位置と大きさ。移植元のメモ帳と同じく位置は覚えず、毎回ここ（画面の左から 260pt・上から 352pt に本文 500×500）
    private func defaultFrame(for window: NSWindow) -> NSRect {
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 500, height: 500)).size
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(origin: .zero, size: size)
        }
        let full = screen.frame
        let visible = screen.visibleFrame
        var frame = NSRect(x: full.minX + 260, y: full.maxY - 352 - size.height, width: size.width, height: size.height)
        // 小さい画面ではみ出すときは、見えるところに収める
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        return frame
    }

    // MARK: - メニュー（ウィンドウが無いときや、アプリ全体の設定）

    /// ⌘N。今のウィンドウの中身は入れ替えず、いつも新しいウィンドウを開く
    @objc func fileNewWindow(_ sender: Any?) {
        newWindow()
    }

    /// ウィンドウが 1 枚も無いときだけここに来る
    @objc func fileOpen(_ sender: Any?) {
        guard let choice = FilePanels.runOpen() else { return }
        open(choice.url, encoding: choice.encoding)
    }

    @objc func toggleWordWrap(_ sender: Any?) {
        Settings.shared.wordWrap.toggle()
        for controller in controllers {
            controller.applyWordWrap()
        }
    }

    @objc func toggleStatusBar(_ sender: Any?) {
        Settings.shared.showStatusBar.toggle()
        for controller in controllers {
            controller.applyStatusBarVisibility()
        }
    }

    @objc func toggleMonospaceFont(_ sender: Any?) {
        Settings.shared.monospaceMode.toggle()
        applyFontToAll()
        // フォントパネルが開いてたら表示を合わせる（ずれたままやと、次の変更が違うフォントに掛かる）
        if NSFontPanel.sharedFontPanelExists {
            NSFontManager.shared.setSelectedFont(Settings.shared.editorFont, isMultiple: false)
        }
    }

    @objc func setAppearanceMode(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let mode = AppearanceMode(rawValue: item.tag) else { return }
        Settings.shared.appearance = mode
        NSApp.appearance = mode.appearance
    }

    @objc func showFontPanel(_ sender: Any?) {
        let fontManager = NSFontManager.shared
        fontManager.setSelectedFont(Settings.shared.editorFont, isMultiple: false)
        fontManager.orderFrontFontPanel(sender)
    }

    /// フォントパネルで選んだら、それを使う（等幅フォントモードは切る）
    @objc func fontPanelChangedFont(_ sender: Any?) {
        let fontManager = (sender as? NSFontManager) ?? NSFontManager.shared
        Settings.shared.font = fontManager.convert(Settings.shared.editorFont)
        Settings.shared.monospaceMode = false
        applyFontToAll()
    }

    private func applyFontToAll() {
        for controller in controllers {
            controller.applyFont()
            controller.updateStatusNow()
        }
    }

    @objc func showAbout(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: "Windows のメモ帳みたいな、ただのテキストエディタ。\nタブなし・自動復元なし。",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: paragraph])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .credits: credits,
        ])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleWordWrap(_:)) {
            menuItem.state = Settings.shared.wordWrap ? .on : .off
        } else if menuItem.action == #selector(toggleStatusBar(_:)) {
            menuItem.state = Settings.shared.showStatusBar ? .on : .off
        } else if menuItem.action == #selector(toggleMonospaceFont(_:)) {
            menuItem.state = Settings.shared.monospaceMode ? .on : .off
        } else if menuItem.action == #selector(setAppearanceMode(_:)) {
            menuItem.state = menuItem.tag == Settings.shared.appearance.rawValue ? .on : .off
        }
        return true
    }
}
