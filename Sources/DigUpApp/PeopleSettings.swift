import AppKit
import DigUpKit
import SwiftUI
import UniformTypeIdentifiers

/// Native Settings surfaces: portraits and file provenance lead, technical scores stay in help text.
struct PeopleSettings: View {
    @Bindable var people: PeopleCoordinator
    let search: (String) -> Void
    @State private var reviewing = false
    @State private var editor = false
    @State private var editingPerson: PersonProfile?
    @State private var importing = false
    @State private var photos: [URL] = []
    @State private var removing: PersonProfile?
    private var selected: PersonProfile? { people.profiles.first { $0.id == people.selectedPerson } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Find files by who’s in them").font(.title3.weight(.semibold))
                    Text("Add someone you know, then search their name.").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("People search", isOn: $people.enabled).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel("Enable people search")
            }
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(Brand.moss)
                Text("Photos and face matches stay on this Mac.").font(.callout).foregroundStyle(.secondary)
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
                Picker("Show", selection: $reviewing) {
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
                    Button("Add Your First Person") { editingPerson = nil; editor = true }.buttonStyle(.borderedProminent)
                }.frame(height: 230)
            } else if reviewing {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Confirm a match or choose a different name. Uncertain faces stay out of search until you confirm them.")
                        .font(.callout).foregroundStyle(.secondary)
                    if people.reviews.isEmpty {
                        ContentUnavailableView("All caught up", systemImage: "checkmark.circle", description: Text("New faces will appear here as your chosen folders are indexed."))
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
                                    Portrait(data: person.portrait, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.name).fontWeight(.medium).lineLimit(1)
                                        Text("\(person.files) files").font(.caption).foregroundStyle(.secondary)
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
                            Button { search(person.name) } label: { Label("Find \(person.files) Files", systemImage: "magnifyingglass") }
                                .disabled(!people.enabled || person.files == 0)
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
                                        Portrait(data: reference.1, size: 64)
                                            .contextMenu { Button("Remove Reference", role: .destructive) { Task { await people.removeReference(reference.0) } } }
                                            .help("Reference photo. Control-click to remove.")
                                    }
                                }
                            }
                            if !people.reviews.isEmpty {
                                Divider()
                                Text("Matched faces").font(.headline)
                                ForEach(people.reviews.prefix(8)) { face in FaceReviewRow(face: face, people: people) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Choose a person to see their references.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180)
                    }
                }.frame(minHeight: 230)
            }
            Divider()
            HStack(spacing: 10) {
                if people.isScanning { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(people.isScanning ? "Looking for faces…" : people.isPaused ? "Face indexing paused" : people.enabled ? "People search is on" : "People search is off").font(.callout.weight(.medium))
                    Text(people.enabled ? "\(people.pending.formatted()) photos waiting · Uses your folders in Settings → Folders" : "Enable it when you’re ready to index faces in your chosen folders.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if people.enabled {
                    Button(people.isPaused ? "Resume" : "Pause") { people.isPaused ? people.resume() : people.pause() }
                }
            }
        }
        .padding(24)
        .task { await people.refresh(); if people.selectedPerson == nil { people.selectedPerson = people.profiles.first?.id; await people.refresh() } }
        .onChange(of: reviewing) { _, value in
            people.selectedPerson = value ? nil : people.profiles.first?.id
            Task { await people.refresh() }
        }
        .sheet(isPresented: $editor) { PersonEditor(person: editingPerson, people: people) }
        .sheet(isPresented: $importing) {
            if let person = selected { ReferencePicker(person: person, photos: photos, people: people) }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this person")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Person", role: .destructive) { if let person = removing { Task { await people.removePerson(person.id) } }; removing = nil }
        } message: { Text("Their references and identity labels will be removed. Your original files stay where they are.") }
    }
    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "Choose reference photos of \(selected?.name ?? "this person"). You’ll select the face in each photo."
        if panel.runModal() == .OK { photos = panel.urls; importing = true }
    }
}

