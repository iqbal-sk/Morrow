import AppKit
import Testing
@testable import DigUpApp
@testable import DigUpKit

@MainActor @Suite struct SearchModelTests {
    @Test func focusDoesNotNavigateAwayFromPeopleOrActivity() {
        let model = SearchModel(engine: SearchStub(), typingPause: .zero)
        for destination in [WorkspaceDestination.people, .activity] {
            model.destination = destination
            model.focusField()
            #expect(model.destination == destination)
        }
    }

    @Test func typingFromAnotherPageStartsAnUnscopedSearch() async throws {
        let engine = SearchStub()
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.browse(folder: "/photos/trip")
        try await eventually { model.hasResults }
        model.filter = .images
        model.destination = .people
        model.editQuery("receipt")
        try await eventually { model.hasResults }
        #expect(model.destination == .library)
        #expect(model.folder == nil)
        #expect(model.filter == nil)
        #expect(!model.browsing)
        #expect(engine.requests.last?.folder == nil)
    }

    @Test func findFromAnotherPageDropsOldScopeWithoutErasingQuery() async throws {
        let engine = SearchStub()
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.browse(folder: "/photos/trip")
        model.editQuery("sunset")
        try await eventually { model.hasResults }
        model.destination = .activity
        model.activateSearch()
        try await eventually { model.hasResults }
        #expect(model.destination == .library)
        #expect(model.folder == nil)
        #expect(model.query == "sunset")
        #expect(engine.requests.last?.folder == nil)
    }

    @Test func libraryNavigationHasTheSameHomeBehaviorForEveryEntryPoint() {
        let model = SearchModel(engine: SearchStub(), typingPause: .zero)
        model.browse(folder: "/photos/trip")
        model.destination = .people
        model.navigate(to: .library)
        #expect(model.showsHome)
        #expect(model.folder == nil)
        model.navigate(to: .activity)
        #expect(model.destination == .activity)
    }

    @Test func clearingFolderSearchReturnsToTheSameFolderAndKind() async throws {
        let engine = SearchStub()
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.browse(folder: "/photos/trip")
        model.filter = .images
        model.editQuery("sunset")
        try await eventually { model.hasResults }
        #expect(engine.requests.last?.folder == "/photos/trip")
        model.clearQuery()
        try await eventually { model.hasResults }
        #expect(model.folder == "/photos/trip")
        #expect(model.filter == .images)
        #expect(model.browsing)
        #expect(engine.browses.last?.folder == "/photos/trip")
        #expect(engine.browses.last?.kinds == [.image])
    }

    @Test func explicitNewSearchResetsFolderScopeAndSetsKindAtomically() async throws {
        let engine = SearchStub()
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.browse(folder: "/photos/trip")
        model.search(for: "waves", kind: .video)
        try await eventually { model.hasResults }
        #expect(model.folder == nil)
        #expect(!model.browsing)
        #expect(model.filter == .video)
        #expect(engine.requests.count == 2) // all-kind counts, then the selected kind
        #expect(engine.requests.allSatisfy { $0.text == "waves" && $0.folder == nil })
    }

    @Test func whitespaceAndNewlinesShowHomeWithoutAnEndlessSpinner() {
        let engine = SearchStub()
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.editQuery(" \n\t ")
        #expect(model.showsHome)
        #expect(!model.hasQuery)
        #expect(model.selectedRow == nil)
        #expect(engine.requests.isEmpty)
    }

    @Test func emptyCodeFilterShowsInstructionsEvenDuringFolderBrowsing() {
        let engine = SearchStub()
        engine.hasCode = true
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.browse(folder: "/photos")
        model.filter = .code
        #expect(model.codePhase == .codeHint)
        #expect(!model.showsHome)
        #expect(!model.hasResults)
        #expect(model.selectedRow == nil)
    }

    @Test func codeWithoutConfiguredFoldersShowsSetup() {
        let model = SearchModel(engine: SearchStub(), typingPause: .zero)
        model.search(for: "code: retry request")
        #expect(model.codePhase == .codeOff)
        #expect(model.selectedRow == nil)
        #expect(model.contentState(hasFolders: false) == .codeInstructions(.codeOff))
    }

    @Test func codeSearchWorksWhenOnlyCodeFoldersAreConfigured() async throws {
        let engine = SearchStub()
        engine.hasCode = true
        engine.hits = [hit("retry", kind: .code)]
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.search(for: "code: retry")
        try await eventually { model.hasResults }
        #expect(model.contentState(hasFolders: false) == .codeResults)
    }

    @Test func inspectorHostStaysStableDuringFilteringAndRemembersTheUsersPreference() async throws {
        let engine = SearchStub()
        engine.hits = [hit("photo")]
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.search(for: "photo")
        try await eventually { model.hasResults }
        #expect(model.hostsPreviewInspector)
        model.filter = .images
        #expect(!model.hasResults)
        #expect(model.hostsPreviewInspector)
        #expect(model.showsPreview)
        #expect(model.canTogglePreview) // An updating inspector can still be hidden.
        try await eventually { model.hasResults }
        #expect(model.hostsPreviewInspector)
        model.home()
        #expect(!model.hostsPreviewInspector)
        #expect(!model.canTogglePreview)
        #expect(model.showsPreview)
        model.search(for: "photo")
        try await eventually { model.hasResults }
        #expect(model.hostsPreviewInspector)
        model.showsPreview = false
        #expect(!model.showsPreview)
        model.destination = .people
        #expect(!model.hostsPreviewInspector)
        #expect(!model.canTogglePreview)
        #expect(!model.canPreviewResults)
    }

