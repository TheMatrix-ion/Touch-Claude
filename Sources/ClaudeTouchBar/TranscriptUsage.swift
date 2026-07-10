import Foundation

enum TranscriptUsageError: Error, CustomStringConvertible {
    case missingTranscript(String)
    case cannotRead(String, Error)

    var description: String {
        switch self {
        case .missingTranscript(let path):
            return "Claude transcript does not exist at \(path)"
        case .cannotRead(let path, let error):
            return "cannot read Claude transcript at \(path): \(error)"
        }
    }
}

/// Reads only transcript metadata and numeric usage counters. Prompt text,
/// assistant content, and tool input/output are never retained or returned.
struct TranscriptUsageScanner {
    private struct PromptMoment {
        let id: String
        let timestamp: Date
    }

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func usage(transcriptURL: URL, promptID: String) throws -> TokenUsageCounters {
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            throw TranscriptUsageError.missingTranscript(transcriptURL.path)
        }

        let timeline = try mainPromptTimeline(in: transcriptURL)
        let mainPromptIDs = Set(timeline.map(\.id))
        var files = [transcriptURL.standardizedFileURL]
        files.append(contentsOf: childTranscriptURLs(for: transcriptURL))

        var messageSnapshots: [String: TokenUsageCounters] = [:]
        for file in files {
            let isMain = file.standardizedFileURL == transcriptURL.standardizedFileURL
            let fileOwner = isMain ? nil : owner(at: try firstTimestamp(in: file), timeline: timeline)
            var carriedPromptID: String?

            try forEachJSONObject(in: file) { object in
                if let recordPromptID = object["promptId"] as? String, !recordPromptID.isEmpty {
                    carriedPromptID = recordPromptID
                }

                guard object["type"] as? String == "assistant" else { return }
                if isMain, object["isSidechain"] as? Bool == true { return }
                guard let message = object["message"] as? [String: Any],
                      let messageID = message["id"] as? String,
                      !messageID.isEmpty,
                      let usageObject = message["usage"] as? [String: Any]
                else { return }

                let ownerPrompt: String?
                if let carriedPromptID, mainPromptIDs.contains(carriedPromptID) {
                    ownerPrompt = carriedPromptID
                } else if isMain {
                    ownerPrompt = carriedPromptID
                } else {
                    ownerPrompt = fileOwner
                }
                guard ownerPrompt == promptID else { return }

                let snapshot = TokenUsageCounters(
                    inputTokens: integer(usageObject["input_tokens"]),
                    outputTokens: integer(usageObject["output_tokens"]),
                    cacheCreationTokens: integer(usageObject["cache_creation_input_tokens"]),
                    cacheReadTokens: integer(usageObject["cache_read_input_tokens"])
                )
                var existing = messageSnapshots[messageID] ?? .zero
                existing.mergeMaximum(snapshot)
                messageSnapshots[messageID] = existing
            }
        }

        return messageSnapshots.values.reduce(into: .zero) { total, snapshot in
            total.add(snapshot)
        }
    }

    /// Stop payloads in some Claude Code versions omit `prompt_id`. Recover it
    /// from the final top-level prompt metadata without inspecting user text.
    func latestPromptID(transcriptURL: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            throw TranscriptUsageError.missingTranscript(transcriptURL.path)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: transcriptURL)
        } catch {
            throw TranscriptUsageError.cannotRead(transcriptURL.path, error)
        }
        defer { try? handle.close() }

        do {
            var offset = try handle.seekToEnd()
            var carry = Data()
            let chunkSize: UInt64 = 64 * 1_024

            while offset > 0 {
                let start = offset > chunkSize ? offset - chunkSize : 0
                try handle.seek(toOffset: start)
                let chunk = try handle.read(upToCount: Int(offset - start)) ?? Data()
                var combined = chunk
                combined.append(carry)
                let fragments = combined.split(separator: 0x0A, omittingEmptySubsequences: false)

                let completeFragments: ArraySlice<Data.SubSequence>
                if start > 0 {
                    carry = fragments.first.map { Data($0) } ?? combined
                    completeFragments = fragments.dropFirst()
                } else {
                    carry.removeAll(keepingCapacity: false)
                    completeFragments = fragments[...]
                }

                for fragment in completeFragments.reversed() {
                    guard !fragment.isEmpty,
                          let object = try? JSONSerialization.jsonObject(with: Data(fragment)) as? [String: Any],
                          object["isSidechain"] as? Bool != true,
                          let promptID = object["promptId"] as? String,
                          !promptID.isEmpty
                    else { continue }
                    return promptID
                }
                offset = start
            }
            return nil
        } catch {
            throw TranscriptUsageError.cannotRead(transcriptURL.path, error)
        }
    }

    private func mainPromptTimeline(in url: URL) throws -> [PromptMoment] {
        var firstSeen: [String: Date] = [:]
        try forEachJSONObject(in: url) { object in
            guard let promptID = object["promptId"] as? String,
                  !promptID.isEmpty,
                  firstSeen[promptID] == nil,
                  let timestamp = parseTimestamp(object["timestamp"])
            else { return }
            firstSeen[promptID] = timestamp
        }
        return firstSeen.map { PromptMoment(id: $0.key, timestamp: $0.value) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func childTranscriptURLs(for mainURL: URL) -> [URL] {
        let sessionDirectory = mainURL.deletingPathExtension()
        guard let enumerator = FileManager.default.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            urls.append(url.standardizedFileURL)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func firstTimestamp(in url: URL) throws -> Date? {
        var result: Date?
        try forEachJSONObject(in: url) { object in
            if result == nil { result = parseTimestamp(object["timestamp"]) }
        }
        return result
    }

    private func owner(at timestamp: Date?, timeline: [PromptMoment]) -> String? {
        guard let timestamp else { return nil }
        return timeline.last(where: { $0.timestamp <= timestamp })?.id
    }

    private func parseTimestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let date = dateFormatter.date(from: text) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: text)
    }

    private func integer(_ value: Any?) -> Int64 {
        max(0, (value as? NSNumber)?.int64Value ?? 0)
    }

    private func forEachJSONObject(in url: URL, _ body: ([String: Any]) -> Void) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw TranscriptUsageError.cannotRead(url.path, error)
        }
        defer { try? handle.close() }

        var buffer = Data()
        do {
            while true {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                buffer.append(chunk)
                consumeCompleteLines(from: &buffer, body)
            }
            if !buffer.isEmpty { parseLine(buffer, body) }
        } catch {
            throw TranscriptUsageError.cannotRead(url.path, error)
        }
    }

    private func consumeCompleteLines(from buffer: inout Data, _ body: ([String: Any]) -> Void) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            parseLine(line, body)
        }
    }

    private func parseLine(_ line: Data, _ body: ([String: Any]) -> Void) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        body(object)
    }
}
