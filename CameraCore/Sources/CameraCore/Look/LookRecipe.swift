import Foundation

public enum LookValidationError: Error, Equatable, Sendable {
    case outOfRange(String)
    case tooManyOps(String)
    case shader(String)

    public var detail: String {
        switch self {
        case .outOfRange(let text): "超出范围：\(text)"
        case .tooManyOps(let text): "操作过多：\(text)"
        case .shader(let text): "着色器不合规：\(text)"
        }
    }
}

public struct CurvePoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// JSON 中写作 `[x, y]`。
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }
}

/// AI 写的一小段逐像素着色代码（见 ShaderSandbox）。
public struct CustomShader: Codable, Sendable, Equatable {
    public var name: String
    public var body: String
    public var params: [Double]

    public init(name: String, body: String, params: [Double] = []) {
        self.name = name
        self.body = body
        self.params = params
    }
}

/// 配方中的一步调色操作。JSON：`{"op": "exposure", "ev": 0.3}`。
public enum LookOp: Sendable, Equatable {
    case exposure(ev: Double)
    case whiteBalance(temperature: Double, tint: Double)
    case contrast(Double)
    case saturation(Double)
    case vibrance(Double)
    case toneCurve([CurvePoint])
    case fade(Double)
    case custom(CustomShader)

    public var name: String {
        switch self {
        case .exposure: "exposure"
        case .whiteBalance: "whiteBalance"
        case .contrast: "contrast"
        case .saturation: "saturation"
        case .vibrance: "vibrance"
        case .toneCurve: "toneCurve"
        case .fade: "fade"
        case .custom: "custom"
        }
    }
}

extension LookOp: Codable {
    private enum Keys: String, CodingKey { case op, ev, temperature, tint, amount, points, name, body, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "exposure": self = .exposure(ev: try c.decode(Double.self, forKey: .ev))
        case "whiteBalance":
            self = .whiteBalance(temperature: try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0,
                                 tint: try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0)
        case "contrast": self = .contrast(try c.decode(Double.self, forKey: .amount))
        case "saturation": self = .saturation(try c.decode(Double.self, forKey: .amount))
        case "vibrance": self = .vibrance(try c.decode(Double.self, forKey: .amount))
        case "toneCurve": self = .toneCurve(try c.decode([CurvePoint].self, forKey: .points))
        case "fade": self = .fade(try c.decode(Double.self, forKey: .amount))
        case "custom":
            self = .custom(CustomShader(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "自定义",
                                        body: try c.decode(String.self, forKey: .body),
                                        params: try c.decodeIfPresent([Double].self, forKey: .params) ?? []))
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "未知的调色操作 \(op)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .op)
        switch self {
        case .exposure(let ev): try c.encode(ev, forKey: .ev)
        case .whiteBalance(let temperature, let tint):
            try c.encode(temperature, forKey: .temperature)
            try c.encode(tint, forKey: .tint)
        case .contrast(let v), .saturation(let v), .vibrance(let v), .fade(let v): try c.encode(v, forKey: .amount)
        case .toneCurve(let points): try c.encode(points, forKey: .points)
        case .custom(let shader):
            try c.encode(shader.name, forKey: .name)
            try c.encode(shader.body, forKey: .body)
            try c.encode(shader.params, forKey: .params)
        }
    }
}

/// 滤镜配方：修正层先执行，风格层后执行，再按 strength 与原图混合。取景与成片共用。
public struct LookRecipe: Codable, Sendable, Equatable {
    public static let maxOpsPerLayer = 16

    public var version: Int
    public var name: String
    public var strength: Double
    public var correction: [LookOp]
    public var style: [LookOp]

    public init(name: String, strength: Double = 1, correction: [LookOp] = [], style: [LookOp] = []) {
        version = 1
        self.name = name
        self.strength = strength
        self.correction = correction
        self.style = style
    }

    private enum Keys: String, CodingKey { case version, name, strength, correction, style }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名"
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        correction = try c.decodeIfPresent([LookOp].self, forKey: .correction) ?? []
        style = try c.decodeIfPresent([LookOp].self, forKey: .style) ?? []
    }

    public static let identity = LookRecipe(name: "原片")

    /// 不改变画面（没有操作或强度为 0）。
    public var isIdentity: Bool { strength <= 0 || (correction.isEmpty && style.isEmpty) }

    public var allOps: [LookOp] { correction + style }

    public func validate() throws(LookValidationError) {
        try check(strength, 0...1, "strength")
        guard correction.count <= Self.maxOpsPerLayer else { throw .tooManyOps("correction") }
        guard style.count <= Self.maxOpsPerLayer else { throw .tooManyOps("style") }
        for (layer, ops) in [("correction", correction), ("style", style)] {
            for (index, op) in ops.enumerated() {
                try validate(op, at: "\(layer)[\(index)]")
            }
        }
    }

    private func validate(_ op: LookOp, at path: String) throws(LookValidationError) {
        switch op {
        case .exposure(let ev): try check(ev, -2...2, "\(path).ev −2…2")
        case .whiteBalance(let temperature, let tint):
            try check(temperature, -1...1, "\(path).temperature −1…1")
            try check(tint, -1...1, "\(path).tint −1…1")
        case .contrast(let v), .saturation(let v), .vibrance(let v): try check(v, -1...1, "\(path).amount −1…1")
        case .fade(let v): try check(v, 0...1, "\(path).amount 0…1")
        case .toneCurve(let points):
            guard (2...8).contains(points.count) else { throw .outOfRange("\(path).points 2–8 个") }
            for point in points {
                try check(point.x, 0...1, "\(path).points x 0…1")
                try check(point.y, 0...1, "\(path).points y 0…1")
            }
            guard zip(points, points.dropFirst()).allSatisfy({ $0.x < $1.x }) else {
                throw .outOfRange("\(path).points x 必须严格递增")
            }
        case .custom(let shader):
            guard shader.params.count <= ShaderSandbox.maxParams else { throw .outOfRange("\(path).params 最多 8 个") }
            for value in shader.params { try check(value, -10...10, "\(path).params −10…10") }
            try ShaderSandbox.validate(shader.body)
        }
    }

    private func check(_ value: Double, _ range: ClosedRange<Double>, _ name: String) throws(LookValidationError) {
        guard value.isFinite, range.contains(value) else { throw .outOfRange(name) }
    }
}

/// 曲线插值：单调三次（Fritsch–Carlson），保证不会出现过冲。
public enum ToneCurveMath {
    public static func sample(_ points: [CurvePoint], at x: Double) -> Double {
        let p = points.sorted { $0.x < $1.x }
        guard let first = p.first, let last = p.last else { return x }
        if p.count == 1 { return first.y }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        let n = p.count
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { delta[i] = (p[i + 1].y - p[i].y) / (p[i + 1].x - p[i].x) }
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) { m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2 }
        for i in 0..<(n - 1) where delta[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
        }
        for i in 0..<(n - 1) where delta[i] != 0 {
            let a = m[i] / delta[i], b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * delta[i]
                m[i + 1] = t * b * delta[i]
            }
        }
        let k = (0..<(n - 1)).last { p[$0].x <= x } ?? 0
        let h = p[k + 1].x - p[k].x
        let t = (x - p[k].x) / h
        let t2 = t * t, t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * m[k + 1]
        return min(max(value, 0), 1)
    }

    /// CIToneCurve 的 5 个采样点。
    public static func fivePoints(_ points: [CurvePoint]) -> [CurvePoint] {
        [0, 0.25, 0.5, 0.75, 1].map { CurvePoint($0, sample(points, at: $0)) }
    }
}
