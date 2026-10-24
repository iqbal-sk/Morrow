import AppKit
import DigUpKit
import Observation
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, folders, people, code, storage

    var title: String {
        switch self {
        case .general: "General"
        case .folders: "Folders"
        case .people: "People"
        case .code: "Code"
        case .storage: "Storage"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .folders: "folder"
        case .people: "person.crop.rectangle.stack"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .storage: "internaldrive"
        }
    }

    var detail: String {
        switch self {
        case .general: "Keyboard and launch behavior."
        case .folders: "Choose folders, follow indexing, and rebuild selected data."
        case .people: "On-device face scanning and matching preferences."
        case .code: "Search inside selected repositories."
        case .storage: "Local models, indexes, and privacy."
        }
    }
}

/// A resizable native Settings window. Enrollment and review belong to the main People workspace.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let state: SettingsState
    /// Folders → Add Folders…, a sheet on this window.
    let addSheet: AddFoldersController
    /// Code → Add Folders… (code search's folders), a sheet on this window.
    let codeSheet: AddFoldersController
    private unowned let app: AppController
    private var window: NSWindow?

    init(app: AppController) {
        self.app = app
        state = SettingsState(app: app)
        addSheet = AddFoldersController(app: app)
        codeSheet = AddFoldersController(app: app, code: true)
        super.init()
        state.addFolders = { [weak self] in self?.addFolders() }
        state.addCodeFolders = { [weak self] in self?.addCodeFolders() }
        for sheet in [addSheet, codeSheet] {
            sheet.onAdded = { [weak self] in
                guard let self else { return }
                Task { await self.state.refresh() }
            }
        }
    }

    /// Opens Add Folders on the Folders tab.
    func addFolders() {
        addSheet.begin(on: window)
    }

    /// Opens the code folders' sheet on the Code tab.
    func addCodeFolders() {
        codeSheet.begin(on: window)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(_ tab: SettingsTab? = nil) {
        let window = self.window ?? makeWindow()
        if let tab { state.tab = tab }
        Task { await state.refresh() }
        app.present(window)
    }

    var selectedTab: SettingsTab { state.tab }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Morrow Settings"
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 760, height: 540)
        window.contentView = NSHostingView(rootView: SettingsRoot(state: state))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        state.selectTab = { [weak self] tab in self?.state.tab = tab }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        addSheet.end()
        codeSheet.end()
        window?.contentView = nil
        window = nil
        app.windowClosed()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }
}

@Observable
final class SettingsState {
    var tab = SettingsTab.general {
        willSet {
            if newValue != tab { animatesNavigation = !MorrowMotion.keyboardInitiated }
        }
    }
    private(set) var animatesNavigation = true
    private(set) var summaries: [Engine.RootSummary]?
    private(set) var codeSummaries: [Engine.RootSummary] = []
    private(set) var indexSize: Int64 = 0
    private(set) var codeIndexSize: Int64 = 0
    var launchAtLogin = false
    var loginProblem: String?
    @ObservationIgnored let app: AppController
    @ObservationIgnored var selectTab: (SettingsTab) -> Void = { _ in }
    @ObservationIgnored var addFolders: () -> Void = {}
    @ObservationIgnored var addCodeFolders: () -> Void = {}

    init(app: AppController) {
        self.app = app
    }

    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var refreshPending = false

    var model: AppModel { app.model }

    func refresh() async {
        lastRefresh = Date()
        launchAtLogin = app.launchesAtLogin
        indexSize = app.engine.indexSize
        codeIndexSize = app.engine.codeIndexSize
        codeSummaries = await app.engine.rootSummaries(code: true)
        summaries = await app.engine.rootSummaries()
    }

    /// The index changed: refresh the folder counts, at most every 2 s while files are being indexed.
    func statusChanged() {
        guard !refreshPending else { return }
        refreshPending = true
        let wait = max(0, 2 - Date().timeIntervalSince(lastRefresh))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            refreshPending = false
            await refresh()
        }
    }

    /// Ready to be drawn (debug snapshots wait for this).
    var isLoaded: Bool { summaries != nil }
}

