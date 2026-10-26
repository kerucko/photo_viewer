import Foundation
import Testing
import Darwin
import CryptoKit
@testable import PhotoCore

struct ZIPExportTests {
    @Test func roundTripFilesLinksAndMetadata() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("Снимки с пробелами")
        try fm.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let file = source.appendingPathComponent("visible.JPG")
        let data = Data("original bytes".utf8)
        try data.write(to: file)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: file.path)
        let attribute = Data("metadata".utf8)
        #expect(attribute.withUnsafeBytes { setxattr(file.path, "com.photoviewer.test", $0.baseAddress, $0.count, 0, 0) } == 0)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "visible.JPG")
        let scan = try ZIPExporter.scan(ZIPSource(root: source))
        #expect(scan.allExtensions == ["jpg", ""])
        let zip = base.appendingPathComponent("result.zip")
        try ZIPExporter.export(scan.plan(including: scan.allExtensions), to: zip)
        let extracted = base.appendingPathComponent("extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, extracted.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let restored = extracted.appendingPathComponent(source.lastPathComponent)
        #expect(try Data(contentsOf: restored.appendingPathComponent(file.lastPathComponent)) == data)
        #expect(try fm.destinationOfSymbolicLink(atPath: restored.appendingPathComponent("link").path) == "visible.JPG")
        #expect(fm.fileExists(atPath: restored.appendingPathComponent("empty").path))
        let attrs = try fm.attributesOfItem(atPath: restored.appendingPathComponent(file.lastPathComponent).path)
        #expect(attrs[.modificationDate] as? Date == date)
        #expect(attrs[.creationDate] as? Date == date)
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = getxattr(restored.appendingPathComponent(file.lastPathComponent).path, "com.photoviewer.test", &bytes, bytes.count, 0, 0)
        #expect(count == attribute.count)
        if count >= 0 { #expect(Data(bytes.prefix(count)) == attribute) }
    }
}

