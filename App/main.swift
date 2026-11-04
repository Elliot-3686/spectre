import AppKit

// Headless tools used by CI and for validation (no UI, no audio permission needed).
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--snapshots") {
    let dir = i + 1 < arguments.count ? arguments[i + 1] : "snapshots"
    exit(SnapshotTool.run(outputDirectory: dir))
}
if let i = arguments.firstIndex(of: "--benchmark") {
    let path = i + 1 < arguments.count ? arguments[i + 1] : "benchmark.md"
    exit(BenchmarkTool.run(reportPath: path))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
