import Darwin
import Foundation
import SQLite3

/// Cheap descriptor facts used to decide whether a persisted revision can be
/// reused without reopening PDFKit.
struct PDFIndexQuickIdentity: Equatable, Sendable {
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let deviceID: UInt64
    let inode: UInt64

    init(metadata: RegularFileMetadata) {
        byteCount = Int64(metadata.byteCount)
        let interval = metadata.modificationDate?.timeIntervalSince1970 ?? 0
        modificationSeconds = Int64(interval.rounded(.down))
        modificationNanoseconds = metadata.modificationNanoseconds ?? Int64(
            (interval - interval.rounded(.down)) * 1_000_000_000
        )
        changeSeconds = metadata.changeSeconds ?? 0
        changeNanoseconds = metadata.changeNanoseconds ?? 0
        deviceID = metadata.deviceID ?? 0
        inode = metadata.inode ?? 0
    }
}

/// Persisted document metadata and extraction status for one PDF revision.
struct PDFIndexDocumentRecord: Sendable {
    let id: Int64
    let path: String
    let revision: String
    let quickIdentity: PDFIndexQuickIdentity
    let title: String
    let titleTruncated: Bool
    let pageCount: Int
    let status: PDFTextExtractionStatus
    let indexedPageCount: Int
}

/// Byte- and count-bounded page candidates hydrated from one scoped query.
struct PDFIndexCandidateBatch: Sendable {
    let pagesByDocument: [Int64: [PDFIndexCandidatePage]]
    let limited: Bool
    let pageCount: Int
    let textBytes: Int
}

/// Fuzzy vocabulary rows plus the bounded SQLite work consumed to find them.
struct PDFIndexVocabularyBatch: Sendable {
    let terms: [String]
    let limited: Bool
    let workCallbacks: Int
}

private final class SQLiteProgressState: @unchecked Sendable {
    private(set) var workExhausted = false
    private(set) var callbacksConsumed = 0
    private var remainingCallbacks: Int?

    func begin(maximumCallbacks: Int) {
        remainingCallbacks = max(maximumCallbacks, 0)
        workExhausted = false
        callbacksConsumed = 0
    }

    func end() {
        remainingCallbacks = nil
        workExhausted = false
    }

    func shouldInterrupt() -> Bool {
        if currentTaskIsCancelled() { return true }
        guard let remainingCallbacks else { return false }
        guard remainingCallbacks > 0 else {
            workExhausted = true
            return true
        }
        self.remainingCallbacks = remainingCallbacks - 1
        callbacksConsumed += 1
        return false
    }
}

/// Actor-isolated SQLite adapter. Callers must never share an instance across
/// actors or threads.
final class PDFSearchIndexDatabase {
    struct DatabaseError: Error, CustomStringConvertible {
        let operation: String
        let message: String
        let code: Int32?

        init(operation: String, message: String, code: Int32? = nil) {
            self.operation = operation
            self.message = message
            self.code = code
        }

        var description: String { "PDF search index \(operation) failed: \(message)" }

        var permitsDerivedIndexRebuild: Bool {
            let primaryCode = code.map { $0 & 0xFF }
            return operation == "schema" || operation == "integrity"
                || operation == "quota"
                || primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB
        }

        var isStorageFull: Bool { code.map { $0 & 0xFF } == SQLITE_FULL }
    }

    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
    private static let applicationID = 0x5342_5044 // "SBPD"
    private static let maximumWarmSchemaObjects = 64
    private static let maximumWarmIndexesPerTable = 32
    private static let maximumWarmIndexColumns = 16
    private static let maximumWarmSchemaSQLBytes = 64 * 1_024

    private let canonicalURL: URL
    private let progressState = SQLiteProgressState()
    private let statementPreparationObserver: (() -> Void)?
    private let exhaustiveIntegrityObserver: (() -> Void)?
    private let forceExhaustiveIntegrity: Bool
    private let maximumBundleBytes: Int64
    private let maximumMainDatabaseBytes: Int64
    private let sidecarReserveBytes: Int64
    private let maximumPublicationRepresentationBytes: Int
    private let peakBundleByteObserver: ((Int64) -> Void)?
    private var handle: OpaquePointer?
    private var openedDeviceID: UInt64 = 0
    private var openedInode: UInt64 = 0

    init(
        url: URL,
        maximumDatabaseBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
        statementPreparationObserver: (() -> Void)? = nil,
        exhaustiveIntegrityObserver: (() -> Void)? = nil,
        forceExhaustiveIntegrity: Bool = false,
        maximumPublicationRepresentationBytes: Int =
            PDFIndexExtractor.Configuration.production.retainedRepresentationByteLimit,
        peakBundleByteObserver: ((Int64) -> Void)? = nil
    ) throws {
        // Resolve only the trusted private parent. Resolving the final
        // component would follow an attacker-controlled database symlink and
        // defeat SQLITE_OPEN_NOFOLLOW. System aliases such as /var ->
        // /private/var are safe to canonicalize at the parent boundary.
        let canonicalURL = try Self.resolvingRootOwnedAlias(url.standardized)
        self.canonicalURL = canonicalURL
        self.statementPreparationObserver = statementPreparationObserver
        self.exhaustiveIntegrityObserver = exhaustiveIntegrityObserver
        self.forceExhaustiveIntegrity = forceExhaustiveIntegrity
        self.maximumPublicationRepresentationBytes = max(
            maximumPublicationRepresentationBytes,
            0
        )
        self.peakBundleByteObserver = peakBundleByteObserver
        let maximumBundleBytes = max(maximumDatabaseBytes, 0)
        self.maximumBundleBytes = maximumBundleBytes
        // A WAL transaction may temporarily retain changed versions of every
        // database page next to the main file. Keep the main database to one
        // third of the aggregate ceiling; the remaining two thirds cover WAL
        // frames, the WAL index, frame headers, and conservative publication
        // growth. Per-transaction preflight below applies the tighter bound
        // derived from the actual publication payload.
        let maximumMainDatabaseBytes = maximumBundleBytes / 3
        let sidecarReserve = maximumBundleBytes - maximumMainDatabaseBytes
        self.sidecarReserveBytes = sidecarReserve
        self.maximumMainDatabaseBytes = maximumMainDatabaseBytes
        try Self.validateDatabasePath(canonicalURL)
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            canonicalURL.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let detail = opened
                .flatMap { sqlite3_errmsg($0) }
                .map(String.init(cString:)) ?? "SQLite code \(result)"
            if let opened { sqlite3_close(opened) }
            throw DatabaseError(
                operation: "open",
                message: "\(detail) (code \(result))",
                code: result
            )
        }
        handle = opened
        sqlite3_progress_handler(
            opened,
            1_000,
            { context in
                guard let context else { return 0 }
                let state = Unmanaged<SQLiteProgressState>
                    .fromOpaque(context).takeUnretainedValue()
                return state.shouldInterrupt() ? 1 : 0
            },
            Unmanaged.passUnretained(progressState).toOpaque()
        )
        do {
            try execute("PRAGMA trusted_schema=OFF")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA busy_timeout=5000")
            let pageSize = max(try scalarInt("PRAGMA page_size"), 1)
            let pageCount = max(try scalarInt("PRAGMA page_count"), 0)
            guard Int64(pageSize) * Int64(pageCount) <= maximumMainDatabaseBytes else {
                throw DatabaseError(
                    operation: "quota",
                    message: "existing index exceeds its private size ceiling"
                )
            }
            let maximumPageCount = Int(min(
                maximumMainDatabaseBytes / Int64(pageSize),
                Int64(Int.max)
            ))
            guard maximumPageCount > 0, maximumPageCount >= pageCount else {
                throw DatabaseError(
                    operation: "quota",
                    message: "existing index leaves no room for private sidecars"
                )
            }

            switch try schemaDisposition() {
            case .new:
                _ = try scalarInt("PRAGMA max_page_count=\(maximumPageCount)")
                try execute("PRAGMA journal_mode=WAL")
                try configureWAL(pageSize: pageSize)
                try createNewSchema()
                try validateExhaustiveIntegrity()
            case .warm:
                // Warm validation is deliberately read-only: no schema DDL,
                // metadata insertion, header assignment, or FTS maintenance.
                // The derived bundle is rebuilt if any required object is absent.
                try validateWarmSchema()
                guard try scalarText("PRAGMA journal_mode").lowercased() == "wal" else {
                    throw DatabaseError(
                        operation: "schema",
                        message: "derived cache does not use the required WAL protocol"
                    )
                }
                _ = try scalarInt("PRAGMA max_page_count=\(maximumPageCount)")
                try configureWAL(pageSize: pageSize)
                if forceExhaustiveIntegrity {
                    try validateExhaustiveIntegrity()
                }
            }
            try checkpointWAL()
            try ensureBundleWithinQuota(
                operation: "quota",
                code: nil
            )
            try Self.hardenDatabaseFiles(canonicalURL)
            var identity = stat()
            guard Darwin.lstat(canonicalURL.path, &identity) == 0,
                  identity.st_mode & S_IFMT == S_IFREG else {
                throw DatabaseError(
                    operation: "validate file",
                    message: "derived index was replaced while opening"
                )
            }
            openedDeviceID = UInt64(identity.st_dev)
            openedInode = UInt64(identity.st_ino)
        } catch {
            sqlite3_close(opened)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    /// True only while the canonical path still names the inode opened by this
    /// adapter. Callers hold the cross-process recovery lock around this check
    /// and every subsequent operation.
    func isCurrentFile() -> Bool {
        var identity = stat()
        return Darwin.lstat(canonicalURL.path, &identity) == 0
            && identity.st_mode & S_IFMT == S_IFREG
            && UInt64(identity.st_dev) == openedDeviceID
            && UInt64(identity.st_ino) == openedInode
    }

    func record(path: String) throws -> PDFIndexDocumentRecord? {
        let statement = try prepare(documentRecordSQL + " WHERE path=?1")
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, to: statement)
        let recordStep = sqlite3_step(statement)
        if recordStep == SQLITE_DONE { return nil }
        guard recordStep == SQLITE_ROW else { throw error("read document") }
        return decodedRecord(statement)
    }

