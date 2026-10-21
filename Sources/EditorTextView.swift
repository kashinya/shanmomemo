import AppKit

/// 本文の NSTextView。ファイルのドロップで開く・ピンチでズーム、だけ足してある。
final class EditorTextView: NSTextView {
    weak var editor: EditorWindowController?
    private var pinchAccumulator: CGFloat = 0

    // MARK: - Finder からファイルを落としたら開く（Windows のメモ帳と同じ）

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        if !types.contains(.fileURL) {
            types.append(.fileURL)
        }
        return types
    }

    private func droppedFileURL(_ info: NSDraggingInfo) -> URL? {
        // 自分の中で文字をドラッグしてるときは普通の移動・コピー
        guard info.draggingSource == nil else { return nil }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL])?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if droppedFileURL(sender) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if droppedFileURL(sender) != nil { return .copy }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if droppedFileURL(sender) != nil { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = droppedFileURL(sender) {
            // ドラッグ処理中に保存確認ダイアログを出さんよう、一拍おく
            DispatchQueue.main.async { [weak self] in
                self?.editor?.openDroppedFile(url)
            }
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: - トラックパッドのピンチでズーム（Windows の Ctrl+ホイール代わり）

    override func magnify(with event: NSEvent) {
        guard let editor = editor else {
            super.magnify(with: event)
            return
        }
        pinchAccumulator += event.magnification
        if pinchAccumulator >= 0.12 {
            editor.zoom(by: 10)
            pinchAccumulator = 0
        } else if pinchAccumulator <= -0.12 {
            editor.zoom(by: -10)
            pinchAccumulator = 0
        }
        if event.phase == .ended || event.phase == .cancelled {
            pinchAccumulator = 0
        }
    }
}
