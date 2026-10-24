#if os(macOS)
import Foundation
import DigUpKit
import FaceRuntime

/// Native face processing in an expendable helper. No Python or external service is needed by the app.
func faceService(_ command: String, raw: [String]) throws {
    func argument(_ flag: String) -> String? { raw.firstIndex(of: flag).flatMap { $0 + 1 < raw.count ? raw[$0+1] : nil } }
    guard let model = argument("--face-model") else { throw FaceError("Missing bundled face model") }
    let recognizer = try FaceRecognizer(model: URL(fileURLWithPath: model))
    if command == "face-detect" || command == "face-embed-aligned" {
        guard let path = argument("--photo") else { throw FaceError("Choose a reference photo") }
        let data: Data
        if command == "face-detect" { data = try JSONEncoder().encode(recognizer.detect(URL(fileURLWithPath: path))) }
        else { data = try JSONEncoder().encode(recognizer.embedAligned(URL(fileURLWithPath: path))) }
        FileHandle.standardOutput.write(data + Data([10]))
        return
    }
    guard let index = argument("--index") else { throw FaceError("Choose an index") }
    let store = try PeopleStore(directory: URL(fileURLWithPath: index))
    var pending = try store.pendingPhotos()
    if let raw = argument("--selection"), let data = raw.data(using: .utf8) {
        let selection = try JSONDecoder().decode([String: [String]].self, from: data)
        pending = pending.filter {
            FolderSelection.isSearched($0.1, folders: selection["roots"] ?? [], skipped: selection["excluded"] ?? [])
                && !(selection["types"] ?? []).contains((($0.1 as NSString).pathExtension).lowercased())
        }
    }
    let limit = argument("--limit").flatMap(Int.init) ?? pending.count
    for (offset, job) in pending.prefix(limit).enumerated() {
        autoreleasepool {
            do {
                let photo = try recognizer.detect(URL(fileURLWithPath: job.1))
                try store.saveFaces(file: job.0, stamp: job.2, samples: photo.faces)
            } catch {
                try? store.saveFaces(file: job.0, stamp: job.2, samples: [], error: error.localizedDescription)
            }
        }
        if offset % 20 == 0 { try store.rematch() }
        emit(["done": offset+1, "total": min(limit,pending.count)])
    }
    try store.rematch()
    emit(["complete": true, "done": min(limit,pending.count)])
}
#endif
