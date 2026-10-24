import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    static private(set) var shared: AppDelegate!

    private(set) var controllers: [EditorWindowController] = []
    private var keyMonitor: Any?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    // MARK: - 起動・終了

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false   // 「タブで開く」系をアプリごと封印
        EmbeddedFonts.register()                        // メニューを作る前に（等幅フォントの名前が変わる）
        NSApp.appearance = Settings.shared.theme.appearance
        installKeyMonitor()
        MacroRecorder.shared.onStateChange = { [weak self] in
            self?.controllers.forEach { $0.refreshTitle() }
        }
        NSApp.mainMenu = MainMenu.make()
        // フォントパネルの変更は本文ビューやなくて、ここで受けて全ウィンドウに反映する
        NSFontManager.shared.action = #selector(AppDelegate.fontPanelChangedFont(_:))
    }

    /// キーを、メニューや本文より先に見る:
    /// - SEDIT 風のときは F1〜F10 を SEDIT のファンクションキーにする（メニューの F3・F5 より先に拾う）
    /// - マクロの記録中は、メニューのショートカット（⌘V など）を覚える
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let controller = self?.controllers.first(where: { $0.window === NSApp.keyWindow }),
                  !controller.textView.hasMarkedText() else {   // 日本語の変換中は F6〜F10 などを IM に渡す
                return event
            }
            if Settings.shared.seditMode,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
               (NSF1FunctionKey...NSF10FunctionKey).contains(Int(scalar.value)) {
                controller.performSeditFunction(Int(scalar.value) - NSF1FunctionKey + 1)   // マクロにはここで覚える
                return nil
            }
            MacroRecorder.shared.recordMenuKeyIfNeeded(event)
            return event
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyPresentationOptions()
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
        LaunchProbe.windowShown(controller.window)
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
        // Windows 2000 風（枠なし）でも外側の大きさは同じにする
        let size = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable]).size
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

    @objc func setLineSpacing(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, Settings.lineSpacingChoices.contains(item.tag) else { return }
        Settings.shared.lineSpacingPercent = item.tag
        applyFontToAll()
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        Settings.shared.showLineNumbers.toggle()
        controllers.forEach { $0.applyRulers() }
    }

    @objc func toggleColumnRuler(_ sender: Any?) {
        Settings.shared.showColumnRuler.toggle()
        controllers.forEach { $0.applyRulers() }
    }

    @objc func toggleCharacterCount(_ sender: Any?) {
        Settings.shared.showCharacterCount.toggle()
        controllers.forEach { $0.updateStatusNow() }
    }

    // MARK: - キーボードマクロ

    private var keyEditor: EditorWindowController? {
        return controllers.first { $0.window === NSApp.keyWindow } ?? controllers.first { $0.window.isMainWindow }
    }

    @objc func toggleMacroRecording(_ sender: Any?) {
        let macro = MacroRecorder.shared
        if macro.isRecording {
            macro.stopRecording()
        } else {
            macro.startRecording()
        }
    }

    @objc func playMacro(_ sender: Any?) {
        guard let editor = keyEditor else { return }
        MacroRecorder.shared.play(times: 1, in: editor)
    }

    @objc func playMacroRepeatedly(_ sender: Any?) {
        guard let editor = keyEditor, let times = MacroRecorder.askRepeatCount() else { return }
        editor.window.makeKeyAndOrderFront(nil)
        MacroRecorder.shared.play(times: times, in: editor)
    }

    @objc func saveMacro(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "マクロ.\(MacroRecorder.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MacroRecorder.shared.save(to: url)
        } catch {
            showMacroError("マクロを保存できませんでした。", error)
        }
    }

    @objc func openMacro(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "マクロのファイル（.\(MacroRecorder.fileExtension)）を選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MacroRecorder.shared.load(from: url)
        } catch {
            showMacroError("このファイルはマクロとして読めませんでした。", error)
        }
    }

    private func showMacroError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc func toggleSeditMode(_ sender: Any?) {
        Settings.shared.seditMode.toggle()
        for controller in controllers {
            controller.applySeditMode()
        }
    }

    @objc func toggleClassicUI(_ sender: Any?) {
        Settings.shared.classicUI.toggle()
        // 先に Mac のメニューバーと Dock を戻す（ウィンドウを画面に収めるときに本当の大きさで測れるように）
        applyPresentationOptions()
        for controller in controllers {
            controller.applyClassicUI()
        }
    }

    @objc func toggleHideMacMenuBar(_ sender: Any?) {
        Settings.shared.hideMacMenuBar.toggle()
        applyPresentationOptions()
    }

    /// Windows 2000 風のときは、このアプリが前にある間だけ Mac のメニューバーを自動で隠す。
    /// macOS の決まりで、メニューバーを隠すときは Dock も一緒に隠すことになる
    func applyPresentationOptions() {
        let settings = Settings.shared
        NSApp.presentationOptions = settings.classicUI && settings.hideMacMenuBar ? [.autoHideDock, .autoHideMenuBar] : []
    }

    @objc func setTheme(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, EditorTheme.all.indices.contains(item.tag) else { return }
        Settings.shared.theme = EditorTheme.all[item.tag]
        applyThemeToAll()
    }

    @objc func showThemePanel(_ sender: Any?) {
        ThemePanelController.shared.show()
    }

    func applyThemeToAll() {
        NSApp.appearance = Settings.shared.theme.appearance
        for controller in controllers {
            controller.applyTheme()
        }
        ThemePanelController.shared.syncFromSettings()
    }

    /// 背景の不透明度と画像だけ（スライダーを動かしてる間に本文を組み直さんように）
    func applyBackgroundToAll() {
        for controller in controllers {
            controller.applyBackground()
        }
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
            return !Settings.shared.seditMode   // SEDIT 風は上の行に出すので
        } else if menuItem.action == #selector(toggleMonospaceFont(_:)) {
            menuItem.state = Settings.shared.monospaceMode ? .on : .off
            return !Settings.shared.seditMode   // SEDIT 風はいつも PC-9800 フォント
        } else if menuItem.action == #selector(showFontPanel(_:)) {
            return !Settings.shared.seditMode
        } else if menuItem.action == #selector(setTheme(_:)) {
            let isCurrent = EditorTheme.all.indices.contains(menuItem.tag) && EditorTheme.all[menuItem.tag].id == Settings.shared.theme.id
            menuItem.state = isCurrent ? .on : .off
            return !Settings.shared.seditMode   // SEDIT 風はいつも黒地に白
        } else if menuItem.action == #selector(setLineSpacing(_:)) {
            menuItem.state = menuItem.tag == Settings.shared.lineSpacingPercent ? .on : .off
        } else if menuItem.action == #selector(toggleLineNumbers(_:)) {
            menuItem.state = Settings.shared.showLineNumbers ? .on : .off
        } else if menuItem.action == #selector(toggleColumnRuler(_:)) {
            menuItem.state = Settings.shared.showColumnRuler ? .on : .off
        } else if menuItem.action == #selector(toggleCharacterCount(_:)) {
            menuItem.state = Settings.shared.showCharacterCount ? .on : .off
        } else if menuItem.action == #selector(toggleMacroRecording(_:)) {
            menuItem.title = MacroRecorder.shared.isRecording ? "記録を終える" : "記録を始める"
            return !MacroRecorder.shared.isPlaying
        } else if menuItem.action == #selector(playMacro(_:)) || menuItem.action == #selector(playMacroRepeatedly(_:)) {
            let macro = MacroRecorder.shared
            return macro.hasMacro && !macro.isRecording && !macro.isPlaying && keyEditor != nil
        } else if menuItem.action == #selector(saveMacro(_:)) {
            return MacroRecorder.shared.hasMacro && !MacroRecorder.shared.isRecording
        } else if menuItem.action == #selector(openMacro(_:)) {
            return !MacroRecorder.shared.isRecording
        } else if menuItem.action == #selector(toggleSeditMode(_:)) {
            menuItem.state = Settings.shared.seditMode ? .on : .off
        } else if menuItem.action == #selector(toggleClassicUI(_:)) {
            menuItem.state = Settings.shared.classicUI ? .on : .off
        } else if menuItem.action == #selector(toggleHideMacMenuBar(_:)) {
            menuItem.state = Settings.shared.hideMacMenuBar ? .on : .off
            return Settings.shared.classicUI
        }
        return true
    }
}
