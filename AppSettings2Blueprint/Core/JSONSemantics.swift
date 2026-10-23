import Foundation

nonisolated extension JSONValue {
    /// Equality that allows for server canonicalisation: object key order is
    /// ignored and numbers compare by value (`1.0` equals `1`). Arrays stay
    /// ordered, strings and booleans compare exactly. Duplicate keys compare by
    /// their first occurrence, as `JSONObject` reads them.
    func isSemanticallyEqual(to other: JSONValue) -> Bool {
        switch (self, other) {
        case (.null, .null):
            return true
        case let (.bool(a), .bool(b)):
            return a == b
        case let (.string(a), .string(b)):
            return a == b
        case let (.number(a), .number(b)):
            if a.literal == b.literal { return true }
            guard let left = Decimal(string: a.literal, locale: Locale(identifier: "en_US_POSIX")),
                  let right = Decimal(string: b.literal, locale: Locale(identifier: "en_US_POSIX")) else { return false }
            return left == right
        case let (.array(a), .array(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.isSemanticallyEqual(to: $1) }
        case let (.object(a), .object(b)):
            let leftKeys = Set(a.keys)
            guard leftKeys == Set(b.keys) else { return false }
            return leftKeys.allSatisfy { key in
                guard let left = a[key], let right = b[key] else { return false }
                return left.isSemanticallyEqual(to: right)
            }
        default:
            return false
        }
    }
}

nonisolated extension JSONValue {
    /// `self` with object members reordered to follow `reference`'s key order:
    /// keys `reference` has come first, in its order; new keys follow in their own
    /// order. Applied recursively (array elements by position), so rewriting a
    /// value keeps the diff to what actually changed.
    func aligned(to reference: JSONValue) -> JSONValue {
        switch (self, reference) {
        case let (.object(object), .object(referenceObject)):
            var members: [JSONObject.Member] = []
            var remaining = object.members
            for key in referenceObject.keys {
                guard let index = remaining.firstIndex(where: { $0.key == key }) else { continue }
                var member = remaining.remove(at: index)
                if let referenceValue = referenceObject[key] { member.value = member.value.aligned(to: referenceValue) }
                members.append(member)
            }
            return .object(JSONObject(members + remaining))
        case let (.array(array), .array(referenceArray)):
            return .array(array.enumerated().map { index, element in
                referenceArray.indices.contains(index) ? element.aligned(to: referenceArray[index]) : element
            })
        default:
            return self
        }
    }
}
