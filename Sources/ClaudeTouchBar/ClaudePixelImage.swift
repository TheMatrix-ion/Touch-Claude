import AppKit

/// Loads mascot sprites from the `assets` directory next to `bin`.
enum ClaudePixelImage {
    static let image = load(named: "claude-pixel-transparent.png")

    static func load(named filename: String) -> NSImage {
        for directory in assetDirectories {
            let url = directory.appendingPathComponent(filename)
            if let image = NSImage(contentsOf: url) { return image }
        }
        Log.debug("could not load mascot asset \(filename)")
        return NSImage(size: NSSize(width: 68, height: 59))
    }

    private static let assetDirectories: [URL] = {
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL {
            directories.append(resources)
        }
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        directories.append(executable
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true))
        return directories
    }()
}
