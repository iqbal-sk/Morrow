import AppKit
import DigUpKit
import Foundation
import Observation

private actor PeopleDatabase {
    let store: PeopleStore
    init(directory: URL, minimumFacePixels: Int) throws {
        store = try PeopleStore(directory: directory)
        try store.setMinimumFacePixels(minimumFacePixels)
    }
    func snapshot(person: Int64?, reconcile: Bool) throws -> ([PersonProfile], [FaceReview], [(Int64, Data)], Int, Int) {
        if reconcile { try store.rematchIfNeeded() }
        return (try store.profiles(), try store.review(person: person), try person.map { try store.references(person: $0) } ?? [],
                try store.pendingPhotos().count, try store.failedPhotos())
    }
    func save(id: Int64?, name: String, aliases: [String]) throws -> Int64 { try store.savePerson(id: id, name: name, aliases: aliases) }
    func add(person: Int64, sample: FaceSample, source: String) throws {
        try store.addReference(person: person, sample: sample, source: source)
    }
    func setMinimumFacePixels(_ value: Int) throws { try store.setMinimumFacePixels(value) }
    func rematchIfNeeded() throws { try store.rematchIfNeeded() }
    func retryFailedPhotos() throws { try store.retryFailedPhotos() }
    func confirm(face: Int64, person: Int64?) throws { try store.confirm(face: face, person: person) }
    func deletePerson(_ id: Int64) throws { try store.deletePerson(id) }
    func deleteReference(_ id: Int64) throws { try store.deleteReference(id) }
}

/// The executable owns inference memory; cancellation terminates only this coordinator's helper.
private actor FaceHelperGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        if held { await withCheckedContinuation { waiters.append($0) } }
        else { held = true }
        defer {
            if waiters.isEmpty { held = false }
            else { waiters.removeFirst().resume() }
        }
        return try await operation()
    }
}

nonisolated final class FaceHelper: @unchecked Sendable {
    private let lock = NSLock()
    private let serial = FaceHelperGate()
    private var process: Process?
    private var generation = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func cancel() { lock.withLock { generation += 1; if process?.isRunning == true { process?.terminate() } } }
    func cancelAndWait() async {
        let active = lock.withLock {
            generation += 1
            if process?.isRunning == true { process?.terminate() }
            return process != nil
        }
        guard active else { return }
        await withCheckedContinuation { continuation in
            let finished = lock.withLock {
                guard process != nil else { return true }
                waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }
    private func complete(_ process: Process, token: Int) -> Bool {
        let state = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            if self.process === process { self.process = nil }
            let cancelled = token != generation
            let waiting = waiters
            waiters.removeAll()
            return (cancelled, waiting)
        }
        state.1.forEach { $0.resume() }
        return state.0
    }
    func run(arguments: [String]) async throws -> Data {
        let token = lock.withLock { generation }
        return try await withTaskCancellationHandler {
          try await serial.withPermit {
            try await Task.detached(priority: .utility) { [self] in
            let process = Process(), output = Pipe()
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/digup")
            process.arguments = arguments
            process.qualityOfService = .utility
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try lock.withLock {
                    guard token == generation else { throw CancellationError() }
                    self.process = process
                    try process.run()
                }
            } catch {
                _ = complete(process, token: token)
                throw error
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let cancelled = complete(process, token: token)
            if cancelled { throw CancellationError() }
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "DigUp.People", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Face processing stopped. Try another photo or resume indexing."])
            }
            return data
            }.value
          }
        } onCancel: { self.cancel() }
    }
}