extension ZIPExportTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func filtersSnapshotAndDestinationExclusion() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
        for path in ["nested/a.JPG", "nested/a.RAF", "nested/b.jpeg", "README", ".hidden", "old.zip"] {
            try Data(path.utf8).write(to: root.appendingPathComponent(path))
        }
        let scan = try ZIPExporter.scan(ZIPSource(root: root))
        try Data().write(to: root.appendingPathComponent("later.jpg"))
        let filtered = scan.plan(including: ["jpg"])
        #expect(filtered.relativePaths == ["", "nested", "nested/a.JPG"])
        #expect(filtered.byteCount == Int64("nested/a.JPG".utf8.count))
        let full = scan.plan(including: scan.allExtensions, excluding: root.appendingPathComponent("old.zip"))
        #expect(!full.relativePaths.contains("old.zip"))
        #expect(!full.relativePaths.contains("later.jpg"))
        #expect(full.relativePaths.contains("nested/empty"))
        try ZIPExporter.export(full, to: root.appendingPathComponent("old.zip"))
        #expect(try Data(contentsOf: root.appendingPathComponent("old.zip")).prefix(2) == Data([0x50, 0x4b]))
    }
    @Test func failuresAndCancellationPreserveExistingArchive() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("a.jpg")
        try Data("before".utf8).write(to: file)
        let destination = root.appendingPathComponent("keep.zip"), old = Data("existing archive".utf8)
        try old.write(to: destination)
        let scan = try ZIPExporter.scan(ZIPSource(root: source)), plan = scan.plan(including: scan.allExtensions)
        try Data("changed".utf8).write(to: file)
        #expect(throws: (any Error).self) { try ZIPExporter.export(plan, to: destination) }
        #expect(try Data(contentsOf: destination) == old)
        let fresh = try ZIPExporter.scan(ZIPSource(root: source))
        for stage in [ZIPStage.preparing, .archiving] {
            let cancellation = ZIPCancellation()
            #expect(throws: CancellationError.self) {
                try ZIPExporter.export(fresh.plan(including: fresh.allExtensions), to: destination, cancellation: cancellation) {
                    if $0.stage == stage { cancellation.cancel() }
                }
            }
            #expect(try Data(contentsOf: destination) == old)
        }
        let cancellation = ZIPCancellation()
        #expect(throws: CancellationError.self) {
            try ZIPExporter.scan(ZIPSource(root: source), cancellation: cancellation) { _ in cancellation.cancel() }
        }
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try ZIPExporter.export(fresh.plan(including: fresh.allExtensions), to: destination) }
        #expect(try Data(contentsOf: destination) == old)
        #expect(throws: (any Error).self) { try ZIPExporter.export(plan, to: root.appendingPathComponent("missing/out.zip")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["keep.zip", "source"])
    }
    @Test func libraryIncludesOnlyRegisteredResourcesAndFailsOnMissing() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PhotoLibrary(root: root.appendingPathComponent("Library"))
        for card in ["card1", "card2"] {
            let source = root.appendingPathComponent(card)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            for name in ["same.JPG", "same.RAF"] { try Data((card + name).utf8).write(to: source.appendingPathComponent(name)) }
            _ = try await library.importPhotos(from: source)
        }
        let source = try await library.zipSource()
        let scan = try ZIPExporter.scan(source)
        #expect(scan.plan(including: scan.allExtensions).fileCount == 4)
        #expect(Set(source.relativePaths!.map { $0.split(separator: "/").first! }).count == 2)
        #expect(!source.relativePaths!.contains { $0.contains("manifest") })
        let selected = try await library.entries().first!.asset!.resources
        let subset = try await library.zipSource(selectedResources: Set(selected.map(\.url)))
        #expect(try ZIPExporter.scan(subset).plan(including: ["jpg"]).fileCount == 1)
        #expect(chflags(selected[0].url.path, UInt32(UF_HIDDEN)) == 0)
        let hiddenSubset = try await library.zipSource(selectedResources: Set(selected.map(\.url)))
        #expect(hiddenSubset.relativePaths?.count == 1)
        #expect(chflags(selected[0].url.path, 0) == 0)
        try FileManager.default.removeItem(at: selected[0].url)
        await #expect(throws: (any Error).self) { try await library.zipSource() }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOVIEWER_ZIP_LARGE_TEST"] == "1"))
    func zip64RoundTripAboveFourGiB() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("payload.bin")
        FileManager.default.createFile(atPath: file.path, contents: Data("begin".utf8))
        let handle = try FileHandle(forWritingTo: file)
        let size: UInt64 = 4_294_967_296 + 1_024
        var sourceHash = SHA256()
        var remaining = size
        try handle.seek(toOffset: 0)
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while remaining > 0 {
            arc4random_buf(&buffer, buffer.count)
            let chunk = Data(buffer.prefix(Int(min(remaining, UInt64(buffer.count)))))
            try handle.write(contentsOf: chunk); sourceHash.update(data: chunk)
            remaining -= UInt64(chunk.count)
        }
        try handle.close()
        let scan = try ZIPExporter.scan(ZIPSource(root: source))
        let zip = root.appendingPathComponent("large.zip")
        try ZIPExporter.export(scan.plan(including: scan.allExtensions), to: zip)
        #expect((try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.uint64Value ?? 0 > 4_294_967_296)
        let extraction = root.appendingPathComponent("extracted")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, extraction.path]
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
        let restored = extraction.appendingPathComponent("large/payload.bin")
        #expect((try FileManager.default.attributesOfItem(atPath: restored.path)[.size] as? NSNumber)?.uint64Value == size)
        let reader = try FileHandle(forReadingFrom: restored); defer { try? reader.close() }
        var restoredHash = SHA256()
        while let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty { restoredHash.update(data: chunk) }
        #expect(sourceHash.finalize() == restoredHash.finalize())
    }
}

extension ZIPExportTests {
    @Test func emptyFolderAndSymlinkAncestorReplacement() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let empty = try ZIPExporter.scan(ZIPSource(root: source))
        #expect(empty.groups.isEmpty)
        try ZIPExporter.export(empty.plan(including: []), to: root.appendingPathComponent("empty.zip"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source.appendingPathComponent("nested/a"))
        let scan = try ZIPExporter.scan(ZIPSource(root: source))
        try FileManager.default.moveItem(at: source.appendingPathComponent("nested"), to: root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("nested"), withDestinationURL: root.appendingPathComponent("moved"))
        #expect(throws: (any Error).self) { try ZIPExporter.export(scan.plan(including: scan.allExtensions), to: root.appendingPathComponent("replaced.zip")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("replaced.zip").path))
    }
}

