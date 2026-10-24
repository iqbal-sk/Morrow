import Foundation
import Testing
@testable import DigUpApp
@testable import DigUpKit

@MainActor @Suite(.serialized) struct PeopleFlowTests {
    @Test func deletingSelectedPersonSelectsAnExistingPerson() async throws {
        let fixture = try PeopleFixture()
        defer { fixture.clean() }
        let first = try #require(await fixture.people.save(id: nil, name: "Ada", aliases: ""))
        let second = try #require(await fixture.people.save(id: nil, name: "Grace", aliases: ""))
        #expect(fixture.people.selectedPerson == second)
        await fixture.people.removePerson(second)
        #expect(fixture.people.selectedPerson == first)
        #expect(fixture.people.profiles.map(\.id) == [first])
    }

    @Test func deletingAnotherPersonPreservesCurrentSelection() async throws {
        let fixture = try PeopleFixture()
        defer { fixture.clean() }
        let first = try #require(await fixture.people.save(id: nil, name: "Ada", aliases: ""))
        let second = try #require(await fixture.people.save(id: nil, name: "Grace", aliases: ""))
        await fixture.people.removePerson(first)
        #expect(fixture.people.selectedPerson == second)
    }

    @Test func reviewAllAndBackPreservesThePersonAndTheirReferences() async throws {
        let fixture = try PeopleFixture()
        defer { fixture.clean() }
        let id = try #require(await fixture.people.save(id: nil, name: "Ada", aliases: "A"))
        let saved = await fixture.people.addReference(person: id, face: fixture.face, source: fixture.root.appendingPathComponent("reference.jpg"))
        #expect(saved)
        #expect(fixture.people.references.count == 1)
        fixture.people.reviewingAllFaces = true
        await fixture.people.refresh()
        #expect(fixture.people.selectedPerson == id)
        #expect(fixture.people.references.isEmpty)
        fixture.people.reviewingAllFaces = false
        await fixture.people.refresh()
        #expect(fixture.people.selectedPerson == id)
        #expect(fixture.people.references.count == 1)
    }

    @Test func failedPhotosAreNeverReportedAsUpToDate() async throws {
        let fixture = try PeopleFixture()
        defer { fixture.clean() }
        let id = try #require(await fixture.people.save(id: nil, name: "Ada", aliases: ""))
        _ = await fixture.people.addReference(person: id, face: fixture.face, source: fixture.root.appendingPathComponent("reference.jpg"))
        fixture.people.pending = 0
        fixture.people.failedPhotos = 2
        #expect(!fixture.people.scanStatusLine.contains("Up to date"))
        #expect(fixture.people.scanStatusLine.contains("2 photos"))
        fixture.people.isPaused = true
        #expect(fixture.people.scanStatusLine.contains("Paused"))
    }

    @Test func invalidNameFailsWithoutChangingSelectionOrRemovingThePerson() async throws {
        let fixture = try PeopleFixture()
        defer { fixture.clean() }
        let id = try #require(await fixture.people.save(id: nil, name: "Ada", aliases: ""))
        let saved = await fixture.people.save(id: id, name: " \n ", aliases: "")
        #expect(saved == nil)
        #expect(fixture.people.problem != nil)
        #expect(fixture.people.selectedPerson == id)
        #expect(fixture.people.profiles.first?.name == "Ada")
    }

    @Test func closingAnOlderReferenceBatchDoesNotCancelANewerBatch() async throws {
        let fixture = try PeopleFixture()
        defer { fixture.clean() }
        let old = UUID(), current = UUID()
        fixture.people.beginReferenceImport(old)
        fixture.people.beginReferenceImport(current)
        fixture.people.endReferenceImport(old)
        #expect(fixture.people.isAddingReferences)
        fixture.people.endReferenceImport(current)
        #expect(!fixture.people.isAddingReferences)
        await fixture.people.refresh()
    }

    @Test func rejectingAMatchedFaceRemovesItFromSearchAndItStaysRejected() async throws {
        let fixture = try PeopleFixture()
        defer { fixture.clean() }
        let id = try #require(await fixture.people.save(id: nil, name: "Ada", aliases: ""))
        _ = await fixture.people.addReference(person: id, face: fixture.face, source: fixture.root.appendingPathComponent("reference.jpg"))
        let face = try fixture.indexedFace()
        await fixture.people.refresh()
        #expect(fixture.people.profiles.first?.files == 1)
        await fixture.people.confirm(face, person: nil)
        #expect(fixture.people.reviews.isEmpty)
        #expect(fixture.people.profiles.first?.files == 0)
        await fixture.people.refresh()
        #expect(fixture.people.reviews.isEmpty)
    }

