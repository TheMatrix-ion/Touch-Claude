import AppKit

/// Loads mascot sprites from the `assets` directory next to `bin`.
enum ClaudePixelImage {
    static let image = load(named: "claude-pixel-transparent.png")

    static func load(named filename: String) -> NSImage {
        let url = assetDirectory.appendingPathComponent(filename)
        guard let image = NSImage(contentsOf: url) else {
            Log.debug("could not load mascot asset at \(url.path)")
            return NSImage(size: NSSize(width: 68, height: 59))
        }
        return image
    }

    private static let assetDirectory: URL = {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
    }()
}
