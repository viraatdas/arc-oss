import Foundation

// Radian's saved state is decoded leniently. A field that is missing or unreadable falls back to a
// default, and an element of a list that cannot be read is skipped, so one bad value, or a file
// written by a newer version, costs that value rather than everything.

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` if it is missing or cannot be read.
    func value<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback()
    }

    /// The value for `key`, or nil if it is missing or cannot be read.
    func optional<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }

    /// Every element of the list under `key` that can be read.
    func lossyArray<T: Decodable>(_ key: Key) -> [T] {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var elements: [T] = []
        while !list.isAtEnd {
            if let element = try? list.decode(T.self) {
                elements.append(element)
            } else if (try? list.decode(SkippedElement.self)) == nil {
                // The decoder could not even step over the element; nothing after it is reachable.
                break
            }
        }
        return elements
    }

    /// How many elements the list under `key` holds, whether or not they can be read.
    func elementCount(_ key: Key) -> Int {
        (try? nestedUnkeyedContainer(forKey: key))?.count ?? 0
    }
}

/// Decodes from any value without reading it, which moves an unkeyed container past it.
private struct SkippedElement: Decodable {
    init(from decoder: Decoder) {}
}
