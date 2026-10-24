import AppKit

/// 開いた・保存したファイルごとに、ウィンドウの位置と大きさを覚える。
/// 新しいウィンドウと「無題」は覚えず、いつも決まった位置と大きさ（AppDelegate.defaultFrame）
enum WindowFrames {
    private static let key = "WindowFrames"            // [ファイルのパス: NSStringFromRect]
    private static let orderKey = "WindowFramesOrder"  // 覚えた順のパス。多すぎたら古いのから忘れる
    private static let limit = 300

    static func frame(for url: URL) -> NSRect? {
        guard let frames = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
              let string = frames[path(of: url)] else { return nil }
        let frame = NSRectFromString(string)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    static func remember(_ frame: NSRect, for url: URL) {
        let defaults = UserDefaults.standard
        let path = path(of: url)
        let string = NSStringFromRect(frame)
        var frames = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        var order = defaults.stringArray(forKey: orderKey) ?? []
        if frames[path] == string, order.last == path { return }
        frames[path] = string
        order.removeAll { $0 == path }
        order.append(path)
        while order.count > limit {
            frames.removeValue(forKey: order.removeFirst())
        }
        defaults.set(frames, forKey: key)
        defaults.set(order, forKey: orderKey)
    }

    private static func path(of url: URL) -> String {
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// 落ちたとき用の控え。保存してない文書の中身を、ときどき ~/Library/Application Support/<アプリの ID>/Recovery/ に書いておく。
/// ふつうに閉じた・終わったときは消す。次に起動したとき残ってたら（落ちた・強制終了した・電源が切れた）、その中身で開き直す
enum Recovery {
    struct Record: Codable {
        var text: String
        var path: String?        // 元のファイル（無題なら nil）
        var encoding: Int        // TextEncoding.rawValue
        var lineEnding: Int      // LineEnding.rawValue
    }

    /// 控えを書く間隔（秒）。書くのは前の控えから中身が変わったときだけ
    static let interval: TimeInterval = 15

    private static var directory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.memocho", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    private static func url(for id: UUID) -> URL? {
        return directory?.appendingPathComponent(id.uuidString + ".json")
    }

    /// 書くのと消すのは、この順番どおりに裏でやる（大きい文書でも、15 秒ごとに手が止まらんように）
    private static let queue = DispatchQueue(label: "local.memocho.recovery", qos: .utility)

    /// 裏で書いて、書けたかどうかを completion（メインスレッド）で返す
    static func write(_ record: Record, id: UUID, completion: @escaping (Bool) -> Void) {
        guard let directory = directory, let url = url(for: id) else {
            completion(false)
            return
        }
        queue.async {
            var ok = true
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(record).write(to: url, options: .atomic)
            } catch {
                ok = false
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// 消す。まだ書いてる途中の控えがあれば、書き終わってから消す（終わるときに呼んでも消し残さんように、待つ）
    static func remove(id: UUID) {
        guard let url = url(for: id) else { return }
        queue.sync {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 前回落ちたときに残った控え（古い順）
    static func leftovers() -> [(id: UUID, record: Record)] {
        guard let directory = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        let found = files.filter { $0.pathExtension == "json" }.compactMap { url -> (UUID, Record, Date)? in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (id, record, date)
        }
        return found.sorted { $0.2 < $1.2 }.map { (id: $0.0, record: $0.1) }
    }
}
