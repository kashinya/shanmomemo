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
        exit(0)
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
