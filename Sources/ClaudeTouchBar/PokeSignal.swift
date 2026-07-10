import Foundation

/// A durable queue of completion animations. Each event is a separate file so
/// two answers that finish inside one UI polling interval cannot collapse into
/// a single bounce. The legacy poke timestamp remains during migration.
enum PokeSignal {
    static var path: String { legacyPokeURL(in: PetStore.defaultDirectory()).path }

    static func legacyPokeURL(in directory: URL) -> URL {
        directory.appendingPathComponent("poke", isDirectory: false)
    }

    static func eventsDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("bounce-events", isDirectory: true)
    }

    static func lastModified(in directory: URL = PetStore.defaultDirectory()) -> Date? {
        // Use a fresh stat each call. `URL.resourceValues` caches the modification
        // date on the URL instance, so a reused URL would never see new touches.
        let attributes = try? FileManager.default.attributesOfItem(atPath: legacyPokeURL(in: directory).path)
        return attributes?[.modificationDate] as? Date
    }

    @discardableResult
    static func enqueue(in directory: URL = PetStore.defaultDirectory()) throws -> URL {
        try prepare(directory)
        let eventURL = eventsDirectory(in: directory)
            .appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString)", isDirectory: false)
        try Data().write(to: eventURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: eventURL.path
        )

        // Keep old helpers functional during an in-place upgrade. The new
        // helper consumes the queue above and ignores this timestamp.
        let legacyURL = legacyPokeURL(in: directory)
        try Data().write(to: legacyURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: legacyURL.path
        )
        return eventURL
    }

    static func pending(in directory: URL = PetStore.defaultDirectory()) -> [URL] {
        let eventsURL = eventsDirectory(in: directory)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: eventsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }

    static func consume(_ eventURL: URL) throws {
        try FileManager.default.removeItem(at: eventURL)
    }

    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: eventsDirectory(in: directory),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: eventsDirectory(in: directory).path
        )
    }
}
