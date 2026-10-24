import AppKit
import Observation

/// State the menubar, the panel and the windows share. Engine updates arrive on the main thread.
@Observable
final class AppModel {
    @ObservationIgnored var onStatusChange: (() -> Void)?
    var status = EngineStatus() {
        didSet { onStatusChange?() }
    }
    var settings: AppSettings
    var hotkey: KeyCombo?
    let download: ModelDownload
    /// A newer Morrow the daily check found ("0.6.1"), until you open it (`Updates`).
    var updateAvailable: String?

    init(settings: AppSettings, download: ModelDownload) {
        self.settings = settings
        self.download = download
    }

    var hasFolders: Bool { !settings.roots.isEmpty }
    /// Code search is on (there are code folders).
    var hasCode: Bool { !settings.codeRoots.isEmpty }

    /// File-search index status, kept distinct from the People face-scan status.
    var statusLine: String {
        let status = self.status
        guard hasFolders else { return "No folders chosen yet" }
        switch status.activity {
        case .starting: return "Starting file search…"
        case .failed(let problem): return "⚠︎ \(problem)"
        case .syncing: return "Checking selected folders…"
        case .indexing(let done, let total):
            let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
            return "Indexing files · \(percent)% · \(done.formatted()) of \(total.formatted())"
        case .finishing(let done, let total, let files):
            let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
            let which = files > 0 ? "\(files.formatted()) long \(files == 1 ? "file" : "files")" : "long files"
            return "Finishing file search · \(which) · \(percent)%"
        case .idle:
            if status.paused {
                var details: [String] = []
                if status.pending > 0 { details.append("\(status.pending.formatted()) files waiting") }
                if status.unfinished > 0 { details.append("\(status.unfinished.formatted()) long files to finish") }
                if let line = downloadLine { details.append(line) }
                return "File indexing paused" + (details.isEmpty ? "" : " · " + details.joined(separator: " · "))
            }
            if let line = downloadLine { return line }
            let waiting = "\(status.pending.formatted()) \(status.pending == 1 ? "file" : "files") to index"
            if status.pending > 0, status.paused { return "File indexing paused · \(waiting)" }
            if let until = status.heldUntil, !status.paused {
                // Outside the set hours: what's known to wait, and when indexing starts again.
                let when = "indexing from \(until.formatted(date: .omitted, time: .shortened))"
                if status.pending > 0 { return "\(waiting) · \(when)" }
                return "\(status.searchable.formatted()) \(status.searchable == 1 ? "file" : "files") ready to search · \(when)"
            }
            if status.pending > 0, let reason = status.waitingFor { return "\(waiting) · \(reason)" }
            if status.pending > 0 { return "\(waiting)" }
            if status.unfinished > 0 {
                let rest = "\(status.unfinished.formatted()) long \(status.unfinished == 1 ? "file" : "files") to finish"
                if status.paused { return "File indexing paused · \(rest)" }
                if let reason = status.waitingFor { return "\(rest) · \(reason)" }
            }
            return "\(status.searchable.formatted()) \(status.searchable == 1 ? "file" : "files") ready to search"
                + (status.paused ? " · file indexing paused" : "")
        }
    }

    /// While the model isn't there, how its download goes.
    private var downloadLine: String? {
        switch download.phase {
        case .ready: nil
        case .downloading: "Downloading EmbeddingGemma · \(Int(download.fraction * 100))%"
        case .verifying: "Checking the EmbeddingGemma download…"
        case .retrying: "Waiting for the network to download EmbeddingGemma"
        case .failed: "⚠︎ The EmbeddingGemma download stopped"
        case .needed: status.pending > 0 ? "EmbeddingGemma isn't downloaded yet" : nil
        }
    }

    /// File-search progress (EmbeddingGemma download, then file indexing); face-scan progress lives on PeopleCoordinator.
    var progress: Double? {
        guard hasFolders else { return nil }
        if download.isActive { return download.fraction }
        switch status.activity {
        case .indexing(let done, let total) where total > 0: return Double(done) / Double(total)
        case .finishing(let done, let total, _) where total > 0: return Double(done) / Double(total)
        default: return nil
        }
    }

    var codeProgress: Double? {
        guard hasCode else { return nil }
        if download.isActive { return download.fraction }
        guard let progress = status.code.indexing, progress.total > 0 else { return nil }
        return Double(progress.done) / Double(progress.total)
    }

    /// One line about the code index, for Settings → Code: "812 code files indexed", "Indexing code 42%…".
    var codeStatusLine: String {
        let code = status.code
        guard hasCode else { return "Code search is off" }
        if !download.isReady { return "Code is read once the model has downloaded" }
        if let indexing = code.indexing, indexing.total > 0 {
            let percent = Int((Double(indexing.done) / Double(indexing.total) * 100).rounded(.down))
            return "Indexing code \(percent)% · \(indexing.done.formatted()) of \(indexing.total.formatted())"
        }
        let waiting = code.pending > 0 ? " · \(code.pending.formatted()) waiting" : ""
        if code.pending > 0, status.paused { return "Paused · \(code.pending.formatted()) code files waiting" }
        if code.pending > 0, let reason = status.waitingFor { return "\(code.pending.formatted()) code files waiting · \(reason)" }
        if code.pending > 0, let until = status.heldUntil {
            return "\(code.pending.formatted()) code files waiting · indexing from "
                + until.formatted(date: .omitted, time: .shortened)
        }
        // Code is read once the other folders have nothing waiting (the helper's order).
        if code.pending > 0, status.pending > 0 {
            let files = "\(code.pending.formatted()) code \(code.pending == 1 ? "file" : "files")"
            return files + " waiting · read after your other files"
        }
        return "\(code.searchable.formatted()) code \(code.searchable == 1 ? "file" : "files") indexed" + waiting
    }

    /// A few words for the search bar while results may be incomplete: "Indexing 42%", "Downloading model · 42%".
    var activityBadge: String? {
        if download.isActive { return "EmbeddingGemma · \(Int(download.fraction * 100))%" }
        if case .indexing(let done, let total) = status.activity, total > 0 {
            return "Files \(Int(Double(done) / Double(total) * 100))%"
        }
        if status.paused, status.pending > 0 { return "File indexing paused" }
        return nil
    }

    /// Why meaning search can't run yet (words still match), or nil.
    var meaningUnavailable: String? {
        guard !download.isReady else { return nil }
        if download.isActive {
            return "Matching words only until EmbeddingGemma finishes downloading (\(Int(download.fraction * 100))%)"
        }
        return "Matching words only: EmbeddingGemma isn't downloaded"
    }

    /// Why results may be incomplete right now, or nil.
    var resultsCaveat: String? {
        if let meaningUnavailable { return meaningUnavailable }
        if case .indexing(let done, let total) = status.activity, total > 0 {
            return "Still preparing file search (\(Int(Double(done) / Double(total) * 100))%): some files aren't ready yet"
        }
        if status.pending > 0 {
            return "\(status.pending.formatted()) \(status.pending == 1 ? "file isn't" : "files aren't") ready to search yet"
        }
        return nil
    }
}
