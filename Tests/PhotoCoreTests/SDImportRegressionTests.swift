import Foundation
import Testing
import Darwin
@testable import PhotoCore

private func importFixture() throws -> (base: URL, source: URL, library: PhotoLibrary) {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    let source = base.appendingPathComponent("SD/DCIM/17.10")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for name in ["one.JPG", "one.RAF"] {
        try Data(name.utf8).write(to: source.appendingPathComponent(name))
    }
    return (base, source.deletingLastPathComponent(), PhotoLibrary(root: base.appendingPathComponent("Library")))
}

private func setSDDates(_ url: URL) throws {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
    var dates = [timespec(tv_sec: 1_600_000_001, tv_nsec: 123_456_789), timespec(tv_sec: 1_600_000_000, tv_nsec: 123_456_789)]
    let result = dates.withUnsafeMutableBytes { setattrlist(url.path, &attributes, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW)) }
    #expect(result == 0)
}

@Test func sdCreationAfterModificationSurvivesImportAndRepeat() async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    for name in ["one.JPG", "one.RAF"] { try setSDDates(fixture.source.appendingPathComponent("17.10/" + name)) }
    let first = try await fixture.library.importPhotos(from: fixture.source)
    #expect(first.imported == 2 && first.issues.isEmpty)
    let asset = try #require(try await fixture.library.entries().first?.asset)
    #expect(asset.isPair)
    for copy in asset.resources {
        let source = fixture.source.appendingPathComponent("17.10/" + copy.url.lastPathComponent)
        #expect(try Data(contentsOf: copy.url) == Data(contentsOf: source))
        var original = stat(), imported = stat()
        #expect(lstat(source.path, &original) == 0 && lstat(copy.url.path, &imported) == 0)
        #expect(original.st_birthtimespec.tv_sec == 1_600_000_001)
        #expect(original.st_mtimespec.tv_sec == 1_600_000_000)
        #expect(original.st_birthtimespec.tv_nsec == 123_456_789 && original.st_mtimespec.tv_nsec == 123_456_789)
        #expect(imported.st_birthtimespec.tv_sec == original.st_birthtimespec.tv_sec)
        #expect(imported.st_birthtimespec.tv_nsec == original.st_birthtimespec.tv_nsec)
        #expect(imported.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec)
        #expect(imported.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)
    }
    let repeated = try await fixture.library.importPhotos(from: fixture.source)
    #expect(repeated.imported == 0 && repeated.skipped == 2 && repeated.issues.isEmpty)
}

@Test(arguments: [false, true])
func provenanceDifferenceIsAcceptedForNewAndOrphanCopies(sourceHasProvenance: Bool) async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let hooks = LibraryImportHooks(readAttributes: { url in
        // Deterministic stand-in for macOS adding/changing provenance during copy.
        var values = ["com.photoviewer.fixture": Data([3])]
        if !url.path.contains("/SD/") || sourceHasProvenance {
            values["com.apple.provenance"] = Data(url.path.contains("/SD/") ? [1] : [2])
        }
        return values
    })
    let first = try await fixture.library.importPhotos(from: fixture.source, hooks: hooks)
    #expect(first.imported == 2 && first.issues.isEmpty)
    try Data(#"{"version":1,"records":[]}"#.utf8).write(to: fixture.library.root.appendingPathComponent("library.json"))
    let recovered = try await fixture.library.importPhotos(from: fixture.source, hooks: hooks)
    #expect(recovered.imported == 2 && recovered.issues.isEmpty)
}

enum ImportFault: String, CaseIterable, Sendable {
    case content, missingAttribute, changedAttribute, extraAttribute, dates, restoreDates
}

