import Foundation

enum LineEnding: Int, CaseIterable {
    case crlf = 0
    case lf = 1
    case cr = 2

    var characters: String {
        switch self {
        case .crlf: return "\r\n"
        case .lf: return "\n"
        case .cr: return "\r"
        }
    }

    var displayName: String {
        switch self {
        case .crlf: return "Windows (CRLF)"
        case .lf: return "Unix (LF)"
        case .cr: return "Macintosh (CR)"
        }
    }
}

enum TextEncoding: Int, CaseIterable {
    case utf8 = 0
    case utf8BOM = 1
    case utf16LE = 2
    case utf16BE = 3
    case shiftJIS = 4
    case eucJP = 5

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 (BOM 付き)"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .shiftJIS: return "Shift_JIS"
        case .eucJP: return "EUC-JP"
        }
    }

    /// Windows の「ANSI」(日本語版) = CP932。①や㈱、～ の扱いが Windows と揃う。
    static let cp932: String.Encoding = {
        let cfEncoding = CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }()

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .shiftJIS: return TextEncoding.cp932
        case .eucJP: return .japaneseEUC
        }
    }

    var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default: return []
        }
    }

    /// 表せない文字があると nil（allowLossy なら「?」に置き換え）
    func encode(_ text: String, allowLossy: Bool) -> Data? {
        guard let body = text.data(using: stringEncoding, allowLossyConversion: allowLossy) else { return nil }
        if bom.isEmpty { return body }
        var data = Data(bom)
        data.append(body)
        return data
    }
}

struct DecodedText {
    let text: String
    let encoding: TextEncoding
    /// 読めないバイトを置換文字にした（＝そのまま保存すると元に戻らん）
    let lossy: Bool
}

enum EncodingDetector {

    /// 自動検出: BOM → BOM なし UTF-16 → UTF-8 → Shift_JIS / EUC-JP
    static func decode(_ data: Data) -> DecodedText {
        let bytes = [UInt8](data)

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return decode(bytes, from: 3, as: .utf8BOM) }
        if bytes.starts(with: [0xFF, 0xFE]) { return decode(bytes, from: 2, as: .utf16LE) }
        if bytes.starts(with: [0xFE, 0xFF]) { return decode(bytes, from: 2, as: .utf16BE) }

        if let littleEndian = guessBOMlessUTF16(bytes) {
            let encoding: TextEncoding = littleEndian ? .utf16LE : .utf16BE
            if let text = String(data: data, encoding: encoding.stringEncoding) {
                return DecodedText(text: text, encoding: encoding, lossy: false)
            }
        }

        if let text = String(data: data, encoding: .utf8) {
            return DecodedText(text: text, encoding: .utf8, lossy: false)
        }

        let sjis = String(data: data, encoding: TextEncoding.cp932)
        let euc = String(data: data, encoding: .japaneseEUC)
        if let s = sjis, let e = euc {
            if japaneseScore(e) > japaneseScore(s) {
                return DecodedText(text: e, encoding: .eucJP, lossy: false)
            }
            return DecodedText(text: s, encoding: .shiftJIS, lossy: false)
        }
        if let s = sjis { return DecodedText(text: s, encoding: .shiftJIS, lossy: false) }
        if let e = euc { return DecodedText(text: e, encoding: .eucJP, lossy: false) }

