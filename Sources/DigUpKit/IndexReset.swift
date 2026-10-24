import Foundation

/// Deletes file-derived rows from both indexes while keeping people and their reference photos.
public enum IndexReset {
    /// Removes every indexed file under the requested scopes. A `nil` scope means the whole index and supersedes
    /// narrower scopes in the same request batch.
    @discardableResult
    public static func delete(in directory: URL, scopes: [String?]) throws -> Int {
        guard !scopes.isEmpty else { return 0 }
        let normalizedScopes: [String?]
        if scopes.contains(where: { $0 == nil }) {
            normalizedScopes = [nil]
        } else {
            normalizedScopes = Array(Set(scopes.compactMap { $0 })).sorted().map(Optional.some)
        }

        let main = try IndexStore(directory: directory)
        var removed = 0
        for scope in normalizedScopes { removed += try main.deleteIndexedFiles(under: scope) }

        let codeFile = directory.appendingPathComponent(IndexStore.codeFile)
        if FileManager.default.fileExists(atPath: codeFile.path) {
            let code = try IndexStore(directory: directory, file: IndexStore.codeFile)
            for scope in normalizedScopes { removed += try code.deleteIndexedFiles(under: scope) }
        }
        return removed
    }
}
