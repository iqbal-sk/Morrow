import AppKit
import DigUpKit
import Observation
import Quartz
import SwiftUI

/// The search window, for the searches the panel is too small for: a big field, kind filters with counts, the results
/// as a grid of pictures, and the selected one in a preview pane with why it matched. The Dock icon shows while it's
/// open, and closing it frees its views (the app goes back to its idle size).
final class SearchWindowController: NSObject, NSWindowDelegate {
    let search: SearchModel
    private unowned let app: AppController
    private var window: QuickLookWindow?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    init(app: AppController) {
        self.app = app
        search = SearchModel(engine: app.engine)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(query: String? = nil, kind: ResultGroupKind? = nil, destination: WorkspaceDestination? = nil) {
        // Menu commands and routes from Settings must respect the same modal boundary as keys.
        // Do not replace the view underneath a person/reference editor or confirmation sheet.
        if let window = self.window, window.attachedSheet != nil {
            app.present(window)
            return
        }
        let window = self.window ?? makeWindow()
        if let query {
            search.search(for: query, kind: kind)
        } else if let destination {
            search.navigate(to: destination)
        }
        app.present(window)
        if !AppController.offscreen, search.destination == .library {
            DispatchQueue.main.async { self.search.focusField() }
        }
        installKeyMonitor()
    }

    func find() {
        guard window?.attachedSheet == nil else {
            if let window { app.present(window) }
            return
        }
        search.activateSearch()
        show()
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> QuickLookWindow {
        let window = QuickLookWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        // SwiftUI owns the native toolbar actions; search stays in the persistent workspace header.
        window.toolbar = NSToolbar(identifier: "MorrowSearch")
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Morrow"
        window.minSize = NSSize(width: 1000, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The frame is remembered in the app's real defaults, so dev runs (their own -defaultsSuite) don't keep it.
        if UserDefaults.standard.string(forKey: "defaultsSuite") == nil {
            window.setFrameAutosaveName("MorrowSearchWindow")
        }
        window.contentView = NSHostingView(rootView: MorrowWorkspace(search: search, app: app))
        if window.frame.origin == .zero { window.center() }
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if ownsVisibleQuickLook { QLPreviewPanel.shared().orderOut(nil) }
        removeKeyMonitor()
        PreviewPlayback.shared.stop()
        window?.contentView = nil
        window = nil
        app.windowClosed()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window else { return event }
            // Keys typed here, or in Quick Look while this window is the one showing it (not the panel's).
            let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
                && event.window === QLPreviewPanel.shared() && QLPreviewPanel.shared().dataSource === window
            guard event.window === window || previewing else { return event }
            return handle(event) ? nil : event
        }
        // A click back in the search field: Space and ← → type again (after a click on a result, they were its).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window, event.window === window, let field = search.field else { return event }
            if field.bounds.contains(field.convert(event.locationInWindow, from: nil)) { search.editing() }
            return event
        }
    }

    private func removeKeyMonitor() {
        for monitor in [keyMonitor, mouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        mouseMonitor = nil
    }

    /// Arrows move through the grid (← → only once you've arrowed, so they still move the cursor while you type),
    /// ↩ opens, ⌘↩ reveals, Space previews, ⌘C copies, Esc closes the preview or clears the search.
    private func handle(_ event: NSEvent) -> Bool {
        guard window?.attachedSheet == nil else { return false }
        // An input method is composing (Japanese, Chinese…): ↩, the arrows and Esc are its keys until it's done.
        if (search.field?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 3, modifiers == .command { // ⌘F always returns to the library query.
            find()
            return true
        }
        if modifiers == [.command, .shift], let index = [18, 19, 20].firstIndex(of: Int(event.keyCode)) {
            search.navigate(to: WorkspaceDestination.allCases[index])
            return true
        }
        guard search.destination == .library, window?.attachedSheet == nil else { return false }
        // A native source list owns its arrows; result navigation must not steal them.
        if window?.firstResponder is NSTableView { return false }
        let previewing = ownsVisibleQuickLook
        switch event.keyCode {
        case 125, 126:   // ↓ ↑
            guard modifiers.isEmpty else { return false }
            search.move(by: event.keyCode == 125 ? search.columns : -search.columns)
        case 123, 124:   // ← →
            guard modifiers.isEmpty, search.navigated || previewing else { return false }
            search.move(by: event.keyCode == 124 ? 1 : -1)
        case 36, 76:   // ↩
            guard let row = search.selectedRow else { return false }
            if modifiers == .command {
                NSWorkspace.shared.activateFileViewerSelecting([row.url])
            } else if modifiers.isEmpty {
                search.open(row)
            } else {
                return false
            }
        case 49 where modifiers.isEmpty && (search.navigated || previewing) && search.selectedRow != nil:   // Space
            toggleQuickLook()
        case 16 where modifiers == .command:   // ⌘Y
            toggleQuickLook()
        case 18...23 where modifiers == .command:   // ⌘1 all, ⌘2…⌘6 one kind
            let kinds: [ResultGroupKind?] = [nil] + ResultGroupKind.files
            let index = [18, 19, 20, 21, 23, 22].firstIndex(of: Int(event.keyCode)) ?? 0   // key codes of 1…6
            search.filter = kinds[index]
        case 26 where modifiers == .command && app.model.hasCode:   // ⌘7: code
            search.filter = .code
        case 8 where modifiers == .command && search.navigated:   // ⌘C
            guard let row = search.selectedRow else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([row.url as NSURL])
        case 53:   // Esc
            if previewing {
                QLPreviewPanel.shared().orderOut(nil)
            } else if !search.query.isEmpty {
                search.clearQuery()
            } else {
                return false
            }
        default:
            return false
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { updateQuickLook() }
        return true
    }

    private var ownsVisibleQuickLook: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
            && QLPreviewPanel.shared().dataSource === window
    }

    func toggleQuickLook() {
        let panel = QLPreviewPanel.shared()!
        if ownsVisibleQuickLook {
            panel.orderOut(nil)
        } else if search.selectedRow != nil {
            updateQuickLook()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Quick Look shows the selected result at its page or moment.
    private func updateQuickLook() {
        window?.previewURL = search.selectedRow?.url
        QLPreviewPanel.shared().reloadData()
        QuickLookMoment.show(search.selectedRow, in: QLPreviewPanel.shared())
    }
}

/// A window that hands Quick Look the selected file (Space / ⌘Y).
final class QuickLookWindow: NSWindow, QLPreviewPanelDataSource {
    var previewURL: URL?

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}

// MARK: Views

struct SearchWindowView: View {
    @Bindable var search: SearchModel
    let model: AppModel
    let app: AppController

    var body: some View {
        if search.hostsPreviewInspector, model.hasFolders || search.isCode {
            resultBody.inspector(isPresented: $search.showsPreview) {
                inspectorContent
                    .inspectorColumnWidth(min: 280, ideal: 324, max: 420)
            }
        } else {
            resultBody
        }
    }

    private var resultBody: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Window minimums belong to the window, not its nested result/inspector panes.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspectorContent: some View {
        Group {
            if let row = search.selectedRow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        PreviewPane(row: row, imageSize: CGSize(width: 292, height: 230),
                                    matchedPeople: search.personContext.people.map(\.name),
                                    personOnly: !search.personContext.people.isEmpty && search.personContext.remainder.isEmpty,
                                    open: { search.open(row) })
                        PreviewActions(row: row, open: { search.open(row) },
                                       reveal: { NSWorkspace.shared.activateFileViewerSelecting([row.url]) })
                    }.padding(16)
                }
            } else if !search.hasResults {
                ProgressView("Updating preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc.text.magnifyingglass",
                                       description: Text("A preview appears when your search finds a file."))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if search.browsing || search.hasQuery || search.isCode {
                if search.browsing && !search.isCode {
                    HStack {
                        Button { search.home() } label: { Label("Library", systemImage: "chevron.left") }.buttonStyle(.borderless)
                        Text(search.folder.map { ($0 as NSString).lastPathComponent } ?? "Recent files").font(.headline)
                        Spacer()
                        Text(search.hasQuery ? "Searching this folder" : "Most recently modified · up to 120 files")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                KindFilters(search: search, showsCode: model.hasCode)
            }
            if !search.isCode { PersonSearchContext(context: search.personContext) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        switch search.contentState(hasFolders: model.hasFolders) {
        case .chooseFolders:
            VStack(spacing: 0) {
                BrandMark()
                Text("Choose folders to search").font(.system(size: 20, weight: .bold)).padding(.top, 18)
                Text("Morrow only looks where you tell it to.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Button("Choose Folders…") { app.chooseFolders() }
                    .controlSize(.large)
                    .morrowAction(.primary)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 18)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .home:
            LibraryHome(search: search, app: app)
        case .codeInstructions(let phase):
            CodeOffOrHint(phase: phase, search: search) { app.chooseCodeFolders() }
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            EmptyState(symbol: search.isCode ? FileKind.code.symbol : "magnifyingglass",
                       title: search.browsing && search.query.isEmpty ? "No searchable files here yet" : "No good matches for “\(search.query.trimmingCharacters(in: .whitespaces))”",
                       message: search.isCode ? "Try saying what the code does, or a name that's in it."
                           : "Try describing what's in it: what you'd see or hear, or words you remember.")
        case .codeResults:
            CodeResultsList(search: search)
        case .fileResults:
            ResultsGrid(search: search)
        }
    }
}

/// All · Screenshots 4 · Images 9 · …: what the query found of each kind; click to see only that kind. With code search
/// on, Code after them: a search of code alone (as "code:" is).
private struct KindFilters: View {
    @Bindable var search: SearchModel
    var showsCode = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            MorrowGlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    filterButton(nil)
                    ForEach(ResultGroupKind.files, id: \.self) { kind in
                        filterButton(kind)
                    }
                    if showsCode || search.isCode {
                        filterButton(.code)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(height: 32)
        .accessibilityLabel("Filter results by file type")
    }

    private func filterButton(_ kind: ResultGroupKind?) -> some View {
        let title = kind?.title ?? "All"
        let symbol = kind?.symbol ?? "square.grid.2x2"
        let selected = kind.map { search.filter == $0 } ?? (search.filter == nil && !search.isCode)
        let count = kind.flatMap { kind in
            search.query.isEmpty || (search.isCode && kind != .code) ? nil : search.counts[kind]
        }
        let shortcut = kind.map { $0 == .code ? 7 : (ResultGroupKind.files.firstIndex(of: $0) ?? 0) + 2 } ?? 1

        return Button {
            if let kind, search.filter != kind {
                search.filter = kind
            } else {
                search.filter = nil
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .monospacedDigit()
                        .opacity(0.62)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
        }
        .morrowSelection(selected)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .help("\(title) (⌘\(shortcut))")
        .accessibilityLabel(count.map { "\(title), \($0) results" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ResultsGrid: View {
    @Bindable var search: SearchModel
    private static let cell = CGSize(width: 176, height: 132)

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell.width, maximum: 230), spacing: 14)],
                              alignment: .leading, spacing: 18) {
                        ForEach(search.results.ranked) { row in cell(row) }
                    }
                    .padding(16)
                    if !search.results.weaker.isEmpty {
                        WeakerToggle(count: search.results.weaker.count, expanded: search.showWeaker) {
                            search.showWeaker.toggle()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        if search.showWeaker {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell.width, maximum: 230),
                                                         spacing: 14)], alignment: .leading, spacing: 18) {
                                ForEach(search.results.weaker) { row in cell(row).opacity(0.85) }
                            }
                            .padding(16)
                        }
                    }
                }
                .onChange(of: search.selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .onAppear { updateColumns(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
        }
    }

    private func updateColumns(_ width: CGFloat) {
        search.columns = max(1, Int((width - 32 + 14) / (Self.cell.width + 14)))
    }

    private func cell(_ row: ResultRow) -> some View {
        GridCell(row: row, selected: row.id == search.selectedRow?.id)
            .id(row.id)
            .overlay(FileDragArea(url: row.url, openTitle: row.openTitle, onClick: { search.select(row) },
                                  onOpen: { search.open(row) }))
    }
}

private struct GridCell: View {
    let row: ResultRow
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A fixed box the picture fills and is clipped to: a picture's own shape must never size the cell.
            Color.primary.opacity(0.05)
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .overlay {
                    if row.kind == .audio {
                        Image(systemName: "waveform")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Brand.gradient)
                    } else {
                        MomentThumbnail(row: row)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if row.kind != .image && row.kind != .screenshot {
                    Image(systemName: row.kind.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(.black.opacity(0.5)))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let place = row.place { PlaceBadge(text: place, onImage: true).padding(6) }
            }
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 0.5)
                .padding(selected ? -3 : 0))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.folder)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.kind.title), \(row.name), \(row.reason)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Code results, one under another: the file, where in its repo, the lines that matched, and why.
private struct CodeResultsList: View {
    @Bindable var search: SearchModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(search.results.ranked) { row in item(row) }
                    if !search.results.weaker.isEmpty {
                        WeakerToggle(count: search.results.weaker.count, expanded: search.showWeaker) {
                            search.showWeaker.toggle()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        if search.showWeaker {
                            ForEach(search.results.weaker) { row in item(row).opacity(0.85) }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: search.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onAppear { search.columns = 1 }
        }
    }

    private func item(_ row: ResultRow) -> some View {
        CodeResultRow(row: row, selected: row.id == search.selectedRow?.id)
            .id(row.id)
            .overlay(FileDragArea(url: row.url, openTitle: row.openTitle, onClick: { search.select(row) },
                                  onOpen: { search.open(row) }))
    }
}

private struct CodeResultRow: View {
    let row: ResultRow
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ThumbnailView(url: row.url, side: 30, iconOnly: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let place = row.place { PlaceBadge(text: place) }
                    Text(row.folder)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let excerpt = row.excerpt {
                    Text(highlighted(excerpt, size: 11))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code, \(row.name), \(row.reason)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "code:" typed without code search on (how to turn it on), or with nothing after it (what to type).
private struct CodeOffOrHint: View {
    let phase: SearchPhase
    let search: SearchModel
    let chooseFolders: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: FileKind.code.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Brand.gradient)
            if phase == .codeOff {
                Text("Code search is off").font(.system(size: 17, weight: .semibold))
                Text("Morrow can find code by what it does, in the folders you pick. Code gets an index of its own and "
                     + "never shows up in other searches.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Choose Code Folders…", action: chooseFolders).padding(.top, 6)
            } else {
                Text("Search your code").font(.system(size: 17, weight: .semibold))
                Text("Say what the code does, or type a name that's in it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A grid cell's picture: the video frame or PDF page that matched (from the preview cache), else Quick Look's.
struct MomentThumbnail: View {
    let row: ResultRow
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                // A page shows its top (its title), anything else its middle.
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: row.page == nil ? .center : .top)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: row.url.path))
                    .resizable()
                    .frame(width: 56, height: 56)
            }
        }
        .task(id: row.previewKey) {
            let side: CGFloat = 230
            image = Previews.shared.cached(row, side: side)
            if image == nil {
                let loaded = await Previews.shared.load(row, side: side, scale: scale)
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
    }
}

struct WeakerToggle: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(expanded ? "Weaker matches" : "\(count) weaker \(count == 1 ? "match" : "matches")")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// After a search: a big quiet symbol, what happened, what to try.
private struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Nothing typed yet: the app's mark (not a magnifier, which reads as a second search field), a pointer to the field
/// above, examples to click (each with the kind it finds), what's in the index, and the shortcut. A click anywhere else
/// puts the cursor in the field.

private struct BrandMark: View {
    var body: some View {
        MorrowAppIcon(size: 84)
            .shadow(color: Brand.accent.opacity(0.3), radius: 14, y: 6)
            .background {
                Circle()
                    .fill(RadialGradient(colors: [Brand.accent.opacity(0.22), Brand.coral.opacity(0.08), .clear],
                                         center: .center, startRadius: 0, endRadius: 150))
                    .frame(width: 300, height: 300)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

/// Lays children out in rows, wrapping like text.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.items + [index], needed, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
