// 起動の速さを測る（CI 用）。アプリの実行ファイルを直接起動して、ウィンドウが画面に出るまでの時間を何回か測る。
//   swiftc -O -o launch-time tools/launch-time.swift && ./launch-time "build/メモ帳.app" 6
// 1 回目はビルドしたてのアプリを初めて起動したとき（macOS の署名の確認なども入る）。2 回目からが普段の起動
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("使い方: launch-time <アプリ.app> [回数]")
    exit(2)
}
let app = URL(fileURLWithPath: arguments[1])
let runs = arguments.count >= 3 ? max(1, Int(arguments[2]) ?? 6) : 6
guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
      let executable = info["CFBundleExecutable"] as? String else {
    print("Info.plist が読めない: \(app.path)")
    exit(1)
}
let executableURL = app.appendingPathComponent("Contents/MacOS/\(executable)")

/// その PID のふつうのウィンドウが画面に出てるか
func hasWindow(_ pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
    return list.contains {
        ($0[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } == pid && ($0[kCGWindowLayer as String] as? Int) == 0
    }
}

func elapsedMilliseconds(since start: DispatchTime) -> Double {
    return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

var times: [Double] = []
for run in 1...runs {
    let process = Process()
    process.executableURL = executableURL
    let start = DispatchTime.now()
    do {
        try process.run()
    } catch {
        print("起動できない: \(error)")
        exit(1)
    }
    var shown: Double?
    while process.isRunning, elapsedMilliseconds(since: start) < 20_000 {
        if hasWindow(process.processIdentifier) {
            shown = elapsedMilliseconds(since: start)
            break
        }
        usleep(5_000)
    }
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
    if let shown = shown {
        times.append(shown)
        print(String(format: "%ld 回目: %.0f ms", run, shown))
    } else {
        print("\(run) 回目: ウィンドウが出なかった")
    }
    usleep(500_000)
}

let warm = Array(times.dropFirst()).sorted()
if !warm.isEmpty {
    print(String(format: "2 回目からの中央値: %.0f ms（最小 %.0f / 最大 %.0f）", warm[warm.count / 2], warm.first!, warm.last!))
}
