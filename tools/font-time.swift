// CI 用: フォントを引くのにかかる時間を測る（起動が止まる原因を探す）。
//   font-time <名前>  … NSFont(name:) で 2 回引く。名前が system / fixed なら monospacedSystemFont / userFixedPitchFont
import AppKit

setvbuf(stdout, nil, _IONBF, 0)
let name = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : "Osaka-Mono"
for attempt in 1...2 {
    let start = DispatchTime.now()
    let font: NSFont?
    switch name {
    case "system": font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    case "fixed": font = NSFont.userFixedPitchFont(ofSize: 13)
    case "available":
        let names = NSFontManager.shared.availableFonts
        print("availableFonts: \(names.count) 個、Osaka 入り: \(names.filter { $0.hasPrefix("Osaka") })")
        font = nil
    case "ctnames":
        let names = (CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? []
        print("CTFontManagerCopyAvailablePostScriptNames: \(names.count) 個、Osaka 入り: \(names.filter { $0.hasPrefix("Osaka") })")
        font = nil
    default: font = NSFont(name: name, size: 13)
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    print(String(format: "%@ %ld 回目: %.0f ms → %@", name, attempt, ms, font?.fontName ?? "nil"))
}
