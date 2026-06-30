import Foundation

/// A "Claude just finished a turn" signal, delivered out-of-band by a Claude Code
/// `Stop` hook that touches this file. The helper watches its modification time
/// and triggers the mascot bounce whenever it advances.
enum PokeSignal {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-touchbar/poke").path

    static func lastModified() -> Date? {
        // Use a fresh stat each call. `URL.resourceValues` caches the modification
        // date on the URL instance, so a reused URL would never see new touches.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}
