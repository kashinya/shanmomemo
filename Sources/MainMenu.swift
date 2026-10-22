import AppKit

/// メニューは Windows のメモ帳の並び。ショートカットは Ctrl を ⌘ に置き換え（Mac で被るものだけ Mac 流）。
enum MainMenu {

    static func make() -> NSMenu {
        let name = AppInfo.name
        let mainMenu = NSMenu(title: "MainMenu")

        // アプリケーションメニュー
        let appMenu = NSMenu(title: name)
        appMenu.addItem(item("\(name)について", #selector(AppDelegate.showAbout(_:))))
        appMenu.addItem(NSMenuItem.separator())
        let servicesMenu = NSMenu(title: "サービス")
        let servicesItem = NSMenuItem(title: "サービス", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(item("\(name)を非表示", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("ほかを非表示", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(item("\(name)を終了", #selector(NSApplication.terminate(_:)), "q"))
        add(appMenu, to: mainMenu)

        // ファイル
        let fileMenu = NSMenu(title: "ファイル")
        fileMenu.addItem(item("新規", #selector(EditorWindowController.fileNew(_:)), "n"))
        fileMenu.addItem(item("新しいウィンドウ", #selector(AppDelegate.fileNewWindow(_:)), "n", [.command, .shift]))
        fileMenu.addItem(item("開く…", #selector(EditorWindowController.fileOpen(_:)), "o"))
        let reopenItem = NSMenuItem(title: "文字コードを指定して開き直す", action: nil, keyEquivalent: "")
        reopenItem.submenu = encodingMenu(title: "文字コードを指定して開き直す",
                                          action: #selector(EditorWindowController.reopenWithEncoding(_:)))
        fileMenu.addItem(reopenItem)
        fileMenu.addItem(item("上書き保存", #selector(EditorWindowController.fileSave(_:)), "s"))
        fileMenu.addItem(item("名前を付けて保存…", #selector(EditorWindowController.fileSaveAs(_:)), "s", [.command, .shift]))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(item("ページ設定…", #selector(NSApplication.runPageLayout(_:)), "p", [.command, .shift]))
        fileMenu.addItem(item("印刷…", #selector(EditorWindowController.filePrint(_:)), "p"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(item("閉じる", #selector(NSWindow.performClose(_:)), "w"))
        add(fileMenu, to: mainMenu)

        // 編集
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(item("元に戻す", Selector(("undo:")), "z"))
        editMenu.addItem(item("やり直し", Selector(("redo:")), "z", [.command, .shift]))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(item("切り取り", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item("コピー", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("貼り付け", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item("削除", #selector(NSText.delete(_:))))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(item("検索…", #selector(EditorWindowController.showFindPanel(_:)), "f"))
        editMenu.addItem(item("次を検索", #selector(EditorWindowController.findNextMatch(_:)), "g"))
        editMenu.addItem(item("前を検索", #selector(EditorWindowController.findPreviousMatch(_:)), "g", [.command, .shift]))
        editMenu.addItem(item("置換…", #selector(EditorWindowController.showReplacePanel(_:)), "f", [.command, .option]))
        editMenu.addItem(item("選択範囲を検索に使用", #selector(EditorWindowController.useSelectionForFind(_:)), "e"))
        editMenu.addItem(item("行へ移動…", #selector(EditorWindowController.goToLine(_:)), "l"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(item("すべて選択", #selector(NSText.selectAll(_:)), "a"))
        editMenu.addItem(item("日付と時刻", #selector(EditorWindowController.insertDateTime(_:)),
                              functionKey(NSF5FunctionKey), []))
        // F3 / Shift+F3 も効くように（メニューには出さない）
        editMenu.addItem(hidden(item("次を検索", #selector(EditorWindowController.findNextMatch(_:)),
                                     functionKey(NSF3FunctionKey), [])))
        editMenu.addItem(hidden(item("前を検索", #selector(EditorWindowController.findPreviousMatch(_:)),
                                     functionKey(NSF3FunctionKey), [.shift])))
        add(editMenu, to: mainMenu)

        // 書式
        let formatMenu = NSMenu(title: "書式")
        formatMenu.addItem(item("右端で折り返す", #selector(AppDelegate.toggleWordWrap(_:))))
        formatMenu.addItem(item(Settings.hasPC98Font ? "等幅フォント（PC-9800）" : "等幅フォント",
                                #selector(AppDelegate.toggleMonospaceFont(_:))))
        formatMenu.addItem(item("フォント…", #selector(AppDelegate.showFontPanel(_:)), "t"))
        formatMenu.addItem(NSMenuItem.separator())
        let saveEncodingItem = NSMenuItem(title: "保存時の文字コード", action: nil, keyEquivalent: "")
        saveEncodingItem.submenu = encodingMenu(title: "保存時の文字コード",
                                                action: #selector(EditorWindowController.setSaveEncoding(_:)))
        formatMenu.addItem(saveEncodingItem)
        let lineEndingItem = NSMenuItem(title: "保存時の改行コード", action: nil, keyEquivalent: "")
        let lineEndingMenu = NSMenu(title: "保存時の改行コード")
        for ending in LineEnding.allCases {
            lineEndingMenu.addItem(item(ending.displayName, #selector(EditorWindowController.setSaveLineEnding(_:)),
                                        tag: ending.rawValue))
        }
        lineEndingItem.submenu = lineEndingMenu
        formatMenu.addItem(lineEndingItem)
        add(formatMenu, to: mainMenu)

        // 表示
        let viewMenu = NSMenu(title: "表示")
        let zoomItem = NSMenuItem(title: "ズーム", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu(title: "ズーム")
        zoomMenu.addItem(item("拡大", #selector(EditorWindowController.editorZoomIn(_:)), "+"))
        zoomMenu.addItem(item("縮小", #selector(EditorWindowController.editorZoomOut(_:)), "-"))
        zoomMenu.addItem(item("既定のズームに戻す", #selector(EditorWindowController.editorZoomReset(_:)), "0"))
        // US 配列の ⌘= と、JIS 配列の ⌘; でも拡大
        zoomMenu.addItem(hidden(item("拡大", #selector(EditorWindowController.editorZoomIn(_:)), "=")))
        zoomMenu.addItem(hidden(item("拡大", #selector(EditorWindowController.editorZoomIn(_:)), ";")))
        zoomItem.submenu = zoomMenu
        viewMenu.addItem(zoomItem)
        viewMenu.addItem(item("ステータス バー", #selector(AppDelegate.toggleStatusBar(_:))))
        let appearanceItem = NSMenuItem(title: "外観", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "外観")
        for mode in AppearanceMode.allCases {
            appearanceMenu.addItem(item(mode.displayName, #selector(AppDelegate.setAppearanceMode(_:)), tag: mode.rawValue))
        }
        appearanceItem.submenu = appearanceMenu
        viewMenu.addItem(appearanceItem)
        add(viewMenu, to: mainMenu)

        // ウインドウ
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("拡大／縮小", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(item("すべてを手前に移動", #selector(NSApplication.arrangeInFront(_:))))
        add(windowMenu, to: mainMenu)
        NSApp.windowsMenu = windowMenu

        // ヘルプ
        let helpMenu = NSMenu(title: "ヘルプ")
        helpMenu.addItem(item("\(name)のバージョン情報", #selector(AppDelegate.showAbout(_:))))
        add(helpMenu, to: mainMenu)
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    private static func encodingMenu(title: String, action: Selector) -> NSMenu {
        let menu = NSMenu(title: title)
        for encoding in TextEncoding.allCases {
            menu.addItem(item(encoding.displayName, action, tag: encoding.rawValue))
        }
        return menu
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty {
            menuItem.keyEquivalentModifierMask = modifiers
        }
        menuItem.tag = tag
        return menuItem
    }

    private static func hidden(_ menuItem: NSMenuItem) -> NSMenuItem {
        menuItem.isHidden = true
        menuItem.allowsKeyEquivalentWhenHidden = true
        return menuItem
    }

    private static func add(_ submenu: NSMenu, to mainMenu: NSMenu) {
        let menuItem = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        mainMenu.addItem(menuItem)
    }

    private static func functionKey(_ code: Int) -> String {
        guard let scalar = UnicodeScalar(code) else { return "" }
        return String(Character(scalar))
    }
}