private struct Portrait: View {
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
    var body: some View {
        HStack(spacing: 10) {
            Portrait(data: face.jpeg, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(face.name ?? "Unrecognized face").fontWeight(.medium)
                Text(face.status == "confirmed" ? "Confirmed" : face.status == "auto" ? "Automatic match" : "Needs your review")
                    .font(.caption).foregroundStyle(.secondary)
                Button((face.path as NSString).lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: face.path)]) }
                    .buttonStyle(.link).font(.caption).lineLimit(1).help(face.path)
            }
            Spacer(minLength: 0)
            if let person = face.person, face.status != "confirmed" {
                Button { Task { await people.confirm(face, person: person) } } label: { Image(systemName: "checkmark") }
                    .help("Confirm \(face.name ?? "this match")").accessibilityLabel("Confirm \(face.name ?? "this match")")
            }
            Menu {
                ForEach(people.profiles) { person in
                    Button("This is \(person.name)") { Task { await people.confirm(face, person: person.id) } }
                }
                Divider()
                Button("Not Someone I’ve Added") { Task { await people.confirm(face, person: nil) } }
            } label: { Image(systemName: "person.crop.circle.badge.questionmark") }
                .menuStyle(.borderlessButton).fixedSize().help("Choose who this is")
        }.padding(.vertical, 5)
    }
}

private struct PersonEditor: View {
    let person: PersonProfile?
    let people: PeopleCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var aliases = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(person == nil ? "Add Someone You Know" : "Edit Person").font(.title2.weight(.semibold))
            Text("A name connects their reference photos to your searches.").foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Person name")
            TextField("Nicknames or aliases, separated by commas", text: $aliases).textFieldStyle(.roundedBorder).accessibilityLabel("Person aliases")
            Text("Use a full name when two people share a first name. Ambiguous names won’t silently choose a person.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save Person") {
                    saving = true
                    Task { if await people.save(id: person?.id, name: name, aliases: aliases) != nil { dismiss() }; saving = false }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }.padding(24).frame(width: 420)
            .onAppear { name = person?.name ?? ""; aliases = person?.aliases.joined(separator: ", ") ?? "" }
    }
}

private struct ReferencePicker: View {
    let person: PersonProfile
    let photos: [URL]
    let people: PeopleCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var faces: [FaceSample] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var problem: String?
    @State private var image: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which face is \(person.name)?").font(.title2.weight(.semibold))
            Text("Photo \(index+1) of \(photos.count) · Select one face to use as a reference.").foregroundStyle(.secondary)
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 8)) }
            if loading { HStack { ProgressView().controlSize(.small); Text("Finding faces…") }.frame(height: 90) }
            else if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).frame(minHeight: 80) }
            else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Array(faces.enumerated()), id: \.element.id) { number, face in
                            Button { selection = face.id } label: {
                                VStack(spacing: 4) {
                                    Portrait(data: face.jpeg, size: 76)
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selection == face.id ? Color.accentColor : .clear, lineWidth: 3))
                                    Text("Face \(number+1)").font(.caption)
                                }.padding(4)
                            }.buttonStyle(.plain).accessibilityLabel("Select face \(number+1) as \(person.name)")
                        }
                    }.padding(3)
                }
            }
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip Photo") { next() }.disabled(loading)
                Button("Use Selected Face") {
                    guard let face = faces.first(where: { $0.id == selection }) else { return }
                    loading = true
                    Task { await people.addReference(person: person.id, face: face, source: photos[index]); next() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(loading || selection == nil)
            }
        }.padding(24).frame(width: 490)
            .task(id: index) {
                loading = true; problem = nil; selection = nil; faces = []
                image = NSImage(contentsOf: photos[index])
                do {
                    faces = try await people.candidates(photos[index]).faces
                    if faces.count == 1 { selection = faces[0].id }
                    if faces.isEmpty { problem = "No usable face was detected. Try a clearer, more front-facing photo." }
                } catch { problem = error.localizedDescription }
                loading = false
            }
    }
    private func next() { if index+1 < photos.count { index += 1 } else { dismiss() } }
}
