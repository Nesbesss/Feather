import CryptoKit
import Foundation
import XCTest

@MainActor
final class WebExtensionImportTests: XCTestCase {
    func testFolderImportCopiesResourcesAndStartsDisabled() async throws {
        let fixture = try sandbox()
        let source = try extensionFolder(in: fixture.root)
        try write("body { color: green; }", to: source.appendingPathComponent("assets/nested/theme.css"))
        try write("License fixture", to: source.appendingPathComponent("LICENSE"))
        try write("private repository data", to: source.appendingPathComponent(".git/config"))

        let entry = try await fixture.store.install(from: source)
        XCTAssertEqual(entry.name, "Feather fixture")
        XCTAssertEqual(entry.version, "1.2.3")
        XCTAssertFalse(entry.enabled)
        XCTAssertFalse(entry.bundled)
        let resources = fixture.store.resourceURL(for: entry)
        XCTAssertNotEqual(resources, source)
        XCTAssertEqual(try String(contentsOf: resources.appendingPathComponent("LICENSE"), encoding: .utf8), "License fixture")
        XCTAssertEqual(try String(contentsOf: resources.appendingPathComponent("assets/nested/theme.css"), encoding: .utf8), "body { color: green; }")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resources.appendingPathComponent(".git").path))
        try write("changed original", to: source.appendingPathComponent("LICENSE"))
        XCTAssertEqual(try String(contentsOf: resources.appendingPathComponent("LICENSE"), encoding: .utf8), "License fixture")
        try assertNoImportWorkspaces(in: fixture.directory)
    }

    func testZIPCRX2AndCRX3ImportsPreserveDirectoryLayout() async throws {
        let fixture = try sandbox()
        let zip = TestExtensionZIP.make([
            .init(name: "manifest.json", data: try manifest()),
            .init(name: "src/content.js", data: Data("document.title = 'fixture'".utf8)),
            .init(name: "LICENSE", data: Data("Keep this license".utf8))
        ])
        var crx2 = Data("Cr24".utf8)
        crx2 += littleEndian(2)
        crx2 += littleEndian(3)
        crx2 += littleEndian(4)
        crx2 += Data(repeating: 0x31, count: 7)
        crx2 += zip
        var crx3 = Data("Cr24".utf8)
        crx3 += littleEndian(3)
        crx3 += littleEndian(2)
        crx3 += Data([0x08, 0x01])
        crx3 += zip

        for (name, data) in [("fixture.zip", zip), ("fixture2.crx", crx2), ("fixture3.crx", crx3)] {
            let source = fixture.root.appendingPathComponent(name)
            try data.write(to: source)
            let entry = try await fixture.store.install(from: source)
            XCTAssertFalse(entry.enabled, name)
            let resources = fixture.store.resourceURL(for: entry)
            XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("src/content.js").path), name)
            XCTAssertEqual(try String(contentsOf: resources.appendingPathComponent("LICENSE"), encoding: .utf8), "Keep this license")
        }
        XCTAssertEqual(fixture.store.entries.count, 4)
        try assertNoImportWorkspaces(in: fixture.directory)
    }

    func testCRX2AndCRX3PreserveTheirChromeExtensionIdentities() async throws {
        let fixture = try sandbox()
        let zip = TestExtensionZIP.make([.init(name: "manifest.json", data: try manifest())])
        let key = Data("Feather CRX2 public key".utf8)
        let crx2 = Data("Cr24".utf8) + littleEndian(2) + littleEndian(UInt32(key.count)) + littleEndian(0) + key + zip
        let source2 = fixture.root.appendingPathComponent("identified2.crx")
        try crx2.write(to: source2)
        let entry2 = try await fixture.store.install(from: source2)
        XCTAssertEqual(entry2.id, "mdjogohndgchdhljdhgodcehbeajpdga")
        await assertRejected(source2, by: fixture.store)

        let signed = Data([0x0a, 0x10]) + Data(0..<16)
        var header = Data([0x08, 0x01, 0x11]) + Data(repeating: 0, count: 8)
        header += Data([0x1a, 0x01, 0x42, 0x25]) + Data(repeating: 0, count: 4)
        header += Data([0x82, 0xf1, 0x04, UInt8(signed.count)]) + signed
        let source3 = fixture.root.appendingPathComponent("identified3.crx")
        try crx3(header: header, zip: zip).write(to: source3)
        let entry3 = try await fixture.store.install(from: source3)
        XCTAssertEqual(entry3.id, "aaabacadaeafagahaiajakalamanaoap")
        await assertRejected(source3, by: fixture.store)
    }

    func testMalformedCRX3ProtobufAndConflictingManifestIdentityAreRejected() async throws {
        let fixture = try sandbox()
        let zip = TestExtensionZIP.make([.init(name: "manifest.json", data: try manifest())])
        let badHeaders = [
            Data([0x82, 0xf1, 0x04, 0x7f, 0]),
            Data([0x82, 0xf1, 0x04, 3, 0x0a, 0x20, 0]),
            Data([0x82, 0xf1, 0x04, 3, 0x0a, 1, 0]),
            Data(repeating: 0x80, count: 10),
            Data([0]), Data([0x0b]), Data([0x11, 0]), Data([0x25, 0])
        ]
        for (index, header) in badHeaders.enumerated() {
            let source = fixture.root.appendingPathComponent("bad-protobuf-\(index).crx")
            try crx3(header: header, zip: zip).write(to: source)
            await assertRejected(source, by: fixture.store)
        }
        let conflictingZIP = TestExtensionZIP.make([.init(name: "manifest.json",
            data: try manifest(extra: ["key": Data("different public key".utf8).base64EncodedString()]))])
        let signed = Data([0x0a, 0x10]) + Data(0..<16)
        let header = Data([0x82, 0xf1, 0x04, UInt8(signed.count)]) + signed
        let source = fixture.root.appendingPathComponent("conflicting.crx")
        try crx3(header: header, zip: conflictingZIP).write(to: source)
        await assertRejected(source, by: fixture.store)
        try assertNoImportWorkspaces(in: fixture.directory)
    }

    func testOneWrapperFolderIsAccepted() async throws {
        let fixture = try sandbox()
        let source = fixture.root.appendingPathComponent("wrapped.zip")
        try TestExtensionZIP.make([
            .init(name: "release/manifest.json", data: try manifest()),
            .init(name: "release/assets/fixture.txt", data: Data("nested asset".utf8)),
            .init(name: ".DS_Store", data: Data())
        ]).write(to: source)
        let entry = try await fixture.store.install(from: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.resourceURL(for: entry)
            .appendingPathComponent("assets/fixture.txt").path))
    }

    func testInvalidCRXHeadersAndOffsetsDoNotChangeRegistry() async throws {
        let fixture = try sandbox()
        let invalid: [Data] = [
            Data("Cr24".utf8),
            Data("Cr24".utf8) + littleEndian(2) + littleEndian(UInt32.max) + littleEndian(UInt32.max),
            Data("Cr24".utf8) + littleEndian(3) + littleEndian(UInt32.max),
            Data("Cr24".utf8) + littleEndian(99) + littleEndian(0),
            Data("This is not an archive".utf8)
        ]
        for (index, data) in invalid.enumerated() {
            let source = fixture.root.appendingPathComponent("invalid-\(index).crx")
            try data.write(to: source)
            await assertRejected(source, by: fixture.store)
        }
        try assertNoImportWorkspaces(in: fixture.directory)
    }

    func testUnsafeZIPPathsLinksDuplicatesAndOversizedMetadataAreRejected() async throws {
        let fixture = try sandbox()
        let manifestEntry = TestExtensionZIP.Entry(name: "manifest.json", data: try manifest())
        let outside = fixture.root.appendingPathComponent("escaped.txt")
        let archives: [[TestExtensionZIP.Entry]] = [
            [manifestEntry, .init(name: "../escaped.txt", data: Data("escape".utf8))],
            [manifestEntry, .init(name: outside.path, data: Data("escape".utf8))],
            [manifestEntry, .init(name: "folder\\escaped.txt", data: Data())],
            [manifestEntry, .init(name: "link", data: Data("../../".utf8), unixMode: 0xa1ff),
             .init(name: "link/escaped.txt", data: Data("escape".utf8))],
            [manifestEntry, .init(name: "MANIFEST.JSON", data: Data())],
            [manifestEntry, .init(name: "huge", data: Data(), declaredSize: 513 * 1_024 * 1_024)]
        ]
        for (index, entries) in archives.enumerated() {
            let source = fixture.root.appendingPathComponent("unsafe-\(index).zip")
            try TestExtensionZIP.make(entries).write(to: source)
            await assertRejected(source, by: fixture.store)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        try assertNoImportWorkspaces(in: fixture.directory)
    }

    func testZIPLocalHeaderMustAgreeWithCentralDirectory() async throws {
        let fixture = try sandbox()
        var data = TestExtensionZIP.make([.init(name: "manifest.json", data: try manifest())])
        data[30] = Character("x").asciiValue!
        let source = fixture.root.appendingPathComponent("inconsistent.zip")
        try data.write(to: source)
        await assertRejected(source, by: fixture.store)
    }

    func testFolderSymlinksAndMissingOrInvalidManifestsAreRejected() async throws {
        let fixture = try sandbox()
        let source = try extensionFolder(in: fixture.root, name: "linked")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("outside"), withDestinationURL: fixture.root)
        await assertRejected(source, by: fixture.store)

        let alias = fixture.root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        await assertRejected(alias, by: fixture.store)

        let missing = fixture.root.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        await assertRejected(missing, by: fixture.store)

        let malformed = fixture.root.appendingPathComponent("malformed")
        try write("not JSON", to: malformed.appendingPathComponent("manifest.json"))
        await assertRejected(malformed, by: fixture.store)

        let unsupported = try extensionFolder(in: fixture.root, name: "unsupported", extra: ["manifest_version": 99])
        await assertRejected(unsupported, by: fixture.store)
        try assertNoImportWorkspaces(in: fixture.directory)
    }

    func testTogglePersistsAndRemoveDoesNotReseedBundledExtension() async throws {
        let fixture = try sandbox()
        let bundled = try XCTUnwrap(fixture.store.entries.first)
        XCTAssertEqual(fixture.store.resourceURL(for: bundled), fixture.bundle)
        XCTAssertEqual(bundled.version, "1.2.3")
        let source = try extensionFolder(in: fixture.root)
        let entry = try await fixture.store.install(from: source)
        try fixture.store.setEnabled(true, id: entry.id)
        XCTAssertEqual(fixture.store.revision, 2)
        let reloaded = WebExtensionStore(directory: fixture.directory, bundledResourceURL: fixture.bundle)
        XCTAssertEqual(reloaded.entries, fixture.store.entries)
        XCTAssertTrue(try XCTUnwrap(reloaded.entries.first(where: { $0.id == entry.id })).enabled)
        try await reloaded.remove(id: entry.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.resourceURL(for: entry).path))
        try await reloaded.remove(id: bundled.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.bundle.path))
        let empty = WebExtensionStore(directory: fixture.directory, bundledResourceURL: fixture.bundle)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertNil(empty.lastError)
    }

    func testKeyedExtensionCannotBeImportedTwice() async throws {
        let fixture = try sandbox()
        let key = Data("Feather extension test public key".utf8)
        let source = try extensionFolder(in: fixture.root, extra: ["key": key.base64EncodedString()])
        let entry = try await fixture.store.install(from: source)
        let expectedID = SHA256.hash(data: key).prefix(16).map {
            String(UnicodeScalar(97 + Int($0 >> 4))!) + String(UnicodeScalar(97 + Int($0 & 15))!)
        }.joined()
        XCTAssertEqual(entry.id, expectedID)
        await assertRejected(source, by: fixture.store)
        XCTAssertEqual(fixture.store.entries.filter { $0.id == entry.id }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.resourceURL(for: entry).path))
    }

    func testRegistryWriteFailureRollsBackInstallToggleAndRemove() async throws {
        let fixture = try sandbox()
        let original = fixture.store.entries
        let registry = fixture.directory.appendingPathComponent("installed.json")
        try FileManager.default.removeItem(at: registry)
        try write("prevent atomic replacement", to: registry.appendingPathComponent("sentinel"))
        XCTAssertThrowsError(try fixture.store.setEnabled(false, id: original[0].id))
        XCTAssertEqual(fixture.store.entries, original)
        XCTAssertEqual(fixture.store.revision, 0)
        await assertRejected(try extensionFolder(in: fixture.root), by: fixture.store)
        do {
            try await fixture.store.remove(id: original[0].id)
            XCTFail("Removing an extension must fail if its registry cannot be saved")
        } catch { }
        XCTAssertEqual(fixture.store.entries, original)
        XCTAssertEqual(fixture.store.revision, 0)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        XCTAssertEqual(remaining, ["installed.json"])
    }

    func testMalformedDuplicateAndUnsafeRegistriesArePreserved() throws {
        let root = try temporaryDirectory()
        let valid = InstalledWebExtension(id: "fixture-id", name: "Fixture", version: "1", enabled: false, bundled: false)
        let unsafe = InstalledWebExtension(id: "../../outside", name: "Unsafe", version: "1", enabled: true, bundled: false)
        let wrongBundle = InstalledWebExtension(id: "different-bundle", name: "Unsafe", version: "1", enabled: true, bundled: true)
        let invalid = [Data("malformed JSON".utf8), try JSONEncoder().encode([valid, valid]),
                       try JSONEncoder().encode([unsafe]), try JSONEncoder().encode([wrongBundle])]
        for (index, data) in invalid.enumerated() {
            let directory = root.appendingPathComponent("registry-\(index)")
            let registry = directory.appendingPathComponent("installed.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: registry)
            let store = WebExtensionStore(directory: directory)
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertNotNil(store.lastError)
            XCTAssertEqual(try Data(contentsOf: registry), data)
        }
    }

    func testChromeWebStoreURLParsingUsesOnlySupportedHostsAndPaths() throws {
        let id = "hacjodpccmeoocakiahjfndppdeallak"
        for input in [id, " \(id)\n", "https://chromewebstore.google.com/detail/study-tools/\(id)?hl=en",
                      "https://chromewebstore.google.com/detail/\(id)",
                      "https://chrome.google.com/webstore/detail/study-tools/\(id)"] {
            XCTAssertEqual(try WebExtensionStore.chromeWebStoreID(from: input), id)
        }
        for input in ["https://example.com/detail/\(id)", "https://chromewebstore.google.com.evil.test/detail/\(id)",
                      "http://chromewebstore.google.com/detail/\(id)", "https://chromewebstore.google.com/search/\(id)",
                      "https://chromewebstore.google.com/detail/name/extra/\(id)", String(repeating: "z", count: 32), ""] {
            XCTAssertThrowsError(try WebExtensionStore.chromeWebStoreID(from: input), input)
        }
    }

    private struct Sandbox {
        let root: URL
        let directory: URL
        let bundle: URL
        let store: WebExtensionStore
    }

    private func sandbox() throws -> Sandbox {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("support", isDirectory: true)
        let bundle = try extensionFolder(in: root, name: "bundled")
        let store = WebExtensionStore(directory: directory, bundledResourceURL: bundle)
        XCTAssertNil(store.lastError)
        return Sandbox(root: root, directory: directory, bundle: bundle, store: store)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherExtensionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func extensionFolder(in root: URL, name: String = "source", extra: [String: Any] = [:]) throws -> URL {
        let source = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try manifest(extra: extra).write(to: source.appendingPathComponent("manifest.json"))
        return source
    }

    private func manifest(extra: [String: Any] = [:]) throws -> Data {
        var values: [String: Any] = ["manifest_version": 3, "name": "Feather fixture", "version": "1.2.3",
                                     "description": "A local extension fixture for import regression tests."]
        values.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func assertRejected(_ source: URL, by store: WebExtensionStore, file: StaticString = #filePath, line: UInt = #line) async {
        let original = store.entries
        let revision = store.revision
        do {
            try await store.install(from: source)
            XCTFail("Expected import rejection: \(source.lastPathComponent)", file: file, line: line)
        } catch {
            XCTAssertNotNil(store.lastError, file: file, line: line)
        }
        XCTAssertEqual(store.entries, original, file: file, line: line)
        XCTAssertEqual(store.revision, revision, file: file, line: line)
    }

    private func assertNoImportWorkspaces(in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".import-") }, file: file, line: line)
    }

    private func littleEndian(_ value: UInt32) -> Data { TestExtensionZIP.littleEndian(value) }

    private func crx3(header: Data, zip: Data) -> Data {
        Data("Cr24".utf8) + littleEndian(3) + littleEndian(UInt32(header.count)) + header + zip
    }
}

