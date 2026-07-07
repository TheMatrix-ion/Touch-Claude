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

    /// Bump the poke file's modification date, exactly like the Stop hook's
    /// `touch` does. Used by `clawd jump` to simulate Claude finishing a turn so
    /// the mascot hops on demand.
    static func poke() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // Writing (creating/overwriting) advances the modification date, which is
        // all the helper watches; the file's contents are irrelevant.
        try Data().write(to: URL(fileURLWithPath: path))
    }
}
