import Foundation
import Testing
@testable import PhotoCore

struct MultipleSelectionTests {
    let order = ["a", "b", "c", "d", "e"]

    @Test func toggleRangeAndPrimaryAreDeterministic() {
        var selection = SelectionState()
        selection.select("b")
        selection.toggle("d", orderedIDs: order)
        #expect(selection.ids == ["b", "d"])
        #expect(selection.id == "d")
        selection.extend(to: "a", orderedIDs: order)
        #expect(selection.ids == ["a", "b", "c", "d"])
        #expect(selection.anchorID == "d")
        selection.extend(to: "c", orderedIDs: order)
        #expect(selection.ids == ["c", "d"])
        #expect(selection.id == "c")
        selection.toggle("d", orderedIDs: order)
        #expect(selection.id == "c")
        selection.toggle("c", orderedIDs: order)
        #expect(selection.ids.isEmpty && selection.id == nil)
    }

    @Test func primaryChangesInvalidatePreviewButGroupOnlyChangesDoNot() {
        var selection = SelectionState()
        selection.select("a"); selection.toggleRAW()
        let revision = selection.revision
        selection.replace(["a", "b"], primary: "a", orderedIDs: order)
        #expect(selection.showsRAW && selection.accepts(revision))
        selection.focus("b")
        #expect(!selection.showsRAW && !selection.accepts(revision))
        #expect(selection.ids == ["a", "b"])
        selection.select("b")
        #expect(selection.ids == ["b"])
    }

    @Test func reorderAndRefreshKeepSurvivorsAndUseCurrentRangeOrder() {
        var selection = SelectionState()
        selection.replace(["b", "d"], primary: "d", orderedIDs: order)
        selection.retain(orderedIDs: ["e", "c", "b", "a"])
        #expect(selection.ids == ["b"] && selection.id == "b")
        selection.extend(to: "e", orderedIDs: ["e", "c", "b", "a"])
        #expect(selection.ids == ["e", "c", "b"])
        selection.retain(orderedIDs: [])
        #expect(selection.ids.isEmpty && selection.id == nil && selection.anchorID == nil)
    }
    private actor Visits {
        var ids: [String] = []
        func append(_ id: String) { ids.append(id) }
    }
    @Test func batchTrashContinuesAfterPartialAndThrownFailures() async {
        let assets = ["first", "second", "third"].map { name in
            PhotoAsset(resources: [PhotoResource(url: URL(fileURLWithPath: "/synthetic/\(name).jpg")),
                                   PhotoResource(url: URL(fileURLWithPath: "/synthetic/\(name).raf"))])
        }
        let visits = Visits()
        let report = await PhotoTrash.trash(assets) { asset in
            await visits.append(asset.id)
            if asset == assets[1] { throw NSError(domain: "SyntheticFailure", code: 1) }
            if asset == assets[0] {
                return TrashReport(trashed: [asset.resources[0].url], failures: ["first.raf: synthetic move failure"])
            }
            return TrashReport(trashed: asset.resources.map(\.url), failures: [])
        }
        #expect(await visits.ids == assets.map(\.id))
        #expect(report.trashed == [assets[0].resources[0].url] + assets[2].resources.map(\.url))
        #expect(report.failures.count == 2)
        #expect(report.failures[0].contains("first.raf"))
        #expect(report.failures[1].contains("second.jpg"))
        #expect(!report.succeeded)
    }

}
