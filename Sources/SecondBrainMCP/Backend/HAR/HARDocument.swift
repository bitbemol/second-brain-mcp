/// Decoded representation of the HTTP Archive fields validated by the inspector.
///
/// Fields decode independently so ``HARInspector`` can report structural
/// validation failures instead of collapsing every type mismatch into invalid JSON.
/// The original archive bytes remain the persistence source and are never
/// re-encoded from this projection.
struct HARDocument: Decodable {
    /// Decoded top-level archive log, or `nil` when missing or malformed.
    let log: Log?

    /// Supported fields from the HAR `log` object.
    struct Log: Decodable {
        /// Declared HAR format version.
        let version: String?
        /// Tool that created the archive.
        let creator: Creator?
        /// Recorded HTTP transactions.
        let entries: [Entry]?

        private enum CodingKeys: String, CodingKey {
            case version
            case creator
            case entries
        }

        /// Decodes each supported log field independently.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = container.decodeIfValid(String.self, forKey: .version)
            creator = container.decodeIfValid(Creator.self, forKey: .creator)
            entries = container.decodeIfValid([Entry].self, forKey: .entries)
        }
    }

    /// Supported fields from the HAR `creator` object.
    struct Creator: Decodable {
        /// Creator display name.
        let name: String?

        private enum CodingKeys: String, CodingKey {
            case name
        }

        /// Decodes the creator name without rejecting its parent log.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = container.decodeIfValid(String.self, forKey: .name)
        }
    }

    /// Supported fields from one HAR transaction entry.
    struct Entry: Decodable {
        /// Recorded request fields.
        let request: Request?
        /// Recorded response fields.
        let response: Response?
        /// Total recorded transaction time in milliseconds.
        let time: Double?

        private enum CodingKeys: String, CodingKey {
            case request
            case response
            case time
        }

        /// Decodes request, response, and timing values independently.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            request = container.decodeIfValid(Request.self, forKey: .request)
            response = container.decodeIfValid(Response.self, forKey: .response)
            time = container.decodeIfValid(Double.self, forKey: .time)
        }
    }

    /// Supported fields from one HAR request.
    struct Request: Decodable {
        /// HTTP method when it is a valid string.
        let method: String?
        /// Request URL when it is a valid string.
        let url: String?

        private enum CodingKeys: String, CodingKey {
            case method
            case url
        }

        /// Decodes the method and URL independently.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            method = container.decodeIfValid(String.self, forKey: .method)
            url = container.decodeIfValid(String.self, forKey: .url)
        }
    }

    /// Supported fields from one HAR response.
    struct Response: Decodable {
        /// HTTP response status when it is a valid integer.
        let status: Int?

        private enum CodingKeys: String, CodingKey {
            case status
        }

        /// Decodes the status without rejecting its parent entry.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = container.decodeIfValid(Int.self, forKey: .status)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case log
    }

    /// Decodes the top-level log without rejecting a syntactically valid object.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        log = container.decodeIfValid(Log.self, forKey: .log)
    }
}

private extension KeyedDecodingContainer {
    /// Returns a field only when it is present and independently decodable.
    func decodeIfValid<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) -> Value? {
        try? decode(type, forKey: key)
    }
}