/// Small uncompressed ZIP fixtures exercise the production parser and ditto
/// together, including metadata that ordinary archive tools refuse to create.
private nonisolated enum TestExtensionZIP {
    struct Entry {
        let name: String
        let data: Data
        var unixMode: UInt32 = 0x81a4
        var declaredSize: UInt32?
    }

    static func make(_ entries: [Entry]) -> Data {
        var local = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let offset = UInt32(local.count)
            let crc = crc32(entry.data)
            let size = entry.declaredSize ?? UInt32(entry.data.count)
            local += littleEndian(0x04034b50)
            local += shorts([20, 0x0800, 0, 0, 0])
            local += littleEndian(crc)
            local += littleEndian(UInt32(entry.data.count))
            local += littleEndian(size)
            local += shorts([UInt16(name.count), 0])
            local += name
            local += entry.data

            central += littleEndian(0x02014b50)
            central += shorts([0x0314, 20, 0x0800, 0, 0, 0])
            central += littleEndian(crc)
            central += littleEndian(UInt32(entry.data.count))
            central += littleEndian(size)
            central += shorts([UInt16(name.count), 0, 0, 0, 0])
            central += littleEndian(entry.unixMode << 16)
            central += littleEndian(offset)
            central += name
        }
        var end = littleEndian(0x06054b50)
        end += shorts([0, 0, UInt16(entries.count), UInt16(entries.count)])
        end += littleEndian(UInt32(central.count))
        end += littleEndian(UInt32(local.count))
        end += shorts([0])
        return local + central + end
    }

    static func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
              UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }

    private static func shorts(_ values: [UInt16]) -> Data {
        Data(values.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        return crc ^ 0xffff_ffff
    }
}