    @Test func assigningToAnotherPersonMovesTheFaceToThatPersonsFiles() async throws {
        let fixture = try PeopleFixture()
        defer { fixture.clean() }
        let ada = try #require(await fixture.people.save(id: nil, name: "Ada", aliases: ""))
        _ = await fixture.people.addReference(person: ada, face: fixture.face, source: fixture.root.appendingPathComponent("reference.jpg"))
        let grace = try #require(await fixture.people.save(id: nil, name: "Grace", aliases: ""))
        let face = try fixture.indexedFace()
        await fixture.people.confirm(face, person: grace)
        #expect(fixture.people.profiles.first(where: { $0.id == ada })?.files == 0)
        #expect(fixture.people.profiles.first(where: { $0.id == grace })?.files == 1)
        #expect(fixture.people.reviews.first?.status == "confirmed")
    }

    @Test func removingTheLastReferenceUpdatesEnrollmentStatus() async throws {
        let fixture = try PeopleFixture()
        defer { fixture.clean() }
        let id = try #require(await fixture.people.save(id: nil, name: "Ada", aliases: ""))
        _ = await fixture.people.addReference(person: id, face: fixture.face, source: fixture.root.appendingPathComponent("reference.jpg"))
        let reference = try #require(fixture.people.references.first?.0)
        await fixture.people.removeReference(reference)
        #expect(fixture.people.references.isEmpty)
        #expect(fixture.people.profiles.first?.references == 0)
        #expect(fixture.people.scanStatusLine.contains("reference photos"))
    }

    @Test func renamedAliasesReachTheSearchResolverImmediately() async throws {
        let fixture = try PeopleFixture()
        defer { fixture.clean() }
        let id = try #require(await fixture.people.save(id: nil, name: "Ada", aliases: "Countess"))
        fixture.people.enabled = true
        _ = await fixture.people.save(id: id, name: "Ada Lovelace", aliases: "Enchantress")
        #expect(fixture.engine.personQuery("Enchantress at the beach").people.first?.id == id)
        #expect(fixture.engine.personQuery("Countess").people.isEmpty)
    }
}

@MainActor private final class PeopleFixture {
    private static let suite = "com.iqbal.morrow.behavior-tests.\(ProcessInfo.processInfo.processIdentifier)"
    let root: URL
    let engine: Engine
    let people: PeopleCoordinator
    var face: FaceSample {
        FaceSample(box: [0.1, 0.1, 0.5, 0.5], vector: [1] + Array(repeating: 0, count: 127), jpeg: Data([1]))
    }
    init() throws {
        UserDefaults.standard.set(Self.suite, forKey: "defaultsSuite")
        AppSettings.defaults.set(false, forKey: "peopleEnabled")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowPeopleBehavior-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = AppSettings(roots: [root], excludedFolders: [], excludedTypes: [],
                                   indexDirectory: root.appendingPathComponent("index"), modelsDirectory: root.appendingPathComponent("models"),
                                   hotkey: "", indexOnBattery: false, indexHoursOn: false, indexHours: .night,
                                   encoderIdleSeconds: 1, onboarded: true, codeRoots: [], codeExcluded: [], codeEditor: nil, codeQuietSeconds: 1)
        engine = Engine(settings: settings, backfillBlocker: nil, heldUntil: nil, onStatus: { _ in })
        people = PeopleCoordinator(settings: settings, engine: engine)
    }
    func indexedFace() throws -> FaceReview {
        let path = root.appendingPathComponent("group.jpg")
        try Data(repeating: 0, count: 10).write(to: path)
        let store = try IndexStore(directory: root.appendingPathComponent("index"))
        let file = try store.insert(Candidate(path: path.path, kind: .image, size: 10, mtime: 1, inode: 1, device: 1))
        try store.finish(file, state: "done")
        let identities = PeopleStore(store: store)
        try identities.saveFaces(file: file, stamp: "10:1.0:1:1", samples: [face])
        try identities.rematchIfNeeded()
        return try #require(identities.review().first)
    }
    func clean() {
        people.pause()
        try? FileManager.default.removeItem(at: root)
        AppSettings.defaults.removePersistentDomain(forName: Self.suite)
    }
}
