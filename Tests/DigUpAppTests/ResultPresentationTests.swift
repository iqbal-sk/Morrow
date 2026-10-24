import Testing
@testable import DigUpApp
@testable import DigUpKit

@MainActor @Suite struct ResultPresentationTests {
    @Test func replacingAFileInvalidatesItsCachedPreview() {
        let original = row(modified: 1, size: 100, segment: 1)
        let replaced = row(modified: 2, size: 100, segment: 1)
        let resized = row(modified: 1, size: 200, segment: 1)
        #expect(original.id == replaced.id)
        #expect(original.previewKey != replaced.previewKey)
        #expect(original.previewKey != resized.previewKey)
    }

    @Test func reindexingAChangedPassageInvalidatesItsTextPreview() {
        let original = row(modified: 1, size: 100, segment: 1)
        let reindexed = row(modified: 1, size: 100, segment: 2)
        #expect(original.previewKey != reindexed.previewKey)
        #expect(original.previewKey == row(modified: 1, size: 100, segment: 1).previewKey)
    }

    private func row(modified: Double, size: Int64, segment: Int64) -> ResultRow {
        ResultRow(SearchHit(path: "/synthetic/receipt.txt", kind: .doc, score: 1, z: nil, cosine: nil,
                            keywordRank: 1, segment: .chunk, segmentID: segment, loc: nil, locEnd: nil,
                            excerpt: "receipt", modified: modified, size: size, info: [:]))
    }
}