@Test(arguments: ImportFault.allCases)
func failedVerificationCleansCopyAndKeepsSource(fault: ImportFault) async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let hooks = LibraryImportHooks(restoreDates: { dates, url in
        if fault == .restoreDates { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        try dates.restore(to: url)
    }, beforeVerification: { url in
        if fault == .content { try Data("corrupted".utf8).write(to: url) }
        if fault == .dates { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: url.path) }
    }, readAttributes: { url in
        let original: [String: Data] = ["com.photoviewer.fixture": Data([3])]
        if !url.lastPathComponent.hasPrefix(".import-") { return original }
        switch fault {
        case .missingAttribute: return [:]
        case .changedAttribute: return ["com.photoviewer.fixture": Data([4])]
        case .extraAttribute: return original.merging(["com.apple.other": Data([5])]) { a, _ in a }
        default: return original
        }
    })
    let report = try await fixture.library.importPhotos(from: fixture.source, hooks: hooks)
    #expect(report.imported == 0 && report.skipped == 0 && report.issues.count == 2)
    let reason = fault == .content ? "Содержимое" : (fault == .dates || fault == .restoreDates ? "даты" : "расширенные атрибуты")
    #expect(report.issues.allSatisfy { $0.contains(reason) && $0.contains("17.10/") })
    #expect(try await fixture.library.entries().isEmpty)
    let files = try #require(FileManager.default.enumerator(at: fixture.library.root, includingPropertiesForKeys: nil))
    let remaining = files.compactMap { ($0 as? URL)?.lastPathComponent }
    #expect(!remaining.contains { $0.hasPrefix(".import-") || $0.hasSuffix(".JPG") || $0.hasSuffix(".RAF") })
    for name in ["one.JPG", "one.RAF"] {
        #expect(try Data(contentsOf: fixture.source.appendingPathComponent("17.10/" + name)) == Data(name.utf8))
    }
}

@Test func partialImportRegistersOnlyVerifiedCopy() async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let hooks = LibraryImportHooks(readAttributes: { url in
        if url.lastPathComponent == "one.RAF" { return ["com.photoviewer.fixture": Data([1])] }
        return [:]
    })
    let report = try await fixture.library.importPhotos(from: fixture.source, hooks: hooks)
    #expect(report.imported == 1 && report.issues.count == 1)
    let entries = try await fixture.library.entries()
    #expect(entries.count == 1 && entries.first?.asset?.resources.count == 1)
}

@Test(arguments: [false, true])
func orphanMetadataConflictIsNotRegisteredOrRewritten(changeDates: Bool) async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let original = fixture.source.appendingPathComponent("17.10/one.JPG")
    let attribute = Data([1, 2, 3])
    let written = attribute.withUnsafeBytes { setxattr(original.path, "com.photoviewer.fixture", $0.baseAddress, attribute.count, 0, 0) }
    #expect(written == 0)
    let first = try await fixture.library.importPhotos(from: fixture.source)
    #expect(first.imported == 2 && first.issues.isEmpty)
    let copy = try #require(try await fixture.library.entries().first?.asset?.jpeg?.url)
    if changeDates {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: copy.path)
    } else {
        #expect(removexattr(copy.path, "com.photoviewer.fixture", 0) == 0)
    }
    let datesBefore = try LibraryImportDates(copy)
    try Data(#"{"version":1,"records":[]}"#.utf8).write(to: fixture.library.root.appendingPathComponent("library.json"))
    let recovered = try await fixture.library.importPhotos(from: fixture.source)
    #expect(recovered.imported == 1 && recovered.issues.count == 1)
    #expect(recovered.issues[0].contains(changeDates ? "даты" : "расширенные атрибуты"))
    #expect(try LibraryImportDates(copy) == datesBefore)
    #expect(try Data(contentsOf: copy) == Data(contentsOf: original))
    if !changeDates { #expect(getxattr(copy.path, "com.photoviewer.fixture", nil, 0, 0, 0) == -1) }
    let entries = try await fixture.library.entries()
    #expect(entries.count == 1 && entries.first?.asset?.jpeg == nil)
}
