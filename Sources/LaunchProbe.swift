import AppKit

/// 起動の速さを測るとき（CI の tools/launch-time.swift）だけ使う。環境変数 MEMOCHO_LAUNCH_PROBE があるときだけ、
/// プロセスが始まってからの時間を、区切りごとに標準エラーに出す。最初のウィンドウを描き終わったら終わる。ふだんは何もしない
enum LaunchProbe {
    private static let isEnabled = ProcessInfo.processInfo.environment["MEMOCHO_LAUNCH_PROBE"] != nil

    static func mark(_ stage: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(String(format: "launch-probe %@: %.1f\n", stage, elapsedMilliseconds()).data(using: .utf8)!)
    }

    static func windowShown(_ window: NSWindow) {
        guard isEnabled else { return }
        window.displayIfNeeded()
        mark("window")
        if ProcessInfo.processInfo.environment["MEMOCHO_PROBE_GEOMETRY"] != nil, let content = window.contentView {
            dumpScrollGeometry(in: content)
        }
        exit(0)
    }

    /// ルーラーと本文の並び方を出す（CI で、ルーラーが本文に重なるかを調べる）
    private static func dumpScrollGeometry(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            let clip = scrollView.contentView
            var lines = [
                "scrollView.frame \(scrollView.frame) wantsLayer \(scrollView.wantsLayer) layer \(scrollView.layer != nil)",
                "clip.frame \(clip.frame) bounds \(clip.bounds) copiesOnScroll \(clip.copiesOnScroll)",
                "automaticallyAdjustsContentInsets \(scrollView.automaticallyAdjustsContentInsets) contentInsets \(clip.contentInsets)",
                "documentVisibleRect \(scrollView.documentVisibleRect) document.frame \(scrollView.documentView?.frame ?? .zero)",
            ]
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
