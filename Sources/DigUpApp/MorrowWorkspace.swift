import AppKit
import DigUpKit
import SwiftUI

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case library, people, activity
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .library: "square.grid.2x2"
        case .people: "person.2"
        case .activity: "waveform.path"
        }
    }
}

private enum WorkspaceSidebarSelection: Hashable {
    case destination(WorkspaceDestination)
    case folder(String)
}

/// A native source list keeps navigation stable while the content changes.
struct MorrowWorkspace: View {
    @Bindable var search: SearchModel
    let app: AppController
    @State private var searchFocused = false

    private var sidebarSelection: Binding<WorkspaceSidebarSelection?> {
        Binding(get: {
            if search.destination == .library, search.browsing, !search.isCode, let folder = search.folder {
                return .folder(folder)
            }
            return .destination(search.destination)
        }, set: { value in
            switch value {
            case .destination(let destination):
                search.navigate(to: destination)
            case .folder(let path): search.browse(folder: path)
            case nil: break
            }
        })
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    MorrowAppIcon(size: 32, launch: app.launchLogo)
                    Text("Morrow").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Spacer()
                }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 20)
                List(selection: sidebarSelection) {
                    Section("Your library") {
                        ForEach(WorkspaceDestination.allCases) { destination in
                            Label(destination.title, systemImage: destination.symbol)
                                .tag(WorkspaceSidebarSelection.destination(destination))
                        }
                    }
                    Section("Folders") {
                        ForEach(app.model.settings.roots, id: \.path) { root in
                            Label(root.lastPathComponent, systemImage: "folder")
                                .tag(WorkspaceSidebarSelection.folder(root.path)).help(root.path)
                        }
                        Button(action: app.chooseFolders) { Label("Add Folders…", systemImage: "plus") }
                            .buttonStyle(.plain)
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 14) {
                    Button { app.showSettings() } label: { Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).help("Settings (⌘,)")
                    Label("Private. On this Mac.", systemImage: "lock.shield")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            VStack(spacing: 0) {
                // Search is the app's primary action. Keep it in the shared workspace header,
                // outside both page transitions and the toolbar's optional overflow items.
                searchControl
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                MorrowPageDeck(selection: search.destination, animated: search.animatesNavigation) {
                    switch search.destination {
                    case .library:
                        SearchWindowView(search: search, model: app.model, app: app)
                    case .people:
                        ScrollView {
                            PeopleSettings(people: app.people, model: app.model,
                                           search: { app.searchWindow.show(query: $0) },
                                           preferences: { app.showSettings(.people) })
                                .frame(maxWidth: 1000)
                                .frame(maxWidth: .infinity)
                        }.scrollBounceBehavior(.basedOnSize)
                    case .activity:
                        LibraryActivity(app: app)
                    }
                }
                Divider()
                WorkspaceStatus(app: app, showActivity: { search.destination = .activity })
            }
        }
        // Window-level chrome survives destination changes.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(search.showsPreview ? "Hide Preview" : "Show Preview", systemImage: "sidebar.right") {
                    search.showsPreview.toggle()
                }.help(search.showsPreview ? "Hide Preview" : "Show Preview")
                    .disabled(!search.canTogglePreview)
                Button("Settings", systemImage: "gearshape") { app.showSettings() }
                    .help("Settings (⌘,)")
            }
        }
        .morrowTheme()
        .task { await app.people.refresh() }
    }

    private var searchControl: some View {
        HStack(spacing: 9) {
            Image(systemName: search.isCode ? FileKind.code.symbol : "magnifyingglass")
                .font(.system(size: search.isCode ? 15 : 17, weight: .semibold))
                .foregroundStyle(Brand.gradient)
                .frame(width: 22)
            SearchField(text: Binding(get: { search.query }, set: { search.editQuery($0) }), fontSize: 15, placeholder: placeholder,
                        onMake: { search.field = $0 }, onFocus: { focused in
                            searchFocused = focused
                        })
                .frame(maxWidth: .infinity)
            if !search.query.isEmpty {
                Button {
                    search.clearQuery()
                    search.focusField()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
        .morrowSearchSurface()
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Brand.accent.opacity(searchFocused ? 0.6 : 0), lineWidth: 2))
        .accessibilityElement(children: .contain)
    }

    private var placeholder: String {
        search.filter == .code
            ? "Describe the code: “retry a request with backoff”, a name in it…"
            : "Search by a memory, a person, or words inside a file…"
    }
}

