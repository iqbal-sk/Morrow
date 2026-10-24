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
    func snapshot(person: Int64?, reconcile: Bool, selection: FacePhotoSelection, includePending: Bool) throws -> PeopleSnapshot {
        if reconcile { try store.rematchIfNeeded() }
        let profiles = try store.profiles(selection: selection)
        let pending = includePending
            ? try store.pendingPhotoSummary(selection: selection, isReadable: FileManager.default.isReadableFile(atPath:))
            : (count: 0, hasReadable: false)
        return PeopleSnapshot(profiles: profiles, reviews: try store.review(person: person, selection: selection),
                              references: try person.map { try store.references(person: $0) } ?? [],
                              pending: pending.count, hasAvailablePending: pending.hasReadable,
                              failedPhotos: try store.failedPhotos(selection: selection))
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

private struct PeopleSnapshot: Sendable {
    let profiles: [PersonProfile]
    let reviews: [FaceReview]
    let references: [(Int64, Data)]
    let pending: Int
    let hasAvailablePending: Bool
    let failedPhotos: Int
}

/// The executable owns inference memory; cancellation terminates only this coordinator's helper.
private actor FaceHelperGate {
    static let shared = FaceHelperGate()
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
    // Detection and background indexing must not each load their own SFace/ONNX session.
    private let serial = FaceHelperGate.shared
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
    func run(arguments: [String], onProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> Data {
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
            let reader = output.fileHandleForReading
            var data = Data()
            var lineBuffer = Data()
            while true {
                let chunk = reader.availableData
                guard !chunk.isEmpty else { break }
                data.append(chunk)
                lineBuffer.append(chunk)
                while let newline = lineBuffer.firstIndex(of: 10) {
                    let line = Data(lineBuffer[..<newline])
                    lineBuffer.removeSubrange(...newline)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Int],
                       let done = event["done"], let total = event["total"], total > 0 {
                        await onProgress(done, total)
                    }
                }
            }
            if !lineBuffer.isEmpty,
               let event = try? JSONSerialization.jsonObject(with: lineBuffer) as? [String: Int],
               let done = event["done"], let total = event["total"], total > 0 {
                await onProgress(done, total)
            }
            process.waitUntilExit()
            let cancelled = complete(process, token: token)
            if cancelled { throw CancellationError() }
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "Morrow.People", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Face processing stopped. Try another photo or resume the face scan."])
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
    var reviewingAllFaces = false
    var pending = 0
    var hasAvailablePending = false
    var failedPhotos = 0
    var isScanning = false
    var isPaused = false
    var scanProgress: EngineStatus.Progress?
    private var detectionCount = 0
    var isDetecting: Bool { detectionCount > 0 }
    var scanProgressFraction: Double? {
        guard let scanProgress, scanProgress.total > 0 else { return nil }
        return Double(scanProgress.done) / Double(scanProgress.total)
    }
    var scanStatusLine: String {
        guard enabled else { return "Off · face scanning is disabled" }
        guard profiles.contains(where: { $0.references > 0 }) else {
            return "Add a person and reference photos to start"
        }
        if isPaused { return "Paused · \(pending.formatted()) photos left to scan" }
        if isUpdatingFacePolicy { return "Updating face scan settings…" }
        if isAddingReferences { return "Adding reference photos…" }
        if let waitingReason { return waitingReason }
        if isScanning {
            if let scanProgress, scanProgress.total > 0 {
                return "Scanning faces · \(scanProgress.done.formatted()) of \(scanProgress.total.formatted()) photos this batch"
            }
            return "Starting face scan"
        }
        if pending > 0 { return "\(pending.formatted()) photos left to scan" }
        if failedPhotos > 0 { return "\(failedPhotos.formatted()) photos couldn’t be checked · retry in Activity" }
        return "Up to date · no photos left to scan"
    }
    var waitingReason: String?
    private(set) var isAddingReferences = false
    private(set) var minimumFacePixels = FaceIdentity.defaultMinimumFacePixels
    private(set) var isUpdatingFacePolicy = false
    var problem: String?
    var enabled: Bool {
        didSet {
            AppSettings.defaults.set(enabled, forKey: "peopleEnabled")
            engine.setPeople(enabled ? profiles : [])
            if !enabled { pause() } else { isPaused = false; scan() }
        }
    }
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var database: PeopleDatabase?
    @ObservationIgnored private let scanner = FaceHelper()
    @ObservationIgnored private let detector = FaceHelper()
    @ObservationIgnored private var activeReferenceImportID: UUID?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var facePolicyGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored var backgroundIndexingWaitReason: () -> String? = { nil }
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
        refreshGeneration += 1
        let generation = refreshGeneration
        let person = selectedPerson
        let allFaces = reviewingAllFaces
        do {
            let snapshot = try await database.snapshot(person: allFaces ? nil : person,
                                                       reconcile: !isAddingReferences && !isScanning,
                                                       selection: engine.faceSelection(), includePending: enabled)
            guard generation == refreshGeneration, selectedPerson == person,
                  reviewingAllFaces == allFaces else { return }
            profiles = snapshot.profiles
            // Removing the selected person, or loading for the first time, selects the next valid person.
            if !allFaces, !profiles.contains(where: { $0.id == person }), let first = profiles.first {
                selectedPerson = first.id
                await refresh()
                return
            }
            if profiles.isEmpty { selectedPerson = nil }
            reviews = snapshot.reviews
            references = snapshot.references
            pending = snapshot.pending; hasAvailablePending = snapshot.hasAvailablePending
            failedPhotos = snapshot.failedPhotos
            engine.setPeople(enabled ? profiles : [])
        } catch {
            guard generation == refreshGeneration else { return }
            problem = error.localizedDescription
        }
    }
    @discardableResult func save(id: Int64?, name: String, aliases: String) async -> Int64? {
        do {
            guard let database else {
                problem = "People search could not open its local database. Reopen Morrow and try again."
                return nil
            }
            let saved = try await database.save(id: id, name: name, aliases: aliases.split(separator: ",").map(String.init))
            selectedPerson = saved
            reviewingAllFaces = false
            await refresh()
            return saved
        } catch { problem = error.localizedDescription; return nil }
    }
    func candidates(_ photo: URL) async throws -> FacePhoto {
        detectionCount += 1
        defer { detectionCount -= 1 }
        // Enrollment gets priority over the background scan.
        return try await withTaskCancellationHandler {
            await scanner.cancelAndWait()
            try Task.checkCancellation()
            let data = try await detector.run(arguments: ["face-detect", "--photo", photo.path,
                "--face-model", modelPath, "--min-face-pixels", String(minimumFacePixels)])
            return try JSONDecoder().decode(FacePhoto.self, from: data)
        } onCancel: { detector.cancel() }
    }
    func beginReferenceImport(_ batchID: UUID) {
        activeReferenceImportID = batchID
        isAddingReferences = true
        waitingReason = nil
        scanProgress = nil
        scanner.cancel()
    }
    func endReferenceImport(_ batchID: UUID) {
        // A late onDisappear from a replaced picker must not stop a newer reference batch.
        guard activeReferenceImportID == batchID else { return }
        activeReferenceImportID = nil
        isAddingReferences = false
        // Cancel this import synchronously. A deferred detector.cancelAndWait() could run after another picker
        // opens and cancel that newer import, because both use the same detector helper.
        detector.cancel()
        scanner.cancel()
        Task {
            await scanner.cancelAndWait()
            guard activeReferenceImportID == nil else { return }
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
        do {
            try await database?.deletePerson(person)
            if selectedPerson == person { selectedPerson = nil }
            await refresh()
        }
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
        scanProgress = nil
        scanner.cancel()
        Task {
            await scanner.cancelAndWait()
            guard generation == facePolicyGeneration else { return }
            do {
                try await database?.setMinimumFacePixels(rounded)
                await refresh()
            } catch { problem = error.localizedDescription }
            guard generation == facePolicyGeneration else { return }
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
    func pause() { isPaused = true; waitingReason = nil; scanProgress = nil; scanner.cancel() }
    func foldersChanged() {
        scanProgress = nil
        scanner.cancel()
        Task {
            await scanner.cancelAndWait()
            await refresh()
            scan()
        }
    }
    func resume() { isPaused = false; scan() }
    func indexingStatusChanged() {
        if backgroundIndexingWaitReason() != nil { scanProgress = nil; scanner.cancel() }
        scan()
    }
    private var modelPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sface.onnx").path }
    private func updateScanProgress(done: Int, total: Int) {
        guard isScanning, !isPaused, !isAddingReferences, !isUpdatingFacePolicy, waitingReason == nil else { return }
        scanProgress = EngineStatus.Progress(done: done, total: total)
    }
    func scan() {
        let hasEnrolledPeople = profiles.contains(where: { $0.references > 0 })
        guard enabled, !isPaused, !isAddingReferences, !isUpdatingFacePolicy, hasEnrolledPeople else {
            waitingReason = nil
            return
        }
        guard pending > 0 else { waitingReason = nil; return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            waitingReason = "Waiting for Low Power Mode to turn off"
            scanProgress = nil
            scanner.cancel()
            return
        }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            waitingReason = "Waiting for the Mac to cool down"
            scanProgress = nil
            scanner.cancel()
            return
        }
        if let reason = backgroundIndexingWaitReason() {
            waitingReason = reason
            scanProgress = nil
            scanner.cancel()
            return
        }
        guard hasAvailablePending else {
            waitingReason = "Waiting for access to \(pending) photos"
            scanProgress = nil
            scanner.cancel()
            return
        }
        waitingReason = nil
        guard !isScanning, !isDetecting else { return }
        guard FileManager.default.fileExists(atPath: modelPath) else { problem = "The face model is missing from this app. Rebuild Morrow."; return }
        isScanning = true
        scanProgress = nil
        Task {
            defer { isScanning = false; scanProgress = nil }
            guard enabled, !isPaused, !isDetecting else { return }
            do {
                let selection = engine.faceSelection()
                _ = try await scanner.run(arguments: ["face-index", "--index", settings.indexDirectory.path,
                    "--face-model", modelPath, "--limit", "40", "--min-face-pixels", String(minimumFacePixels), "--selection",
                    String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)], onProgress: { done, total in
                        await self.updateScanProgress(done: done, total: total)
                    })
            } catch is CancellationError { }
            catch { if !isPaused && !isDetecting { problem = error.localizedDescription } }
            await refresh()
        }
    }
}
