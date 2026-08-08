import Foundation
import SQLite3

/// SQLite's own `SQLITE_TRANSIENT`, which the C macro hides from Swift. Tells
/// SQLite to copy a bound string rather than borrow it — without it a Swift
/// string's buffer can be freed before the statement runs.
private let transientText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Facts that survive relaunch, in `~/.jarvis/memory.sqlite`.
///
/// Deviates from the spec's GRDB + FTS5: FTS5 is here, GRDB is not. Every local
/// package is deliberately dependency-free — that is what lets `scripts/test.sh`
/// fall back to the Command Line Tools toolchain when the Xcode licence lapses —
/// and macOS's system SQLite already carries FTS5. Adding a package for the
/// wrapper would cost that property to save a few dozen lines of C interop.
public actor SQLiteMemoryStore: MemoryStore {
    public enum StoreError: Error, Equatable {
        case cannotOpen(String)
        case sql(String)
    }

    /// Owns the sqlite3 handle purely so it can be closed when the store goes
    /// away. Under Swift 6 an actor's `deinit` is nonisolated and cannot touch
    /// the actor's own non-Sendable state, so the pointer lives one level down
    /// in a class that closes it in its own deinit.
    private final class Connection {
        let handle: OpaquePointer
        init(handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }

    private let connection: Connection
    private var handle: OpaquePointer { connection.handle }

    /// A single FTS5 table rather than a table plus an external-content index.
    /// External content needs triggers to stay in step with its base table, and
    /// a memory that silently stops matching what it contains is worse than one
    /// that ranks slightly less well.
    private static let schema = """
        CREATE VIRTUAL TABLE IF NOT EXISTS facts USING fts5(
            id UNINDEXED,
            text,
            category UNINDEXED,
            created_at UNINDEXED
        );
        """

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
    }

    /// Pass `nil` for a private in-memory database — used by the tests, and a
    /// safe default for anything that must not touch the user's real memory.
    public init(url: URL? = defaultURL) throws {
        let path: String
        if let url {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            path = url.path
        } else {
            path = ":memory:"
        }

        var opened: OpaquePointer?
        guard sqlite3_open(path, &opened) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(opened)
            throw StoreError.cannotOpen(message)
        }
        self.connection = Connection(handle: opened)

        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(opened, Self.schema, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.sql(message)
        }
    }

    public func remember(_ fact: Fact) async throws {
        try run(
            "INSERT INTO facts (id, text, category, created_at) VALUES (?, ?, ?, ?);",
            bind: [
                .text(fact.id.uuidString),
                .text(fact.text),
                .text(fact.category),
                .double(fact.createdAt.timeIntervalSince1970),
            ]
        )
    }

    public func forget(id: UUID) async throws {
        try run("DELETE FROM facts WHERE id = ?;", bind: [.text(id.uuidString)])
    }

    public func allFacts() async throws -> [Fact] {
        try query("SELECT id, text, category, created_at FROM facts ORDER BY created_at DESC;")
    }

    public func recall(matching query: String, limit: Int = 10) async throws -> [Fact] {
        guard let expression = Self.matchExpression(for: query) else { return [] }
        // bm25 returns a smaller number for a better match, so ascending.
        return try self.query(
            """
            SELECT id, text, category, created_at FROM facts
            WHERE facts MATCH ? ORDER BY bm25(facts) LIMIT ?;
            """,
            bind: [.text(expression), .int(limit)]
        )
    }

    /// Rewrites free text into an FTS5 match expression.
    ///
    /// Necessary, not cosmetic: FTS5's query language treats bare `AND`, `OR`,
    /// `NOT`, `NEAR`, `*`, `:` and quotes as syntax, so a spoken sentence like
    /// "what did I say about dad's car?" is a syntax error rather than a
    /// search. Each word is extracted and quoted as a literal term, and the
    /// terms are OR-ed so a partial match still recalls something.
    static func matchExpression(for query: String) -> String? {
        let terms = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0)\"" }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    // MARK: SQLite plumbing

    private enum Binding {
        case text(String)
        case double(Double)
        case int(Int)
    }

    private var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func prepare(_ sql: String, bind bindings: [Binding]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.sql(lastErrorMessage)
        }
        for (index, binding) in bindings.enumerated() {
            let column = Int32(index + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(statement, column, value, -1, transientText)
            case .double(let value): sqlite3_bind_double(statement, column, value)
            case .int(let value): sqlite3_bind_int64(statement, column, Int64(value))
            }
        }
        return statement
    }

    private func run(_ sql: String, bind bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bind: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sql(lastErrorMessage)
        }
    }

    private func query(_ sql: String, bind bindings: [Binding] = []) throws -> [Fact] {
        let statement = try prepare(sql, bind: bindings)
        defer { sqlite3_finalize(statement) }

        var facts: [Fact] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: idText)),
                  let text = sqlite3_column_text(statement, 1),
                  let category = sqlite3_column_text(statement, 2)
            else { continue }
            facts.append(Fact(
                id: id,
                text: String(cString: text),
                category: String(cString: category),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return facts
    }
}
