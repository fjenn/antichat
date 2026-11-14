// M6.T08 step 2–3 (R-272 AC2, P-files-tools-03 residual): the C-level shim over the DuckDB Swift API. duckdb-swift keeps
// its `duckdb_connection` private, so the handle is read once with `Mirror` (pinned @095e449567: `Connection.ptr`,
// an `UnsafeMutablePointer<duckdb_connection?>`); with it the statement guard runs `duckdb_extract_statements` +
// `duckdb_prepared_statement_type`, and the 10 s timeout calls `duckdb_interrupt` on the query's dedicated connection
// (the interrupt path, not the connection-drop fallback). If a duckdb-swift bump renames the field, `cHandle` is nil
// and the guard fails closed (every query is rejected) — QueryDataToolTests catches it.
@_implementationOnly import Cduckdb
import DuckDB
import Foundation

enum DuckDBC {
    static func cHandle(_ c: Connection) -> duckdb_connection? {
        (Mirror(reflecting: c).descendant("ptr") as? UnsafeMutablePointer<duckdb_connection?>)?.pointee
    }

    enum Kind: Equatable { case select, other(Int), multiple(Int), parseError(String) }

    /// The statement types in `sql` (no execution). Only a single SELECT-type statement passes the guard: DuckDB
    /// plans WITH, SUMMARIZE, DESCRIBE, PIVOT and FROM-first queries as SELECT.
    static func kind(_ sql: String, on c: Connection) -> Kind {
        guard let conn = cHandle(c) else { return .parseError("internal: no DuckDB connection handle") }
        var extracted: duckdb_extracted_statements?
        defer { duckdb_destroy_extracted(&extracted) }
        let n = sql.withCString { duckdb_extract_statements(conn, $0, &extracted) }
        if n == 0 {
            let msg = duckdb_extract_statements_error(extracted).map { String(cString: $0) } ?? "could not parse the SQL"
            return .parseError(msg)
        }
        if n > 1 { return .multiple(Int(n)) }
        var prepared: duckdb_prepared_statement?
        defer { duckdb_destroy_prepare(&prepared) }
        guard duckdb_prepare_extracted_statement(conn, extracted, 0, &prepared) == DuckDBSuccess else {
            return .parseError(duckdb_prepare_error(prepared).map { String(cString: $0) } ?? "could not prepare the SQL")
        }
        let t = duckdb_prepared_statement_type(prepared)
        return t == DUCKDB_STATEMENT_TYPE_SELECT ? .select : .other(Int(t.rawValue))
    }

    static func interrupt(_ c: Connection) {
        if let conn = cHandle(c) { duckdb_interrupt(conn) }
    }
}
