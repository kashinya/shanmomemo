import AppKit

/// キーボードマクロ（［マクロ］メニュー）: 記録・回数を指定して実行・ファイルに保存／読み込み。
/// キーをそのまま覚えるのではなく、「入った文字」「カーソル移動や削除などのコマンド」「メニューのショートカット」
/// 「SEDIT のファンクションキー」として覚える。日本語は変換を確定した文字で覚えるので、再生で変換し直しにならない
final class MacroRecorder {
    static let shared = MacroRecorder()

    enum Step: Codable, Equatable {
        /// 入った文字（続けて打った分はまとめる）
        case insert(String)
        /// NSResponder のコマンド（moveLeft:、deleteBackward:、insertNewline: など）
        case command(String)
        /// メニューのショートカット（⌘V、⌘G、F3 など）
        case menuKey(characters: String, charactersIgnoringModifiers: String, keyCode: UInt16, modifiers: UInt)
        /// SEDIT 風のファンクションキー（1〜10）
        case sedit(Int)
    }

    /// 保存するファイルの中身
    private struct File: Codable {
        var format = "shanmomemo-macro"
        var version = 1
        var steps: [Step]
    }

    static let fileExtension = "memomacro"
    static let maxRepeat = 99_999

    private(set) var steps: [Step] = []
    private(set) var isRecording = false
    private(set) var isPlaying = false
    /// 再生中に検索が見つからなかったときなど、繰り返しをやめる
    var abortRequested = false
    /// 記録の開始・終了で、タイトルやメニューを変える
    var onStateChange: (() -> Void)?

    var hasMacro: Bool { return !steps.isEmpty }

    // MARK: - 記録

    func startRecording() {
        guard !isPlaying else { return }
        steps = []
        isRecording = true
        onStateChange?()
    }

    func stopRecording() {
        isRecording = false
        onStateChange?()
    }

    func record(_ step: Step) {
        guard isRecording, !isPlaying else { return }
        if case .insert(let text) = step, case .insert(let previous)? = steps.last {
            steps[steps.count - 1] = .insert(previous + text)
        } else {
            steps.append(step)
        }
    }

    // MARK: - 実行

    /// times 回くり返す。全部で「元に戻す」1 回ぶん。検索が見つからなくなったらそこでやめる
    func play(times: Int, in editor: EditorWindowController) {
        guard !steps.isEmpty, !isRecording, !isPlaying else { return }
        isPlaying = true
        abortRequested = false
        let textView = editor.textView
        let undoManager = textView.undoManager
        textView.breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        defer {
            isPlaying = false
            abortRequested = false
            if let undoManager = undoManager, undoManager.groupingLevel > 0 {
                undoManager.endUndoGrouping()
                undoManager.setActionName("マクロの実行")
            }
            textView.breakUndoCoalescing()
        }
        for _ in 0..<max(1, min(times, MacroRecorder.maxRepeat)) {
            for step in steps {
                // 記録したときと同じく、いつもこのウィンドウの本文に効かせる（検索パネルなどが前に出てても）
                if NSApp.keyWindow !== editor.window {
                    editor.window.makeKeyAndOrderFront(nil)
                }
                perform(step, in: editor)
                if abortRequested { return }
            }
        }
    }

    /// 再生中にダイアログをキャンセルしたときなど: そこで止める
    func abortIfPlaying() {
        if isPlaying {
            abortRequested = true
        }
    }

    private func perform(_ step: Step, in editor: EditorWindowController) {
        let textView = editor.textView
        switch step {
        case .insert(let text):
            textView.insertText(text, replacementRange: textView.selectedRange())
        case .command(let name):
            textView.doCommand(by: NSSelectorFromString(name))
        case .menuKey(_, let key, _, let modifiers):
            // キーを打ち直すのではなく、そのショートカットのメニュー項目を直接動かす。
            // Mac のショートカットとして流すと、メニューバーが光ったり、再生を始めたときに押してた ⌥⌘ が混ざったりする。
            // 手で書き換えたファイルに、元に戻す・マクロ自体の操作が入ってても動かさない
            guard let item = MacroRecorder.menuItem(key: key, modifiers: NSEvent.ModifierFlags(rawValue: modifiers),
                                                    in: NSApp.mainMenu),
                  let action = item.action, !MacroRecorder.macroActions.contains(action) else { return }
            MacroRecorder.run(item)
        case .sedit(let number):
            editor.performSeditFunction(number)
        }
    }

