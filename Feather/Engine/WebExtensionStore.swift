import CryptoKit
import Foundation
import Observation
import WebKit

nonisolated struct InstalledWebExtension: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    var enabled: Bool
    let bundled: Bool
}

/// The registry contains metadata only. Every imported extension runs from a
/// private copy, so moving its original download cannot change installed code.
@MainActor
@Observable
final class WebExtensionStore {
    static let shared = WebExtensionStore()
    static let studyToolsID = "hacjodpccmeoocakiahjfndppdeallak"

    private(set) var entries: [InstalledWebExtension] = []
    private(set) var revision = 0
    var lastError: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let registryURL: URL
    @ObservationIgnored private let bundledResourceURL: URL
    @ObservationIgnored private let files = FileManager.default

    init(directory: URL? = nil, bundledResourceURL: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Feather/Extensions", isDirectory: true)
        registryURL = self.directory.appendingPathComponent("installed.json")
        self.bundledResourceURL = bundledResourceURL ?? Bundle.main.url(forResource: "StudyTools", withExtension: nil)
            ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("StudyTools", isDirectory: true)
        do {
            try files.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if files.fileExists(atPath: registryURL.path) {
                let saved = try JSONDecoder().decode([InstalledWebExtension].self,
                                                     from: Data(contentsOf: registryURL))
                guard Set(saved.map(\.id)).count == saved.count,
                      saved.allSatisfy({ Self.isSafeIdentifier($0.id)
                          && (!$0.bundled || $0.id == Self.studyToolsID) }) else {
                    throw WebExtensionImportFailure("The installed extension registry is invalid.")
                }
                entries = saved
            } else {
                let seed = InstalledWebExtension(id: Self.studyToolsID, name: "Study Tools for Magister",
                                                 version: Self.bundledVersion(at: self.bundledResourceURL), enabled: true, bundled: true)
                try persist([seed])
                entries = [seed]
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resourceURL(for entry: InstalledWebExtension) -> URL {
        if entry.bundled {
            return bundledResourceURL
        }
        return directory.appendingPathComponent(entry.id, isDirectory: true)
    }

    func setEnabled(_ enabled: Bool, id: String) throws {
        do {
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw WebExtensionImportFailure("That extension is no longer installed.")
            }
            guard entries[index].enabled != enabled else { return }
            var updated = entries
            updated[index].enabled = enabled
            try persist(updated)
            publish(updated)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func remove(id: String) async throws {
        do {
            guard let entry = entries.first(where: { $0.id == id }) else {
                throw WebExtensionImportFailure("That extension is no longer installed.")
            }
            // Persist first: a failed write must leave the running registry intact.
            let updated = entries.filter { $0.id != id }
            try persist(updated)
            publish(updated)
            if !entry.bundled {
                let resources = resourceURL(for: entry)
                if files.fileExists(atPath: resources.path) {
                    do { try files.removeItem(at: resources) }
                    catch {
                        lastError = "The extension was removed, but its files could not be deleted: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Imports are disabled until the user reviews their requested permissions.
    @discardableResult
    func install(from source: URL) async throws -> InstalledWebExtension {
        try await install(from: source, preferredID: nil)
    }

    @discardableResult
    func installFromChromeWebStore(_ input: String) async throws -> InstalledWebExtension {
        do {
            let id = try Self.chromeWebStoreID(from: input)
            var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
            let chromeVersion = Bundle(path: "/Applications/Google Chrome.app")?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "156.0.0.0"
            components.queryItems = [
                URLQueryItem(name: "response", value: "redirect"),
                URLQueryItem(name: "prodversion", value: chromeVersion),
                URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
                URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc")
            ]
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let limit = WebExtensionDownloadLimit()
            let download: URL
            let response: URLResponse
            do { (download, response) = try await session.download(from: components.url!, delegate: limit) }
            catch {
                if limit.exceeded { throw WebExtensionImportFailure("The Chrome Web Store download exceeds the 50 MB limit.") }
                throw error
            }
            defer { try? files.removeItem(at: download) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw WebExtensionImportFailure("The Chrome Web Store could not provide that extension. Check its link and try again.")
            }
            let size = try download.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= WebExtensionDownloadLimit.maximumSize else {
                throw WebExtensionImportFailure("The Chrome Web Store download is empty or exceeds the 50 MB limit.")
            }
            return try await install(from: download, preferredID: id)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func install(from source: URL, preferredID: String?) async throws -> InstalledWebExtension {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let directory = directory
            let prepared = try await Task.detached(priority: .userInitiated) {
                try WebExtensionImporter.prepare(from: source, in: directory)
            }.value
            defer { try? files.removeItem(at: prepared.workspace) }
            let webExtension = try await WKWebExtension(resourceBaseURL: prepared.resources)
            guard webExtension.manifestVersion == 2 || webExtension.manifestVersion == 3 else {
                throw WebExtensionImportFailure("Only Manifest V2 and Manifest V3 extensions are supported.")
            }
            // Some WebKit versions expose parse errors that cannot bridge to
            // Swift.Error. Read their Objective-C descriptions without casting.
            if let errors = webExtension.value(forKey: "errors") as? NSArray,
               let error = errors.firstObject as? NSError {
                throw WebExtensionImportFailure(error.localizedDescription)
            }
            guard let name = webExtension.displayName, !name.isEmpty,
                  let version = webExtension.version, !version.isEmpty else {
                throw WebExtensionImportFailure("The extension needs a valid name and version in manifest.json.")
            }
            let manifestID: String?
            if let key = webExtension.manifest["key"] as? String,
               let publicKey = Data(base64Encoded: key, options: .ignoreUnknownCharacters), !publicKey.isEmpty {
                manifestID = WebExtensionImporter.identifier(forPublicKey: publicKey)
            } else { manifestID = nil }
            let identifiers = [manifestID, preferredID, prepared.packageID].compactMap { $0 }
            guard Set(identifiers).count <= 1 else {
                throw WebExtensionImportFailure("The package identity does not match its manifest or Chrome Web Store ID.")
            }
            let id = manifestID ?? preferredID ?? prepared.packageID ?? UUID().uuidString.lowercased()
            guard !entries.contains(where: { $0.id == id }) else {
                throw WebExtensionImportFailure("This extension is already installed. Remove it before importing another copy.")
            }
            let entry = InstalledWebExtension(id: id, name: name, version: version, enabled: false, bundled: false)
            let destination = resourceURL(for: entry)
            try files.moveItem(at: prepared.resources, to: destination)
            do { try persist(entries + [entry]) }
            catch {
                try? files.removeItem(at: destination)
                throw error
            }
            publish(entries + [entry])
            return entry
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func persist(_ updated: [InstalledWebExtension]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: registryURL, options: .atomic)
    }

    private func publish(_ updated: [InstalledWebExtension]) {
        entries = updated
        revision += 1
        lastError = nil
    }

    private static func isSafeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.unicodeScalars.allSatisfy { (97...122).contains($0.value)
                || (48...57).contains($0.value) || $0.value == 45 }
    }

    static func chromeWebStoreID(from input: String) throws -> String {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func valid(_ value: String) -> Bool {
            value.count == 32 && value.unicodeScalars.allSatisfy { (97...112).contains($0.value) }
        }
        if valid(input) { return input }
        if let url = URL(string: input), url.scheme?.lowercased() == "https",
           let host = url.host?.lowercased(), ["chromewebstore.google.com", "chrome.google.com"].contains(host) {
            let components = url.pathComponents.filter { $0 != "/" }
            let prefix = host == "chromewebstore.google.com" ? ["detail"] : ["webstore", "detail"]
            if components.starts(with: prefix), components.count == prefix.count + 1 || components.count == prefix.count + 2,
               let id = components.last, valid(id) { return id }
        }
        throw WebExtensionImportFailure("Enter a Chrome Web Store extension link or its 32-letter extension ID.")
    }

    private static func bundledVersion(at resources: URL) -> String {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Unknown" }
        return manifest["version"] as? String ?? "Unknown"
    }
}

private nonisolated final class WebExtensionDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let maximumSize = 50 * 1_024 * 1_024
    private let lock = NSLock()
    private var didExceedLimit = false
    var exceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceedLimit
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten > Int64(Self.maximumSize) || totalBytesExpectedToWrite > Int64(Self.maximumSize) else { return }
        lock.lock()
        didExceedLimit = true
        lock.unlock()
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

private nonisolated struct WebExtensionImportFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private nonisolated struct PreparedWebExtension: Sendable {
    let workspace: URL
    let resources: URL
    let packageID: String?
}

/// Archive validation runs before extraction. In particular, a symlink must
/// never be created by ditto and then followed by a later archive entry.
private nonisolated enum WebExtensionImporter {
    private static let maximumArchiveSize = 256 * 1_024 * 1_024
    private static let maximumExpandedSize = 512 * 1_024 * 1_024
    private static let maximumFiles = 50_000
    private static let skippedNames: Set<String> = [".git", "node_modules", "__MACOSX", ".DS_Store"]

    static func prepare(from source: URL, in directory: URL) throws -> PreparedWebExtension {
        guard source.isFileURL else { throw WebExtensionImportFailure("Choose a local extension folder, ZIP, or CRX file.") }
        let files = FileManager.default
        let workspace = directory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        do {
            let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
            var packageID: String?
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isAliasFile != true else {
                throw WebExtensionImportFailure("Extension imports cannot contain symbolic links or aliases.")
            }
            if values.isDirectory == true {
                var count = 0
                var size = 0
                try copyDirectory(source, to: unpacked, depth: 0, count: &count, size: &size)
            } else {
                guard let size = values.fileSize, size <= maximumArchiveSize else {
                    throw WebExtensionImportFailure("The extension archive is larger than the 256 MB import limit.")
                }
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                let payload = try zipPayload(data)
                packageID = payload.identifier
                try validateZIP(payload.zip)
                let archive = workspace.appendingPathComponent("extension.zip")
                try payload.zip.write(to: archive)
                try files.createDirectory(at: unpacked, withIntermediateDirectories: true)
                try extract(archive, to: unpacked)
            }
            var count = 0
            var size = 0
            try validateDirectory(unpacked, depth: 0, count: &count, size: &size)
            let resources = try manifestRoot(in: unpacked)
            return PreparedWebExtension(workspace: workspace, resources: resources, packageID: packageID)
        } catch {
            try? files.removeItem(at: workspace)
            throw error
        }
    }

    private static func manifestRoot(in directory: URL) throws -> URL {
        let files = FileManager.default
        if files.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) { return directory }
        let children = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !skippedNames.contains($0.lastPathComponent) }
        if children.count == 1, try children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
           files.fileExists(atPath: children[0].appendingPathComponent("manifest.json").path) {
            return children[0]
        }
        throw WebExtensionImportFailure("No manifest.json was found at the extension root. Choose the extension folder or an archive with one enclosing folder.")
    }

    private static func copyDirectory(_ source: URL, to destination: URL, depth: Int,
                                      count: inout Int, size: inout Int) throws {
        guard depth <= 64 else { throw WebExtensionImportFailure("The extension contains too many nested folders.") }
        let files = FileManager.default
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            if skippedNames.contains(child.lastPathComponent) { continue }
            let values = try validatedValues(child, count: &count, size: &size)
            let target = destination.appendingPathComponent(child.lastPathComponent, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                try copyDirectory(child, to: target, depth: depth + 1, count: &count, size: &size)
            } else { try files.copyItem(at: child, to: target) }
        }
    }

    private static func validateDirectory(_ directory: URL, depth: Int,
                                          count: inout Int, size: inout Int) throws {
        guard depth <= 64 else { throw WebExtensionImportFailure("The extension contains too many nested folders.") }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let values = try validatedValues(child, count: &count, size: &size)
            if values.isDirectory == true {
                try validateDirectory(child, depth: depth + 1, count: &count, size: &size)
            }
        }
    }

    private static func validatedValues(_ url: URL, count: inout Int, size: inout Int) throws -> URLResourceValues {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                     .isAliasFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isAliasFile != true,
              values.isDirectory == true || values.isRegularFile == true else {
            throw WebExtensionImportFailure("Extension imports can contain only regular files and folders, without links or aliases.")
        }
        count += 1
        size += values.isRegularFile == true ? max(values.fileSize ?? 0, 0) : 0
        guard count <= maximumFiles, size <= maximumExpandedSize else {
            throw WebExtensionImportFailure("The extension exceeds the 50,000 file or 512 MB expanded import limit.")
        }
        return values
    }

    static func identifier(forPublicKey data: Data) -> String {
        identifier(forBytes: Data(SHA256.hash(data: data).prefix(16)))
    }

    private static func identifier(forBytes data: Data) -> String {
        data.map {
            String(UnicodeScalar(97 + Int($0 >> 4))!) + String(UnicodeScalar(97 + Int($0 & 15))!)
        }.joined()
    }

    private static func zipPayload(_ data: Data) throws -> (zip: Data, identifier: String?) {
        guard data.count >= 4 else { throw WebExtensionImportFailure("This is not a ZIP or CRX extension archive.") }
        if data.prefix(4) != Data([0x43, 0x72, 0x32, 0x34]) { return (data, nil) }
        guard data.count >= 12 else { throw WebExtensionImportFailure("The CRX header is incomplete.") }
        let version = try uint32(data, at: 4)
        let offset: Int
        let packageID: String?
        switch version {
        case 2:
            guard data.count >= 16 else { throw WebExtensionImportFailure("The CRX2 header is incomplete.") }
            let keyLength = Int(try uint32(data, at: 8))
            offset = 16 + keyLength + Int(try uint32(data, at: 12))
            guard offset < data.count else { throw WebExtensionImportFailure("The CRX2 package has an invalid payload offset.") }
            packageID = keyLength > 0 ? identifier(forPublicKey: data.subdata(in: 16..<16 + keyLength)) : nil
        case 3:
            offset = 12 + Int(try uint32(data, at: 8))
            guard offset < data.count else { throw WebExtensionImportFailure("The CRX3 package has an invalid payload offset.") }
            packageID = try crx3Identifier(in: data.subdata(in: 12..<offset))
        default:
            throw WebExtensionImportFailure("Only CRX2 and CRX3 packages are supported.")
        }
        guard offset < data.count else { throw WebExtensionImportFailure("The CRX package has no ZIP payload.") }
        return (Data(data[offset...]), packageID)
    }

    private static func crx3Identifier(in header: Data) throws -> String? {
        var reader = ProtobufReader(data: header)
        var signedHeader: Data?
        while let field = try reader.nextField() {
            if field.number == 10_000 {
                guard field.wire == 2, signedHeader == nil else {
                    throw WebExtensionImportFailure("The CRX3 signed header is invalid or duplicated.")
                }
                signedHeader = try reader.readBytes()
            } else { try reader.skip(wire: field.wire) }
        }
        guard let signedHeader else { return nil }
        var signedReader = ProtobufReader(data: signedHeader)
        var identifier: String?
        while let field = try signedReader.nextField() {
            if field.number == 1 {
                guard field.wire == 2, identifier == nil else {
                    throw WebExtensionImportFailure("The CRX3 extension ID is invalid or duplicated.")
                }
                let bytes = try signedReader.readBytes()
                guard bytes.count == 16 else { throw WebExtensionImportFailure("The CRX3 extension ID must contain 16 bytes.") }
                identifier = self.identifier(forBytes: bytes)
            } else { try signedReader.skip(wire: field.wire) }
        }
        return identifier
    }

    private struct ProtobufReader {
        let data: Data
        private var cursor = 0

        init(data: Data) { self.data = data }

        mutating func nextField() throws -> (number: UInt64, wire: UInt64)? {
            if cursor == data.count { return nil }
            let key = try readVarint()
            let number = key >> 3
            let wire = key & 7
            guard number > 0, number < (1 << 29), [0, 1, 2, 5].contains(wire) else {
                throw WebExtensionImportFailure("The CRX3 protobuf header contains an invalid field.")
            }
            return (number, wire)
        }

        mutating func readBytes() throws -> Data {
            let count = try readVarint()
            guard count <= UInt64(data.count - cursor) else {
                throw WebExtensionImportFailure("The CRX3 protobuf field exceeds its header bounds.")
            }
            let end = cursor + Int(count)
            defer { cursor = end }
            return data.subdata(in: cursor..<end)
        }

        mutating func skip(wire: UInt64) throws {
            switch wire {
            case 0: _ = try readVarint()
            case 1: try advance(8)
            case 2: _ = try readBytes()
            case 5: try advance(4)
            default: throw WebExtensionImportFailure("The CRX3 protobuf wire type is unsupported.")
            }
        }

        private mutating func advance(_ count: Int) throws {
            guard count <= data.count - cursor else {
                throw WebExtensionImportFailure("The CRX3 protobuf header is truncated.")
            }
            cursor += count
        }

        private mutating func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard cursor < data.count else { throw WebExtensionImportFailure("The CRX3 protobuf integer is truncated.") }
                let byte = data[cursor]
                cursor += 1
                guard index < 9 || byte <= 1 else { throw WebExtensionImportFailure("The CRX3 protobuf integer is too large.") }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte & 0x80 == 0 { return value }
            }
            throw WebExtensionImportFailure("The CRX3 protobuf integer is too large.")
        }
    }

    private static func validateZIP(_ data: Data) throws {
        guard data.count >= 22 else { throw WebExtensionImportFailure("The ZIP archive is incomplete.") }
        let minimum = max(0, data.count - 22 - 65_535)
        var end: Int?
        for position in stride(from: data.count - 22, through: minimum, by: -1) {
            if try uint32(data, at: position) == 0x06054b50,
               position + 22 + Int(try uint16(data, at: position + 20)) == data.count {
                end = position
                break
            }
        }
        guard let end else { throw WebExtensionImportFailure("The ZIP directory is missing or invalid.") }
        let count = Int(try uint16(data, at: end + 10))
        let centralSize = Int(try uint32(data, at: end + 12))
        let centralOffset = Int(try uint32(data, at: end + 16))
        guard try uint16(data, at: end + 4) == 0, try uint16(data, at: end + 6) == 0,
              Int(try uint16(data, at: end + 8)) == count, count < 65_535,
              centralSize != Int(UInt32.max), centralOffset != Int(UInt32.max),
              count <= maximumFiles, centralOffset + centralSize <= end else {
            throw WebExtensionImportFailure("Multipart, ZIP64, or oversized ZIP archives are not supported.")
        }
        var cursor = centralOffset
        var expandedSize = 0
        var names = Set<String>()
        for _ in 0..<count {
            guard cursor + 46 <= centralOffset + centralSize,
                  try uint32(data, at: cursor) == 0x02014b50 else {
                throw WebExtensionImportFailure("The ZIP directory contains an invalid entry.")
            }
            let flags = try uint16(data, at: cursor + 8)
            let compressedSize = Int(try uint32(data, at: cursor + 20))
            let size = Int(try uint32(data, at: cursor + 24))
            let nameLength = Int(try uint16(data, at: cursor + 28))
            let extraLength = Int(try uint16(data, at: cursor + 30))
            let commentLength = Int(try uint16(data, at: cursor + 32))
            let attributes = try uint32(data, at: cursor + 38)
            let localOffset = Int(try uint32(data, at: cursor + 42))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= centralOffset + centralSize, nameLength > 0, flags & 1 == 0,
                  compressedSize != Int(UInt32.max), size != Int(UInt32.max), localOffset != Int(UInt32.max),
                  try uint16(data, at: cursor + 34) == 0 else {
                throw WebExtensionImportFailure("Encrypted, multipart, or invalid ZIP entries are not supported.")
            }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) else {
                throw WebExtensionImportFailure("The ZIP archive contains an unsafe file path.")
            }
            let normalizedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .precomposedStringWithCanonicalMapping.lowercased()
            guard !normalizedName.isEmpty, names.insert(normalizedName).inserted else {
                throw WebExtensionImportFailure("The ZIP archive contains duplicate file paths.")
            }
            let fileType = (attributes >> 16) & 0xf000
            guard fileType == 0 || fileType == 0x8000 || fileType == 0x4000 else {
                throw WebExtensionImportFailure("Extension archives cannot contain symbolic links or special files.")
            }
            expandedSize += size
            guard expandedSize <= maximumExpandedSize,
                  localOffset + 30 <= centralOffset,
                  try uint32(data, at: localOffset) == 0x04034b50 else {
                throw WebExtensionImportFailure("The ZIP archive is invalid or exceeds the 512 MB expanded import limit.")
            }
            let localNameLength = Int(try uint16(data, at: localOffset + 26))
            let localExtraLength = Int(try uint16(data, at: localOffset + 28))
            let localEnd = localOffset + 30 + localNameLength + localExtraLength
            guard localEnd + compressedSize <= centralOffset, localNameLength == nameLength,
                  try uint16(data, at: localOffset + 6) == flags,
                  data.subdata(in: localOffset + 30..<localOffset + 30 + localNameLength) == nameData else {
                throw WebExtensionImportFailure("The ZIP archive has inconsistent file headers.")
            }
            cursor = next
        }
        guard cursor == centralOffset + centralSize else {
            throw WebExtensionImportFailure("The ZIP directory has unexpected trailing data.")
        }
    }

    private static func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw WebExtensionImportFailure("The archive header is incomplete.") }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw WebExtensionImportFailure("The archive header is incomplete.") }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func extract(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--noqtn", archive.path, destination.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data.prefix(2_000), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw WebExtensionImportFailure(detail.isEmpty ? "The extension archive could not be extracted." : detail)
        }
    }
}
