@testable import CameraCore

extension JSONValue {
    /// 递归收集所有 image_url.detail。
    var allImageDetails: [String] {
        switch self {
        case .object(let object):
            var found: [String] = []
            if let detail = object["image_url"]?["detail"]?.stringValue { found.append(detail) }
            for value in object.values { found += value.allImageDetails }
            return found
        case .array(let array): return array.flatMap(\.allImageDetails)
        default: return []
        }
    }

    var allKeys: Set<String> {
        switch self {
        case .object(let object): return Set(object.keys).union(object.values.flatMap(\.allKeys))
        case .array(let array): return Set(array.flatMap(\.allKeys))
        default: return []
        }
    }

    var containsTypeNull: Bool {
        switch self {
        case .object(let object):
            if object["type"] == .string("null") { return true }
            if case .array(let types)? = object["type"], types.contains(.string("null")) { return true }
            return object.values.contains { $0.containsTypeNull }
        case .array(let array): return array.contains { $0.containsTypeNull }
        default: return false
        }
    }
}
