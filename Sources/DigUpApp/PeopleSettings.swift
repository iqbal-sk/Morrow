import AppKit
import ImageIO
import DigUpKit
import SwiftUI
import UniformTypeIdentifiers

/// Native Settings surfaces: portraits and file provenance lead, technical scores stay in help text.
struct PeopleSettings: View {
    @Bindable var people: PeopleCoordinator
    let model: AppModel
    let search: (String) -> Void
    var preferences: () -> Void = {}
    @State private var editor = false
    @State private var editingPerson: PersonProfile?
    @State private var importing = false
    @State private var photos: [URL] = []
    @State private var importBatchID = UUID()
    @State private var removing: PersonProfile?
    private var selected: PersonProfile? { people.profiles.first { $0.id == people.selectedPerson } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("People").font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.7)
                    Text("Familiar faces. Easier to find.").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: preferences) { Label("Scan Settings", systemImage: "slider.horizontal.3") }
            }
            HStack(spacing: 10) {
                Label(people.enabled ? "On-device face matching" : "People search is off", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(people.scanStatusLine).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = people.problem {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(problem).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { people.problem = nil }.buttonStyle(.borderless)
                }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Picker("Show", selection: $people.reviewingAllFaces) {
                    Text("People").tag(false)
                    Text("Review faces").tag(true)
                }.pickerStyle(.segmented).frame(width: 240)
                Spacer()
                Button { editingPerson = nil; editor = true } label: { Label("Add Person", systemImage: "plus") }
            }
            if people.profiles.isEmpty {
                ContentUnavailableView {
                    Label("Who would you like to find?", systemImage: "person.crop.rectangle.stack")
                } description: {
                    Text("Start with a name and a few clear reference photos. Group photos work too—you choose the face.")
                } actions: {
                    Button("Add Your First Person") { editingPerson = nil; editor = true }.morrowAction(.primary)
                }.frame(height: 230)
            } else if people.reviewingAllFaces {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Confirm a match or choose a different name. Uncertain faces stay out of search until you confirm them.")
                        .font(.callout).foregroundStyle(.secondary)
                    if people.reviews.isEmpty {
                        ContentUnavailableView("All caught up", systemImage: "checkmark.circle", description: Text("New faces will appear here as Morrow scans photos in your chosen folders."))
                            .frame(height: 180)
                    } else {
                        ForEach(people.reviews) { face in FaceReviewRow(face: face, people: people) }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 6) {
                        ForEach(people.profiles) { person in
                            Button {
                                people.selectedPerson = person.id
                                Task { await people.refresh() }
                            } label: {
                                HStack(spacing: 8) {
                                    PersonPortrait(data: person.portrait, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.name).fontWeight(.medium).lineLimit(1)
                                        Text("\(person.files.formatted()) matched files").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(8).frame(maxWidth: .infinity)
                                    .background(person.id == people.selectedPerson ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).accessibilityLabel("\(person.name), \(person.files) matched files")
                        }
                    }.frame(width: 150)
                    Divider()
                    if let person = selected {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(person.name).font(.title2.weight(.semibold))
                                Spacer()
                                Menu {
                                    Button("Edit Name & Aliases…") { editingPerson = person; editor = true }
                                    Button("Remove Person…", role: .destructive) { removing = person }
                                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                            }
                            if !person.aliases.isEmpty { Text("Also: " + person.aliases.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary) }
                            Button { search(person.name) } label: { Label("Search Files", systemImage: "magnifyingglass") }
                                .disabled(!people.enabled)
                            Divider()
                            HStack {
                                Text("Reference photos").font(.headline)
                                Spacer()
                                Button("Add Photos…") { choosePhotos() }
                            }
                            Text("Choose 3–5 varied photos. Only the face you select becomes a reference.")
                                .font(.caption).foregroundStyle(.secondary)
                            if people.references.isEmpty {
                                Label("Add a reference to start finding \(person.name).", systemImage: "photo.badge.plus")
                                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], alignment: .leading, spacing: 10) {
                                    ForEach(people.references, id: \.0) { reference in
                                        PersonPortrait(data: reference.1, size: 64)
                                            .contextMenu { Button("Remove Reference", role: .destructive) { Task { await people.removeReference(reference.0) } } }
                                            .help("Reference photo. Control-click to remove.")
                                    }
                                }
                            }
                            if !people.reviews.isEmpty {
                                Divider()
                                Text("Face matches").font(.headline)
                                ForEach(people.reviews.prefix(8)) { face in FaceReviewRow(face: face, people: people) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Choose a person to see their references.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180)
                    }
                }.frame(minHeight: 230)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                IndexingTrackerRow(title: "File search", detail: model.statusLine,
                                   symbol: "doc.text.magnifyingglass", progress: model.progress)
                Divider()
                HStack(spacing: 12) {
                    IndexingTrackerRow(title: "People search", detail: people.scanStatusLine,
                                       symbol: "person.crop.rectangle.stack", progress: people.scanProgressFraction)
                    if people.enabled {
                        Button(people.isPaused ? "Resume" : "Pause") { people.isPaused ? people.resume() : people.pause() }
                    }
                }
            }
            if people.failedPhotos > 0 {
                HStack {
                    Label("\(people.failedPhotos.formatted()) photos could not be checked", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { people.retryFailedPhotos() }
                        .disabled(!people.enabled || people.isPaused || people.isScanning)
                }
            }
        }
        .padding(32)
        .task { await people.refresh() }
        .onChange(of: people.reviewingAllFaces) { Task { await people.refresh() } }
        .sheet(isPresented: $editor) { PersonEditor(person: editingPerson, people: people) }
        .sheet(isPresented: $importing) {
            if let person = selected { ReferencePicker(person: person, photos: photos, batchID: importBatchID, people: people).id(importBatchID) }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this person")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Person", role: .destructive) { if let person = removing { Task { await people.removePerson(person.id) } }; removing = nil }
        } message: { Text("Their references and identity labels will be removed. Your original files stay where they are.") }
    }
    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "Choose reference photos of \(selected?.name ?? "this person"). You’ll select the face in each photo."
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            photos = panel.urls
            importBatchID = UUID()
            importing = true
        }
    }
}

