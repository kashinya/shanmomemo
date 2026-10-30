import AppKit

/// 起動の速さを測るとき（CI の tools/launch-time.swift）だけ使う。環境変数 MEMOCHO_LAUNCH_PROBE があるときだけ、
/// プロセスが始まってからの時間を、区切りごとに標準エラーに出す。最初のウィンドウを描き終わったら終わる。ふだんは何もしない
enum LaunchProbe {
    private static let isEnabled = ProcessInfo.processInfo.environment["MEMOCHO_LAUNCH_PROBE"] != nil

    static func mark(_ stage: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(String(format: "launch-probe %@: %.1f\n", stage, elapsedMilliseconds()).data(using: .utf8)!)
    }

    static func windowShown(_ controller: EditorWindowController) {
        guard isEnabled else { return }
        let window = controller.window
        window.displayIfNeeded()
        mark("window")
        let environment = ProcessInfo.processInfo.environment
        if let output = environment["MEMOCHO_SCREENSHOT"] {
            takeScreenshot(of: controller, to: output, environment: environment)
        }
        // 写真を撮るときは、文書を開いて大きさを変えたあとの並び方を出す
        if environment["MEMOCHO_PROBE_GEOMETRY"] != nil, let content = window.contentView {
            dumpScrollGeometry(in: content)
        }
        exit(0)
    }

    /// README の画面写真用（CI）: MEMOCHO_SCREENSHOT_TEXT のファイルを開いて、本文の大きさを MEMOCHO_SCREENSHOT_SIZE（幅x高さ）にし、
    /// ウィンドウをそのまま PNG にする。アプリが自分で描くので、画面収録の許可は要らん
    private static func takeScreenshot(of controller: EditorWindowController, to output: String, environment: [String: String]) {
        let window = controller.window
        if let size = environment["MEMOCHO_SCREENSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        if let text = environment["MEMOCHO_SCREENSHOT_TEXT"] {
            controller.load(URL(fileURLWithPath: text), encoding: nil)
        }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        // タイトルバーまで入れる（枠なしの Windows 2000 風は、中身の View がウィンドウ全体）
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            mark("screenshot-failed")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: output))
            mark("screenshot")
        }
    }

    /// ルーラーと本文の並び方を出す（CI で、ルーラーが本文に重なるかを調べる）
    private static func dumpScrollGeometry(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            let clip = scrollView.contentView
            var lines = [
                "scrollView.frame \(scrollView.frame) wantsLayer \(scrollView.wantsLayer) layer \(scrollView.layer != nil)",
                "clip.frame \(clip.frame) bounds \(clip.bounds)",
                "automaticallyAdjustsContentInsets \(scrollView.automaticallyAdjustsContentInsets) contentInsets \(clip.contentInsets)",
                "documentVisibleRect \(scrollView.documentVisibleRect) document.frame \(scrollView.documentView?.frame ?? .zero)",
                "contentSize \(scrollView.contentSize) hasVerticalScroller \(scrollView.hasVerticalScroller) scrollerStyle \(scrollView.scrollerStyle.rawValue) verticalScroller.frame \(scrollView.verticalScroller?.frame ?? .zero)",
            ]
            if let textView = scrollView.documentView as? NSTextView, let container = textView.textContainer,
               let layoutManager = textView.layoutManager {
                layoutManager.ensureLayout(for: container)
                lines.append("textView.frame \(textView.frame) autoresizing \(textView.autoresizingMask.rawValue) horizontallyResizable \(textView.isHorizontallyResizable)")
                lines.append("container.size \(container.size) widthTracksTextView \(container.widthTracksTextView) inset \(textView.textContainerInset) padding \(container.lineFragmentPadding)")
                lines.append("usedRect \(layoutManager.usedRect(for: container)) textContainerOrigin \(textView.textContainerOrigin)")
            }
            for ruler in [scrollView.verticalRulerView, scrollView.horizontalRulerView].compactMap({ $0 }) {
                lines.append("ruler \(ruler.orientation == .verticalRuler ? "vertical" : "horizontal") frame \(ruler.frame) superview \(ruler.superview.map { String(describing: type(of: $0)) } ?? "nil") hidden \(ruler.isHidden) thickness \(ruler.ruleThickness)")
            }
            for line in lines {
                FileHandle.standardError.write("launch-probe geometry: \(line)\n".data(using: .utf8)!)
            }
            return
        }
        for subview in view.subviews {
            dumpScrollGeometry(in: subview)
        }
    }

    private static func elapsedMilliseconds() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_un.__p_starttime   // C の p_starttime はマクロなので Swift からは見えん
        var now = timeval()
        gettimeofday(&now, nil)
        return Double(now.tv_sec - start.tv_sec) * 1000 + Double(now.tv_usec - start.tv_usec) / 1000
    }
}