@Observable final class PeopleCoordinator {
    var profiles: [PersonProfile] = []
    var reviews: [FaceReview] = []
    var references: [(Int64, Data)] = []
    var selectedPerson: Int64?
    var pending = 0
    var failedPhotos = 0
    var isScanning = false
    var isPaused = false
    var isDetecting = false
    private(set) var isAddingReferences = false
    private(set) var minimumFacePixels = FaceIdentity.defaultMinimumFacePixels
    private(set) var isUpdatingFacePolicy = false
    var problem: String?
    var enabled: Bool {
        didSet { AppSettings.defaults.set(enabled, forKey: "peopleEnabled"); if !enabled { pause() } else { isPaused = false; scan() } }
    }
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var database: PeopleDatabase?
    @ObservationIgnored private let scanner = FaceHelper()
    @ObservationIgnored private let detector = FaceHelper()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var facePolicyGeneration = 0
    @ObservationIgnored var mayIndex: () -> Bool = { true }
    init(settings: AppSettings, engine: Engine) {
        self.settings = settings; self.engine = engine
        enabled = AppSettings.defaults.bool(forKey: "peopleEnabled")
        minimumFacePixels = AppSettings.defaults.object(forKey: "peopleMinimumFacePixels") as? Int ?? FaceIdentity.defaultMinimumFacePixels
        do { database = try PeopleDatabase(directory: settings.indexDirectory, minimumFacePixels: minimumFacePixels) }
        catch { problem = error.localizedDescription }
    }
    func start() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                scan()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
    func refresh() async {
        guard let database else { return }
        do {
            let snapshot = try await database.snapshot(person: selectedPerson, reconcile: !isAddingReferences && !isScanning)
            profiles = snapshot.0; reviews = snapshot.1; references = snapshot.2; pending = snapshot.3; failedPhotos = snapshot.4
            engine.setPeople(enabled ? profiles : [])
        } catch { problem = error.localizedDescription }
    }
    @discardableResult func save(id: Int64?, name: String, aliases: String) async -> Int64? {
        do {
            guard let database else { return nil }
            let saved = try await database.save(id: id, name: name, aliases: aliases.split(separator: ",").map(String.init))
            selectedPerson = saved
            await refresh()
            return saved
        } catch { problem = error.localizedDescription; return nil }
    }
    func candidates(_ photo: URL) async throws -> FacePhoto {
        guard !isDetecting else { throw CancellationError() }
        isDetecting = true
        defer { isDetecting = false }
        // Enrollment gets priority over the background scan.
        return try await withTaskCancellationHandler {
            await scanner.cancelAndWait()
            try Task.checkCancellation()
            let data = try await detector.run(arguments: ["face-detect", "--photo", photo.path,
                "--face-model", modelPath, "--min-face-pixels", String(minimumFacePixels)])
            return try JSONDecoder().decode(FacePhoto.self, from: data)
        } onCancel: { detector.cancel() }
    }
    func beginReferenceImport() {
        isAddingReferences = true
        scanner.cancel()
    }
    func endReferenceImport() {
        guard isAddingReferences else { return }
        isAddingReferences = false
        Task {
            await scanner.cancelAndWait()
            do {
                try await database?.rematchIfNeeded()
                await refresh()
                scan()
            } catch { problem = error.localizedDescription }
        }
    }
    func addReference(person: Int64, face: FaceSample, source: URL) async -> Bool {
        do {
            guard let database else { return false }
            try await database.add(person: person, sample: face, source: source.path)
            if !enabled { enabled = true }
            await refresh()
            return true
        } catch { problem = error.localizedDescription; return false }
    }
    func confirm(_ face: FaceReview, person: Int64?) async {
        do { try await database?.confirm(face: face.id, person: person); await refresh() }
        catch { problem = error.localizedDescription }
    }
    func removePerson(_ person: Int64) async {
        do { try await database?.deletePerson(person); selectedPerson = nil; await refresh() }
        catch { problem = error.localizedDescription }
    }
    func removeReference(_ id: Int64) async {
        do { try await database?.deleteReference(id); await refresh() }
        catch { problem = error.localizedDescription }
    }
    func setMinimumFacePixels(_ value: Int) {
        let rounded = min(128, max(0, Int((Double(value) / 8).rounded()) * 8))
        guard rounded != minimumFacePixels else { return }
        minimumFacePixels = rounded
        AppSettings.defaults.set(rounded, forKey: "peopleMinimumFacePixels")
        facePolicyGeneration += 1
        let generation = facePolicyGeneration
        isUpdatingFacePolicy = true
        scanner.cancel()
        Task {
            await scanner.cancelAndWait()
            guard generation == facePolicyGeneration else { return }
            do {
                try await database?.setMinimumFacePixels(rounded)
                await refresh()
            } catch { problem = error.localizedDescription }
            isUpdatingFacePolicy = false
            scan()
        }
    }
    func retryFailedPhotos() {
        guard !isScanning else { return }
        Task {
            do {
                try await database?.retryFailedPhotos()
                await refresh()
                scan()
            } catch { problem = error.localizedDescription }
        }
    }
    func pause() { isPaused = true; scanner.cancel() }
    func foldersChanged() { scanner.cancel(); Task { await refresh() } }
    func resume() { isPaused = false; scan() }
    private var modelPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sface.onnx").path }
    func scan() {
        guard enabled, !isPaused, !isAddingReferences, !isUpdatingFacePolicy, !isScanning, !isDetecting, pending > 0,
              profiles.contains(where: { $0.references > 0 }), mayIndex(),
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else { return }
        guard FileManager.default.fileExists(atPath: modelPath) else { problem = "The face model is missing from this app. Rebuild DigUp People."; return }
        isScanning = true
        Task {
            defer { isScanning = false }
            guard enabled, !isPaused, !isDetecting else { return }
            do {
                let selection = engine.faceSelection()
                _ = try await scanner.run(arguments: ["face-index", "--index", settings.indexDirectory.path,
                    "--face-model", modelPath, "--limit", "40", "--min-face-pixels", String(minimumFacePixels), "--selection",
                    String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)])
            } catch is CancellationError { }
            catch { if !isPaused && !isDetecting { problem = error.localizedDescription } }
            await refresh()
        }
    }
}