    // MARK: - メニューのショートカットの記録

    /// このキーがメニューのショートカットなら覚える（マクロ自体の操作は覚えない）
    func recordMenuKeyIfNeeded(_ event: NSEvent) {
        guard isRecording, !isPlaying,
              let item = MacroRecorder.menuItem(key: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags,
                                                in: NSApp.mainMenu),
              let action = item.action, !MacroRecorder.macroActions.contains(action) else { return }
        record(.menuKey(characters: event.characters ?? "",
                        charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                        keyCode: event.keyCode,
                        modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
    }

    private static let macroActions: [Selector] = [
        #selector(AppDelegate.toggleMacroRecording(_:)),
        #selector(AppDelegate.playMacro(_:)),
        #selector(AppDelegate.playMacroRepeatedly(_:)),
        #selector(AppDelegate.saveMacro(_:)),
        #selector(AppDelegate.openMacro(_:)),
        // 元に戻す・やり直しは、マクロ全体を 1 回の「元に戻す」にまとめてるのとぶつかるので覚えない
        Selector(("undo:")),
        Selector(("redo:")),
    ]

    /// メニュー（の中のメニュー）から、このキーで動く項目を探す。隠れてる項目（F3 など）も含める。
    /// key: Shift だけ効かせた文字（NSEvent の charactersIgnoringModifiers）
    private static func menuItem(key: String, modifiers: NSEvent.ModifierFlags, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu = menu, !key.isEmpty else { return nil }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let pressed = modifiers.intersection(relevant)
        for item in menu.items {
            if let found = menuItem(key: key, modifiers: modifiers, in: item.submenu) {
                return found
            }
            guard !item.keyEquivalent.isEmpty, item.keyEquivalent.lowercased() == key.lowercased() else { continue }
            var mask = item.keyEquivalentModifierMask.intersection(relevant)
            if item.keyEquivalent != item.keyEquivalent.lowercased() {
                mask.insert(.shift)   // 大文字のショートカットは Shift 込み
            }
            // 「+」のように Shift で打つ記号は、Shift はあってもなくても同じ（JIS キーボードの ⌘+ は ⇧⌘; で打つ）
            let isSymbol = key.lowercased() == key.uppercased()
            if mask == pressed || (isSymbol && item.keyEquivalent == key && mask.union(.shift) == pressed.union(.shift)) {
                return item
            }
        }
        return nil
    }

    /// メニュー項目を、メニューから選んだのと同じに動かす。今使えない項目（選択がないときのコピーなど）は何もしない
    private static func run(_ item: NSMenuItem) {
        guard let menu = item.menu else { return }
        let index = menu.index(of: item)
        guard index >= 0 else { return }
        menu.update()   // 有効・無効を今の状態で決め直す
        guard item.isEnabled else { return }
        menu.performActionForItem(at: index)
    }

    // MARK: - ファイル

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(File(steps: steps)).write(to: url, options: .atomic)
    }

    func load(from url: URL) throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.format == "shanmomemo-macro" else { throw CocoaError(.fileReadCorruptFile) }
        steps = file.steps
        onStateChange?()
    }

    /// 実行する回数を聞く。キャンセルなら nil
    static func askRepeatCount() -> Int? {
        let alert = NSAlert()
        alert.messageText = "マクロを何回実行しますか?"
        alert.informativeText = "1〜\(maxRepeat) 回。途中で検索が見つからなくなったら、そこでやめます。"
        alert.addButton(withTitle: "実行")
        alert.addButton(withTitle: "キャンセル").keyEquivalent = "\u{1b}"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "1"
        alert.accessoryView = field
        alert.layout()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        guard let count = Int(digits), count >= 1 else {
            NSSound.beep()
            return nil
        }
        return min(count, maxRepeat)
    }
}