struct PersonPortrait: View {
    let data: Data?
    let size: CGFloat
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "person.crop.square").resizable().scaledToFit().padding(size/5).foregroundStyle(.secondary) }
        }.frame(width: size, height: size).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: size/6))
    }
}

private struct FaceReviewRow: View {
    let face: FaceReview
    let people: PeopleCoordinator
    @State private var saving = false
    var body: some View {
        HStack(spacing: 12) {
            PersonPortrait(data: face.jpeg, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(face.name ?? "Unrecognized face").fontWeight(.medium)
                Text(face.status == "confirmed" ? "Confirmed" : face.status == "auto" ? "Automatic match" : "Needs your review")
                    .font(.caption).foregroundStyle(.secondary)
                Button((face.path as NSString).lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: face.path)]) }
                    .buttonStyle(.link).font(.caption).lineLimit(1).help(face.path)
            }
            Spacer(minLength: 0)
            if saving { ProgressView().controlSize(.mini).accessibilityLabel("Saving face decision") }
            if let person = face.person, face.status != "confirmed" {
                Button { assign(person) } label: {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
                }.morrowAction()
                    .help("Confirm \(face.name ?? "this match")").accessibilityLabel("Confirm \(face.name ?? "this match")")
            }
            Button { assign(nil) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .morrowAction()
            .help("Not someone I know")
            .accessibilityLabel("Not someone I know")
            Menu {
                ForEach(people.profiles) { person in
                    Button("Assign to \(person.name)") { assign(person.id) }
                }
            } label: { Image(systemName: "person.crop.circle.badge.questionmark") }
                .menuStyle(.borderlessButton).fixedSize().help("Assign this face to a person")
        }.padding(.vertical, 8).disabled(saving)
    }
    private func assign(_ person: Int64?) {
        guard !saving else { return }
        saving = true
        Task {
            await people.confirm(face, person: person)
            saving = false
        }
    }
}

private struct PersonEditor: View {
    let person: PersonProfile?
    let people: PeopleCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var aliases = ""
    @State private var saving = false
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(person == nil ? "Add Someone You Know" : "Edit Person").font(.title2.weight(.semibold))
            Text("A name connects their reference photos to your searches.").foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Person name")
            TextField("Nicknames or aliases, separated by commas", text: $aliases).textFieldStyle(.roundedBorder).accessibilityLabel("Person aliases")
            Text("Use a full name when two people share a first name. Ambiguous names won’t silently choose a person.").font(.caption).foregroundStyle(.secondary)
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "Saving…" : "Save Person") {
                    saving = true
                    problem = nil
                    Task {
                        if await people.save(id: person?.id, name: name, aliases: aliases) != nil { dismiss() }
                        else { problem = people.problem ?? "This person could not be saved. Try again." }
                        saving = false
                    }
                }.morrowAction(.primary).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }.padding(24).frame(width: 420).interactiveDismissDisabled(saving)
            .onAppear { name = person?.name ?? ""; aliases = person?.aliases.joined(separator: ", ") ?? "" }
    }
}

