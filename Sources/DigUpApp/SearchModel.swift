import AppKit
import DigUpKit
import Observation

/// The window's state is tested independently of helper processes and model inference.
@MainActor protocol WindowSearchServing: AnyObject {
    var hasCode: Bool { get }
    func personQuery(_ text: String) -> PersonQuery
    func prewarm()
    func embedAhead(_ text: String, code: Bool)
    func embedQuery(_ text: String, code: Bool) async -> Engine.QueryVector?
    func search(_ text: String, vector: Engine.QueryVector?, prefixLast: Bool, kinds: Set<FileKind>?,
                limit: Int, code: Bool, folder: String?) async -> [SearchHit]
    func libraryFiles(folder: String?, kinds: Set<FileKind>?, limit: Int) async -> [SearchHit]
    func open(_ row: ResultRow)
}

extension Engine: WindowSearchServing {}

enum SearchWindowContent: Equatable {
    case chooseFolders, home, loading, empty, codeResults, fileResults
    case codeInstructions(SearchPhase)
}

/// The window's query: keyword and meaning results together after a short pause in typing, optionally of one kind.
@Observable
final class SearchModel {
    var destination = WorkspaceDestination.library {
        willSet {
            if newValue != destination { animatesNavigation = !MorrowMotion.keyboardInitiated }
        }
    }
    private(set) var animatesNavigation = true
    private(set) var browsing = false
    private(set) var folder: String?
    var personContext: PersonQuery { engine.personQuery(query) }

    /// Text edits are global when made from another destination; folder searches keep their scope.
    func editQuery(_ text: String) {
        updateContext {
            if destination != .library { folder = nil; browsing = false; filter = nil }
            destination = .library
            query = text
        }
    }

    func clearQuery() { editQuery("") }

    func navigate(to destination: WorkspaceDestination) {
        if destination == .library { home() }
        else { self.destination = destination }
    }

    func activateSearch() {
        if destination != .library {
            updateContext {
                folder = nil; browsing = false; filter = nil; destination = .library
            }
        }
        focusField()
    }

    /// Multiple related changes produce one request, never intermediate searches with mixed scope.
    private func updateContext(_ change: () -> Void) {
        updatingContext = true
        change()
        updatingContext = false
        run()
    }

    func search(for text: String, kind: ResultGroupKind? = nil) {
        updateContext {
            folder = nil; browsing = false; destination = .library
            filter = kind; query = text
        }
    }

    func browse(folder: String? = nil, selecting row: ResultRow? = nil) {
        updateContext {
            self.folder = folder
            browsing = true
            destination = .library
            filter = nil
            query = ""
        }
        if let row { select(row) }
    }

