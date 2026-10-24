import Foundation

/// Identity embeddings have their own version and never enter Gemma's 768-D matrix.
public enum FaceIdentity {
    public static let version = "sface-2021dec-vision3-similarity3-1600-rgb112-v1"
    public static let dimension = 128
    public static func normalized(_ values: [Float]) throws -> [Float] {
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard values.count == dimension, values.allSatisfy(\.isFinite), norm.isFinite, norm > 0 else {
            throw Database.Failure(message: "Invalid face embedding")
        }
        return values.map { $0 / norm }
    }
    static func data(_ vector: [Float]) throws -> Data {
        let values = try normalized(vector)
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func vector(_ data: Data?) -> [Float]? {
        guard let data, data.count == dimension * 4 else { return nil }
        return data.withUnsafeBytes { bytes in (0..<dimension).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
    }
}

public struct FaceSample: Codable, Sendable, Identifiable {
    public var id: String
    public var box: [Double] // normalized top-left x, y, width, height
    public var vector: [Float]
    public var jpeg: Data
    public init(id: String = UUID().uuidString, box: [Double], vector: [Float], jpeg: Data) {
        self.id = id; self.box = box; self.vector = vector; self.jpeg = jpeg
    }
}

public struct FacePhoto: Codable, Sendable {
    public var faces: [FaceSample]
    public var width: Int
    public var height: Int
    public var seconds: Double
    public init(faces: [FaceSample], width: Int, height: Int, seconds: Double) {
        self.faces = faces; self.width = width; self.height = height; self.seconds = seconds
    }
}

public struct PersonProfile: Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let aliases: [String]
    public let references: Int
    public let files: Int
    public let portrait: Data?
}

public struct FaceReview: Identifiable, Sendable {
    public let id: Int64
    public let path: String
    public let jpeg: Data
    public let person: Int64?
    public let name: String?
    public let score: Double
    public let status: String
}

public struct PersonQuery: Sendable {
    public let people: [PersonProfile]
    public let remainder: String
    public let ambiguous: [String]
}

/// Confined to the caller's serial queue, like IndexStore. Curated records survive resetAll().
public final class PeopleStore {
    let store: IndexStore
    var db: Database { store.db }
    static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS people(id INTEGER PRIMARY KEY, name TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '[]');
        CREATE TABLE IF NOT EXISTS person_references(id INTEGER PRIMARY KEY, person INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
            vector BLOB NOT NULL, jpeg BLOB NOT NULL, source TEXT NOT NULL, model TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS references_person ON person_references(person);
        CREATE TABLE IF NOT EXISTS face_files(file INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            stamp TEXT NOT NULL, model TEXT NOT NULL, error TEXT);
        CREATE TABLE IF NOT EXISTS faces(id INTEGER PRIMARY KEY, file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            box TEXT NOT NULL, vector BLOB NOT NULL, jpeg BLOB NOT NULL, model TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS faces_file ON faces(file);
        CREATE TABLE IF NOT EXISTS face_matches(face INTEGER PRIMARY KEY REFERENCES faces(id) ON DELETE CASCADE,
            person INTEGER REFERENCES people(id) ON DELETE CASCADE, score REAL NOT NULL DEFAULT 0,
            status TEXT NOT NULL CHECK(status IN ('auto','suggested','confirmed','rejected')));
        CREATE INDEX IF NOT EXISTS matches_person ON face_matches(person, status);
        """
    public init(directory: URL) throws { store = try IndexStore(directory: directory) }
    public init(store: IndexStore) { self.store = store }

    public func profiles() throws -> [PersonProfile] {
        var profiles: [PersonProfile] = []
        try db.query("""
            SELECT p.id,p.name,p.aliases,(SELECT COUNT(*) FROM person_references r WHERE r.person=p.id),
            (SELECT COUNT(DISTINCT f.file) FROM faces f JOIN face_matches m ON m.face=f.id WHERE m.person=p.id AND m.status IN ('auto','confirmed')),
            (SELECT jpeg FROM person_references r WHERE r.person=p.id ORDER BY r.id LIMIT 1) FROM people p ORDER BY p.name COLLATE NOCASE
            """) { row in
            profiles.append(PersonProfile(id: row.int(0), name: row.text(1) ?? "", aliases: Self.strings(row.text(2)),
                                          references: Int(row.int(3)), files: Int(row.int(4)), portrait: row.blob(5)))
        }
        return profiles
    }
    @discardableResult public func savePerson(id: Int64? = nil, name: String, aliases: [String]) throws -> Int64 {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Database.Failure(message: "Give this person a name") }
        let aliases = Array(Set(aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let json = String(decoding: try JSONEncoder().encode(aliases), as: UTF8.self)
        if let id {
            try db.run("UPDATE people SET name=?,aliases=? WHERE id=?", [.text(name), .text(json), .int(id)])
            return id
        }
        try db.run("INSERT INTO people(name,aliases) VALUES(?,?)", [.text(name), .text(json)])
        return db.lastInsertID
    }
    public func deletePerson(_ id: Int64) throws { try db.run("DELETE FROM people WHERE id=?", [.int(id)]) }
    public func addReference(person: Int64, sample: FaceSample, source: String) throws {
        try db.run("INSERT INTO person_references(person,vector,jpeg,source,model) VALUES(?,?,?,?,?)",
                   [.int(person), .blob(try FaceIdentity.data(sample.vector)), .blob(sample.jpeg), .text(source), .text(FaceIdentity.version)])
    }
    public func references(person: Int64) throws -> [(Int64, Data)] {
        var rows: [(Int64, Data)] = []
        try db.query("SELECT id,jpeg FROM person_references WHERE person=? ORDER BY id", [.int(person)]) {
            if let data = $0.blob(1) { rows.append(($0.int(0), data)) }
        }
        return rows
    }
    public func deleteReference(_ id: Int64) throws { try db.run("DELETE FROM person_references WHERE id=?", [.int(id)]) }
    public func pendingPhotos() throws -> [(Int64, String, String)] {
        var rows: [(Int64, String, String)] = []
        try db.query("""
            SELECT f.id,f.path,CAST(f.size AS TEXT)||':'||CAST(f.mtime AS TEXT) FROM files f
            LEFT JOIN face_files d ON d.file=f.id WHERE f.kind IN ('image','screenshot')
            AND (d.file IS NULL OR d.stamp != CAST(f.size AS TEXT)||':'||CAST(f.mtime AS TEXT) OR d.model != ?)
            ORDER BY f.mtime DESC
            """, [.text(FaceIdentity.version)]) { rows.append(($0.int(0), $0.text(1) ?? "", $0.text(2) ?? "")) }
        return rows
    }
    public func saveFaces(file: Int64, stamp: String, samples: [FaceSample], error: String? = nil) throws {
        try db.transaction {
            // A helper may be processing a photo while the crawler updates or deletes it.
            var current: String?
            try db.query("SELECT CAST(size AS TEXT)||':'||CAST(mtime AS TEXT) FROM files WHERE id=?", [.int(file)]) { current = $0.text(0) }
            guard current == stamp else { return }
            var alreadySaved = false
            try db.query("SELECT 1 FROM face_files WHERE file=? AND stamp=? AND model=?",
                         [.int(file), .text(stamp), .text(FaceIdentity.version)]) { _ in alreadySaved = true }
            guard !alreadySaved else { return }
            try db.run("DELETE FROM faces WHERE file=?", [.int(file)])
            for sample in samples {
                try db.run("INSERT INTO faces(file,box,vector,jpeg,model) VALUES(?,?,?,?,?)", [.int(file),
                    .text(String(decoding: try JSONEncoder().encode(sample.box), as: UTF8.self)),
                    .blob(try FaceIdentity.data(sample.vector)), .blob(sample.jpeg), .text(FaceIdentity.version)])
            }
            try db.run("INSERT OR REPLACE INTO face_files(file,stamp,model,error) VALUES(?,?,?,?)",
                       [.int(file), .text(stamp), .text(FaceIdentity.version), .optional(error)])
        }
    }

    /// Conservative defaults; uncertain faces remain reviewable and never enter automatic person search.
    public func rematch() throws {
        var references: [Int64: [[Float]]] = [:]
        try db.query("SELECT person,vector FROM person_references WHERE model=?", [.text(FaceIdentity.version)]) {
            if let vector = FaceIdentity.vector($0.blob(1)) { references[$0.int(0), default: []].append(vector) }
        }
        var matches: [(Int64, Int64?, Double, String)] = []
        try db.query("""
            SELECT f.id,f.vector FROM faces f LEFT JOIN face_matches m ON m.face=f.id
            WHERE f.model=? AND (m.status IS NULL OR m.status IN ('auto','suggested'))
            """, [.text(FaceIdentity.version)]) { row in
            guard let vector = FaceIdentity.vector(row.blob(1)) else { return }
            var scores: [(Int64, Float)] = []
            for (person, samples) in references {
                var best: Float = -1
                for sample in samples {
                    var dot: Float = 0
                    for i in 0..<FaceIdentity.dimension { dot += vector[i] * sample[i] }
                    best = max(best, dot)
                }
                scores.append((person,best))
            }
            scores.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            let best = scores.first
            let margin = (best?.1 ?? 0) - (scores.dropFirst().first?.1 ?? -1)
            let status = (best?.1 ?? -1) >= 0.50 && margin >= 0.08 ? "auto" : "suggested"
            matches.append((row.int(0), (best?.1 ?? -1) >= 0.35 ? best?.0 : nil, Double(best?.1 ?? 0), status))
        }
        try db.transaction {
            for (face, person, score, status) in matches {
                try db.run("""
                    INSERT INTO face_matches(face,person,score,status) VALUES(?,?,?,?)
                    ON CONFLICT(face) DO UPDATE SET person=excluded.person,score=excluded.score,status=excluded.status
                    WHERE face_matches.status IN ('auto','suggested')
                    """,
                           [.int(face), person.map(SQLValue.int) ?? .null, .double(score), .text(status)])
            }
        }
    }
    public func review(person: Int64? = nil, limit: Int = 100) throws -> [FaceReview] {
        var rows: [FaceReview] = []
        let clause = person == nil ? "WHERE COALESCE(m.status,'suggested') IN ('auto','suggested')" : "WHERE m.person=?"
        try db.query("""
            SELECT f.id,s.path,f.jpeg,m.person,p.name,COALESCE(m.score,0),COALESCE(m.status,'suggested')
            FROM faces f JOIN files s ON s.id=f.file LEFT JOIN face_matches m ON m.face=f.id LEFT JOIN people p ON p.id=m.person
            \(clause) ORDER BY CASE m.status WHEN 'suggested' THEN 0 WHEN 'auto' THEN 1 ELSE 2 END,f.id DESC LIMIT ?
            """, (person.map { [SQLValue.int($0)] } ?? []) + [.int(Int64(limit))]) { row in
            rows.append(FaceReview(id: row.int(0), path: row.text(1) ?? "", jpeg: row.blob(2) ?? Data(),
                person: row.isNull(3) ? nil : row.int(3), name: row.text(4), score: row.double(5), status: row.text(6) ?? "suggested"))
        }
        return rows
    }
    public func confirm(face: Int64, person: Int64?) throws {
        try db.run("INSERT OR REPLACE INTO face_matches(face,person,score,status) VALUES(?,?,1,?)",
                   [.int(face), person.map(SQLValue.int) ?? .null, .text(person == nil ? "rejected" : "confirmed")])
    }
    public func fileIDs(for people: [Int64]) throws -> Set<Int64> {
        guard !people.isEmpty else { return [] }
        var sets: [Set<Int64>] = []
        for person in people {
            var files = Set<Int64>()
            try db.query("""
                SELECT DISTINCT f.file FROM faces f JOIN face_matches m ON m.face=f.id JOIN files s ON s.id=f.file
                JOIN face_files d ON d.file=f.file WHERE m.person=? AND m.status IN ('auto','confirmed')
                AND d.stamp=CAST(s.size AS TEXT)||':'||CAST(s.mtime AS TEXT) AND f.model=?
                """, [.int(person), .text(FaceIdentity.version)]) { files.insert($0.int(0)) }
            // Names in extracted document/audio text are searchable evidence, distinct from face matches.
            // Do not use photo folder names: evaluation labels and album names are not face evidence.
            var aliases: [String] = []
            try db.query("SELECT name,aliases FROM people WHERE id=?", [.int(person)]) {
                aliases = [$0.text(0) ?? ""] + Self.strings($0.text(1))
            }
            let pattern = aliases.filter { !$0.isEmpty }.map { "\"" + SearchText.normalized($0).replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
            if !pattern.isEmpty {
                try db.query("""
                    SELECT DISTINCT s.file FROM fts JOIN segments s ON s.id=fts.rowid JOIN files f ON f.id=s.file
                    WHERE fts MATCH ? AND s.kind != 'name' AND f.kind IN ('pdf','doc','audio')
                    """, [.text(pattern)]) { files.insert($0.int(0)) }
            }
            sets.append(files)
        }
        return sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }
    }
    public func resolve(_ query: String) throws -> PersonQuery {
        Self.resolve(query, profiles: try profiles())
    }
    public static func resolve(_ query: String, profiles: [PersonProfile]) -> PersonQuery {
        let tokens = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var owners: [String: [PersonProfile]] = [:]
        for profile in profiles {
            for alias in Set([profile.name] + profile.aliases) { owners[alias.lowercased(), default: []].append(profile) }
        }
        var found: [Int64: PersonProfile] = [:], used = Set<Int>(), ambiguous = Set<String>()
        // Longer aliases first; word boundaries prevent "Ann" matching "annual".
        for alias in owners.keys.sorted(by: { $0.count > $1.count }) {
            let parts = alias.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }
            guard !parts.isEmpty, parts.count <= tokens.count else { continue }
            for start in 0...(tokens.count - parts.count) {
                let range = start..<(start + parts.count)
                guard range.allSatisfy({ !used.contains($0) }), range.map({ tokens[$0].lowercased() }) == parts else { continue }
                let choices = Dictionary(owners[alias, default: []].map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                guard choices.count == 1, let person = choices.values.first else { ambiguous.insert(alias); continue }
                found[person.id] = person; used.formUnion(range)
            }
        }
        let filler: Set<String> = ["and", "with", "of", "photos", "photo", "pictures", "picture", "show", "me", "find"]
        let rest = tokens.indices.filter { !used.contains($0) }.map { tokens[$0] }
        let remainder = found.isEmpty ? query : rest.filter { !filler.contains($0.lowercased()) }.joined(separator: " ")
        return PersonQuery(people: found.values.sorted { $0.id < $1.id }, remainder: remainder, ambiguous: ambiguous.sorted())
    }
    static func strings(_ json: String?) -> [String] {
        json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }
}