private struct SettingsRoot: View {
    @Bindable var state: SettingsState
    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsTab?>(get: { state.tab }, set: { tab in
                if let tab { state.tab = tab }
            })) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }.listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            MorrowPageDeck(selection: state.tab, animated: state.animatesNavigation) {
                settingsPage
            }
        }.morrowTheme()
            .onChange(of: state.model.status) { state.statusChanged() }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.tab.title).font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(state.tab.detail).font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 8)
            // Each native Form owns its scrolling. Disabling a Form inside another ScrollView
            // makes its lower sections unreachable when the settings window is short.
            switch state.tab {
            case .general: GeneralSettings(state: state)
            case .folders: FolderSettings(state: state)
            case .people:
                ScrollView {
                    PeoplePreferences(people: state.app.people) {
                        state.app.searchWindow.show(destination: .people)
                    }
                }.scrollBounceBehavior(.basedOnSize)
            case .code: CodeSettings(state: state)
            case .storage: StorageSettings(state: state)
            }
        }.frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct PeoplePreferences: View {
    @Bindable var people: PeopleCoordinator
    let openPeople: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let problem = people.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Enable People search", isOn: $people.enabled).toggleStyle(.switch)
                    Text("Match faces to the people you add. Photos, references and identity matches stay on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open People…", action: openPeople)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Face detection") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Minimum face size")
                        Spacer()
                        Text(people.minimumFacePixels == 0 ? "All sizes" : "\(people.minimumFacePixels) px").monospacedDigit()
                    }
                    Slider(value: Binding(get: { Double(people.minimumFacePixels) }, set: { people.setMinimumFacePixels(Int($0)) }), in: 0...128, step: 8)
                        .accessibilityLabel("Minimum face size in pixels")
                    Text(people.isUpdatingFacePolicy ? "Applying the filter and rechecking your photos…" : "Smaller faces are skipped. Changing this rechecks photos in your chosen folders; zero keeps every face.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            Label("File preparation and face scanning have separate progress in Activity.", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(24)
    }
}

