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
        try people.saveFaces(file: id, stamp: "10:1.0", samples: [sample(0),sample(1),sample(2)])
        try people.rematch()
        let reviews = try people.review()
        #expect(reviews.count == 3)
        #expect(reviews.filter { $0.status == "auto" }.count == 2)
        #expect(reviews.filter { $0.person == nil }.count == 1)
        #expect(try people.fileIDs(for: [a,b]) == [id])
        let face = try #require(reviews.first { $0.person == a })
        try people.confirm(face: face.id, person: b)
        try people.saveFaces(file: id, stamp: "10:1.0", samples: [sample(2)]) // overlapping worker must preserve decisions
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
        try people.saveFaces(file: id, stamp: "10:1.0", samples: [sample(0)])
        try people.rematch()
        let face = try #require(people.review().first)
        try people.confirm(face: face.id, person: nil)
        try people.rematch()
        #expect(try people.fileIDs(for: [a]).isEmpty)
        #expect(try people.review().isEmpty)
        try store.requeue(id, as: Candidate(path: "/photos/one.jpg", kind: .image, size: 11, mtime: 2, inode: 1, device: 1))
        #expect(try people.pendingPhotos().count == 1)
        try people.saveFaces(file: id, stamp: "10:1.0", samples: [sample(0)]) // stale in-flight job
        #expect(try people.pendingPhotos().count == 1)
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
