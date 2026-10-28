import Foundation
import os

/// Reads and writes `session.json`. Writes are atomic and happen off the main
/// thread unless the app is quitting.
final class SessionStore {
    let url: URL
    private let queue = DispatchQueue(label: "Feather.SessionStore", qos: .utility)
    private let log = Logger(subsystem: "dev.nesbes.Feather", category: "Session")

    init(url: URL) {
        self.url = url
    }

    func load() -> SessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try SessionCodec.decode(data)
        } catch {
            log.error("Ignoring unreadable session: \(error.localizedDescription)")
            return nil
        }
    }

    func save(_ record: SessionRecord, synchronously: Bool) {
        let url = self.url
        let log = self.log
        if synchronously {
            queue.sync { Self.write(record, to: url, log: log) }
        } else {
            queue.async { Self.write(record, to: url, log: log) }
        }
    }

    private nonisolated static func write(_ record: SessionRecord, to url: URL, log: Logger) {
        do {
            try SessionCodec.encode(record).write(to: url, options: .atomic)
        } catch {
            log.error("Session save failed: \(error.localizedDescription)")
        }
    }
}