        return lossyGuess(data)
    }

    /// 文字コードを指定して読む（「文字コードを指定して開き直す」用）
    static func decode(_ data: Data, as encoding: TextEncoding) -> DecodedText {
        let bytes = [UInt8](data)
        var start = 0
        switch encoding {
        case .utf8, .utf8BOM:
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }
        case .utf16LE:
            if bytes.starts(with: [0xFF, 0xFE]) { start = 2 }
        case .utf16BE:
            if bytes.starts(with: [0xFE, 0xFF]) { start = 2 }
        case .shiftJIS, .eucJP:
            break
        }
        return decode(bytes, from: start, as: encoding)
    }

    private static func decode(_ bytes: [UInt8], from start: Int, as encoding: TextEncoding) -> DecodedText {
        let body = Data(bytes[start...])
        if let text = String(data: body, encoding: encoding.stringEncoding) {
            return DecodedText(text: text, encoding: encoding, lossy: false)
        }
        return DecodedText(text: lossyDecode(body, as: encoding), encoding: encoding, lossy: true)
    }

    private static func lossyDecode(_ data: Data, as encoding: TextEncoding) -> String {
        switch encoding {
        case .utf8, .utf8BOM:
            return String(decoding: data, as: UTF8.self)
        case .utf16LE, .utf16BE:
            let bytes = [UInt8](data)
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2)
            var i = 0
            while i + 1 < bytes.count {
                let a = UInt16(bytes[i])
                let b = UInt16(bytes[i + 1])
                units.append(encoding == .utf16LE ? (a | (b << 8)) : ((a << 8) | b))
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        case .shiftJIS, .eucJP:
            if let text = lossyConvert(data, candidates: [encoding.stringEncoding]).text {
                return text
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// どれでも素直に読めんときは、一番それっぽいのを置換文字込みで拾う
    private static func lossyGuess(_ data: Data) -> DecodedText {
        let candidates: [String.Encoding] = [.utf8, TextEncoding.cp932, .japaneseEUC]
        let result = lossyConvert(data, candidates: candidates)
        if let text = result.text, let raw = result.encoding {
            let encoding: TextEncoding
            if raw == TextEncoding.cp932.rawValue || raw == String.Encoding.shiftJIS.rawValue {
                encoding = .shiftJIS
            } else if raw == String.Encoding.japaneseEUC.rawValue {
                encoding = .eucJP
            } else {
                encoding = .utf8
            }
            return DecodedText(text: text, encoding: encoding, lossy: true)
        }
        return DecodedText(text: String(decoding: data, as: UTF8.self), encoding: .utf8, lossy: true)
    }

    private static func lossyConvert(_ data: Data, candidates: [String.Encoding]) -> (text: String?, encoding: UInt?) {
        var converted: NSString?
        var usedLossy: ObjCBool = false
        let options: [StringEncodingDetectionOptionsKey: Any] = [
            .suggestedEncodingsKey: candidates.map { NSNumber(value: $0.rawValue) },
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: true,
        ]
        let raw = NSString.stringEncoding(for: data,
                                          encodingOptions: options,
                                          convertedString: &converted,
                                          usedLossyConversion: &usedLossy)
        guard raw != 0, let text = converted else { return (nil, nil) }
        return (text as String, raw)
    }

    /// BOM なし UTF-16 は、ASCII 主体ならゼロバイトの偏りで分かる
    /// 戻り値: true = LE, false = BE, nil = UTF-16 っぽくない
    private static func guessBOMlessUTF16(_ bytes: [UInt8]) -> Bool? {
        let count = min(bytes.count, 8192) & ~1
        guard count >= 4 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        var i = 0
        while i < count {
            if bytes[i] == 0 { evenZeros += 1 }
            if bytes[i + 1] == 0 { oddZeros += 1 }
            i += 2
        }
        let pairs = count / 2
        if oddZeros * 10 >= pairs * 4 && evenZeros * 20 <= pairs { return true }
        if evenZeros * 10 >= pairs * 4 && oddZeros * 20 <= pairs { return false }
        return nil
    }

    /// 間違った方で読むと、ひらがなが消えて「､･｡」や外字が増え、半角カナと全角が 1 文字おきに混ざる。
    /// 半角カナだけの CSV（全銀データとか）は Shift_JIS と判定されるようにしてある。
    private static func japaneseScore(_ text: String) -> Int {
        var score = 0
        var previous = 0   // 0: ASCII など / 1: 半角カナ / 2: 全角
        for scalar in text.unicodeScalars {
            var current = 0
            switch scalar.value {
            case 0x3041...0x309F: score += 3; current = 2                    // ひらがな
            case 0x30A0...0x30FF: score += 2; current = 2                    // カタカナ
            case 0x4E00...0x9FFF: score += 1; current = 2                    // 漢字
            case 0x3000...0x303F, 0xFF01...0xFF60: score += 1; current = 2   // 和文の記号・全角英数
            case 0xFF61...0xFF65: score -= 2; current = 1                    // 半角の ｡｢｣､･
            case 0xFF66...0xFF9F: score += 1; current = 1                    // 半角カナ
            case 0xE000...0xF8FF: score -= 3; current = 2                    // 外字
            default: break
            }
            if (previous == 1 && current == 2) || (previous == 2 && current == 1) {
                score -= 2
            }
            previous = current
        }
        return score
    }
}

enum LineEndings {
    /// 一番多い改行の種類。改行が無ければ nil
    static func detect(in text: String) -> LineEnding? {
        var crlf = 0
        var lf = 0
        var cr = 0
        var previousWasCR = false
        for unit in text.utf16 {
            if unit == 13 {
                if previousWasCR { cr += 1 }
                previousWasCR = true
            } else {
                if unit == 10 {
                    if previousWasCR { crlf += 1 } else { lf += 1 }
                } else if previousWasCR {
                    cr += 1
                }
                previousWasCR = false
            }
        }
        if previousWasCR { cr += 1 }
        if crlf == 0 && lf == 0 && cr == 0 { return nil }
        if crlf >= lf && crlf >= cr { return .crlf }
        if lf >= cr { return .lf }
        return .cr
    }

    /// 編集中は LF だけにしておき、保存時に元の改行へ戻す
    static func normalize(_ text: String) -> String {
        guard text.utf16.contains(13) else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
            .replacingOccurrences(of: "\r", with: "\n", options: .literal)
    }

    static func convert(_ text: String, to ending: LineEnding) -> String {
        if ending == .lf { return text }
        return text.replacingOccurrences(of: "\n", with: ending.characters, options: .literal)
    }
}

enum FileIO {
    struct Loaded {
        let text: String
        let encoding: TextEncoding
        let lineEnding: LineEnding
        let lossy: Bool
    }

    static func load(_ url: URL, encoding forced: TextEncoding?) throws -> Loaded {
        let data = try Data(contentsOf: url)
        let decoded: DecodedText
        if let forced = forced {
            decoded = EncodingDetector.decode(data, as: forced)
        } else {
            decoded = EncodingDetector.decode(data)
        }
        let ending = LineEndings.detect(in: decoded.text) ?? .lf
        return Loaded(text: LineEndings.normalize(decoded.text),
                      encoding: decoded.encoding,
                      lineEnding: ending,
                      lossy: decoded.lossy)
    }

    /// 既存ファイルは中身だけ差し替える。パーミッション（実行権限とか）とシンボリックリンクはそのまま。
    static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let target = url.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: target.path) else {
            try data.write(to: target, options: .atomic)
            return
        }
        do {
            let tempDirectory = try fileManager.url(for: .itemReplacementDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: target,
                                                    create: true)
            defer { try? fileManager.removeItem(at: tempDirectory) }
            let tempFile = tempDirectory.appendingPathComponent(target.lastPathComponent)
            try data.write(to: tempFile)
            _ = try fileManager.replaceItemAt(target, withItemAt: tempFile)
        } catch {
            // 置き場所にテンポラリを作れん場合などは、その場で上書き
            try data.write(to: target)
        }
    }
}
