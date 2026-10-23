import Foundation
import Testing
import PhotoCore
@testable import PhotoViewer

@MainActor struct LibraryBrowserTests {
    @Test func trashRequiresPhotoAndIdleCatalog() {
        let model = BrowserModel()
        let resource = PhotoResource(url: URL(fileURLWithPath: "/fixture/frame.JPG"))
        let asset = PhotoAsset(resources: [resource])
        model.entries = [CatalogEntry(url: resource.url, asset: asset)]
        model.selection.select(asset.id)
        #expect(model.canTrash)
        model.loading = true
        #expect(!model.canTrash)
        model.loading = false; model.busy = true
        #expect(!model.canTrash)
        model.busy = false
        model.entries = [CatalogEntry(url: URL(fileURLWithPath: "/fixture/folder"))]
        model.selection.select(model.entries[0].id)
        #expect(!model.canTrash)
    }

    @Test func operationLocksSelectionAndNavigation() {
        let model = BrowserModel()
        model.selection.select("captured")
        model.busy = true
        model.select("other")
        model.open(URL(fileURLWithPath: "/other"))
        #expect(model.selection.id == "captured")
        #expect(model.location == nil)
    }

    @Test func libraryLocationHasNoPhysicalAncestorsAndRestoresThroughHistory() {
        let model = BrowserModel()
        let root = URL(fileURLWithPath: "/fixture/library")
        model.libraryRoot = root
        model.openLibrary()
        #expect(model.location == .library(root))
        #expect(model.ancestors.isEmpty)
        #expect(!model.canUp)
        model.open(URL(fileURLWithPath: "/fixture/folder"))
        #expect(!model.isLibrary)
        model.back()
        #expect(model.location == .library(root))
        #expect(model.ancestors.isEmpty)
    }

    @Test func folderNavigationClearsLibraryWarnings() {
        let model = BrowserModel()
        model.catalogIssues = ["Файл библиотеки недоступен"]
        model.open(URL(fileURLWithPath: "/fixture/folder"))
        #expect(model.catalogIssues.isEmpty)
    }

    @Test func importIssuesRemainBounded() {
        let summary = BrowserModel.summarizeIssues((1...100).map { "Ошибка \($0)" })
        #expect(summary.contains("Ошибка 12"))
        #expect(!summary.contains("Ошибка 13"))
        #expect(summary.contains("И ещё: 88."))
    }
}