private struct WorkspaceStatus: View {
    let app: AppController
    let showActivity: () -> Void
    var body: some View {
        Button(action: showActivity) {
            HStack(spacing: 16) {
                Label(app.model.statusLine, systemImage: "doc.text.magnifyingglass").lineLimit(1)
                Spacer(minLength: 8)
                Label(app.people.scanStatusLine, systemImage: "person.crop.rectangle.stack").lineLimit(1)
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
            }.font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(.plain).help("View file preparation and face scanning separately")
            .accessibilityLabel("Activity. Files: \(app.model.statusLine). Faces: \(app.people.scanStatusLine)")
    }
}

struct LibraryHome: View {
    let search: SearchModel
    let app: AppController
    @State private var recent: [ResultRow] = []
    @State private var folders: [Engine.RootSummary] = []
    @State private var loaded = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                hero
                if !app.people.profiles.isEmpty {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeading("Your people", action: "Manage People") { search.destination = .people }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 22) {
                                    ForEach(app.people.profiles) { person in
                                        Button { app.searchWindow.show(query: person.name) } label: {
                                            VStack(spacing: 8) {
                                                PersonPortrait(data: person.portrait, size: 60).clipShape(Circle())
                                                Text(person.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            }.frame(width: 76)
                                        }.buttonStyle(QuietPressStyle()).help("Find files with \(person.name)")
                                    }
                                }.padding(.vertical, 2)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading("Your folders", action: "Manage Folders") { app.showSettings(.folders) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                        ForEach(app.model.settings.roots, id: \.path) { root in
                            folderCard(root)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading("Recently modified", action: "Browse Files") { search.browse() }
                    if !loaded {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 100)
                    } else if recent.isEmpty {
                        Text("Your files will appear here as they become searchable.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 28)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 16)], alignment: .leading, spacing: 20) {
                            ForEach(recent) { row in
                                Button {
                                    search.browse(selecting: row)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Color.primary.opacity(0.04).frame(height: 122)
                                            .overlay { MomentThumbnail(row: row) }
                                            .clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(row.modified, style: .date).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(QuietPressStyle())
                                    .contextMenu {
                                        Button("Open") { search.open(row) }
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                                    }
                            }
                        }
                    }
                }
            }.padding(30).frame(maxWidth: 1250).frame(maxWidth: .infinity)
        }.scrollBounceBehavior(.basedOnSize)
            .task(id: app.model.settings.roots.map(\.path)) { await refresh() }
            .task(id: app.model.status.searchable) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await refresh()
            }
    }

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                heroCopy.frame(width: 340, alignment: .leading)
                if !recent.isEmpty {
                    HeroPhotos(rows: Array(recent.prefix(3))).frame(width: 250, height: 210)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            heroCopy.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(26)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Brand.peach.opacity(scheme == .dark ? 0.16 : 0.40),
                                              Brand.coral.opacity(scheme == .dark ? 0.10 : 0.15),
                                              Brand.rose.opacity(0.035)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("YOUR PERSONAL LIBRARY", systemImage: "sparkle")
                .font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Brand.accent)
            Text("Find what you\nremember.")
                .font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1.2).fixedSize(horizontal: false, vertical: true)
            Text("Search your files by a moment, a person,\nor a few words you remember.")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
            MorrowGlassGroup {
                HStack(spacing: 8) {
                    suggestion("a beach at sunset", symbol: "sun.horizon")
                    suggestion("a receipt", symbol: "doc.text")
                }
            }.padding(.top, 6)
        }
    }

    private func suggestion(_ text: String, symbol: String) -> some View {
        Button { search.query = text; search.focusField() } label: {
            Label(text, systemImage: symbol).font(.system(size: 12, weight: .medium))
        }.morrowAction()
    }

    private func sectionHeading(_ title: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 18, weight: .semibold)).tracking(-0.3)
            Spacer()
            Button(action, action: perform).buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
        }
    }

    private func folderCard(_ root: URL) -> some View {
        let summary = folders.first { $0.path == root.path }
        return Button { search.browse(folder: root.path) } label: {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill").font(.system(size: 27, weight: .light)).foregroundStyle(Brand.gradient)
                    .frame(width: 46, height: 48).background(Brand.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(root.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let summary {
                        Text(summary.missing ? "Folder unavailable" : "\(summary.indexed.formatted()) files searchable")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else { Text("Checking folder…").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(QuietPressStyle()).help(root.path)
    }

    private func refresh() async {
        async let files = app.engine.libraryFiles(limit: 12)
        async let summaries = app.engine.rootSummaries()
        let (hits, roots) = await (files, summaries)
        guard !Task.isCancelled else { return }
        recent = hits.map { hit in var row = ResultRow(hit); row.isBrowsing = true; return row }
        folders = roots
        loaded = true
    }
}

private struct HeroPhotos: View {
    let rows: [ResultRow]
    var body: some View {
        ZStack {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Color(nsColor: .controlBackgroundColor)
                    .frame(width: 145, height: 172)
                    .overlay { MomentThumbnail(row: row).padding(5) }
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.20), lineWidth: 1))
                    .rotationEffect(.degrees(Double(index - 1) * 11))
                    .offset(x: CGFloat(index - 1) * 42, y: index == 1 ? -6 : 5)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}

private struct LibraryActivity: View {
    let app: AppController
    @State private var folders: [Engine.RootSummary] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity").font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.7)
                    Text("Follow each part of your local library.").font(.title3).foregroundStyle(.secondary)
                }
                activityCard(title: "File search", subtitle: "Reads file content and prepares meaning and word search.",
                             detail: app.model.statusLine, symbol: "doc.text.magnifyingglass", progress: app.model.progress) {
                    Button(app.model.status.paused ? "Resume" : "Pause") { app.engine.setPaused(!app.model.status.paused) }
                        .disabled(!app.model.hasFolders)
                }
                if app.model.hasCode {
                    activityCard(title: "Code search", subtitle: "Prepares the separate index for your code folders.",
                                 detail: app.model.codeStatusLine, symbol: "chevron.left.forwardslash.chevron.right", progress: app.model.codeProgress) {
                        Button(app.model.status.paused ? "Resume" : "Pause") { app.engine.setPaused(!app.model.status.paused) }
                    }
                }
                activityCard(title: "People search", subtitle: "Checks photos for faces and matches the people you added.",
                             detail: app.people.scanStatusLine, symbol: "person.crop.rectangle.stack", progress: app.people.scanProgressFraction) {
                    Button(app.people.isPaused ? "Resume" : "Pause") { app.people.isPaused ? app.people.resume() : app.people.pause() }
                        .disabled(!app.people.enabled)
                }
                Label("A file can be ready for content search while its faces are still waiting to be checked.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Folders").font(.headline)
                    Spacer()
                    Button("Manage Folders…") { app.showSettings(.folders) }.buttonStyle(.borderless)
                }
                ForEach(folders) { folder in
                    HStack(spacing: 14) {
                        Image(systemName: "folder").foregroundStyle(Brand.accent).font(.title2)
                        VStack(alignment: .leading, spacing: 5) {
                            Text((folder.path as NSString).lastPathComponent).fontWeight(.medium)
                            Text(tildePath(folder.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(folder.missing ? "Not connected" : folder.unreadable ? "No access" : "\(folder.indexed.formatted()) searchable").font(.callout)
                            if folder.pending > 0 { Text("\(folder.pending.formatted()) waiting").font(.caption).foregroundStyle(.secondary) }
                            if folder.failed > 0 { Text("\(folder.failed.formatted()) couldn’t be read").font(.caption).foregroundStyle(.orange) }
                        }
                    }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                }
                if app.people.failedPhotos > 0 {
                    HStack {
                        Label("\(app.people.failedPhotos.formatted()) photos couldn’t be checked for faces", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Retry Face Scan") { app.people.retryFailedPhotos() }
                            .disabled(!app.people.enabled || app.people.isScanning || app.people.isPaused)
                    }.font(.callout)
                }
            }.padding(32).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.scrollBounceBehavior(.basedOnSize)
            .task { await refresh() }
            .task(id: app.model.statusLine) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await refresh()
            }
    }
    private func refresh() async { folders = await app.engine.rootSummaries() }
    private func activityCard<Actions: View>(title: String, subtitle: String, detail: String, symbol: String,
                                             progress: Double?, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 23, weight: .light)).foregroundStyle(Brand.accent)
                    .frame(width: 48, height: 48).background(Brand.coral.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                actions()
            }
            if let progress { ProgressView(value: progress).tint(Brand.accent).accentColor(Brand.accent) }
            Text(detail).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
        }.padding(22).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
    }
}
