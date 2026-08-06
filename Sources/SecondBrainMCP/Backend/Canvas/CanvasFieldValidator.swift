/// Validates constrained JSON Canvas string fields during decoding.
enum CanvasFieldValidator {
    /// Accepts a standard edge attachment side or an omitted value.
    static func validateSide<Key: CodingKey>(
        _ value: String?,
        container: KeyedDecodingContainer<Key>,
        key: Key
    ) throws {
        guard let value else { return }
        guard ["top", "right", "bottom", "left"].contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "side must be top, right, bottom, or left"
            )
        }
    }

    /// Accepts a standard edge-end decoration or an omitted value.
    static func validateEnd<Key: CodingKey>(
        _ value: String?,
        container: KeyedDecodingContainer<Key>,
        key: Key
    ) throws {
        guard let value else { return }
        guard ["none", "arrow"].contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "end must be none or arrow"
            )
        }
    }

    /// Accepts a standard group background rendering style or an omitted value.
    static func validateBackgroundStyle<Key: CodingKey>(
        _ value: String?,
        container: KeyedDecodingContainer<Key>,
        key: Key
    ) throws {
        guard let value else { return }
        guard ["cover", "ratio", "repeat"].contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "backgroundStyle must be cover, ratio, or repeat"
            )
        }
    }

    /// Accepts an anchor-prefixed file subpath or an omitted value.
    static func validateSubpath<Key: CodingKey>(
        _ value: String?,
        container: KeyedDecodingContainer<Key>,
        key: Key
    ) throws {
        guard let value else { return }
        guard value.hasPrefix("#") else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "subpath must start with '#'"
            )
        }
    }

    /// Accepts `#RGB`, `#RRGGBB`, or a JSON Canvas preset from `1` through `6`.
    static func validateColor<Key: CodingKey>(
        _ value: String,
        container: KeyedDecodingContainer<Key>,
        key: Key
    ) throws {
        if ["1", "2", "3", "4", "5", "6"].contains(value) { return }
        if value.hasPrefix("#") {
            let hex = value.dropFirst()
            if (hex.count == 3 || hex.count == 6), hex.allSatisfy(\.isHexDigit) {
                return
            }
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "color must be a hex value (e.g. #FF0000) or a preset 1–6"
        )
    }
}
