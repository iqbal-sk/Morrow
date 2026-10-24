import Testing
@testable import DigUpKit

@Suite struct AppPathsTests {
    @Test func indexAndModelsUseMorrowOwnedSupportDirectory() {
        let support = AppPaths.applicationSupport.path
        #expect(AppPaths.applicationSupport.lastPathComponent.lowercased() == "morrow")
        #expect(AppPaths.defaultIndex.path.hasPrefix(support + "/"))
        #expect(ModelFiles.installed.path.hasPrefix(support + "/"))
    }
}