private struct GeneralSettings: View {
    @Bindable var state: SettingsState

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ShortcutRecorder(combo: state.model.hotkey, apply: { state.app.setHotkey($0) },
                                     listening: { state.app.hotkeyRecording($0) }, capSize: 13)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Search shortcut")
                        Text("Opens the search panel from any app.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { state.launchAtLogin }, set: { on in
                    state.loginProblem = state.app.setLaunchAtLogin(on)
                    state.launchAtLogin = state.app.launchesAtLogin
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Morrow when you log in")
                        Text(state.loginProblem ?? "So the shortcut always works.")
                            .font(.system(size: 11))
                            .foregroundStyle(state.loginProblem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FolderSettings: View {
    @Bindable var state: SettingsState
    @State private var removing: Engine.RootSummary?
    @State private var folderAlert: FolderAlert?

    private enum FolderAlert {
        case reset(URL)
        case outsideIndexedFolders(URL)
    }

    var body: some View {
        Form {
            Section {
                IndexProgress(model: state.model) { state.app.engine.setPaused(!state.model.status.paused) }
                HStack(spacing: 12) {
                    IndexingTrackerRow(title: "People search", detail: state.app.people.scanStatusLine,
                                       symbol: "person.crop.rectangle.stack", progress: state.app.people.scanProgressFraction)
                    Button("View Activity") {
                        state.app.searchWindow.show(destination: .activity)
                    }
                }
            }
            Section {
                if let summaries = state.summaries {
                    if summaries.isEmpty {
                        Text("No folders yet. Add the ones Morrow should search.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(summaries) { summary in
                        FolderStatusRow(summary: summary,
                                        reset: { state.app.engine.resetIndex(under: URL(fileURLWithPath: summary.path)) },
                                        remove: { removing = summary })
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            } header: {
                Text("Folders to search")
            } footer: {
                HStack {
                    Button(action: state.addFolders) {
                        Label("Add Folders…", systemImage: "plus")
                    }
                    Spacer()
                    Button {
                        state.app.pickFolderToReset(for: NSApp.keyWindow) { folder in
                            guard let folder else { return }
                            let selection = FolderSelection(chosen: state.model.settings.roots.map(\.path),
                                                            skipped: state.model.settings.excludedFolders.map(\.path))
                            let codeSelection = FolderSelection(chosen: state.model.settings.codeRoots.map(\.path),
                                                                skipped: state.model.settings.codeExcluded.map(\.path))
                            folderAlert = (selection.isSearched(folder.path) || codeSelection.isSearched(folder.path))
                                ? .reset(folder) : .outsideIndexedFolders(folder)
                        }
                    } label: {
                        Label("Reset Directory…", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(state.model.settings.roots.isEmpty && state.model.settings.codeRoots.isEmpty)
                }
            }
            Section {
                ForEach(state.model.settings.excludedFolders, id: \.path) { folder in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(tildePath(folder.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            state.app.setExcluded(state.model.settings.excludedFolders.filter { $0 != folder })
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Search this folder again")
                    }
                }
                if state.model.settings.excludedFolders.isEmpty {
                    Text("None. Code projects, app bundles and caches are skipped anyway (code has its own tab).")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Skip these folders")
            } footer: {
                HStack {
                    Button {
                        state.app.pickFolders(for: NSApp.keyWindow, prompt: "Skip") { folders in
                            guard !folders.isEmpty else { return }
                            state.app.setExcluded(state.model.settings.excludedFolders
                                + folders.filter { !state.model.settings.excludedFolders.contains($0) })
                        }
                    } label: {
                        Label("Skip a Folder…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                TypeExclusions(types: state.model.settings.excludedTypes) { state.app.setExcludedTypes($0) }
            } header: {
                Text("Skip these file types")
            } footer: {
                Text("Morrow only reads pictures, PDFs, documents (txt, md, typ, rtf, docx, odt, html), audio and video here; "
                     + "code is read only in the code folders (the Code tab). Keys, certificates and password files are "
                     + "never read, nor are hidden folders like ~/.ssh.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: Binding(get: { state.model.settings.indexOnBattery },
                                     set: { state.app.setIndexOnBattery($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppSettings.batteryTitle)
                        Text(AppSettings.batteryDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { state.model.settings.indexHoursOn }, set: { on in
                    state.app.setIndexHours(on: on, hours: state.model.settings.indexHours)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Index only at set hours")
                        Text("Files are read only between these times, and what changed meanwhile is picked up when "
                             + "they begin. Search works all day.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if state.model.settings.indexHoursOn {
                    LabeledContent("From") {
                        HStack(spacing: 6) {
                            DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Text("to")
                            DatePicker("To", selection: time(\.end), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil },
                                                               set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let removing else { return }
                state.app.removeFolder(URL(fileURLWithPath: removing.path))
                Task { await state.refresh() }
            }
        } message: {
            Text("Its \(removing?.files.formatted() ?? "") files leave the index. Adding it back later indexes them "
                 + "again.")
        }
        .alert(folderAlertTitle, isPresented: Binding(get: { folderAlert != nil },
                                                       set: { if !$0 { folderAlert = nil } })) {
            if case .reset(let folder) = folderAlert {
                Button("Reset Directory Index", role: .destructive) {
                    state.app.engine.resetIndex(under: folder)
                    folderAlert = nil
                }
            }
            Button("Cancel", role: .cancel) { folderAlert = nil }
        } message: {
            switch folderAlert {
            case .reset(let folder):
                Text("Morrow will remove indexed data for “\(folder.lastPathComponent)” and its contents, then index that folder again. People names and reference photos are kept.")
            case .outsideIndexedFolders(let folder):
                Text("“\(folder.path)” is not inside a folder Morrow currently searches, so it has no index data to reset here.")
            case nil:
                Text("")
            }
        }
    }

    private var folderAlertTitle: String {
        switch folderAlert {
        case .reset(let folder): "Reset the index for “\(folder.lastPathComponent)”?"
        case .outsideIndexedFolders: "Folder isn’t indexed"
        case nil: ""
        }
    }

    private var removalTitle: String {
        "Stop searching “\(removing.map { ($0.path as NSString).lastPathComponent } ?? "")”?"
    }

    /// One end of the set hours, as a time of day for a date picker.
    private func time(_ end: KeyPath<IndexHours, Int>) -> Binding<Date> {
        Binding(get: {
            let minute = state.model.settings.indexHours[keyPath: end]
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let hours = state.model.settings.indexHours
            state.app.setIndexHours(on: true, hours: end == \IndexHours.start ? IndexHours(start: minute, end: hours.end)
                                                                              : IndexHours(start: hours.start, end: minute))
        })
    }
}

/// Extensions typed as "heic, txt": applied on Return or when the field loses focus.
private struct TypeExclusions: View {
    let types: [String]
    let apply: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Extensions", text: $text, prompt: Text("e.g. heic, txt"))
            .labelsHidden()
            .focused($focused)
            .onSubmit { apply(text) }
            .onChange(of: focused) { _, now in if !now { apply(text) } }
            .onAppear { text = types.joined(separator: ", ") }
            .onChange(of: types) { _, now in text = now.joined(separator: ", ") }
    }
}

/// What the index is doing, with Pause/Resume.
private struct IndexProgress: View {
    let model: AppModel
    let togglePause: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("File search").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(model.statusLine).font(.system(size: 13, weight: .semibold))
                if let progress = model.progress {
                    ProgressView(value: progress).controlSize(.small)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasFolders {
                Button(model.status.paused ? "Resume" : "Pause", action: togglePause)
            }
        }
    }

    /// "357 of 365 files searchable · 8 waiting · 2 long files to finish"
    private var detail: String {
        let status = model.status
        var text = "\(status.searchable.formatted()) of \(status.files.formatted()) files searchable"
        if status.pending > 0 { text += " · \(status.pending.formatted()) waiting" }
        if status.unfinished > 0 {
            text += " · \(status.unfinished.formatted()) long \(status.unfinished == 1 ? "file" : "files") to finish"
        }
        if model.download.isActive { text += " · model \(model.download.progressText)" }
        return text
    }
}

private struct FolderStatusRow: View {
    let summary: Engine.RootSummary
    let reset: () -> Void
    let remove: () -> Void
    @State private var showingReasons = false
    @State private var confirmingReset = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: summary.missing ? "/Volumes" : summary.path))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(summary.missing ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((summary.path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                    if summary.missing || summary.unreadable {
                        Text(summary.missing ? "Not connected" : "No access")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    if summary.unreadable {
                        Button("Allow in Settings…", action: openFolderPrivacySettings)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                Text(tildePath(summary.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !summary.kinds.isEmpty {
                    KindCounts(counts: summary.kinds).padding(.top, 1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(summary.missing || summary.unreadable ? "Kept for when it's back"
                     : "\(summary.indexed.formatted()) of \(summary.files.formatted()) searchable")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                if !states.isEmpty {
                    if reasons.isEmpty {
                        Text(states).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Button { showingReasons.toggle() } label: {
                            HStack(spacing: 3) {
                                Text(states)
                                Image(systemName: "info.circle")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Why some files aren't searchable")
                        .popover(isPresented: $showingReasons, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(reasons, id: \.self) { Text($0) }
                            }
                            .font(.system(size: 12))
                            .padding(12)
                            .frame(maxWidth: 360, alignment: .leading)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button { confirmingReset = true } label: {
                    Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset the index for this folder")
                .accessibilityLabel("Reset index for \((summary.path as NSString).lastPathComponent)")
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop searching this folder")
                .accessibilityLabel("Remove \((summary.path as NSString).lastPathComponent)")
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Reset the index for “\((summary.path as NSString).lastPathComponent)”?",
                            isPresented: $confirmingReset) {
            Button("Reset Folder Index", role: .destructive, action: reset)
        } message: {
            Text("Morrow will remove indexed data for this folder and its contents, then index it again when available. People names and reference photos are kept.")
        }
    }

    private var states: String {
        [summary.pending > 0 ? "\(summary.pending.formatted()) waiting" : nil,
         summary.unfinished > 0
            ? "\(summary.unfinished.formatted()) long \(summary.unfinished == 1 ? "file" : "files") to finish" : nil,
         summary.skipped > 0 ? "\(summary.skipped.formatted()) skipped" : nil,
         summary.failed > 0 ? "\(summary.failed.formatted()) couldn't be read" : nil,
         summary.leftOutCount > 0 ? "\(summary.leftOutCount.formatted()) not read" : nil].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// One line per reason: what the crawl never queued from this folder, then what was skipped once read.
    private var reasons: [String] {
        let crawl: [String: String] = [
            "other type": "of types Morrow doesn't read",
            "app or bundle": "inside apps or bundles",
            "Photos library": "in a Photos library (its photos aren't read yet)",
            "link or special file": "links or special files",
            "in the cloud, not downloaded": "only in the cloud, not downloaded",
            "inside a code project": "inside code projects, where only screenshots count",
            "dataset": "in folders that look like datasets",
            "code or data file": "code or data files",
            "excluded type": "of the file types you skip",
        ]
        let leftOut = summary.leftOut.sorted { $0.value > $1.value }.map { reason, count in
            reason.hasPrefix("folders ") ? "\(count.formatted()) folders weren't opened (\(reason.dropFirst(8)))"
                : "\(count.formatted()) \(crawl[reason] ?? reason)"
        }
        let skipped = summary.skippedReasons.sorted { $0.value > $1.value }.map { "\($1.formatted()) skipped: \($0)" }
        return leftOut + skipped
    }
}

private struct StorageSettings: View {
    let state: SettingsState
    @State private var confirmingIndexReset = false

    var body: some View {
        Form {
            Section {
                LabeledContent("EmbeddingGemma 2") {
                    Text("Google · Apache 2.0 · 865 MB")
                }
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Text(state.model.download.isReady ? "Downloaded" : state.model.download.progressText)
                        switch state.model.download.phase {
                        case .needed, .failed:
                            Button("Download") { state.model.download.start() }.controlSize(.small)
                            Button("Use Files…") { state.model.download.chooseFiles(for: NSApp.keyWindow) }
                                .controlSize(.small)
                        default:
                            EmptyView()
                        }
                    }
                }
                LabeledContent("Location") {
                    PathButton(url: state.model.settings.modelsDirectory)
                }
            } header: {
                Text("Model")
            } footer: {
                if !state.model.download.isReady {
                    HStack(alignment: .firstTextBaseline) {
                        Text("If your network blocks Hugging Face, download the two files on another network and "
                             + "click Use Files… to choose them. Morrow checks them before it uses them.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Copy Links") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ModelDownload.links, forType: .string)
                        }
                        .controlSize(.small)
                        .help("Copies the addresses of the two files")
                    }
                }
            }
            Section("Index") {
                LabeledContent {
                    Button("Reset Index", role: .destructive) { confirmingIndexReset = true }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rebuild all indexed folders")
                        Text("Clears indexed file data, then indexes your chosen folders again.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Size on disk", value: bytes(state.indexSize))
                if state.model.hasCode {
                    LabeledContent("Code index", value: bytes(state.codeIndexSize))
                }
                LabeledContent("Location") {
                    PathButton(url: state.model.settings.indexDirectory)
                }
            }
            Section("Privacy") {
                Text("Morrow reads only the folders you choose. Search and face matching run on this Mac; "
                     + "the index and people you add stay here. It goes online only to download its model.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("Morrow \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · "
                     + "EmbeddingGemma 2 by Google (Apache 2.0), run by llama.cpp (MIT).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the entire index?", isPresented: $confirmingIndexReset) {
            Button("Reset All Indexes", role: .destructive) {
                state.app.engine.resetIndex()
            }
        } message: {
            Text("Morrow will remove indexed file data from the main and code indexes, then rebuild them from your selected folders. People names and reference photos are kept.")
        }
    }
}

/// Code search: its folders and how far along their index is, the editor results open in, and turning it off.
private struct CodeSettings: View {
    @Bindable var state: SettingsState
    @State private var turningOff = false
    @State private var removing: Engine.RootSummary?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Search your code").font(.system(size: 13, weight: .semibold))
                    Text("Find code by what it does, or by a name in it: type code: in the search panel, as in "
                         + "“code: retry with backoff”. Code has an index of its own, and it never shows up in "
                         + "other searches.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.model.hasCode {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.model.codeStatusLine).font(.system(size: 12, weight: .medium))
                            if let indexing = state.model.status.code.indexing, indexing.total > 0 {
                                ProgressView(value: Double(indexing.done) / Double(indexing.total)).controlSize(.small)
                            }
                        }
                        Spacer()
                        Text(bytes(state.codeIndexSize))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if state.codeSummaries.isEmpty {
                    Text("No code folders yet. Add the folders that hold your projects.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.codeSummaries) { summary in
                    FolderStatusRow(summary: summary,
                                    reset: { state.app.engine.resetIndex(under: URL(fileURLWithPath: summary.path)) },
                                    remove: { removing = summary })
                }
            } header: {
                Text("Code folders")
            } footer: {
                HStack {
                    Button(action: state.addCodeFolders) {
                        Label(state.model.hasCode ? "Add Folders…" : "Choose Code Folders…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            if state.model.hasCode {
                Section {
                    ForEach(state.model.settings.codeExcluded, id: \.path) { folder in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(tildePath(folder.path)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                state.app.applyCodeFolders(state.model.settings.codeRoots,
                                                           excluded: state.model.settings.codeExcluded.filter { $0 != folder })
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Search this folder's code again")
                        }
                    }
                    if state.model.settings.codeExcluded.isEmpty {
                        Text("None. What git ignores, vendored and generated code are skipped anyway.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Skip these folders")
                } footer: {
                    HStack {
                        Button {
                            state.app.pickFolders(for: NSApp.keyWindow, prompt: "Skip") { folders in
                                guard !folders.isEmpty else { return }
                                let excluded = state.model.settings.codeExcluded
                                state.app.applyCodeFolders(state.model.settings.codeRoots,
                                                           excluded: excluded + folders.filter { !excluded.contains($0) })
                            }
                        } label: {
                            Label("Skip a Folder…", systemImage: "plus")
                        }
                        Spacer()
                    }
                }
            }
            Section {
                Picker("Open code in", selection: Binding(get: { CodeEditor.chosen(state.model.settings.codeEditor).id },
                                                          set: { state.app.setCodeEditor($0) })) {
                    ForEach(CodeEditor.installed) { editor in Text(editor.name).tag(editor.id) }
                    Text(CodeEditor.defaultApp.name).tag(CodeEditor.defaultApp.id)
                }
            } footer: {
                Text("A result opens there at the line that matched. Space shows the whole file in Quick Look.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("The code index keeps your code's text on this Mac, as the main index keeps your documents'. "
                     + "It skips what git ignores, vendored and generated code, data files, and anything that looks "
                     + "like a key or a password.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.model.hasCode {
                    HStack {
                        Spacer()
                        Button("Turn Off Code Search…", role: .destructive) { turningOff = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Turn off code search?", isPresented: $turningOff) {
            Button("Turn Off", role: .destructive) {
                state.app.applyCodeFolders([], excluded: [])
                Task { await state.refresh() }
            }
        } message: {
            Text("The code index (\(bytes(state.codeIndexSize))) is deleted. Turning it on again reads the code again.")
        }
        .confirmationDialog("Stop searching the code in “\(removing.map { ($0.path as NSString).lastPathComponent } ?? "")”?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let removing else { return }
                state.app.removeCodeFolder(URL(fileURLWithPath: removing.path))
                Task { await state.refresh() }
            }
        } message: {
            Text("Its \(removing?.files.formatted() ?? "") code files leave the code index.")
        }
    }
}

/// "~/Library/…/Models" that shows the folder in Finder.
private struct PathButton: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(spacing: 4) {
                Text(tildePath(url.path)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Show in Finder")
    }
}