    func home() {
        updateContext {
            browsing = false
            folder = nil
            filter = nil
            query = ""
            destination = .library
        }
    }
    var query = "" {
        didSet { if query != oldValue, !updatingContext { run() } }
    }
    var filter: ResultGroupKind? {
        didSet { if filter != oldValue, !updatingContext { run() } }
    }
    private(set) var results = ResultSet.empty
    /// Results per kind for the query, whatever the filter (the counts on the kind buttons).
    private(set) var counts: [ResultGroupKind: Int] = [:]
    private(set) var hasResults = false
    /// What the window shows instead of results: "code:" alone (what to type), or code search that's off.
    private(set) var codePhase: SearchPhase?
    var selection: String?
    var showWeaker = false
    var showsPreview = true
    /// You moved the selection with the arrow keys since the last edit: Space and ← → act on results then.
    private(set) var navigated = false
    /// The grid's columns right now (↑ ↓ move by a row).
    var columns = 4
    @ObservationIgnored weak var field: NSTextField?
    @ObservationIgnored private let engine: any WindowSearchServing
    @ObservationIgnored private let typingPause: Duration
    @ObservationIgnored private var updatingContext = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init(engine: any WindowSearchServing, typingPause: Duration = .milliseconds(120)) {
        self.engine = engine
        self.typingPause = typingPause
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var showsHome: Bool { !hasQuery && !browsing && !isCode }

    func contentState(hasFolders: Bool) -> SearchWindowContent {
        if let codePhase { return .codeInstructions(codePhase) }
        if !hasFolders && !isCode { return .chooseFolders }
        if showsHome { return .home }
        if !hasResults { return .loading }
        if results.isEmpty { return .empty }
        return isCode ? .codeResults : .fileResults
    }

    var canPreviewResults: Bool { destination == .library && selectedRow != nil }
    /// Keep the inspector host stable while a query refreshes. Binding its presentation to
    /// selectedRow makes SwiftUI write a dismissal back after the new results have arrived.
    var hostsPreviewInspector: Bool { destination == .library && !showsHome && codePhase == nil }
    var canTogglePreview: Bool { hostsPreviewInspector && (showsPreview || canPreviewResults) }

    /// Every result shown, in order (strong ones, then the weaker ones once they're unfolded).
    var rows: [ResultRow] { results.ranked + (showWeaker ? results.weaker : []) }

    /// A search of code: the Code filter, or "code:" typed.
    var isCode: Bool { filter == .code || CodeQuery.text(of: query) != nil }
    var selectedRow: ResultRow? { hasResults ? (rows.first { $0.id == selection } ?? rows.first) : nil }

    /// A click on a result: like the arrow keys, it makes Space and ← → act on the results.
    func select(_ row: ResultRow) {
        selection = row.id
        navigated = true
    }

    /// A click in the search field: keys are the text's again.
    func editing() {
        navigated = false
    }

    /// Puts the cursor in the search field (a click on the empty window lands there).
    func focusField() {
        editing()
        guard let field, field.currentEditor() == nil else { return }
        field.window?.makeFirstResponder(field)
    }

    /// The file in its app, at the page or moment that matched when the app can be told where.
    func open(_ row: ResultRow) {
        engine.open(row)
    }

    func move(by step: Int) {
        guard hasResults else { return }
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, index + step))]
        navigated = true
    }

    private func run() {
        generation += 1
        let current = generation
        task?.cancel()
        navigated = false
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = isCode
        let text = CodeQuery.text(of: typed) ?? typed
        codePhase = nil
        counts = [:]
        hasResults = false
        if code, !engine.hasCode || text.isEmpty {
            results = .empty
            counts = [:]
            selection = nil
            codePhase = engine.hasCode ? .codeHint : .codeOff
            return
        }
        if typed.isEmpty, browsing {
            hasResults = false
            let scope = folder
            let kinds = filter?.kinds
            task = Task {
                let hits = await engine.libraryFiles(folder: scope, kinds: kinds, limit: 120)
                guard !Task.isCancelled, current == generation else { return }
                var set = ResultSet.empty
                set.ranked = hits.map { hit in var row = ResultRow(hit); row.isBrowsing = true; return row }
                set.groups = ResultGroupKind.allCases.compactMap { kind in
                    let rows = set.ranked.filter { ResultGroupKind($0.kind) == kind }
                    return rows.isEmpty ? nil : ResultGroup(kind: kind, rows: rows, total: rows.count)
                }
                results = set
                counts = [:]
                showWeaker = false
                if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
                hasResults = true
            }
            return
        }
        guard !typed.isEmpty else {
            results = .empty
            counts = [:]
            selection = nil
            showWeaker = false
            return
        }
        engine.prewarm()
        engine.embedAhead(text, code: code)
        let filter = self.filter
        let folder = self.folder
        let showAt = ContinuousClock.now + typingPause
        if code {
            task = Task {
                let vector = await engine.embedQuery(text, code: true)
                guard !Task.isCancelled, current == generation else { return }
                let hits = await engine.search(text, vector: vector, prefixLast: false, kinds: nil, limit: 120, code: true, folder: nil)
                try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
                guard !Task.isCancelled, current == generation else { return }
                counts = [.code: Searcher.strongCount(hits)]
                results = ResultSet(hits, query: text)
                showWeaker = false
                if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
                hasResults = true
                log("window: code \"\(text)\": \(results.ranked.count) results + \(results.weaker.count) weaker")
            }
            return
        }
        task = Task {
            let vector = await engine.embedQuery(text, code: false)
            guard !Task.isCancelled, current == generation else { return }
            let all = await engine.search(text, vector: vector, prefixLast: false, kinds: nil, limit: 120, code: false, folder: folder)
            let shown = filter == nil ? all : await engine.search(text, vector: vector, prefixLast: false,
                                                                    kinds: filter!.kinds, limit: 120, code: false, folder: folder)
            try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
            guard !Task.isCancelled, current == generation else { return }
            var counts: [ResultGroupKind: Int] = [:]
            for hit in all.prefix(Searcher.strongCount(all)) { counts[ResultGroupKind(hit.kind), default: 0] += 1 }
            self.counts = counts
            results = ResultSet(shown, query: text)
            showWeaker = false
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
            hasResults = true
            log("window: \"\(text)\"\(filter.map { " in \($0.title)" } ?? ""): \(results.ranked.count) results "
                + "+ \(results.weaker.count) weaker")
        }
    }
}
