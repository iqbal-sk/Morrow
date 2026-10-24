import Foundation
import Testing
@testable import DigUpKit

@Suite struct PeopleTests {
    func setup() throws -> (IndexStore, PeopleStore) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpPeopleTests-\(UUID().uuidString)")
        let store = try IndexStore(directory: folder)
        return (store, PeopleStore(store: store))
    }
    func vector(_ axis: Int) -> [Float] { var v = [Float](repeating: 0, count: 128); v[axis] = 1; return v }
    func sample(_ axis: Int) -> FaceSample { FaceSample(box: [0,0,1,1], vector: vector(axis), jpeg: Data([1,2,3])) }
    func file(_ store: IndexStore, name: String, inode: UInt64 = 1, kind: FileKind = .image) throws -> Int64 {
        try store.insert(Candidate(path: "/photos/\(name)", kind: kind, size: 10, mtime: 1, inode: inode, device: 1))
    }
    @Test func matchesUnknownsCorrectionsAndReferencesSurviveContentReset() throws {
        let (store,people) = try setup()
        let a = try people.savePerson(name: "Iqbal", aliases: ["Iq"])
        let b = try people.savePerson(name: "Siri", aliases: [])
        try people.addReference(person: a, sample: sample(0), source: "reference-a.jpg")
        try people.addReference(person: b, sample: sample(1), source: "reference-b.jpg")
        let id = try file(store,name: "group.jpg")
        try people.saveFaces(file: id, stamp: "10:1.0:1:1", samples: [sample(0),sample(1),sample(2)])
        try people.rematch()
        let reviews = try people.review()
        #expect(reviews.count == 3)
        #expect(reviews.filter { $0.status == "auto" }.count == 2)
        #expect(reviews.filter { $0.person == nil }.count == 1)
        #expect(try people.fileIDs(for: [a,b]) == [id])
        let face = try #require(reviews.first { $0.person == a })
        try people.confirm(face: face.id, person: b)
        try people.saveFaces(file: id, stamp: "10:1.0:1:1", samples: [sample(2)]) // overlapping worker must preserve decisions
        try people.rematch()
        #expect(try people.review(person: b).contains { $0.id == face.id && $0.status == "confirmed" })
        #expect(try people.fileIDs(for: [a]).isEmpty)
        try store.resetAll()
        #expect(try people.profiles().count == 2)
        #expect(try people.references(person: a).count == 1)
        #expect(try people.review(person: b).contains { $0.id == face.id && $0.status == "confirmed" })
        try store.delete(id)
        #expect(try people.review(person: b).isEmpty)
        #expect(try people.references(person: b).count == 1)
    }
    @Test func rejectedFacesAreNotReassignedAndChangedFilesAreExcluded() throws {
        let (store,people) = try setup()
        let a = try people.savePerson(name: "Iqbal", aliases: [])
        try people.addReference(person: a, sample: sample(0), source: "reference.jpg")
        let id = try file(store,name: "one.jpg")
        try people.saveFaces(file: id, stamp: "10:1.0:1:1", samples: [sample(0)])
        try people.rematch()
        let face = try #require(people.review().first)
        try people.confirm(face: face.id, person: nil)
        try people.rematch()
        #expect(try people.fileIDs(for: [a]).isEmpty)
        #expect(try people.review().isEmpty)
        try store.requeue(id, as: Candidate(path: "/photos/one.jpg", kind: .image, size: 11, mtime: 2, inode: 1, device: 1))
        #expect(try people.pendingPhotos().count == 1)
        try people.saveFaces(file: id, stamp: "10:1.0:1:1", samples: [sample(0)]) // stale in-flight job
        #expect(try people.pendingPhotos().count == 1)
    }
    @Test func replacementFileWithSameSizeAndMtimeInvalidatesItsFaces() throws {
        let (store, people) = try setup()
        let id = try file(store, name: "replaced.jpg", inode: 11)
        try people.saveFaces(file: id, stamp: "10:1.0:11:1", samples: [sample(0)])
        #expect(try people.pendingPhotos().isEmpty)
        #expect(try people.review().count == 1)

        // A copied-over file can retain size and modification time while the filesystem identity changes.
        try store.requeue(id, as: Candidate(path: "/photos/replaced.jpg", kind: .image, size: 10, mtime: 1,
                                            inode: 12, device: 1))
        #expect(try people.pendingPhotos().count == 1)
        #expect(try people.review().isEmpty)
    }

    @Test func resettingFolderDeletesItsFacesButKeepsPeopleAndReferences() throws {
        let (store, people) = try setup()
        let person = try people.savePerson(name: "Iqbal", aliases: ["Iq"])
        try people.addReference(person: person, sample: sample(0), source: "reference.jpg")
        let target = try file(store, name: "trip/group.jpg", inode: 1)
        let other = try file(store, name: "family/group.jpg", inode: 2)
        try people.saveFaces(file: target, stamp: "10:1.0:1:1", samples: [sample(0)])
        try people.saveFaces(file: other, stamp: "10:1.0:2:1", samples: [sample(0)])
        try people.rematch()
        #expect(try people.review().count == 2)

        #expect(try store.deleteIndexedFiles(under: "/photos/trip") == 1)
        #expect(try people.review().count == 1)
        #expect(try people.profiles().count == 1)
        #expect(try people.references(person: person).count == 1)
        #expect(try store.files(under: ["/photos"]).map(\.path) == ["/photos/family/group.jpg"])

        #expect(try store.deleteIndexedFiles() == 1)
        #expect(try people.review().isEmpty)
        #expect(try people.profiles().count == 1)
        #expect(try people.references(person: person).count == 1)
    }
    @Test func lateFaceResultsFromAnOlderSizePolicyAreDiscarded() throws {
        let (store, people) = try setup()
        let id = try file(store, name: "policy-change.jpg")
        let stamp = "10:1.0:1:1"
        try people.saveFaces(file: id, stamp: stamp, samples: [sample(0)], minimumFacePixels: 48)
        try people.setMinimumFacePixels(64)

        // A worker finishing after the slider changed must not overwrite the new policy's pending state.
        try people.saveFaces(file: id, stamp: stamp, samples: [sample(1)], minimumFacePixels: 48)
        #expect(try people.pendingPhotos().count == 1)
        #expect(try people.review().isEmpty)

        try people.saveFaces(file: id, stamp: stamp, samples: [sample(2)], minimumFacePixels: 64)
        #expect(try people.pendingPhotos().isEmpty)
        #expect(try people.review().count == 1)
    }
    @Test func addingAReferenceRematchesStoredFacesWithoutRequeuingPhotos() throws {
        let (store, people) = try setup()
        let first = try people.savePerson(name: "Iqbal", aliases: [])
        try people.addReference(person: first, sample: sample(0), source: "iqbal-reference.jpg")
        let photo = try file(store, name: "group.jpg")
        try people.saveFaces(file: photo, stamp: "10:1.0:1:1", samples: [sample(1)])
        try people.rematch()
        #expect(try people.pendingPhotos().isEmpty)
        #expect(try people.fileIDs(for: [first]).isEmpty)

        let second = try people.savePerson(name: "Siri", aliases: [])
        try people.addReference(person: second, sample: sample(1), source: "siri-reference.jpg")
        try people.rematchIfNeeded()
        #expect(try people.pendingPhotos().isEmpty)
        #expect(try people.fileIDs(for: [second]) == [photo])
    }
    @Test func interruptedBatchResumesOnlyUnprocessedPhotosAfterReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpPeopleResume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (person, processed, pending): (Int64, Int64, Int64) = try {
            let store = try IndexStore(directory: folder)
            let people = PeopleStore(store: store)
            let person = try people.savePerson(name: "Iqbal", aliases: [])
            try people.addReference(person: person, sample: sample(0), source: "reference.jpg")
            let processed = try store.insert(Candidate(path: "/photos/processed.jpg", kind: .image, size: 10,
                                                       mtime: 1, inode: 1, device: 1))
            let pending = try store.insert(Candidate(path: "/photos/pending.jpg", kind: .image, size: 11,
                                                      mtime: 1, inode: 2, device: 1))
            // Simulate termination after one per-photo transaction in a larger batch.
            try people.saveFaces(file: processed, stamp: "10:1.0:1:1", samples: [sample(0)])
            try people.rematchIfNeeded()
            return (person, processed, pending)
        }()

        let reopened = try PeopleStore(directory: folder)
        #expect(try reopened.pendingPhotos().map(\.0) == [pending])
        #expect(try reopened.fileIDs(for: [person]) == [processed])
    }
    @Test func faceSelectionLeavesExcludedAndUnavailablePhotosPending() throws {
        let (store, people) = try setup()
        let included = try file(store, name: "keep/photo.jpg")
        _ = try file(store, name: "keep/private/photo.jpg", inode: 2)
        _ = try file(store, name: "keep/notes.pdf", inode: 3, kind: .image)
        _ = try file(store, name: "keep/offline.jpg", inode: 4)
        let jobs = try people.pendingPhotos()
        let selection = FacePhotoSelection(roots: ["/photos/keep"], excluded: ["/photos/keep/private"], types: [".PDF"])
        let selectedPending = selection.eligiblePending(jobs)
        #expect(selectedPending.count == 2) // the readable and unavailable chosen photos remain eligible
        let readablePending = selection.filterPending(jobs) { $0 != "/photos/keep/offline.jpg" }
        #expect(readablePending.map(\.0) == [included])
        #expect(try people.pendingPhotos().count == 4) // filtering never deletes or marks skipped rows complete
    }
    @Test func referencePhotoBatchRejectsStaleIndicesAndStopsAtItsBoundary() {
        let first = URL(fileURLWithPath: "/photos/first.jpg")
        let second = URL(fileURLWithPath: "/photos/second.jpg")
        let one = ReferencePhotoBatch(photos: [first])
        #expect(one.photo(at: 0) == first)
        #expect(one.photo(at: -1) == nil)
        #expect(one.photo(at: 1) == nil)
        #expect(one.photo(at: Int.max) == nil)
        #expect(one.nextIndex(after: 0) == nil)
        #expect(one.nextIndex(after: Int.max) == nil)

        let two = ReferencePhotoBatch(photos: [first, second])
        let next = two.nextIndex(after: 0)
        #expect(next == 1)
        #expect(next.flatMap { two.photo(at: $0) } == second)
        #expect(two.nextIndex(after: 1) == nil)
    }
    @Test func personResultsExcludeOldFoldersBeforeSearchRanking() throws {
        let (store, people) = try setup()
        let photoRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpPeopleSearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: photoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: photoRoot) }
        func photo(_ folder: String, _ name: String, inode: UInt64) throws -> Int64 {
            let directory = photoRoot.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try Data([1]).write(to: url)
            return try store.insert(Candidate(path: url.path, kind: .image, size: 10, mtime: 1, inode: inode, device: 1))
        }
        let person = try people.savePerson(name: "Iqbal", aliases: [])
        try people.addReference(person: person, sample: sample(0), source: "reference.jpg")
        for index in 0..<300 {
            let id = try photo("old", "beach-\(index).jpg", inode: UInt64(index + 1))
            try people.saveFaces(file: id, stamp: "10:1.0:\(index + 1):1", samples: [sample(0)])
        }
        let target = try photo("keep", "beach-target.jpg", inode: 2000)
        try people.saveFaces(file: target, stamp: "10:1.0:2000:1", samples: [sample(0)])
        try people.rematch()

        let selection = FacePhotoSelection(roots: [photoRoot.appendingPathComponent("keep").path], excluded: [], types: [])
        let personFiles = try people.fileIDs(for: [person], selection: selection)
        #expect(personFiles == [target])
        let searcher = try Searcher(store: store, loadVectors: false)
        let hits = try searcher.search("beach", queryVector: nil, limit: 1, fileIDs: personFiles)
        #expect(hits.map(\.path) == [photoRoot.appendingPathComponent("keep/beach-target.jpg").path])
    }
    @Test func peopleReviewAndCountsFollowFolderSelectionWithoutDeletingVectors() throws {
        let (store, people) = try setup()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpPeopleScope-\(UUID().uuidString)")
        let outsideRoot = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        let person = try people.savePerson(name: "Iqbal", aliases: [])
        try people.addReference(person: person, sample: sample(0), source: "reference.jpg")
        func add(_ relativePath: String, inode: UInt64, selectedRoot: Bool = true) throws -> (Int64, String) {
            let url = (selectedRoot ? root : outsideRoot).appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
            let id = try store.insert(Candidate(path: url.path, kind: .image, size: 1, mtime: 1, inode: inode, device: 1))
            try people.saveFaces(file: id, stamp: "1:1.0:\(inode):1", samples: [sample(0)])
            return (id, url.path)
        }
        let publicPhoto = try add("public.jpg", inode: 1)
        let excludedPhoto = try add("private/hidden.jpg", inode: 2)
        let explicitlyChosenPhoto = try add("private/keep/selected.jpg", inode: 3)
        let excludedType = try add("notes.PDF", inode: 4)
        _ = try add("outside.jpg", inode: 5, selectedRoot: false)
        try people.rematch()

        let selection = FacePhotoSelection(
            roots: [root.path, root.appendingPathComponent("private/keep").path],
            excluded: [root.appendingPathComponent("private").path],
            types: [".PDF"])
        #expect(selection.includes(publicPhoto.1))
        #expect(!selection.includes(excludedPhoto.1))
        #expect(selection.includes(explicitlyChosenPhoto.1)) // a deeper chosen root overrides its parent's skip
        #expect(!selection.includes(excludedType.1))

        let (selectionSQL, selectionValues) = selection.sqlPredicate(pathExpression: "s.path")
        var sqlPaths = Set<String>()
        try people.db.query("SELECT s.path FROM files s WHERE \(selectionSQL)", selectionValues) {
            sqlPaths.insert($0.text(0) ?? "")
        }
        #expect(sqlPaths == [publicPhoto.1, explicitlyChosenPhoto.1])

        let scopedProfile = try #require(people.profiles(selection: selection).first { $0.id == person })
        #expect(scopedProfile.files == 2)
        #expect(Set(try people.review(selection: selection).map(\.path)) == [publicPhoto.1, explicitlyChosenPhoto.1])
        #expect(try people.fileIDs(for: [person], selection: selection) == [publicPhoto.0, explicitlyChosenPhoto.0])

        // Excluding a folder hides it from this view but preserves its vectors for a later re-include.
        let allProfile = try #require(people.profiles().first { $0.id == person })
        #expect(allProfile.files == 5)
        #expect(try people.review().count == 5)
    }
    @Test func rematchKeepsAConcurrentRequestForTheNextPass() throws {
        let (store, people) = try setup()
        let person = try people.savePerson(name: "Iqbal", aliases: [])
        try people.addReference(person: person, sample: sample(0), source: "reference.jpg")
        let photo = try file(store, name: "concurrent-rematch.jpg")
        try people.saveFaces(file: photo, stamp: "10:1.0:1:1", samples: [sample(0)])
        try store.db.execute("""
            CREATE TRIGGER request_another_rematch AFTER INSERT ON face_matches
            BEGIN UPDATE meta SET value='newer-rematch-request' WHERE key='people.rematchNeeded'; END;
            """)

        try people.rematchIfNeeded()
        var marker: String?
        try store.db.query("SELECT value FROM meta WHERE key='people.rematchNeeded'") { marker = $0.text(0) }
        #expect(marker == "newer-rematch-request")

        try store.db.execute("DROP TRIGGER request_another_rematch")
        try people.rematchIfNeeded()
        marker = nil
        try store.db.query("SELECT value FROM meta WHERE key='people.rematchNeeded'") { marker = $0.text(0) }
        #expect(marker == nil)
        #expect(try people.fileIDs(for: [person]) == [photo])
    }
    @Test func aliasesHaveBoundariesAndAmbiguityDoesNotPickAnIdentity() throws {
        let (_,people) = try setup()
        let id = try people.savePerson(name: "Iqbal", aliases: ["Iq"])
        try people.savePerson(name: "Siri", aliases: ["friend"])
        try people.savePerson(name: "Vikas", aliases: ["friend"])
        #expect(try people.resolve("Iqbal and Siri at the beach").people.count == 2)
        #expect(try people.resolve("Iqbal and Siri at the beach").remainder == "at the beach")
        #expect(try people.resolve("show me photos of Iq").people.first?.id == id)
        #expect(try people.resolve("show me photos of Iq").remainder.isEmpty)
        #expect(try people.resolve("friend").people.isEmpty)
        #expect(try people.resolve("friend").ambiguous == ["friend"])
        #expect(try people.resolve("Iqbally").people.isEmpty)
    }
    @Test func ambiguousFullNameCannotFallBackToOnePersonsShortAlias() throws {
        let (_, people) = try setup()
        try people.savePerson(name: "Alex Smith", aliases: ["Alex"])
        try people.savePerson(name: "Alex Smith", aliases: [])
        let query = try people.resolve("Alex Smith")
        #expect(query.people.isEmpty)
        #expect(query.ambiguous == ["alex smith"])
        #expect(query.remainder == "Alex Smith")
    }
    @Test func punctuationVariantsOfAnAliasRemainAmbiguous() throws {
        let (_, people) = try setup()
        try people.savePerson(name: "A B", aliases: [])
        try people.savePerson(name: "C D", aliases: ["A-B"])
        let query = try people.resolve("A/B")
        #expect(query.people.isEmpty)
        #expect(query.ambiguous == ["a b"])
    }
    @Test func personFilterIsAppliedBeforeKeywordTopK() throws {
        let (store,_) = try setup()
        for i in 0..<1010 {
            let id = try file(store, name: "beach-\(i).txt", inode: UInt64(i+1), kind: .doc)
            try store.addSegment(file: id, kind: .chunk, modality: .text, text: "beach")
        }
        let target = try file(store,name: "target.txt", inode: 2000, kind: .doc)
        try store.addSegment(file: target, kind: .chunk, modality: .text, text: "a beach in the middle of a long note")
        let searcher = try Searcher(store: store, loadVectors: false)
        let hits = try searcher.search("beach", queryVector: nil, limit: 1, fileIDs: [target])
        #expect(hits.count == 1)
        #expect(hits.first?.path == "/photos/target.txt")
        #expect(try searcher.search("", queryVector: nil, fileIDs: [target]).count == 1)
        #expect(try searcher.search("beach", queryVector: nil, fileIDs: []).isEmpty)
    }
    @Test func mentionsUseExtractedTextAndNotLabelledPhotoFolders() throws {
        let (store,people) = try setup()
        let a = try people.savePerson(name: "Iqbal", aliases: ["Iq"])
        _ = try file(store,name: "Iqbal/group.jpg")
        let doc = try file(store,name: "notes.txt", inode: 2, kind: .doc)
        try store.addSegment(file: doc, kind: .chunk, modality: .text, text: "Trip plans with Iq")
        #expect(try people.fileIDs(for: [a]) == [doc])
    }
}
