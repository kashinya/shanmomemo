// CI 用: フォントを名前で引くのにかかる時間を測る（起動が止まる原因を探す）
import AppKit

func time(_ label: String, _ body: () -> Any?) {
    let start = DispatchTime.now()
    let result = body()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    print(String(format: "%@: %.0f ms → %@", label, ms, result.map { "\($0)" } ?? "nil"))
}
time("Osaka-Mono") { NSFont(name: "Osaka-Mono", size: 13) }
time("Osaka-Mono 2 回目") { NSFont(name: "Osaka-Mono", size: 13) }
time("PC_9800") { NSFont(name: "PC_9800", size: 16) }
time("userFixedPitchFont") { NSFont.userFixedPitchFont(ofSize: 13) }
time("monospacedSystemFont") { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
