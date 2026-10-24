import Foundation
import Testing
@testable import DigUpKit

@Suite struct LibraryBrowserTests {
    @Test func browsingRespectsBoundariesAvailabilityPoliciesAndLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory.appendingPathComponent("index"))
        let root = directory.appendingPathComponent("photos")
        let sibling = directory.appendingPathComponent("photos-old")
        let skipped = root.appendingPathComponent("private")
        for folder in [root, sibling, skipped] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        func add(_ path: URL, time: Double, state: String = "done", exists: Bool = true) throws -> Int64 {
            if exists { try Data().write(to: path) }
            let id = try store.insert(Candidate(path: path.path, kind: .image, size: 0, mtime: time, inode: UInt64(time), device: 1))
            try store.finish(id, state: state, info: ["width": "1200"])
            return id
        }
        let first = try add(root.appendingPathComponent("new.jpg"), time: 10)
        try add(root.appendingPathComponent("older.png"), time: 2, state: "partial")
        try add(root.appendingPathComponent("pending.jpg"), time: 20, state: "pending")
        try add(root.appendingPathComponent("gone.jpg"), time: 30, exists: false)
        try add(skipped.appendingPathComponent("hidden.jpg"), time: 40)
        let outside = try add(sibling.appendingPathComponent("sibling.jpg"), time: 50)
        let hits = try store.libraryFiles(under: [root.path], excluded: [skipped.path], limit: 1)
        #expect(hits.map(\.path) == [root.appendingPathComponent("new.jpg").path])
        #expect(hits.first?.info["width"] == "1200")
        let png = try store.libraryFiles(under: [root.path], excluded: [skipped.path], excludedTypes: ["jpg"])
        #expect(png.map(\.path) == [root.appendingPathComponent("older.png").path])
        #expect(try store.libraryFiles(under: [], limit: 10).isEmpty)
        #expect(try store.libraryFiles(under: [root.path], kinds: []).isEmpty)
        let ids = try store.libraryFileIDs(under: [root.path])
        #expect(ids.contains(first))
        #expect(!ids.contains(outside))
    }
}
