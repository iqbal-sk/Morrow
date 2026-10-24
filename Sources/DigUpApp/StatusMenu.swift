import AppKit
import SwiftUI

/// The menubar uses the Reveal artwork exported to `Resources/AppIcon/tray*.png`.
/// During indexing, color returns in a clockwise progress sweep; the paused variant adds two bars.
enum StatusIcon {
    private static let logo = picture("tray"), dimmed = picture("tray-dim"), pausedLogo = picture("tray-paused")

    private static func picture(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    /// `update`: a newer version is waiting, a dot at the top right.
    static func image(progress: Double?, paused: Bool = false, update: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            if paused {
                pausedLogo?.draw(in: rect)
            } else if let progress {
                dimmed?.draw(in: rect)
                NSGraphicsContext.saveGraphicsState()
                let center = NSPoint(x: rect.midX, y: rect.midY)
                let reached = NSBezierPath()
                reached.move(to: center)
                reached.appendArc(withCenter: center, radius: rect.width, startAngle: 90,
                                  endAngle: 90 - 360 * min(1, max(0, progress)), clockwise: true)
                reached.close()
                reached.addClip()
                logo?.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                logo?.draw(in: rect)
            }
            if update {
                // Cut a gap around it, so it reads as a dot on the logo and not part of it.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 11.5, y: 11.5, width: 7, height: 7)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12.75, y: 12.75, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        image.accessibilityDescription = "Morrow"
        return image
    }
}

/// The menubar icon and its menu: what's going on (with a progress bar), Search…, the window, Pause, Settings, Quit.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let people: PeopleCoordinator
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    var onSearch: () -> Void = {}
    var onOpenWindow: () -> Void = {}
    var onSettings: () -> Void = {}
    var onChooseFolders: () -> Void = {}
    var onPauseChanged: (Bool) -> Void = { _ in }
    private var shownProgress: Double?
    private var shownPaused = false

    init(model: AppModel, people: PeopleCoordinator) {
        self.model = model
        self.people = people
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        refreshButton()
        observeModel()
        observePeople()
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.status
            _ = model.progress
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshButton()
                self?.observeModel()
            }
        }
    }

    private func observePeople() {
        withObservationTracking {
            _ = people.scanStatusLine
            _ = people.scanProgressFraction
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshButton()
                self?.observePeople()
            }
        }
    }

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let progress = (model.progress ?? model.codeProgress ?? people.scanProgressFraction).map { ($0 * 50).rounded() / 50 }
        let paused = model.status.paused
        if progress != shownProgress || paused != shownPaused || button.image == nil {
            button.image = StatusIcon.image(progress: progress, paused: paused)
            shownProgress = progress
            shownPaused = paused
        }
        button.toolTip = "Morrow — \(model.statusLine) · \(people.scanStatusLine)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem()
        let view = NSHostingView(rootView: MenuStatusView(model: model, people: people).morrowTheme())
        view.frame.size = view.fittingSize
        header.view = view
        menu.addItem(header)
        menu.addItem(.separator())
        if !model.hasFolders {
            menu.addItem(ActionMenuItem("Choose Folders to Search…") { [weak self] in self?.onChooseFolders() })
        }
        let search = ActionMenuItem("Search…") { [weak self] in self?.onSearch() }
        if let hotkey = model.hotkey, let (key, modifiers) = hotkey.menuEquivalent {
            search.keyEquivalent = key
            search.keyEquivalentModifierMask = modifiers
        }
        menu.addItem(search)
        menu.addItem(ActionMenuItem("Open Morrow") { [weak self] in self?.onOpenWindow() })
        if model.hasFolders || model.hasCode {
            menu.addItem(.separator())
            let paused = model.status.paused
            menu.addItem(ActionMenuItem(paused ? "Resume Indexing" : "Pause Indexing") { [weak self] in
                self?.onPauseChanged(!paused)
            })
        }
        switch model.download.phase {
        case .failed, .needed:
            menu.addItem(ActionMenuItem("Download the Model") { [weak self] in self?.model.download.start() })
        default:
            break
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Settings…", key: ",") { [weak self] in self?.onSettings() })
        menu.addItem(ActionMenuItem("Quit Morrow", key: "q") { NSApp.terminate(nil) })
    }

    /// The menu as text, for the -debugMenu launch argument (menus can't be clicked from a script).
    func describeMenu() -> String {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if item.view != nil { return "[File search: \(model.statusLine) · People search: \(people.scanStatusLine)]" }
            return item.title + (item.isEnabled ? "" : " (disabled)")
        }.joined(separator: " | ")
    }

    /// Runs a menu item by title, for -debugMenu.
    func performItem(titled title: String) {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// A compact, consistently worded tracker for one of Morrow's two background jobs.
struct IndexingTrackerRow: View {
    let title: String
    let detail: String
    let symbol: String
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(Brand.accent)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(detail).font(.system(size: 12, weight: .medium)).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if let progress {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .accessibilityLabel("\(title) progress")
            }
        }
    }
}

/// The top of the menu shows file search and face scanning as separate jobs.
struct MenuStatusView: View {
    let model: AppModel
    let people: PeopleCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IndexingTrackerRow(title: "File search", detail: model.statusLine,
                               symbol: "doc.text.magnifyingglass", progress: model.progress)
            if model.hasCode {
                Divider()
                IndexingTrackerRow(title: "Code search", detail: model.codeStatusLine,
                                   symbol: "chevron.left.forwardslash.chevron.right", progress: model.codeProgress)
            }
            Divider()
            IndexingTrackerRow(title: "People search", detail: people.scanStatusLine,
                               symbol: "person.crop.rectangle.stack", progress: people.scanProgressFraction)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(width: 280, alignment: .leading)
    }

    private var detail: String? {
        if model.download.isActive { return model.download.progressText }
        if case .failed(let message) = model.download.phase { return message }
        guard model.hasFolders else { return "Pick the folders it should search." }
        let missing = Set(model.status.missingRoots), unreadable = Set(model.status.unreadableRoots)
        let names = model.settings.roots.map { root in
            root.lastPathComponent + (missing.contains(root.path) ? " (not connected)"
                                      : unreadable.contains(root.path) ? " (no access)" : "")
        }
        return "In " + names.joined(separator: ", ")
    }
}

/// Makes an NSMenuItem that runs a closure.
private final class MenuAction: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

func ActionMenuItem(_ title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
    item.target = action
    item.representedObject = action  // `target` is weak; this keeps the action alive
    return item
}