private struct ReferencePicker: View {
    let person: PersonProfile
    let photos: [URL]
    let batchID: UUID
    let people: PeopleCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var faces: [FaceSample] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var savingReference = false
    @State private var problem: String?
    @State private var saveProblem: String?
    @State private var image: NSImage?
    private var photoBatch: ReferencePhotoBatch { ReferencePhotoBatch(photos: photos) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which face is \(person.name)?").font(.title2.weight(.semibold))
            Text("Photo \(min(index + 1, max(photos.count, 1))) of \(photos.count) · Select one face to use as a reference.").foregroundStyle(.secondary)
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 8)) }
            if loading { HStack { ProgressView().controlSize(.small); Text(savingReference ? "Saving reference…" : "Finding faces…") }.frame(height: 90) }
            else if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).frame(minHeight: 80) }
            else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Array(faces.enumerated()), id: \.element.id) { number, face in
                            Button { selection = face.id } label: {
                                VStack(spacing: 4) {
                                    PersonPortrait(data: face.jpeg, size: 76)
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selection == face.id ? Color.accentColor : .clear, lineWidth: 3))
                                    Text("Face \(number+1)").font(.caption)
                                }.padding(4)
                            }.buttonStyle(.plain).accessibilityLabel("Select face \(number+1) as \(person.name)")
                        }
                    }.padding(3)
                }.frame(height: 112)
            }
            if let saveProblem {
                Label(saveProblem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(savingReference)
                Spacer()
                Button("Skip Photo") { next() }.disabled(loading || savingReference)
                Button("Use Selected Face") {
                    guard let face = faces.first(where: { $0.id == selection }),
                          let source = photoBatch.photo(at: index) else { return }
                    loading = true
                    savingReference = true
                    saveProblem = nil
                    Task {
                        let saved = await people.addReference(person: person.id, face: face, source: source)
                        savingReference = false
                        loading = false
                        if saved { next() }
                        else { saveProblem = people.problem ?? "This reference could not be saved. Try again." }
                    }
                }.morrowAction(.primary).keyboardShortcut(.defaultAction).disabled(loading || selection == nil || savingReference)
            }
        }.padding(24).frame(width: 490).interactiveDismissDisabled(savingReference)
            .onAppear { people.beginReferenceImport(batchID) }
            .onDisappear { people.endReferenceImport(batchID) }
            .task(id: "\(batchID.uuidString)-\(index)-\(people.minimumFacePixels)") {
                guard let photo = photoBatch.photo(at: index) else {
                    image = nil; faces = []; loading = false
                    problem = photos.isEmpty ? "Choose at least one photo." : "This photo batch changed. Close and choose the photos again."
                    return
                }
                let requestedIndex = index
                loading = true; problem = nil; saveProblem = nil; selection = nil; faces = []
                image = nil
                async let preview = Self.thumbnailJPEG(for: photo)
                do {
                    let candidates = try await people.candidates(photo)
                    let previewData = await preview
                    guard !Task.isCancelled, index == requestedIndex,
                          photoBatch.photo(at: requestedIndex) == photo else { return }
                    image = previewData.flatMap(NSImage.init(data:))
                    faces = candidates.faces
                    if faces.count == 1, let face = faces.first { selection = face.id }
                    if faces.isEmpty { problem = "No usable face was detected. Try a clearer, more front-facing photo." }
                } catch {
                    let previewData = await preview
                    guard !Task.isCancelled, index == requestedIndex,
                          photoBatch.photo(at: requestedIndex) == photo else { return }
                    image = previewData.flatMap(NSImage.init(data:))
                    problem = error.localizedDescription
                }
                if !Task.isCancelled, index == requestedIndex,
                   photoBatch.photo(at: requestedIndex) == photo { loading = false }
            }
    }
    private static func thumbnailJPEG(for url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1200
                      ] as CFDictionary) else { return nil }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    return nil
                }
                CGImageDestinationAddImage(destination, thumbnail,
                    [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { return nil }
                return data as Data
            }
        }.value
    }
    private func next() {
        guard let nextIndex = photoBatch.nextIndex(after: index) else { dismiss(); return }
        index = nextIndex
    }
}