    @Test func codeSearchUsesItsOwnIndexWithoutThePhotoFolderScope() async throws {
        let engine = SearchStub()
        engine.hasCode = true
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.browse(folder: "/photos")
        model.editQuery("code: retry")
        try await eventually { model.hasResults }
        let request = try #require(engine.requests.last)
        #expect(request.code)
        #expect(request.text == "retry")
        #expect(request.folder == nil)
    }

    @Test func pendingQueryDisablesOldResultActionsAndLateResponsesCannotReplaceNewOnes() async throws {
        let engine = SearchStub()
        engine.hits = [hit("first")]
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.search(for: "first")
        try await eventually { model.hasResults }
        #expect(model.selectedRow?.name == "first.jpg")
        engine.heldText = "slow"
        model.editQuery("slow")
        try await eventually { engine.held != nil }
        #expect(!model.hasResults)
        #expect(model.selectedRow == nil)
        model.move(by: 1)
        #expect(!model.navigated)
        engine.hits = [hit("latest")]
        model.editQuery("latest")
        try await eventually { model.hasResults }
        engine.held?.resume(returning: [hit("obsolete")])
        engine.held = nil
        await Task.yield()
        await Task.yield()
        #expect(model.selectedRow?.name == "latest.jpg")
        #expect(model.query == "latest")
    }

    @Test func browsingKeepsTheRecentFileThatWasClickedSelected() async throws {
        let engine = SearchStub()
        engine.hits = [hit("first"), hit("clicked")]
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.browse(selecting: ResultRow(engine.hits[1]))
        try await eventually { model.hasResults }
        #expect(model.selectedRow?.name == "clicked.jpg")
        #expect(model.navigated)
        #expect(model.rows.allSatisfy { $0.isBrowsing })
    }

    @Test func filtersKeepAllKindCountsAndNavigationStaysInsideVisibleResults() async throws {
        let engine = SearchStub()
        engine.hits = [hit("one"), hit("two"), hit("clip", kind: .video)]
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.search(for: "trip", kind: .images)
        try await eventually { model.hasResults }
        #expect(model.counts[.images] == 2)
        #expect(model.counts[.video] == 1)
        #expect(model.rows.count == 2)
        model.move(by: 100)
        #expect(model.selectedRow?.name == "two.jpg")
        model.move(by: -100)
        #expect(model.selectedRow?.name == "one.jpg")
    }

    @Test func homeCancelsPendingWorkAndClearsScopeAndSelection() async throws {
        let engine = SearchStub()
        engine.heldText = "slow"
        let model = SearchModel(engine: engine, typingPause: .zero)
        model.search(for: "slow")
        try await eventually { engine.held != nil }
        model.home()
        engine.held?.resume(returning: [hit("late")])
        engine.held = nil
        await Task.yield()
        #expect(model.showsHome)
        #expect(model.results.isEmpty)
        #expect(model.selectedRow == nil)
    }

    private func hit(_ name: String, kind: FileKind = .image) -> SearchHit {
        SearchHit(path: "/synthetic/\(name).jpg", kind: kind, score: 1, z: nil, cosine: nil,
                  keywordRank: 1, segment: .image, segmentID: 1, loc: nil, locEnd: nil,
                  excerpt: nil, modified: 1, size: 1, info: [:])
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

@MainActor private final class SearchStub: WindowSearchServing {
    struct Request { let text: String; let kinds: Set<FileKind>?; let code: Bool; let folder: String? }
    var hasCode = false
    var hits: [SearchHit] = []
    var requests: [Request] = []
    var browses: [(folder: String?, kinds: Set<FileKind>?)] = []
    var heldText: String?
    var held: CheckedContinuation<[SearchHit], Never>?
    func personQuery(_ text: String) -> PersonQuery { PeopleStore.resolve(text, profiles: []) }
    func prewarm() {}
    func embedAhead(_ text: String, code: Bool) {}
    func embedQuery(_ text: String, code: Bool) async -> Engine.QueryVector? { nil }
    func search(_ text: String, vector: Engine.QueryVector?, prefixLast: Bool, kinds: Set<FileKind>?,
                limit: Int, code: Bool, folder: String?) async -> [SearchHit] {
        requests.append(Request(text: text, kinds: kinds, code: code, folder: folder))
        if text == heldText { return await withCheckedContinuation { held = $0 } }
        return hits.filter { kinds == nil || kinds!.contains($0.kind) }
    }
    func libraryFiles(folder: String?, kinds: Set<FileKind>?, limit: Int) async -> [SearchHit] {
        browses.append((folder, kinds))
        return hits.filter { kinds == nil || kinds!.contains($0.kind) }
    }
    func open(_ row: ResultRow) {}
}
