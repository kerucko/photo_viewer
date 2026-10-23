import Foundation
import Testing
import Darwin
@testable import PhotoCore

@Test func acceptanceLibraryPersistsMetadataAndPartialDeletion() async throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("SD/DCIM")
    let root = temporary.appendingPathComponent("Library")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    let names = ["frame.JPG", "frame.RAF"]
    let modified = Date(timeIntervalSince1970: 1_600_000_000)
    for name in names {
        let url = source.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
    let jpg = source.appendingPathComponent(names[0])
    let created = try jpg.resourceValues(forKeys: [.creationDateKey]).creationDate
    let library = PhotoLibrary(root: root)
    let imported = try await library.importPhotos(from: source)
    #expect(imported.imported == 2 && imported.issues.isEmpty)
    let reopened = PhotoLibrary(root: root)
    let asset = try #require(try await reopened.entries().first?.asset)
    let copied = try #require(asset.jpeg?.url)
    #expect(try copied.resourceValues(forKeys: [.creationDateKey]).creationDate == created)
    let partial = try await reopened.trash(asset, move: { url in
        if url.pathExtension.lowercased() == "raf" { throw NSError(domain: "fixture", code: 1) }
        try FileManager.default.moveItem(at: url, to: temporary.appendingPathComponent("trashed.JPG"))
    })
    #expect(partial.trashed.count == 1 && partial.failures.count == 1 && !partial.succeeded)
    let again = PhotoLibrary(root: root)
    let remaining = try await again.entries()
    #expect(remaining.count == 1 && remaining[0].asset?.jpeg == nil && remaining[0].asset?.raw != nil)
    let repeated = try await again.importPhotos(from: source)
    #expect(repeated.skipped == 2 && repeated.imported == 0 && repeated.issues.isEmpty)
    for name in names {
        let url = source.appendingPathComponent(name)
        #expect(try Data(contentsOf: url) == Data(name.utf8))
        #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    }
    #expect(try jpg.resourceValues(forKeys: [.creationDateKey]).creationDate == created)
}

@Test func acceptanceModifiedLibraryCopyIsNeverOverwritten() async throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("SD")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    let original = source.appendingPathComponent("a.jpg")
    try Data("original".utf8).write(to: original)
    let library = PhotoLibrary(root: temporary.appendingPathComponent("Library"))
    _ = try await library.importPhotos(from: source)
    let copy = try #require(try await library.entries().first?.url)
    try Data("edited".utf8).write(to: copy)
    let result = try await library.importPhotos(from: source)
    #expect(result.imported == 0 && result.skipped == 0 && result.issues.count == 1)
    #expect(try Data(contentsOf: copy) == Data("edited".utf8))
    #expect(try Data(contentsOf: original) == Data("original".utf8))
}

@Test func acceptanceRecursiveImportDoesNotSkipSiblingAfterSymlink() async throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("SD")
    for name in ["first", "second"] {
        let folder = source.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(name.utf8).write(to: folder.appendingPathComponent("same.jpg"))
    }
    try fm.createSymbolicLink(at: source.appendingPathComponent("link.jpg"), withDestinationURL: source.appendingPathComponent("first/same.jpg"))
    let library = PhotoLibrary(root: temporary.appendingPathComponent("Library"))
    let report = try await library.importPhotos(from: source)
    #expect(report.imported == 2, "Imported \(report.imported); issues: \(report.issues)")
}
