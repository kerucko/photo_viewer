import Foundation
import Testing
import Darwin
@testable import PhotoCore

struct PhotoEditStoreTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoEdits-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func resource(_ root: URL, _ name: String, _ value: String = "original") throws -> PhotoResource {
        let url = root.appendingPathComponent(name)
        try Data(value.utf8).write(to: url)
        return PhotoResource(url: url)
    }
    @Test func persistsPairSurvivesMissingMemberAndRejectsChangedMember() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let jpg = try resource(root, "pair.jpg"), raw = try resource(root, "pair.raf")
        let asset = PhotoAsset(resources: [jpg, raw])
        let store = PhotoEditStore(folder: root, libraryRoot: root)
        let edit = PhotoEdit(quarterTurns: 1, angleDegrees: 12, crop: PhotoCrop(width: 0.8, height: 0.9))
        let initial = try await store.load(for: asset)
        try await store.save(edit, for: asset, token: initial.token)
        let restart = PhotoEditStore(folder: root, libraryRoot: root)
        let loaded = try await restart.load(for: asset)
        #expect(loaded.edit == edit); #expect(loaded.warning == nil)
        try FileManager.default.removeItem(at: raw.url)
        let survivor = PhotoAsset(resources: [jpg])
        let missing = try await restart.load(for: survivor)
        #expect(missing.edit == edit); #expect(missing.warning == nil)
        try Data("replaced".utf8).write(to: raw.url)
        let replaced = try await restart.load(for: asset)
        #expect(replaced.edit == .identity); #expect(replaced.warning != nil)
        let survivorWithChangedCompanion = try await restart.load(for: survivor)
        #expect(survivorWithChangedCompanion.warning != nil)
        try await restart.save(edit, for: asset, token: replaced.token)
        #expect(try await restart.load(for: asset).edit == edit)
    }
    @Test func copiedLibraryUsesRelativeReferencesAndNewCompanionRequiresSave() async throws {
        let root = try directory(), copy = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: copy) }
        let jpg = try resource(root, "one.jpg"), asset = PhotoAsset(resources: [jpg])
        let store = PhotoEditStore(folder: root, libraryRoot: root)
        let edit = PhotoEdit(angleDegrees: 7)
        try await store.save(edit, for: asset, token: store.load(for: asset).token)
        let data = try Data(contentsOf: root.appendingPathComponent("edits.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains(root.path))
        try FileManager.default.copyItem(at: root, to: copy)
        let relocated = PhotoEditStore(folder: copy, libraryRoot: copy)
        #expect(try await relocated.load(for: PhotoAsset(resources: [PhotoResource(url: copy.appendingPathComponent("one.jpg"))])).edit == edit)
        let raw = try resource(root, "one.raf")
        let pair = PhotoAsset(resources: [jpg, raw])
        let added = try await store.load(for: pair)
        #expect(added.warning != nil); #expect(added.edit == .identity)
        try await store.save(edit, for: pair, token: added.token)
        #expect(try await store.load(for: pair).edit == edit)
    }
    @Test func changedAfterCaptureFailsAndFailurePreservesPreviousFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let jpg = try resource(root, "one.jpg"), asset = PhotoAsset(resources: [jpg])
        let target = root.appendingPathComponent("edits.json")
        let store = PhotoEditStore(folder: root, libraryRoot: root)
        let initial = try await store.load(for: asset)
        try Data("changed".utf8).write(to: jpg.url)
        do { try await store.save(PhotoEdit(quarterTurns: 1), for: asset, token: initial.token); Issue.record("Changed file accepted") }
        catch PhotoEditError.changedResources { }
        let fresh = try await store.load(for: asset)
        try await store.save(PhotoEdit(quarterTurns: 1), for: asset, token: fresh.token)
        let before = try Data(contentsOf: target)
        let failing = PhotoEditStore(folder: root, libraryRoot: root, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let load = try await failing.load(for: asset)
        do { try await failing.save(PhotoEdit(quarterTurns: 2), for: asset, token: load.token); Issue.record("Injected error lost") }
        catch { #expect(try Data(contentsOf: target) == before) }
        // A retry with the same unchanged token works when storage recovers.
        let retry = PhotoEditStore(folder: root, libraryRoot: root)
        try await retry.save(PhotoEdit(quarterTurns: 2), for: asset, token: load.token)
        #expect(try await retry.load(for: asset).edit.quarterTurns == 2)
    }
    @Test func corruptUnknownAndConcurrentStoreCannotBeOverwritten() async throws {
        for invalid in ["not JSON", "{\"version\":900,\"records\":[]}"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let asset = PhotoAsset(resources: [try resource(root, "one.jpg")])
            let store = PhotoEditStore(folder: root, libraryRoot: root)
            let initial = try await store.load(for: asset)
            let target = root.appendingPathComponent("edits.json"), bytes = Data(invalid.utf8)
            try bytes.write(to: target)
            do { _ = try await store.load(for: asset); Issue.record("Corrupt store accepted") } catch PhotoEditError.invalidStore { }
            do { try await store.save(.identity, for: asset, token: initial.token); Issue.record("Corrupt store overwritten") } catch PhotoEditError.invalidStore { }
            #expect(try Data(contentsOf: target) == bytes)
        }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let asset = PhotoAsset(resources: [try resource(root, "one.jpg")])
        let store = PhotoEditStore(folder: root, libraryRoot: root)
        let token = try await store.load(for: asset).token
        try await store.save(PhotoEdit(quarterTurns: 1), for: asset, token: token)
        do { try await store.save(.identity, for: asset, token: token); Issue.record("Concurrent update overwritten") } catch PhotoEditError.changedStore { }
    }
    @Test func mergingDifferentEditsAndRenameWarnAndFolderStaysUntouched() async throws {
        let root = try directory(), support = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: support) }
        let jpg = try resource(root, "one.jpg"), raw = try resource(root, "one.raf", "raw original")
        let store = PhotoEditStore(folder: root, storageURL: support.appendingPathComponent("recipes.json"))
        for (resource, turn) in [(jpg, 1), (raw, 2)] {
            let asset = PhotoAsset(resources: [resource])
            try await store.save(PhotoEdit(quarterTurns: turn), for: asset, token: store.load(for: asset).token)
        }
        let merged = try await store.load(for: PhotoAsset(resources: [jpg, raw]))
        #expect(merged.warning != nil); #expect(merged.edit == .identity)
        let moved = root.appendingPathComponent("renamed.jpg")
        try FileManager.default.moveItem(at: jpg.url, to: moved)
        #expect(try await store.load(for: PhotoAsset(resources: [PhotoResource(url: moved)])).warning != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(Set(names) == Set(["renamed.jpg", "one.raf"]))
    }
    @Test func directoryAliasesShareStoreButFileLinksAndEscapesAreRejected() async throws {
        let base = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: outside) }
        let actual = base.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let actualResource = try resource(actual, "one.jpg")
        let rootLink = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: actual)
        let aliasAsset = PhotoAsset(resources: [PhotoResource(url: rootLink.appendingPathComponent("one.jpg"))])
        let aliasStore = PhotoEditStore(folder: rootLink, libraryRoot: rootLink)
        let edit = PhotoEdit(quarterTurns: 1)
        try await aliasStore.save(edit, for: aliasAsset, token: aliasStore.load(for: aliasAsset).token)
        let canonicalStore = PhotoEditStore(folder: actual, libraryRoot: actual)
        #expect(try await canonicalStore.load(for: PhotoAsset(resources: [actualResource])).edit == edit)
        let ancestorLink = base.appendingPathComponent("ancestor", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: base)
        let throughAncestor = ancestorLink.appendingPathComponent("actual", isDirectory: true)
        let ancestorStore = PhotoEditStore(folder: throughAncestor)
        let ordinaryCanonical = PhotoEditStore(folder: actual)
        #expect(ancestorStore.storageURL == ordinaryCanonical.storageURL)
        #expect(PhotoEditStore(folder: rootLink).storageURL == ordinaryCanonical.storageURL)
        let ordinaryURL = base.appendingPathComponent("ordinary-edits.json")
        let ordinaryAlias = PhotoEditStore(folder: throughAncestor, storageURL: ordinaryURL)
        try await ordinaryAlias.save(edit, for: aliasAsset, token: ordinaryAlias.load(for: aliasAsset).token)
        let ordinaryDirect = PhotoEditStore(folder: actual, storageURL: ordinaryURL)
        #expect(try await ordinaryDirect.load(for: PhotoAsset(resources: [actualResource])).edit == edit)
        let ancestorLibrary = PhotoEditStore(folder: throughAncestor, libraryRoot: throughAncestor)
        let ancestorAsset = PhotoAsset(resources: [PhotoResource(url: throughAncestor.appendingPathComponent("one.jpg"))])
        #expect(try await ancestorLibrary.load(for: ancestorAsset).edit == edit)
        let fileLink = actual.appendingPathComponent("linked.jpg")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: actualResource.url)
        let escaped = try resource(outside, "escaped.jpg")
        let directoryLink = actual.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
        for url in [fileLink, escaped.url, directoryLink.appendingPathComponent("escaped.jpg")] {
            do {
                _ = try await canonicalStore.load(for: PhotoAsset(resources: [PhotoResource(url: url)]))
                Issue.record("A file symlink or path outside the root was accepted")
            } catch PhotoEditError.outsideRoot { }
        }
    }
    @Test func originalsMetadataAndExtendedAttributesAreUnchanged() async throws {
        let root = try directory(), support = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: support) }
        let jpg = try resource(root, "one.jpg"), asset = PhotoAsset(resources: [jpg])
        let name = "org.photoviewer.test"
        let value = Data("metadata".utf8)
        let setResult = value.withUnsafeBytes { setxattr(jpg.url.path, name, $0.baseAddress, value.count, 0, 0) }
        #expect(setResult == 0)
        let before = try FileManager.default.attributesOfItem(atPath: jpg.url.path)
        let bytes = try Data(contentsOf: jpg.url)
        let store = PhotoEditStore(folder: root, storageURL: support.appendingPathComponent("edits.json"))
        try await store.save(PhotoEdit(angleDegrees: 4), for: asset, token: store.load(for: asset).token)
        let after = try FileManager.default.attributesOfItem(atPath: jpg.url.path)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(before[.creationDate] as? Date == after[.creationDate] as? Date)
        #expect(try Data(contentsOf: jpg.url) == bytes)
        var buffer = Data(count: value.count)
        let read = buffer.withUnsafeMutableBytes { getxattr(jpg.url.path, name, $0.baseAddress, value.count, 0, 0) }
        #expect(read == value.count); #expect(buffer == value)
    }
}
