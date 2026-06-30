import AppKit

/// The pixel-art Claude mascot, embedded as base64 so the single binary stays
/// self-contained (the installer only copies the executable, no asset files).
/// Source: assets/claude-pixel.png (68x59).
enum ClaudePixelImage {
    static let image: NSImage = {
        guard
            let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
            let image = NSImage(data: data)
        else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        return image
    }()

    private static let base64 =
        "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" +
        "/mnjjP8DrkhD//EMaa8AAAAASUVORK5CYII="
}