extension ZIPExportTests {
    @Test func activeCopyFaultsAndRunningDittoAreCleanedUp() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("large.bin")
        try Data(repeating: 42, count: 8 * 1_048_576).write(to: file)
        let scan = try ZIPExporter.scan(ZIPSource(root: source)), plan = scan.plan(including: scan.allExtensions)
        let destination = root.appendingPathComponent("existing.zip"), original = Data("old archive".utf8)
        try original.write(to: destination)
        let copyCancellation = ZIPCancellation()
        var copiedChunks = 0
        var hooks = ZIPExporter.TestHooks()
        hooks.afterChunk = { _ in copiedChunks += 1; copyCancellation.cancel() }
        #expect(throws: CancellationError.self) { try ZIPExporter.export(plan, to: destination, cancellation: copyCancellation, hooks: hooks) }
        #expect(copiedChunks == 1)
        for errorNumber in [ENOSPC, EACCES] {
            hooks = ZIPExporter.TestHooks()
            if errorNumber == ENOSPC { hooks.write = { _, _, _ in errno = ENOSPC; return -1 } }
            else { hooks.read = { _, _, _ in errno = EACCES; return -1 } }
            #expect(throws: (any Error).self) { try ZIPExporter.export(plan, to: destination, hooks: hooks) }
            #expect(try Data(contentsOf: destination) == original)
        }
        hooks = ZIPExporter.TestHooks()
        var mutated = false
        hooks.afterChunk = { url in
            if !mutated {
                mutated = true
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.write(contentsOf: Data([17]))
            }
        }
        #expect(throws: (any Error).self) { try ZIPExporter.export(plan, to: destination, hooks: hooks) }
        #expect(mutated)
        let fresh = try ZIPExporter.scan(ZIPSource(root: source))
        let cancellation = ZIPCancellation()
        var child: Process?, staging: URL?
        hooks = ZIPExporter.TestHooks()
        hooks.processStarted = { process, directory in
            child = process; staging = directory
            #expect(process.isRunning)
            #expect(FileManager.default.fileExists(atPath: directory.path))
            cancellation.cancel()
        }
        #expect(throws: CancellationError.self) { try ZIPExporter.export(fresh.plan(including: fresh.allExtensions), to: destination, cancellation: cancellation, hooks: hooks) }
        let process = try #require(child)
        #expect(!process.isRunning)
        var status: Int32 = 0
        #expect(waitpid(process.processIdentifier, &status, WNOHANG) == -1 && errno == ECHILD)
        #expect(!FileManager.default.fileExists(atPath: try #require(staging).path))
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["existing.zip", "source"])
    }
    @Test func pendingDeletionSnapshotDoesNotRewriteJournal() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("card"), libraryRoot = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["alive.JPG", "gone.JPG"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        let library = PhotoLibrary(root: libraryRoot)
        _ = try await library.importPhotos(from: source)
        let manifest = libraryRoot.appendingPathComponent("library.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var records = try #require(json["records"] as? [[String: Any]])
        for index in records.indices {
            records[index]["deleted"] = true; records[index]["pendingDeletion"] = true
            let stored = try #require(records[index]["stored"] as? String)
            if stored.hasSuffix("gone.JPG") { try FileManager.default.removeItem(at: libraryRoot.appendingPathComponent(stored)) }
        }
        json["records"] = records
        let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try bytes.write(to: manifest)
        let before = try FileManager.default.attributesOfItem(atPath: manifest.path)
        let snapshot = try await library.zipSource()
        #expect(snapshot.relativePaths?.count == 1)
        #expect(snapshot.relativePaths?.first?.hasSuffix("alive.JPG") == true)
        #expect(try Data(contentsOf: manifest) == bytes)
        let after = try FileManager.default.attributesOfItem(atPath: manifest.path)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
    }
}

extension ZIPExportTests {
    @Test func hiddenFilesAndSubtreesAreExcluded() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: true)
        for index in 0..<13 { try Data().write(to: root.appendingPathComponent("photo\(index).JPG")) }
        try Data("synthetic Finder metadata".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        for directory in [".private", "finder-hidden"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(directory + "/child.JPG"))
        }
        #expect(chflags(root.appendingPathComponent("finder-hidden").path, UInt32(UF_HIDDEN)) == 0)
        try Data().write(to: root.appendingPathComponent("finder-file.JPG"))
        #expect(chflags(root.appendingPathComponent("finder-file.JPG").path, UInt32(UF_HIDDEN)) == 0)
        let selected = try ZIPExporter.scan(ZIPSource(root: root, relativePaths: [".private/missing.JPG", "finder-hidden/child.JPG", "finder-file.JPG", "photo0.JPG"]))
        #expect(selected.plan(including: selected.allExtensions).fileCount == 1)
        let scan = try ZIPExporter.scan(ZIPSource(root: root))
        #expect(!scan.plan(including: scan.allExtensions).relativePaths.contains("finder-hidden"))
        #expect(scan.groups.first { $0.extensionName == "jpg" }?.count == 13)
        #expect(!scan.allExtensions.contains(""))
        #expect(scan.plan(including: scan.allExtensions).fileCount == 13)
        #expect(scan.plan(including: [""]).relativePaths == [""])
    }
}
