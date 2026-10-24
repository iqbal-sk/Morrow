#if os(macOS)
import Foundation
import DigUpKit
import FaceRuntime

/// Native face processing in an expendable helper. No Python or external service is needed by the app.
func faceService(_ command: String, raw: [String]) throws {
    func argument(_ flag: String) -> String? { raw.firstIndex(of: flag).flatMap { $0 + 1 < raw.count ? raw[$0+1] : nil } }
    guard let model = argument("--face-model") else { throw FaceError("Missing bundled face model") }
    if command == "face-detect" || command == "face-embed-aligned" {
        guard let path = argument("--photo") else { throw FaceError("Choose a reference photo") }
        let recognizer = try FaceRecognizer(model: URL(fileURLWithPath: model))
        let data: Data
        if command == "face-detect" {
            let minimum = argument("--min-face-pixels").flatMap(Int.init) ?? FaceIdentity.defaultMinimumFacePixels
            data = try JSONEncoder().encode(recognizer.detect(URL(fileURLWithPath: path), minimumFacePixels: minimum))
        }
        else { data = try JSONEncoder().encode(recognizer.embedAligned(URL(fileURLWithPath: path))) }
        FileHandle.standardOutput.write(data + Data([10]))
        return
    }
    guard let index = argument("--index") else { throw FaceError("Choose an index") }
    let store = try PeopleStore(directory: URL(fileURLWithPath: index))
    let minimumFacePixels = try store.minimumFacePixels()
    var pending: [(Int64, String, String)]
    if let raw = argument("--selection"), let data = raw.data(using: .utf8) {
        let selection = try JSONDecoder().decode(FacePhotoSelection.self, from: data)
        // Leave ejected or unreadable paths pending so they can be processed when access returns.
        pending = selection.filterPending(try store.pendingPhotos(selection: selection),
                                          isReadable: FileManager.default.isReadableFile(atPath:))
    } else {
        pending = try store.pendingPhotos().filter { FileManager.default.isReadableFile(atPath: $0.1) }
    }
    let limit = max(0, argument("--limit").flatMap(Int.init) ?? pending.count)
    guard !pending.isEmpty, limit > 0 else {
        try store.rematchIfNeeded()
        emit(["complete": true, "done": 0, "total": 0])
        return
    }
    // Avoid loading the ONNX session when every queued path was excluded or unavailable.
    let recognizer = try FaceRecognizer(model: URL(fileURLWithPath: model))
    for (offset, job) in pending.prefix(limit).enumerated() {
        autoreleasepool {
            do {
                let photo = try recognizer.detect(URL(fileURLWithPath: job.1), minimumFacePixels: minimumFacePixels)
                try store.saveFaces(file: job.0, stamp: job.2, samples: photo.faces, minimumFacePixels: minimumFacePixels)
            } catch {
                if FileManager.default.isReadableFile(atPath: job.1) {
                    try? store.saveFaces(file: job.0, stamp: job.2, samples: [], minimumFacePixels: minimumFacePixels,
                                         error: error.localizedDescription)
                }
            }
        }
        emit(["done": offset+1, "total": min(limit,pending.count)])
    }
    try store.rematchIfNeeded()
    emit(["complete": true, "done": min(limit,pending.count)])
}
#endif
