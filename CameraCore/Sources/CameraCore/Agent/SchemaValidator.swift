/// 客户端二次校验模型的工具参数：即使服务端严格模式失效，也不接受 schema 之外的输出。
/// 支持本项目 schema 用到的子集：type、enum、minimum、maximum、properties、required、
/// additionalProperties: false、items。
public enum SchemaValidator {
    public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "$") throws {
        if let options = schema["enum"]?.arrayValue, !options.contains(value) {
            throw ModelError.schema("\(path) 不在枚举中")
        }
        switch schema["type"]?.stringValue {
        case "object":
            guard let object = value.objectValue else { throw ModelError.schema("\(path) 应为对象") }
            let properties = schema["properties"]?.objectValue ?? [:]
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
                throw ModelError.schema("\(path).\(key) 缺失")
            }
            for (key, child) in object {
                guard let childSchema = properties[key] else {
                    if schema["additionalProperties"] == .bool(false) { throw ModelError.schema("\(path).\(key) 不允许") }
                    continue
                }
                try validate(child, against: childSchema, path: "\(path).\(key)")
            }
        case "array":
            guard let array = value.arrayValue else { throw ModelError.schema("\(path) 应为数组") }
            if let items = schema["items"] {
                for (index, item) in array.enumerated() { try validate(item, against: items, path: "\(path)[\(index)]") }
            }
        case "number", "integer":
            guard let number = value.doubleValue, number.isFinite else { throw ModelError.schema("\(path) 应为数字") }
            if schema["type"] == "integer", number.rounded() != number { throw ModelError.schema("\(path) 应为整数") }
            if let minimum = schema["minimum"]?.doubleValue, number < minimum { throw ModelError.schema("\(path) 过小") }
            if let maximum = schema["maximum"]?.doubleValue, number > maximum { throw ModelError.schema("\(path) 过大") }
        case "string":
            guard value.stringValue != nil else { throw ModelError.schema("\(path) 应为字符串") }
        case "boolean":
            guard value.boolValue != nil else { throw ModelError.schema("\(path) 应为布尔值") }
        default:
            break
        }
    }
}

/// 检查 schema 满足 DeepSeek 严格模式：每个对象 additionalProperties 为 false 且全部属性 required。
public enum SchemaLint {
    public static func checkStrict(_ schema: JSONValue, path: String = "$") throws {
        if schema["type"] == "object" {
            let keys = Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? [])
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            guard schema["additionalProperties"] == .bool(false), keys == required else {
                throw ModelError.schema("\(path) 不满足严格模式")
            }
        }
        for (key, child) in schema.objectValue ?? [:] where key == "properties" || key == "items" {
            if key == "items" { try checkStrict(child, path: "\(path).items") }
            for (name, property) in child.objectValue ?? [:] where key == "properties" {
                try checkStrict(property, path: "\(path).\(name)")
            }
        }
    }
}
