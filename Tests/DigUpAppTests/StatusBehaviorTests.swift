import Foundation
import Testing
@testable import DigUpApp

@MainActor @Suite struct StatusBehaviorTests {
    @Test func codeProgressDoesNotAppearAsFileProgress() {
        let model = makeModel()
        model.status.activity = .idle
        model.status.code.indexing = .init(done: 5, total: 10)
        #expect(model.progress == nil)
        #expect(model.codeProgress == 0.5)
    }

    @Test func fileAndCodeProgressRemainIndependentWhenBothRun() {
        let model = makeModel()
        model.status.activity = .indexing(done: 2, total: 10)
        model.status.code.indexing = .init(done: 7, total: 10)
        #expect(model.progress == 0.2)
        #expect(model.codeProgress == 0.7)
    }

    @Test func pausedPendingFilesAreNotReportedAsReady() {
        let model = makeModel()
        model.status.activity = .idle
        model.status.files = 10
        model.status.searchable = 3
        model.status.pending = 7
        model.status.paused = true
        #expect(model.statusLine.localizedCaseInsensitiveContains("paused"))
        #expect(!model.statusLine.contains("ready to search"))
    }

    @Test func zeroTotalsDoNotProduceInvalidProgressValues() {
        let model = makeModel()
        model.status.activity = .indexing(done: 0, total: 0)
        model.status.code.indexing = .init(done: 0, total: 0)
        #expect(model.progress == nil)
        #expect(model.codeProgress == nil)
    }

    private func makeModel() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowStatus-\(UUID())")
        let settings = AppSettings(roots: [root], excludedFolders: [], excludedTypes: [], indexDirectory: root,
                                   modelsDirectory: root.appendingPathComponent("models"), hotkey: "", indexOnBattery: false,
                                   indexHoursOn: false, indexHours: .night, encoderIdleSeconds: 1, onboarded: true,
                                   codeRoots: [root.appendingPathComponent("code")], codeExcluded: [], codeEditor: nil, codeQuietSeconds: 1)
        return AppModel(settings: settings, download: ModelDownload(folder: settings.modelsDirectory))
    }
}
