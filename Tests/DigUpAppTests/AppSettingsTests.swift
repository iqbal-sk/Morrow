import Foundation
import Testing
@testable import DigUpApp
@testable import DigUpKit

@MainActor @Suite struct AppSettingsTests {
    @Test func chosenFoldersUseTheSamePathsAsIndexedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowPaths-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("receipt.txt")
        try Data("Hardware receipt".utf8).write(to: file)
        let chosen = AppSettings.folderURL(folder.standardizedFileURL.path).path
        let indexed = FolderSelection.realPath(file.path)
        #expect(chosen == FolderSelection.realPath(folder.path))
        #expect(FolderSelection.isSearched(indexed, folders: [chosen], skipped: []))
        #expect(FacePhotoSelection(roots: [chosen], excluded: [], types: []).includes(indexed))
    }

    @Test func symlinkChoicesAndExclusionsShareOnePathIdentity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowAliases-\(UUID())")
        let actual = folder.appendingPathComponent("actual")
        let excluded = actual.appendingPathComponent("private")
        let alias = folder.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let chosen = AppSettings.folderURL(alias.path).path
        let skip = AppSettings.folderURL(alias.appendingPathComponent("private").path).path
        #expect(chosen == FolderSelection.realPath(actual.path))
        #expect(!FolderSelection.isSearched(FolderSelection.realPath(excluded.path) + "/photo.jpg",
                                            folders: [chosen], skipped: [skip]))
        #expect(FolderSelection.isSearched(chosen + "/public.jpg", folders: [chosen], skipped: [skip]))
        #expect(!FolderSelection.isSearched(chosen + "-other/photo.jpg", folders: [chosen], skipped: []))
    }
}
