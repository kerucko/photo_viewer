import Foundation
import Testing
import Darwin
@testable import PhotoCore

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func managedImportPairsPreservesAndRepeats() async throws {
    let temporary = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("SD/DCIM"), root = temporary.appendingPathComponent("Library")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let jpg = source.appendingPathComponent("DSCF1.JPG"), raw = source.appendingPathComponent("DSCF1.RAF")
    try Data("jpeg-fixture".utf8).write(to: jpg)
    try Data("raw-fixture".utf8).write(to: raw)
    let date = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: jpg.path)
    let attr = Data("test metadata".utf8)
    let set = attr.withUnsafeBytes { setxattr(jpg.path, "com.photoviewer.test", $0.baseAddress, attr.count, 0, 0) }
    #expect(set == 0)
    let library = PhotoLibrary(root: root)
    let first = try await library.importPhotos(from: temporary.appendingPathComponent("SD"))
    #expect(first.imported == 2)
    #expect(first.issues.isEmpty)
    let entries = try await library.entries()
    #expect(entries.count == 1)
    #expect(entries.first?.asset?.isPair == true)
    let copied = try #require(entries.first?.asset?.jpeg?.url)
    #expect(try Data(contentsOf: copied) == Data(contentsOf: jpg))
    #expect(try copied.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
    var read = Data(count: attr.count)
    let readCount = read.withUnsafeMutableBytes { getxattr(copied.path, "com.photoviewer.test", $0.baseAddress, attr.count, 0, 0) }
    #expect(readCount == attr.count && read == attr)
    let second = try await library.importPhotos(from: temporary.appendingPathComponent("SD"))
    #expect(second.skipped == 2 && second.imported == 0 && second.issues.isEmpty)
    try Data("changed".utf8).write(to: jpg)
    let conflict = try await library.importPhotos(from: temporary.appendingPathComponent("SD"))
    #expect(conflict.issues.count == 1)
    #expect(try Data(contentsOf: copied) == Data("jpeg-fixture".utf8))
}

@Test func trashPreflightsEntirePairAndReportsPartialFailure() throws {
    let temporary = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let jpg = temporary.appendingPathComponent("one.jpg"), raw = temporary.appendingPathComponent("one.raf")
    try Data().write(to: jpg)
    let pair = PhotoAsset(resources: [PhotoResource(url: jpg), PhotoResource(url: raw)])
    var visited: [URL] = []
    let missing = PhotoTrash.trash(pair) { visited.append($0) }
    #expect(visited.isEmpty && missing.failures.count == 1)
    try Data().write(to: raw)
    let partial = PhotoTrash.trash(pair) { url in
        visited.append(url)
        if url == raw { throw NSError(domain: "test", code: 1) }
    }
    #expect(visited == [jpg, raw])
    #expect(partial.trashed == [jpg] && partial.failures.count == 1)
}

@Test func managedDeletionTombstonePreventsReimport() async throws {
    let temporary = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("SD")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for name in ["a.jpg", "a.raf"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
    let library = PhotoLibrary(root: temporary.appendingPathComponent("Library"))
    _ = try await library.importPhotos(from: source)
    let entries = try await library.entries()
    let asset = try #require(entries.first?.asset)
    let report = try await library.trash(asset, move: { url in
        try FileManager.default.moveItem(at: url, to: temporary.appendingPathComponent("trash-" + url.lastPathComponent))
    })
    #expect(report.trashed.count == 2 && report.succeeded)
    #expect(try await library.entries().isEmpty)
    let reimport = try await library.importPhotos(from: source)
    #expect(reimport.skipped == 2 && reimport.imported == 0)
}

@Test func libraryRejectsOverlapAndCorruption() async throws {
    let temporary = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let library = PhotoLibrary(root: temporary.appendingPathComponent("Library"))
    do { _ = try await library.importPhotos(from: temporary); Issue.record("overlap accepted") } catch {}
    try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: library.root.appendingPathComponent("library.json"))
    do { _ = try await library.entries(); Issue.record("corruption accepted") } catch {}
}

@Test func importSeparatesDirectoriesSkipsLinksAndReportsMissingCopy() async throws {
    let temporary = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("SD")
    for folder in ["first", "second"] {
        let directory = source.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(folder.utf8).write(to: directory.appendingPathComponent("same.jpg"))
    }
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.jpg"), withDestinationURL: source.appendingPathComponent("first/same.jpg"))
    let library = PhotoLibrary(root: temporary.appendingPathComponent("Library"))
    let report = try await library.importPhotos(from: source)
    #expect(report.imported == 2 && report.issues.count == 1)
    let entries = try await library.entries()
    #expect(entries.count == 2)
    #expect(Set(entries.map(\.id)).count == 2)
    try FileManager.default.removeItem(at: entries[0].url)
    let repeated = try await library.importPhotos(from: source)
    #expect(repeated.skipped == 1 && repeated.issues.count == 2)
    let snapshot = try await library.snapshot()
    #expect(snapshot.entries.count == 1 && snapshot.issues.count == 1)
}

@Test func orphanImportIsRecoveredWithoutOverwritingConflicts() async throws {
    let temporary = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("SD")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: source.appendingPathComponent("a.jpg"))
    let library = PhotoLibrary(root: temporary.appendingPathComponent("Library"))
    _ = try await library.importPhotos(from: source)
    let entries = try await library.entries()
    let destination = try #require(entries.first?.url)
    let manifest = library.root.appendingPathComponent("library.json")
    // Simulate a successful move whose manifest write was interrupted.
    try Data(#"{"version":1,"records":[]}"#.utf8).write(to: manifest)
    let recovered = try await library.importPhotos(from: source)
    #expect(recovered.imported == 1 && recovered.issues.isEmpty)
    #expect(try await library.entries().count == 1)
    try Data(#"{"version":1,"records":[]}"#.utf8).write(to: manifest)
    try Data("different".utf8).write(to: destination)
    let conflict = try await library.importPhotos(from: source)
    #expect(conflict.imported == 0 && conflict.issues.count == 1)
    #expect(try Data(contentsOf: destination) == Data("different".utf8))
}

@Test func changedSourceAtDeletedPathReportsConflict() async throws {
    let temporary = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("SD")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let jpg = source.appendingPathComponent("a.jpg")
    try Data("original".utf8).write(to: jpg)
    let library = PhotoLibrary(root: temporary.appendingPathComponent("Library"))
    _ = try await library.importPhotos(from: source)
    let entries = try await library.entries()
    let asset = try #require(entries.first?.asset)
    _ = try await library.trash(asset, move: { try FileManager.default.moveItem(at: $0, to: temporary.appendingPathComponent("trashed.jpg")) })
    try Data("new camera capture".utf8).write(to: jpg)
    let report = try await library.importPhotos(from: source)
    #expect(report.skipped == 0 && report.imported == 0 && report.issues.count == 1)
}