    /// Loads the complete current scope with one prepared query. Invalidated
    /// contract rows are omitted so callers refresh them like cache misses.
    func records(paths: [String]) throws -> [String: PDFIndexDocumentRecord] {
        guard !paths.isEmpty else { return [:] }
        let placeholders = paths.indices.map { "?\($0 + 1)" }.joined(separator: ",")
        let statement = try prepare(documentRecordSQL + " WHERE path IN (\(placeholders))")
        defer { sqlite3_finalize(statement) }
        for (index, path) in paths.enumerated() {
            try bind(path, at: Int32(index + 1), to: statement)
        }
        var result: [String: PDFIndexDocumentRecord] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error("read documents") }
            try Task.checkCancellation()
            if let record = decodedRecord(statement) {
                result[record.path] = record
            }
        }
        return result
    }

    private var documentRecordSQL: String {
        """
        SELECT id,path,content_sha256,byte_count,mtime_sec,mtime_nsec,
               ctime_sec,ctime_nsec,device_id,inode,title,page_count,status,
               indexed_page_count,title_truncated,extractor_version,normalizer_version,
               classifier_version,sensitive_policy_version
          FROM pdf_document
        """
    }

    private func decodedRecord(
        _ statement: OpaquePointer
    ) -> PDFIndexDocumentRecord? {
        let contractMatches = int(statement, 15) == PDFSearchIndexContract.extractorVersion
            && int(statement, 16) == PDFSearchIndexContract.normalizerVersion
            && int(statement, 17) == PDFSearchIndexContract.classifierVersion
            && int(statement, 18) == PDFSearchIndexContract.sensitivePolicyVersion
        guard contractMatches,
              let status = PDFTextExtractionStatus(rawValue: text(statement, 12)) else {
            return nil
        }
        return PDFIndexDocumentRecord(
            id: sqlite3_column_int64(statement, 0),
            path: text(statement, 1),
            revision: text(statement, 2),
            quickIdentity: PDFIndexQuickIdentity(
                byteCount: sqlite3_column_int64(statement, 3),
                modificationSeconds: sqlite3_column_int64(statement, 4),
                modificationNanoseconds: sqlite3_column_int64(statement, 5),
                changeSeconds: sqlite3_column_int64(statement, 6),
                changeNanoseconds: sqlite3_column_int64(statement, 7),
                deviceID: UInt64(bitPattern: sqlite3_column_int64(statement, 8)),
                inode: UInt64(bitPattern: sqlite3_column_int64(statement, 9))
            ),
            title: text(statement, 10),
            titleTruncated: int(statement, 14) != 0,
            pageCount: int(statement, 11),
            status: status,
            indexedPageCount: int(statement, 13)
        )
    }

    func generation() throws -> Int {
        try scalarInt("SELECT generation FROM index_meta WHERE id=1")
    }

    func publish(
        path: String,
        revision: String,
        quickIdentity: PDFIndexQuickIdentity,
        extraction: IndexedPDFExtraction
    ) throws -> PDFIndexDocumentRecord {
        try withBundleTransactionEnvelope(
            operation: "publish",
            preflight: {
                try preflightPublication(
                    path: path,
                    revision: revision,
                    extraction: extraction
                )
            }
        ) {
                let upsert = try prepare("""
                INSERT INTO pdf_document(
                  path,content_sha256,byte_count,mtime_sec,mtime_nsec,ctime_sec,
                  ctime_nsec,device_id,inode,title,page_count,status,indexed_page_count,
                  title_truncated,extractor_version,normalizer_version,classifier_version,
                  sensitive_policy_version
                ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)
                ON CONFLICT(path) DO UPDATE SET
                  content_sha256=excluded.content_sha256,
                  byte_count=excluded.byte_count,mtime_sec=excluded.mtime_sec,
                  mtime_nsec=excluded.mtime_nsec,ctime_sec=excluded.ctime_sec,
                  ctime_nsec=excluded.ctime_nsec,device_id=excluded.device_id,
                  inode=excluded.inode,title=excluded.title,page_count=excluded.page_count,
                  status=excluded.status,indexed_page_count=excluded.indexed_page_count,
                  title_truncated=excluded.title_truncated,
                  extractor_version=excluded.extractor_version,
                  normalizer_version=excluded.normalizer_version,
                  classifier_version=excluded.classifier_version,
                  sensitive_policy_version=excluded.sensitive_policy_version
                """)
                defer { sqlite3_finalize(upsert) }
                try bind(path, at: 1, to: upsert)
                try bind(revision, at: 2, to: upsert)
                bind(quickIdentity.byteCount, at: 3, to: upsert)
                bind(quickIdentity.modificationSeconds, at: 4, to: upsert)
                bind(quickIdentity.modificationNanoseconds, at: 5, to: upsert)
                bind(quickIdentity.changeSeconds, at: 6, to: upsert)
                bind(quickIdentity.changeNanoseconds, at: 7, to: upsert)
                bind(Int64(bitPattern: quickIdentity.deviceID), at: 8, to: upsert)
                bind(Int64(bitPattern: quickIdentity.inode), at: 9, to: upsert)
                try bind(extraction.title, at: 10, to: upsert)
                bind(Int64(extraction.pageCount), at: 11, to: upsert)
                try bind(extraction.status.rawValue, at: 12, to: upsert)
                bind(Int64(extraction.pages.count), at: 13, to: upsert)
                bind(Int64(extraction.titleTruncated ? 1 : 0), at: 14, to: upsert)
                bind(Int64(PDFSearchIndexContract.extractorVersion), at: 15, to: upsert)
                bind(Int64(PDFSearchIndexContract.normalizerVersion), at: 16, to: upsert)
                bind(Int64(PDFSearchIndexContract.classifierVersion), at: 17, to: upsert)
                bind(Int64(PDFSearchIndexContract.sensitivePolicyVersion), at: 18, to: upsert)
                try stepDone(upsert, operation: "publish document")

                let documentID = try requiredDocumentID(path: path)
                let deleteFTS = try prepare("""
                  DELETE FROM pdf_page_fts
                   WHERE rowid IN (SELECT id FROM pdf_page WHERE document_id=?1)
                """)
                defer { sqlite3_finalize(deleteFTS) }
                bind(documentID, at: 1, to: deleteFTS)
                try stepDone(deleteFTS, operation: "delete old FTS pages")
                let deletePages = try prepare(
                    "DELETE FROM pdf_page WHERE document_id=?1"
                )
                defer { sqlite3_finalize(deletePages) }
                bind(documentID, at: 1, to: deletePages)
                try stepDone(deletePages, operation: "delete old pages")
                observePeakBundleBytes()

                let insert = try prepare("""
                    INSERT INTO pdf_page(
                      document_id,physical_page,printed_page,page_kind,line_count,
                      raw_text,literal_folded,normalized_terms
                    ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)
                    """)
                defer { sqlite3_finalize(insert) }
                let fts = try prepare(
                    "INSERT INTO pdf_page_fts(rowid,normalized_terms) VALUES(?1,?2)"
                )
                defer { sqlite3_finalize(fts) }
                for page in extraction.pages {
                    try reset(insert, operation: "reset page insertion")
                    bind(documentID, at: 1, to: insert)
                    bind(Int64(page.physicalPage), at: 2, to: insert)
                    try bindOptional(page.printedPage, at: 3, to: insert)
                    try bind(page.kind.rawValue, at: 4, to: insert)
                    bind(Int64(page.lineCount), at: 5, to: insert)
                    try bind(page.rawText, at: 6, to: insert)
                    try bind(page.literalFolded, at: 7, to: insert)
                    try bind(page.normalizedTerms, at: 8, to: insert)
                    try stepDone(insert, operation: "insert page")
                    let pageID = sqlite3_last_insert_rowid(requiredHandle())
                    try reset(fts, operation: "reset FTS insertion")
                    bind(pageID, at: 1, to: fts)
                    try bind(page.normalizedTerms, at: 2, to: fts)
                    try stepDone(fts, operation: "insert FTS page")
                    observePeakBundleBytes()
                }
                try execute("""
                  UPDATE index_meta SET generation=generation+1 WHERE id=1
                """)
        }
        return try record(path: path) ?? {
            throw DatabaseError(operation: "publish", message: "record disappeared")
        }()
    }

    func remove(path: String) throws {
        guard let documentID = try rawDocumentID(path: path) else { return }
        try withBundleTransactionEnvelope(
            operation: "remove",
            preflight: {
                try preflightTransaction(
                    additionalPayloadBytes: 0,
                    additionalRows: 0,
                    operation: "remove"
                )
            }
        ) {
            let deleteFTS = try prepare("""
              DELETE FROM pdf_page_fts
               WHERE rowid IN (SELECT id FROM pdf_page WHERE document_id=?1)
            """)
            defer { sqlite3_finalize(deleteFTS) }
            bind(documentID, at: 1, to: deleteFTS)
            try stepDone(deleteFTS, operation: "remove FTS pages")
            let deleteDocument = try prepare("DELETE FROM pdf_document WHERE id=?1")
            defer { sqlite3_finalize(deleteDocument) }
            bind(documentID, at: 1, to: deleteDocument)
            try stepDone(deleteDocument, operation: "remove document")
            try execute("UPDATE index_meta SET generation=generation+1 WHERE id=1")
            observePeakBundleBytes()
        }
    }

    /// Deletes derived rows whose source path disappeared from one fully
    /// enumerated scope. A partial/scoped caller must never invoke this with an
    /// incomplete current-path set.
    func pruneMissing(scopePrefix: String, currentPaths: [String]) throws -> Int {
        try execute("""
          CREATE TEMP TABLE IF NOT EXISTS current_pdf_paths(
            path TEXT PRIMARY KEY
          )
        """)
        try transaction {
            try execute("DELETE FROM current_pdf_paths")
            if !currentPaths.isEmpty {
                let values = currentPaths.indices.map { "(?\($0 + 1))" }
                    .joined(separator: ",")
                let insert = try prepare(
                    "INSERT OR IGNORE INTO current_pdf_paths(path) VALUES \(values)"
                )
                defer { sqlite3_finalize(insert) }
                for (index, path) in currentPaths.enumerated() {
                    try bind(path, at: Int32(index + 1), to: insert)
                }
                try stepDone(insert, operation: "bind current PDF paths")
            }
        }

        guard scopePrefix.hasSuffix("/") else {
            throw DatabaseError(
                operation: "prune",
                message: "scope prefix must end at a directory boundary"
            )
        }
        // `/` immediately precedes `0` in Unicode/UTF-8/SQLite BINARY order,
        // so replacing the final separator with `0` is the true exclusive
        // upper bound for every possible descendant, including a name that
        // begins with U+10FFFF and has a suffix.
        let upperBound = String(scopePrefix.dropLast()) + "0"
        let staleCount = try countStaleDocuments(
            scopePrefix: scopePrefix,
            upperBound: upperBound
        )
        guard staleCount > 0 else { return 0 }
        try withBundleTransactionEnvelope(
            operation: "prune",
            preflight: {
                try preflightTransaction(
                    additionalPayloadBytes: 0,
                    additionalRows: 0,
                    operation: "prune"
                )
            }
        ) {
            let deleteFTS = try prepare("""
              DELETE FROM pdf_page_fts WHERE rowid IN (
                SELECT p.id FROM pdf_page p
                JOIN pdf_document d ON d.id=p.document_id
                WHERE d.path>=?1 AND d.path<?2
                  AND NOT EXISTS (
                    SELECT 1 FROM current_pdf_paths c WHERE c.path=d.path
                  )
              )
            """)
            defer { sqlite3_finalize(deleteFTS) }
            try bind(scopePrefix, at: 1, to: deleteFTS)
            try bind(upperBound, at: 2, to: deleteFTS)
            try stepDone(deleteFTS, operation: "prune FTS pages")

            let deleteDocuments = try prepare("""
              DELETE FROM pdf_document
              WHERE path>=?1 AND path<?2
                AND NOT EXISTS (
                  SELECT 1 FROM current_pdf_paths c
                  WHERE c.path=pdf_document.path
                )
            """)
            defer { sqlite3_finalize(deleteDocuments) }
            try bind(scopePrefix, at: 1, to: deleteDocuments)
            try bind(upperBound, at: 2, to: deleteDocuments)
            try stepDone(deleteDocuments, operation: "prune documents")
            try execute("UPDATE index_meta SET generation=generation+1 WHERE id=1")
            observePeakBundleBytes()
        }
        return staleCount
    }

    private func countStaleDocuments(
        scopePrefix: String,
        upperBound: String
    ) throws -> Int {
        let statement = try prepare("""
          SELECT COUNT(*) FROM pdf_document d
          WHERE d.path>=?1 AND d.path<?2
            AND NOT EXISTS (
              SELECT 1 FROM current_pdf_paths c WHERE c.path=d.path
            )
        """)
        defer { sqlite3_finalize(statement) }
        try bind(scopePrefix, at: 1, to: statement)
        try bind(upperBound, at: 2, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw error("count stale documents") }
        return int(statement, 0)
    }

    func exactPages(
        documentID: Int64,
        foldedQuery: String,
        maximum: Int
    ) throws -> ([IndexedPDFPage], Bool) {
        try pages(
            sql: """
            SELECT physical_page,printed_page,page_kind,line_count,raw_text,
                   literal_folded,normalized_terms
              FROM pdf_page
             WHERE document_id=?1 AND instr(literal_folded,?2)>0
             ORDER BY physical_page LIMIT ?3
            """,
            bindQuery: foldedQuery,
            documentID: documentID,
            maximum: maximum
        )
    }

    func scopedExactPages(
        documentIDs: [Int64],
        foldedQuery: String,
        maximum: Int,
        maximumTextBytes: Int,
        maximumWorkCallbacks: Int
    ) throws -> PDFIndexCandidateBatch {
        try installScope(documentIDs)
        return try scopedPages(
            sql: """
            SELECT p.document_id,p.physical_page,p.printed_page,p.page_kind,
                   p.line_count,p.raw_text
              FROM pdf_page p
              JOIN pdf_document d ON d.id=p.document_id
              JOIN current_pdf_scope s ON s.id=p.document_id
             WHERE instr(p.literal_folded,?1)>0
             ORDER BY d.path,p.physical_page LIMIT ?2
            """,
            query: foldedQuery,
            maximum: maximum,
            maximumTextBytes: maximumTextBytes,
            maximumWorkCallbacks: maximumWorkCallbacks
        )
    }

    func scopedFTSPages(
        documentIDs: [Int64],
        expression: String,
        maximum: Int,
        maximumTextBytes: Int,
        maximumWorkCallbacks: Int
    ) throws -> PDFIndexCandidateBatch {
        try installScope(documentIDs)
        return try scopedPages(
            sql: """
            SELECT p.document_id,p.physical_page,p.printed_page,p.page_kind,
                   p.line_count,p.raw_text
              FROM pdf_page_fts
              JOIN pdf_page p ON p.id=pdf_page_fts.rowid
              JOIN pdf_document d ON d.id=p.document_id
              JOIN current_pdf_scope s ON s.id=p.document_id
             WHERE pdf_page_fts MATCH ?1
             ORDER BY d.path,p.physical_page LIMIT ?2
            """,
            query: expression,
            maximum: maximum,
            maximumTextBytes: maximumTextBytes,
            maximumWorkCallbacks: maximumWorkCallbacks
        )
    }

    func ftsPages(
        documentID: Int64,
        expression: String,
        maximum: Int
    ) throws -> ([IndexedPDFPage], Bool) {
        try pages(
            sql: """
            SELECT p.physical_page,p.printed_page,p.page_kind,p.line_count,
                   p.raw_text,p.literal_folded,p.normalized_terms
              FROM pdf_page_fts
              JOIN pdf_page p ON p.id=pdf_page_fts.rowid
             WHERE p.document_id=?1 AND pdf_page_fts MATCH ?2
             ORDER BY p.physical_page LIMIT ?3
            """,
            bindQuery: expression,
            documentID: documentID,
            maximum: maximum
        )
    }

    func allPages(documentID: Int64, maximum: Int) throws -> ([IndexedPDFPage], Bool) {
        try pages(
            sql: """
            SELECT physical_page,printed_page,page_kind,line_count,raw_text,
                   literal_folded,normalized_terms
              FROM pdf_page WHERE document_id=?1
             ORDER BY physical_page LIMIT ?2
            """,
            bindQuery: nil,
            documentID: documentID,
            maximum: maximum
        )
    }

    func vocabulary(
        minimumLength: Int,
        maximumLength: Int,
        maximum: Int,
        maximumWorkCallbacks: Int
    ) throws -> PDFIndexVocabularyBatch {
        progressState.begin(maximumCallbacks: maximumWorkCallbacks)
        defer { progressState.end() }
        let statement = try prepare("""
          SELECT term FROM pdf_page_vocab
           WHERE length(term) BETWEEN ?1 AND ?2 ORDER BY term LIMIT ?3
        """)
        defer { sqlite3_finalize(statement) }
        bind(Int64(minimumLength), at: 1, to: statement)
        bind(Int64(maximumLength), at: 2, to: statement)
        bind(Int64(max(maximum, 0) + 1), at: 3, to: statement)
        var result: [String] = []
        var workLimited = false
        while true {
            let resultCode = sqlite3_step(statement)
            if resultCode == SQLITE_DONE { break }
            if resultCode == SQLITE_INTERRUPT, progressState.workExhausted {
                workLimited = true
                break
            }
            guard resultCode == SQLITE_ROW else { throw error("read vocabulary") }
            try Task.checkCancellation()
            result.append(text(statement, 0))
        }
        return PDFIndexVocabularyBatch(
            terms: Array(result.prefix(max(maximum, 0))),
            limited: workLimited || result.count > maximum,
            workCallbacks: progressState.callbacksConsumed
        )
    }

    private func installScope(_ documentIDs: [Int64]) throws {
        try execute("CREATE TEMP TABLE IF NOT EXISTS current_pdf_scope(id INTEGER PRIMARY KEY)")
        try transaction {
            try execute("DELETE FROM current_pdf_scope")
            if !documentIDs.isEmpty {
                let values = documentIDs.indices
                    .map { "(?\($0 + 1))" }
                    .joined(separator: ",")
                let statement = try prepare(
                    "INSERT OR IGNORE INTO current_pdf_scope(id) VALUES \(values)"
                )
                defer { sqlite3_finalize(statement) }
                for (index, documentID) in documentIDs.enumerated() {
                    bind(documentID, at: Int32(index + 1), to: statement)
                }
                try stepDone(statement, operation: "bind scope")
            }
        }
    }

    private func scopedPages(
        sql: String,
        query: String,
        maximum: Int,
        maximumTextBytes: Int,
        maximumWorkCallbacks: Int
    ) throws -> PDFIndexCandidateBatch {
        progressState.begin(maximumCallbacks: maximumWorkCallbacks)
        defer { progressState.end() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(query, at: 1, to: statement)
        bind(Int64(max(maximum, 0) + 1), at: 2, to: statement)
        var grouped: [Int64: [PDFIndexCandidatePage]] = [:]
        var examinedCount = 0
        var retainedCount = 0
        var retainedBytes = 0
        var limited = false
        while true {
            let resultCode = sqlite3_step(statement)
            if resultCode == SQLITE_DONE { break }
            if resultCode == SQLITE_INTERRUPT, progressState.workExhausted {
                limited = true
                break
            }
            guard resultCode == SQLITE_ROW else { throw error("read candidates") }
            try Task.checkCancellation()
            examinedCount += 1
            guard examinedCount <= maximum else {
                limited = true
                continue
            }
            let rawBytes = Int(sqlite3_column_bytes(statement, 5))
            guard rawBytes <= max(maximumTextBytes - retainedBytes, 0) else {
                limited = true
                continue
            }
            let documentID = sqlite3_column_int64(statement, 0)
            grouped[documentID, default: []].append(PDFIndexCandidatePage(
                physicalPage: int(statement, 1),
                printedPage: optionalText(statement, 2),
                kind: PDFSearchPageKind(rawValue: text(statement, 3)) ?? .body,
                lineCount: int(statement, 4),
                rawText: text(statement, 5)
            ))
            retainedCount += 1
            retainedBytes += rawBytes
        }
        return PDFIndexCandidateBatch(
            pagesByDocument: grouped,
            limited: limited,
            pageCount: retainedCount,
            textBytes: retainedBytes
        )
    }

    private func pages(
        sql: String,
        bindQuery: String?,
        documentID: Int64,
        maximum: Int
    ) throws -> ([IndexedPDFPage], Bool) {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(documentID, at: 1, to: statement)
        if let bindQuery { try bind(bindQuery, at: 2, to: statement) }
        let limitIndex: Int32 = bindQuery == nil ? 2 : 3
        bind(Int64(max(maximum, 0) + 1), at: limitIndex, to: statement)
        var rows: [IndexedPDFPage] = []
        while true {
            let resultCode = sqlite3_step(statement)
            if resultCode == SQLITE_DONE { break }
            guard resultCode == SQLITE_ROW else { throw error("read pages") }
            try Task.checkCancellation()
            rows.append(IndexedPDFPage(
                physicalPage: int(statement, 0),
                printedPage: optionalText(statement, 1),
                kind: PDFSearchPageKind(rawValue: text(statement, 2)) ?? .body,
                lineCount: int(statement, 3),
                rawText: text(statement, 4),
                literalFolded: text(statement, 5),
                normalizedTerms: text(statement, 6)
            ))
        }
        let limited = rows.count > maximum
        return (Array(rows.prefix(max(maximum, 0))), limited)
    }

    private enum SchemaDisposition {
        case new
        case warm
    }

    /// Version zero is accepted only for a genuinely empty SQLite catalog.
    /// This prevents schema creation from silently repairing or adopting an
    /// unversioned database supplied at the private cache path.
    private func schemaDisposition() throws -> SchemaDisposition {
        let version = try scalarInt("PRAGMA user_version")
        let applicationID = try scalarInt("PRAGMA application_id")
        let objectStatement = try prepare("""
          SELECT name FROM sqlite_schema
           WHERE name NOT LIKE 'sqlite_%'
           LIMIT \(Self.maximumWarmSchemaObjects + 1)
        """)
        defer { sqlite3_finalize(objectStatement) }
        var objectCount = 0
        while true {
            let result = sqlite3_step(objectStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error("read schema catalog") }
            objectCount += 1
            guard objectCount <= Self.maximumWarmSchemaObjects else {
                throw DatabaseError(
                    operation: "schema",
                    message: "derived-cache schema contains too many objects"
                )
            }
        }
        if version == 0, applicationID == 0, objectCount == 0 {
            return .new
        }
        guard version == PDFSearchIndexContract.schemaVersion else {
            throw DatabaseError(operation: "schema", message: "unsupported version")
        }
        guard applicationID == Self.applicationID else {
            throw DatabaseError(
                operation: "schema",
                message: "derived-cache application identity mismatch"
            )
        }
        return .warm
    }

    private func createNewSchema() throws {
        try transaction {
            try execute("""
            CREATE TABLE index_meta(
              id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL
            );
            INSERT INTO index_meta(id,generation) VALUES(1,0);
            CREATE TABLE pdf_document(
              id INTEGER PRIMARY KEY,
              path TEXT NOT NULL UNIQUE,
              content_sha256 TEXT NOT NULL,
              byte_count INTEGER NOT NULL,
              mtime_sec INTEGER NOT NULL, mtime_nsec INTEGER NOT NULL,
              ctime_sec INTEGER NOT NULL, ctime_nsec INTEGER NOT NULL,
              device_id INTEGER NOT NULL, inode INTEGER NOT NULL,
              title TEXT NOT NULL, page_count INTEGER NOT NULL,
              status TEXT NOT NULL, indexed_page_count INTEGER NOT NULL,
              title_truncated INTEGER NOT NULL DEFAULT 0,
              extractor_version INTEGER NOT NULL,
              normalizer_version INTEGER NOT NULL,
              classifier_version INTEGER NOT NULL,
              sensitive_policy_version INTEGER NOT NULL
            );
            CREATE TABLE pdf_page(
              id INTEGER PRIMARY KEY,
              document_id INTEGER NOT NULL REFERENCES pdf_document(id) ON DELETE CASCADE,
              physical_page INTEGER NOT NULL,
              printed_page TEXT,
              page_kind TEXT NOT NULL,
              line_count INTEGER NOT NULL,
              raw_text TEXT NOT NULL,
              literal_folded TEXT NOT NULL,
              normalized_terms TEXT NOT NULL,
              UNIQUE(document_id,physical_page)
            );
            CREATE VIRTUAL TABLE pdf_page_fts USING fts5(
              normalized_terms, tokenize='unicode61 remove_diacritics 2'
            );
            CREATE VIRTUAL TABLE pdf_page_vocab USING fts5vocab(
              pdf_page_fts, 'row'
            );
            """)
            try execute("PRAGMA application_id=\(Self.applicationID)")
            try execute("PRAGMA user_version=\(PDFSearchIndexContract.schemaVersion)")
        }
    }

    /// Performs only bounded reads and statement probes on a warm, private
    /// derived cache. It intentionally contains no repair DDL or FTS writes.
    private func validateWarmSchema() throws {
        guard try scalarInt("PRAGMA application_id") == Self.applicationID,
              try scalarInt("PRAGMA user_version")
                == PDFSearchIndexContract.schemaVersion else {
            throw DatabaseError(
                operation: "schema",
                message: "derived-cache identity mismatch"
            )
        }
        _ = try scalarInt("PRAGMA schema_version")

        let requiredObjects: [String: String] = [
            "index_meta": "table",
            "pdf_document": "table",
            "pdf_page": "table",
            "pdf_page_fts": "table",
            "pdf_page_vocab": "table",
        ]
        let objectStatement = try prepare("""
          SELECT name,type FROM sqlite_schema
           WHERE name IN ('index_meta','pdf_document','pdf_page',
                          'pdf_page_fts','pdf_page_vocab')
        """)
        defer { sqlite3_finalize(objectStatement) }
        var observedObjects: [String: String] = [:]
        while true {
            let result = sqlite3_step(objectStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error("read schema objects") }
            observedObjects[text(objectStatement, 0)] = text(objectStatement, 1)
        }
        guard observedObjects == requiredObjects else {
            throw DatabaseError(
                operation: "schema",
                message: "required derived-cache objects are missing or incompatible"
            )
        }

        try validateColumns(table: "index_meta", expected: ["id", "generation"])
        try validateColumns(table: "pdf_document", expected: [
            "id", "path", "content_sha256", "byte_count", "mtime_sec",
            "mtime_nsec", "ctime_sec", "ctime_nsec", "device_id", "inode",
            "title", "page_count", "status", "indexed_page_count",
            "title_truncated", "extractor_version", "normalizer_version",
            "classifier_version", "sensitive_policy_version",
        ])
        try validateColumns(table: "pdf_page", expected: [
            "id", "document_id", "physical_page", "printed_page", "page_kind",
            "line_count", "raw_text", "literal_folded", "normalized_terms",
        ])
        try validateColumns(table: "pdf_page_fts", expected: ["normalized_terms"])
        try validateColumns(table: "pdf_page_vocab", expected: ["term", "doc", "cnt"])
        guard try hasUniqueIndex(table: "pdf_document", columns: ["path"]),
              try hasUniqueIndex(
                table: "pdf_page",
                columns: ["document_id", "physical_page"]
              ),
              try hasRequiredPageForeignKey() else {
            throw DatabaseError(
                operation: "schema",
                message: "required derived-cache constraints are missing"
            )
        }

        let metadataProbe = try prepare(
            "SELECT id,generation FROM index_meta LIMIT 2"
        )
        defer { sqlite3_finalize(metadataProbe) }
        guard sqlite3_step(metadataProbe) == SQLITE_ROW,
              int(metadataProbe, 0) == 1,
              int(metadataProbe, 1) >= 0,
              sqlite3_step(metadataProbe) == SQLITE_DONE else {
            throw DatabaseError(
                operation: "schema",
                message: "invalid generation metadata"
            )
        }
        let ftsSQL = try schemaSQL(name: "pdf_page_fts").lowercased()
        let vocabSQL = try schemaSQL(name: "pdf_page_vocab").lowercased()
        guard ftsSQL.contains("using fts5"),
              ftsSQL.contains("tokenize='unicode61 remove_diacritics 2'"),
              vocabSQL.contains("using fts5vocab"),
              vocabSQL.contains("pdf_page_fts, 'row'") else {
            throw DatabaseError(operation: "schema", message: "invalid FTS objects")
        }

        let ftsProbe = try prepare("""
          SELECT rowid FROM pdf_page_fts
           WHERE pdf_page_fts MATCH ?1 LIMIT 1
        """)
        defer { sqlite3_finalize(ftsProbe) }
        try bind("secondbrainwarmprobe", at: 1, to: ftsProbe)
        let ftsResult = sqlite3_step(ftsProbe)
        guard ftsResult == SQLITE_ROW || ftsResult == SQLITE_DONE else {
            throw error("probe FTS query")
        }
        let vocabProbe = try prepare("SELECT term FROM pdf_page_vocab LIMIT 1")
        defer { sqlite3_finalize(vocabProbe) }
        let vocabResult = sqlite3_step(vocabProbe)
        guard vocabResult == SQLITE_ROW || vocabResult == SQLITE_DONE else {
            throw error("probe FTS vocabulary")
        }
    }

    private func validateColumns(table: String, expected: Set<String>) throws {
        guard try columnNames(table: table) == expected else {
            throw DatabaseError(
                operation: "schema",
                message: "incompatible columns for \(table)"
            )
        }
    }

    private func schemaSQL(name: String) throws -> String {
        let statement = try prepare(
            "SELECT sql FROM sqlite_schema WHERE type='table' AND name=?1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(name, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError(operation: "schema", message: "missing \(name)")
        }
        let byteCount = Int(sqlite3_column_bytes(statement, 0))
        guard byteCount <= Self.maximumWarmSchemaSQLBytes else {
            throw DatabaseError(
                operation: "schema",
                message: "schema SQL for \(name) exceeds its bounded probe ceiling"
            )
        }
        return text(statement, 0)
    }

    private func hasUniqueIndex(table: String, columns: [String]) throws -> Bool {
        let list = try prepare("PRAGMA index_list(\(table))")
        defer { sqlite3_finalize(list) }
        var candidateNames: [String] = []
        var observedIndexes = 0
        while true {
            let result = sqlite3_step(list)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw error("read schema indexes")
            }
            observedIndexes += 1
            guard observedIndexes <= Self.maximumWarmIndexesPerTable else {
                throw DatabaseError(
                    operation: "schema",
                    message: "derived-cache table contains too many indexes"
                )
            }
            if int(list, 2) == 1, int(list, 4) == 0 {
                candidateNames.append(text(list, 1))
            }
        }
        for name in candidateNames {
            if try indexColumns(name: name) == columns { return true }
        }
        return false
    }

    private func indexColumns(name: String) throws -> [String] {
        let statement = try prepare("PRAGMA index_info(\(name))")
        defer { sqlite3_finalize(statement) }
        var observed: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error("read schema index") }
            observed.append(text(statement, 2))
            guard observed.count <= Self.maximumWarmIndexColumns else {
                throw DatabaseError(
                    operation: "schema",
                    message: "derived-cache index contains too many columns"
                )
            }
        }
        return observed
    }

    private func hasRequiredPageForeignKey() throws -> Bool {
        let statement = try prepare("PRAGMA foreign_key_list(pdf_page)")
        defer { sqlite3_finalize(statement) }
        var observed = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error("read schema foreign keys") }
            guard text(statement, 2) == "pdf_document",
                  text(statement, 3) == "document_id",
                  text(statement, 4) == "id",
                  text(statement, 6).uppercased() == "CASCADE" else {
                return false
            }
            observed += 1
        }
        return observed == 1
    }

    /// Refuses a publication before `BEGIN` unless its bounded input and a
    /// conservative SQLite allocation envelope fit beside the current main
    /// database. The envelope reserves two complete dirty generations of the
    /// current database plus input-derived B-tree/FTS write amplification and
    /// the corresponding WAL-index growth.
    private func preflightPublication(
        path: String,
        revision: String,
        extraction: IndexedPDFExtraction
    ) throws {
        var representationBytes: Int64 = 0
        for page in extraction.pages {
            let pageBytes = PDFIndexExtractor.retainedRepresentationByteCount(
                for: page
            )
            representationBytes = try checkedAdd(
                representationBytes,
                Int64(pageBytes),
                operation: "publish"
            )
        }
        guard representationBytes <= Int64(maximumPublicationRepresentationBytes) else {
            throw DatabaseError(
                operation: "publish",
                message: "publication exceeds its retained representation ceiling",
                code: SQLITE_FULL
            )
        }
        var payloadBytes = representationBytes
        for value in [path, revision, extraction.title] {
            payloadBytes = try checkedAdd(
                payloadBytes,
                Int64(value.utf8.count),
                operation: "publish"
            )
        }
        // `normalized_terms` is retained once more by FTS. The allocation
        // multiplier below covers B-tree cells, FTS segments, and sparse pages.
        for page in extraction.pages {
            payloadBytes = try checkedAdd(
                payloadBytes,
                Int64(page.normalizedTerms.utf8.count),
                operation: "publish"
            )
        }
        let rowCount = try checkedAdd(
            try checkedMultiply(
                Int64(extraction.pages.count),
                2,
                operation: "publish"
            ),
            1,
            operation: "publish"
        )
        try preflightTransaction(
            additionalPayloadBytes: payloadBytes,
            additionalRows: rowCount,
            operation: "publish"
        )
    }

    /// Applies one storage envelope to every persistent write transaction.
    /// The initial checkpoint makes the bundle facts used by preflight current;
    /// a failed transaction is rolled back by `transaction` and checkpointed so
    /// repeated failures cannot retain growing WAL frames. Post-commit failures
    /// are deliberately non-retryable capacity failures because the disposable
    /// derived cache has already changed and must be reopened or rebuilt.
    private func withBundleTransactionEnvelope<Result>(
        operation: String,
        preflight: () throws -> Void,
        transactionBody: () throws -> Result
    ) throws -> Result {
        try checkpointWAL()
        try ensureBundleWithinQuota(operation: operation, code: SQLITE_FULL)
        try preflight()
        observePeakBundleBytes()

        let result: Result
        do {
            result = try transaction(transactionBody)
        } catch {
            try? checkpointWAL()
            throw error
        }

        try checkpointWAL()
        try ensureBundleWithinQuota(operation: "quota", code: nil)
        return result
    }

    private func preflightTransaction(
        additionalPayloadBytes: Int64,
        additionalRows: Int64,
        operation: String
    ) throws {
        let pageSize = Int64(max(try scalarInt("PRAGMA page_size"), 1))
        let pageCount = Int64(max(try scalarInt("PRAGMA page_count"), 0))
        let currentMainBytes = try checkedMultiply(
            pageSize,
            pageCount,
            operation: operation
        )
        let payloadAllocation = try checkedMultiply(
            additionalPayloadBytes,
            2,
            operation: operation
        )
        let rowAllocation = try checkedMultiply(
            additionalRows,
            pageSize,
            operation: operation
        )
        let projectedMainBytes = try checkedAdd(
            currentMainBytes,
            try checkedAdd(
                64 * 1_024,
                try checkedAdd(
                    payloadAllocation,
                    rowAllocation,
                    operation: operation
                ),
                operation: operation
            ),
            operation: operation
        )
        guard projectedMainBytes <= maximumMainDatabaseBytes else {
            throw DatabaseError(
                operation: operation,
                message: "publication cannot fit inside the peak database envelope",
                code: SQLITE_FULL
            )
        }

        let walDirtyBytes = try checkedAdd(
            try checkedMultiply(currentMainBytes, 2, operation: operation),
            try checkedAdd(
                try checkedMultiply(
                    payloadAllocation,
                    2,
                    operation: operation
                ),
                try checkedAdd(
                    try checkedMultiply(
                        rowAllocation,
                        2,
                        operation: operation
                    ),
                    128 * 1_024,
                    operation: operation
                ),
                operation: operation
            ),
            operation: operation
        )
        let projectedFrames = (walDirtyBytes / pageSize)
            + (walDirtyBytes % pageSize == 0 ? 0 : 1)
        let walFrameBytes = try checkedMultiply(
            projectedFrames,
            pageSize + 24,
            operation: operation
        )
        let walBytes = try checkedAdd(32, walFrameBytes, operation: operation)
        let walIndexBytes = try checkedAdd(
            64 * 1_024,
            try checkedMultiply(
                projectedFrames,
                32,
                operation: operation
            ),
            operation: operation
        )
        // TRUNCATE normally reduces WAL to zero, but an already allocated WAL
        // index may remain. Model the peak as the larger of each existing
        // sidecar and the transaction-derived requirement so warm sidecar bytes
        // can never disappear from the prediction.
        let existingMainBytes = try bundleComponentByteCount(
            canonicalURL,
            operation: operation
        )
        let existingWALBytes = try bundleComponentByteCount(
            URL(fileURLWithPath: canonicalURL.path + "-wal"),
            operation: operation
        )
        let existingSHMBytes = try bundleComponentByteCount(
            URL(fileURLWithPath: canonicalURL.path + "-shm"),
            operation: operation
        )
        let peakBytes = try checkedAdd(
            max(currentMainBytes, existingMainBytes),
            try checkedAdd(
                max(walBytes, existingWALBytes),
                max(walIndexBytes, existingSHMBytes),
                operation: operation
            ),
            operation: operation
        )
        guard peakBytes <= maximumBundleBytes else {
            throw DatabaseError(
                operation: operation,
                message: "transaction cannot fit inside the peak database bundle ceiling",
                code: SQLITE_FULL
            )
        }
    }

    private func bundleComponentByteCount(
        _ url: URL,
        operation: String
    ) throws -> Int64 {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return 0 }
            throw DatabaseError(operation: "inspect file", message: url.path)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0 else {
            throw DatabaseError(operation: operation, message: "unsafe bundle file")
        }
        return metadata.st_size
    }

    private func checkedAdd(
        _ lhs: Int64,
        _ rhs: Int64,
        operation: String
    ) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw DatabaseError(
                operation: operation,
                message: "database transaction size overflow",
                code: SQLITE_FULL
            )
        }
        return result.partialValue
    }

    private func checkedMultiply(
        _ lhs: Int64,
        _ rhs: Int64,
        operation: String
    ) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw DatabaseError(
                operation: operation,
                message: "database transaction size overflow",
                code: SQLITE_FULL
            )
        }
        return result.partialValue
    }

    private func observePeakBundleBytes() {
        guard let peakBundleByteObserver else { return }
        var total: Int64 = 0
        for candidate in Self.databaseBundleURLs(canonicalURL) {
            var metadata = stat()
            if Darwin.lstat(candidate.path, &metadata) == 0,
               metadata.st_mode & S_IFMT == S_IFREG,
               metadata.st_size >= 0 {
                let next = total.addingReportingOverflow(metadata.st_size)
                guard !next.overflow else { return }
                total = next.partialValue
            }
        }
        peakBundleByteObserver(total)
    }

    private func configureWAL(pageSize: Int) throws {
        try execute("PRAGMA synchronous=NORMAL")
        let journalLimit = max(
            min(sidecarReserveBytes / 4, 1 * 1_024 * 1_024),
            Int64(pageSize)
        )
        _ = try scalarInt("PRAGMA journal_size_limit=\(journalLimit)")
        let checkpointPages = max(
            1,
            min(Int(journalLimit / Int64(pageSize)), 1_000)
        )
        _ = try scalarInt("PRAGMA wal_autocheckpoint=\(checkpointPages)")
    }

    /// Truncates committed WAL frames while the owning index holds its
    /// cross-process writer lease. A busy result is not treated as success.
    private func checkpointWAL() throws {
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let result = sqlite3_wal_checkpoint_v2(
            requiredHandle(),
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrames,
            &checkpointedFrames
        )
        guard result == SQLITE_OK else {
            throw DatabaseError(
                operation: "checkpoint",
                message: "another connection retained the private WAL",
                code: result
            )
        }
    }

    private func ensureBundleWithinQuota(
        operation: String,
        code: Int32?
    ) throws {
        var total: Int64 = 0
        for candidate in Self.databaseBundleURLs(canonicalURL) {
            var metadata = stat()
            if Darwin.lstat(candidate.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_size >= 0 else {
                    throw DatabaseError(
                        operation: "validate file",
                        message: candidate.path
                    )
                }
                let (next, overflow) = total.addingReportingOverflow(metadata.st_size)
                guard !overflow else {
                    throw DatabaseError(
                        operation: operation,
                        message: "private index bundle size overflow",
                        code: code
                    )
                }
                total = next
            } else if errno != ENOENT {
                throw DatabaseError(operation: "inspect file", message: candidate.path)
            }
        }
        guard total <= maximumBundleBytes else {
            throw DatabaseError(
                operation: operation,
                message: "private index bundle exceeds its storage ceiling",
                code: code
            )
        }
    }

    private func validateExhaustiveIntegrity() throws {
        exhaustiveIntegrityObserver?()
        guard try scalarText("PRAGMA quick_check(1)") == "ok" else {
            throw DatabaseError(operation: "integrity", message: "quick check failed")
        }
        try execute("INSERT INTO pdf_page_fts(pdf_page_fts) VALUES('integrity-check')")
        let sourcePageCount = try scalarInt("SELECT COUNT(*) FROM pdf_page")
        let indexedPageCount = try scalarInt("SELECT COUNT(*) FROM pdf_page_fts")
        let missingIndexRows = try scalarInt("""
          SELECT COUNT(*) FROM pdf_page p
           LEFT JOIN pdf_page_fts f ON f.rowid=p.id WHERE f.rowid IS NULL
        """)
        let orphanIndexRows = try scalarInt("""
          SELECT COUNT(*) FROM pdf_page_fts f
           LEFT JOIN pdf_page p ON p.id=f.rowid WHERE p.id IS NULL
        """)
        let divergentPayloadRows = try scalarInt("""
          SELECT COUNT(*) FROM pdf_page p
          JOIN pdf_page_fts f ON f.rowid=p.id
          WHERE f.normalized_terms IS NOT p.normalized_terms
        """)
        guard sourcePageCount == indexedPageCount,
              missingIndexRows == 0, orphanIndexRows == 0,
              divergentPayloadRows == 0 else {
            throw DatabaseError(operation: "integrity", message: "FTS rows diverged")
        }
    }

    private func columnNames(table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while true {
            let resultCode = sqlite3_step(statement)
            if resultCode == SQLITE_DONE { break }
            guard resultCode == SQLITE_ROW else { throw error("read schema") }
            result.insert(text(statement, 1))
        }
        return result
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result != SQLITE_DONE { throw error("read integer") }
            throw DatabaseError(operation: "schema", message: "missing scalar")
        }
        return int(statement, 0)
    }

    private func scalarText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result != SQLITE_DONE { throw error("read text") }
            throw DatabaseError(operation: "integrity", message: "missing result")
        }
        return text(statement, 0)
    }

    private func requiredDocumentID(path: String) throws -> Int64 {
        let statement = try prepare("SELECT id FROM pdf_document WHERE path=?1")
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result != SQLITE_DONE { throw error("lookup document") }
            throw DatabaseError(operation: "lookup", message: "missing document")
        }
        return sqlite3_column_int64(statement, 0)
    }

    /// Ignores extractor/policy contract versions so an invalidated sensitive
    /// row can always be deleted from the derived index.
    private func rawDocumentID(path: String) throws -> Int64? {
        let statement = try prepare("SELECT id FROM pdf_document WHERE path=?1")
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw error("lookup raw document") }
        return sqlite3_column_int64(statement, 0)
    }

    private func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            observePeakBundleBytes()
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        statementPreparationObserver?()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requiredHandle(), sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw error("prepare")
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(requiredHandle(), sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(message)
            let code = sqlite3_extended_errcode(requiredHandle())
            if code == SQLITE_INTERRUPT, currentTaskIsCancelled() {
                throw CancellationError()
            }
            throw DatabaseError(
                operation: "execute",
                message: detail,
                code: code
            )
        }
    }

    private func stepDone(_ statement: OpaquePointer, operation: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error(operation) }
    }

    private func reset(_ statement: OpaquePointer, operation: String) throws {
        guard sqlite3_reset(statement) == SQLITE_OK,
              sqlite3_clear_bindings(statement) == SQLITE_OK else {
            throw error(operation)
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let byteCount = value.utf8.count
        guard byteCount <= Int(Int32.max) else {
            throw DatabaseError(operation: "bind text", message: "value too large")
        }
        let result = value.withCString {
            sqlite3_bind_text(
                statement,
                index,
                $0,
                Int32(byteCount),
                Self.transient
            )
        }
        guard result == SQLITE_OK else {
            throw error("bind text")
        }
    }

    private func bindOptional(
        _ value: String?, at index: Int32, to statement: OpaquePointer
    ) throws {
        if let value { try bind(value, at: index, to: statement) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        return String(
            decoding: UnsafeBufferPointer(start: value, count: byteCount),
            as: UTF8.self
        )
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }

    private func int(_ statement: OpaquePointer, _ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    private func requiredHandle() -> OpaquePointer {
        precondition(handle != nil)
        return handle!
    }

    private func error(_ operation: String) -> any Error {
        let code = sqlite3_extended_errcode(requiredHandle())
        if code == SQLITE_INTERRUPT, currentTaskIsCancelled() {
            return CancellationError()
        }
        return DatabaseError(
            operation: operation,
            message: String(cString: sqlite3_errmsg(requiredHandle())),
            code: code
        )
    }

    /// Removes only a fully validated, process-owned derived-index bundle.
    /// Every component is inspected before any deletion so a malicious
    /// hardlink/symlink sidecar prevents the entire recovery operation.
    static func discardBundleForRebuild(at url: URL) throws {
        let canonicalURL = try resolvingRootOwnedAlias(url.standardized)
        let parent = canonicalURL.deletingLastPathComponent()
        var parentStat = stat()
        guard Darwin.lstat(parent.path, &parentStat) == 0,
              parentStat.st_mode & S_IFMT == S_IFDIR,
              parentStat.st_uid == geteuid(),
              parentStat.st_mode & 0o077 == 0 else {
            throw DatabaseError(operation: "validate recovery", message: "unsafe directory")
        }
        let bundle = databaseBundleURLs(canonicalURL)
        var existing: [URL] = []
        for candidate in bundle {
            var value = stat()
            if Darwin.lstat(candidate.path, &value) == 0 {
                guard value.st_mode & S_IFMT == S_IFREG,
                      value.st_uid == geteuid(), value.st_nlink == 1 else {
                    throw DatabaseError(operation: "validate recovery", message: "unsafe file")
                }
                existing.append(candidate)
            } else if errno != ENOENT {
                throw DatabaseError(operation: "inspect recovery", message: "unavailable")
            }
        }
        for candidate in existing {
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private static func validateDatabasePath(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        var parentStat = stat()
        guard Darwin.lstat(parent.path, &parentStat) == 0,
              parentStat.st_mode & S_IFMT == S_IFDIR,
              parentStat.st_uid == geteuid(),
              parentStat.st_mode & 0o077 == 0 else {
            throw DatabaseError(operation: "validate directory", message: parent.path)
        }
        for candidate in databaseBundleURLs(url) {
            var value = stat()
            if Darwin.lstat(candidate.path, &value) == 0 {
                guard value.st_mode & S_IFMT == S_IFREG,
                      value.st_uid == geteuid(), value.st_nlink == 1,
                      value.st_mode & 0o077 == 0 else {
                    throw DatabaseError(
                        operation: "validate file",
                        message: candidate.path
                    )
                }
            } else if errno != ENOENT {
                throw DatabaseError(
                    operation: "inspect file",
                    message: candidate.path
                )
            }
        }
    }

    /// SQLite's NOFOLLOW VFS rejects macOS's root aliases (`/var`, `/tmp`).
    /// Rewrite only a root-owned first component; no user-controlled parent is
    /// resolved or followed here.
    private static func resolvingRootOwnedAlias(_ url: URL) throws -> URL {
        let components = url.path.split(separator: "/").map(String.init)
        guard let first = components.first else { return url }
        let alias = URL(fileURLWithPath: "/\(first)")
        var value = stat()
        guard Darwin.lstat(alias.path, &value) == 0 else {
            throw DatabaseError(operation: "inspect root alias", message: "unavailable")
        }
        guard value.st_mode & S_IFMT == S_IFLNK else { return url }
        guard value.st_uid == 0 else {
            throw DatabaseError(operation: "validate root alias", message: "not root owned")
        }
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: alias.path
        )
        let rootDestination = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : URL(fileURLWithPath: "/").appendingPathComponent(destination)
        return components.dropFirst().reduce(rootDestination) {
            $0.appendingPathComponent($1)
        }
    }

    private static func hardenDatabaseFiles(_ url: URL) throws {
        for candidate in databaseBundleURLs(url) {
            var value = stat()
            guard Darwin.lstat(candidate.path, &value) == 0 else {
                if errno == ENOENT { continue }
                throw DatabaseError(operation: "inspect file", message: candidate.path)
            }
            guard value.st_mode & S_IFMT == S_IFREG,
                  value.st_uid == geteuid(), value.st_nlink == 1 else {
                throw DatabaseError(operation: "validate file", message: candidate.path)
            }
            if value.st_mode & 0o777 != 0o600 {
                guard Darwin.chmod(candidate.path, 0o600) == 0 else {
                    throw DatabaseError(operation: "harden file", message: candidate.path)
                }
            }
        }
    }

    private static func databaseBundleURLs(_ url: URL) -> [URL] {
        [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
        ]
    }
}

private extension PDFIndexQuickIdentity {
    init(
        byteCount: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        changeSeconds: Int64,
        changeNanoseconds: Int64,
        deviceID: UInt64,
        inode: UInt64
    ) {
        self.byteCount = byteCount
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
        self.deviceID = deviceID
        self.inode = inode
    }
}

private func currentTaskIsCancelled() -> Bool {
    withUnsafeCurrentTask { $0?.isCancelled ?? false }
}
