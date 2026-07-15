import AppKit

enum ClaudePetImages {
    static func image(for expression: PetExpression) -> NSImage {
        switch expression {
        case .normal:
            return ClaudePixelImage.image
        case .distressed:
            return distressed
        case .sleeping:
            return sleeping
        }
    }

    private static let distressed = ClaudePixelImage.load(named: "claude-distressed.png")
    private static let sleeping = ClaudePixelImage.load(named: "claude-sleeping.png")
}
