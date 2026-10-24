import Foundation

extension IndexStore {
    /// File identifiers for a folder scope, applied before search ranking and its result limit.
    public func libraryFileIDs(under roots: [String]) throws -> Set<Int64> {
        let ranges = roots.flatMap(Self.pathRanges(under:))
        guard !ranges.isEmpty else { return [] }
        let predicate = ranges.map { _ in "(path >= ? AND path < ?)" }.joined(separator: " OR ")
        let values = ranges.flatMap { [SQLValue.text($0.from), .text($0.to)] }
        var ids = Set<Int64>()
        try db.query("SELECT id FROM files WHERE \(predicate)", values) { ids.insert($0.int(0)) }
        return ids
    }

    /// Recently modified searchable files. Does not run an embedding model or duplicate indexed data.
    public func libraryFiles(under roots: [String], excluded: [String] = [], excludedTypes: Set<String> = [],
                             kinds: Set<FileKind>? = nil, limit: Int = 120) throws -> [SearchHit] {
        let ranges = roots.flatMap(Self.pathRanges(under:))
        guard !ranges.isEmpty, limit > 0 else { return [] }
        var predicate = ranges.map { _ in "(path >= ? AND path < ?)" }.joined(separator: " OR ")
        var values = ranges.flatMap { [SQLValue.text($0.from), .text($0.to)] }
        predicate = "(" + predicate + ") AND state IN ('done','partial')"
        if let kinds {
            guard !kinds.isEmpty else { return [] }
            let ordered = kinds.map(\.rawValue).sorted()
            predicate += " AND kind IN (" + ordered.map { _ in "?" }.joined(separator: ",") + ")"
            values += ordered.map(SQLValue.text)
        }
        // Filter before applying the visible limit so skipped/missing files cannot hide valid later rows.
        var hits: [SearchHit] = []
        let statement = try Statement(db, "SELECT path,kind,mtime,size,info FROM files WHERE \(predicate) ORDER BY mtime DESC,path ASC")
        try statement.bind(values)
        while hits.count < min(limit, 240), try statement.step() {
            let path = statement.text(0) ?? ""
            guard FolderSelection.isSearched(path, folders: roots, skipped: excluded),
                  !excludedTypes.contains((path as NSString).pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: path) else { continue }
            let info = statement.text(4)?.data(using: .utf8).flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: String]
            } ?? [:]
            hits.append(SearchHit(path: path, kind: FileKind(rawValue: statement.text(1) ?? "") ?? .doc,
                                  score: 0, z: nil, cosine: nil, keywordRank: nil, segment: .name,
                                  segmentID: 0, loc: nil, locEnd: nil, excerpt: nil,
                                  modified: statement.double(2), size: statement.int(3), info: info))
        }
        return hits
    }
}
