// 起動の速さを測る（CI 用）。アプリを環境変数 MEMOCHO_LAUNCH_PROBE 付きで何回か起動して、
// プロセスが始まってから最初のウィンドウを描き終わるまでの時間（アプリが自分で測って出す）を集める。
//   swiftc -O -o launch-time tools/launch-time.swift && ./launch-time "build/メモ帳.app" 6
// 1 回目はビルドしたてのアプリを初めて起動したとき（macOS の署名の確認なども入る）。2 回目からが普段の起動
import Foundation

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

// 実行ファイルを直接起動すると、CI では applicationDidFinishLaunching まで来んかったので、
// ふだんと同じく LaunchServices（open コマンド）で起動する
let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("memocho-launch-probe.log")

var times: [Double] = []
for run in 1...runs {
    try? FileManager.default.removeItem(at: logURL)
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var arguments = ["-W", "-n", "-F", "--env", "MEMOCHO_LAUNCH_PROBE=1"]
    if ProcessInfo.processInfo.environment["MEMOCHO_PROBE_GEOMETRY"] != nil {
        arguments += ["--env", "MEMOCHO_PROBE_GEOMETRY=1"]   // ルーラーと本文の並び方も出させる
    }
    process.arguments = arguments + ["--stderr", logURL.path, app.path]
    do {
        try process.run()
    } catch {
        print("起動できない: \(error)")
        exit(1)
    }
    let deadline = Date().addingTimeInterval(15)
    while process.isRunning, Date() < deadline {
        usleep(10_000)
    }
    if process.isRunning {
        process.terminate()
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-9", "-f", "Contents/MacOS/\(executable)"]
        try? kill.run()
        kill.waitUntilExit()
    }
    process.waitUntilExit()
    let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    // 「launch-probe 区切り: ミリ秒」の行を拾う。window まで来てたら測れた
    let marks = output.split(separator: "\n").compactMap { line -> (String, Double)? in
        guard line.hasPrefix("launch-probe "), !line.hasPrefix("launch-probe geometry"), let colon = line.firstIndex(of: ":"),
              let value = Double(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (String(line[line.index(line.startIndex, offsetBy: "launch-probe ".count)..<colon]), value)
    }
    let detail = marks.map { String(format: "%@ %.0f", $0.0, $0.1) }.joined(separator: " → ")
    for line in output.split(separator: "\n") where line.hasPrefix("launch-probe geometry: ") {
        print(line)
    }
    if let window = marks.first(where: { $0.0 == "window" }) {
        times.append(window.1)
        print(String(format: "%ld 回目: %.0f ms（%@）", run, window.1, detail))
    } else {
        print("\(run) 回目: ウィンドウまで来んかった（\(detail.isEmpty ? "区切りなし" : detail)、終了コード \(process.terminationStatus)）")
        print(output.suffix(2000))
    }
    usleep(500_000)
}

let warm = Array(times.dropFirst()).sorted()
if !warm.isEmpty {
    print(String(format: "2 回目からの中央値: %.0f ms（最小 %.0f / 最大 %.0f）", warm[warm.count / 2], warm.first!, warm.last!))
}
