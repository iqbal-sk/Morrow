import Foundation
import Testing
@testable import DigUpKit

@Suite struct IndexResetTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowReset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func insert(_ path: String, into store: IndexStore, inode: UInt64) throws {
        _ = try store.insert(Candidate(path: path, kind: .image, size: 10, mtime: 1, inode: inode, device: 1))
    }

    @Test func directoryAndFullResetsCoverBothIndexesAndCoalesceScopes() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = try IndexStore(directory: folder)
        let code = try IndexStore(directory: folder, file: IndexStore.codeFile)
        try insert("/photos/trip/one.jpg", into: main, inode: 1)
        try insert("/photos/trip/day-two/two.jpg", into: main, inode: 2)
        try insert("/photos/trip-old/keep.jpg", into: main, inode: 3)
        try insert("/projects/trip/one.jpg", into: code, inode: 4)
        try insert("/projects/other/keep.jpg", into: code, inode: 5)

        #expect(try IndexReset.delete(in: folder, scopes: ["/photos/trip", "/projects/trip", "/photos/trip"]) == 3)
        #expect(try IndexStore(directory: folder).files(under: ["/photos"]).map(\.path) == ["/photos/trip-old/keep.jpg"])
        #expect(try IndexStore(directory: folder, file: IndexStore.codeFile).files(under: ["/projects"]).map(\.path)
            == ["/projects/other/keep.jpg"])

        #expect(try IndexReset.delete(in: folder, scopes: ["/photos/trip-old", nil]) == 2)
        #expect(try IndexStore(directory: folder).files(under: ["/"]).isEmpty)
        #expect(try IndexStore(directory: folder, file: IndexStore.codeFile).files(under: ["/"]).isEmpty)
    }
}
