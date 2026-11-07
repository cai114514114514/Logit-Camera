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

/// HSL 的八个色相段。
public enum HueBand: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    /// 段中心色相（度）。
    public var center: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 270
        case .magenta: 300
        }
    }
}

public struct HSLBand: Codable, Sendable, Equatable {
    public var band: HueBand
    /// 色相偏移 −1…1（±30°）、饱和度与明度 −1…1。
    public var hue: Double
    public var saturation: Double
    public var luminance: Double

    public init(_ band: HueBand, hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.band = band
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    private enum Keys: String, CodingKey { case band, hue, saturation, luminance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        band = try c.decode(HueBand.self, forKey: .band)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        luminance = try c.decodeIfPresent(Double.self, forKey: .luminance) ?? 0
    }
}

public struct GradeWheel: Codable, Sendable, Equatable {
    /// 色相 0…360、强度 0…1。
    public var hue: Double
    public var amount: Double

    public init(hue: Double = 0, amount: Double = 0) {
        self.hue = hue
        self.amount = amount
    }
}

/// 三向色轮：阴影、中间调、高光各自叠加色偏；balance 移动阴影与高光的分界。
public struct ColorGrade: Codable, Sendable, Equatable {
    public var shadows: GradeWheel
    public var midtones: GradeWheel
    public var highlights: GradeWheel
    public var balance: Double

    public init(shadows: GradeWheel = GradeWheel(), midtones: GradeWheel = GradeWheel(),
                highlights: GradeWheel = GradeWheel(), balance: Double = 0) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.balance = balance
    }

    private enum Keys: String, CodingKey { case shadows, midtones, highlights, balance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        shadows = try c.decodeIfPresent(GradeWheel.self, forKey: .shadows) ?? GradeWheel()
        midtones = try c.decodeIfPresent(GradeWheel.self, forKey: .midtones) ?? GradeWheel()
        highlights = try c.decodeIfPresent(GradeWheel.self, forKey: .highlights) ?? GradeWheel()
        balance = try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0
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
    case highlightsShadows(highlights: Double, shadows: Double)
    case hsl([HSLBand])
    case colorGrade(ColorGrade)
    case grain(amount: Double, size: Double)
    case vignette(amount: Double, midpoint: Double)
    case mono(red: Double, green: Double, blue: Double)
    case bloom(Double)
    /// 以 (x, y)（左上原点）为中心的柔和径向补光；radius 相对短边，amount 单位 EV。
    case subjectLight(x: Double, y: Double, radius: Double, amount: Double)
    /// 天空恢复：压暗画面上方偏蓝偏亮的区域并略加饱和；horizon 为天空下沿（0…1，左上原点）。
    case skyRecover(amount: Double, horizon: Double)
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
        case .highlightsShadows: "highlightsShadows"
        case .hsl: "hsl"
        case .colorGrade: "colorGrade"
        case .grain: "grain"
        case .vignette: "vignette"
        case .mono: "mono"
        case .bloom: "bloom"
        case .subjectLight: "subjectLight"
        case .skyRecover: "skyRecover"
        case .custom: "custom"
        }
    }
}

extension LookOp: Codable {
    private enum Keys: String, CodingKey {
        case op, ev, temperature, tint, amount, points, name, body, params
        case highlights, shadows, midtones, balance, bands, size, midpoint, red, green, blue
        case x, y, radius, horizon
    }

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
        case "highlightsShadows":
            self = .highlightsShadows(highlights: try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0,
                                      shadows: try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0)
        case "hsl": self = .hsl(try c.decode([HSLBand].self, forKey: .bands))
        case "colorGrade": self = .colorGrade(try ColorGrade(from: decoder))
        case "grain":
            self = .grain(amount: try c.decode(Double.self, forKey: .amount),
                          size: try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.5)
        case "vignette":
            self = .vignette(amount: try c.decode(Double.self, forKey: .amount),
                             midpoint: try c.decodeIfPresent(Double.self, forKey: .midpoint) ?? 0.5)
        case "mono":
            self = .mono(red: try c.decodeIfPresent(Double.self, forKey: .red) ?? 0.3,
                         green: try c.decodeIfPresent(Double.self, forKey: .green) ?? 0.59,
                         blue: try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0.11)
        case "bloom": self = .bloom(try c.decode(Double.self, forKey: .amount))
        case "subjectLight":
            self = .subjectLight(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
                                 radius: try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.3,
                                 amount: try c.decode(Double.self, forKey: .amount))
        case "skyRecover":
            self = .skyRecover(amount: try c.decode(Double.self, forKey: .amount),
                               horizon: try c.decodeIfPresent(Double.self, forKey: .horizon) ?? 0.45)
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
        case .highlightsShadows(let highlights, let shadows):
            try c.encode(highlights, forKey: .highlights)
            try c.encode(shadows, forKey: .shadows)
        case .hsl(let bands): try c.encode(bands, forKey: .bands)
        case .colorGrade(let grade):
            try c.encode(grade.shadows, forKey: .shadows)
            try c.encode(grade.midtones, forKey: .midtones)
            try c.encode(grade.highlights, forKey: .highlights)
            try c.encode(grade.balance, forKey: .balance)
        case .grain(let amount, let size):
            try c.encode(amount, forKey: .amount)
            try c.encode(size, forKey: .size)
        case .vignette(let amount, let midpoint):
            try c.encode(amount, forKey: .amount)
            try c.encode(midpoint, forKey: .midpoint)
        case .mono(let red, let green, let blue):
            try c.encode(red, forKey: .red)
            try c.encode(green, forKey: .green)
            try c.encode(blue, forKey: .blue)
        case .bloom(let amount): try c.encode(amount, forKey: .amount)
        case .subjectLight(let x, let y, let radius, let amount):
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(radius, forKey: .radius)
            try c.encode(amount, forKey: .amount)
        case .skyRecover(let amount, let horizon):
            try c.encode(amount, forKey: .amount)
            try c.encode(horizon, forKey: .horizon)
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
        case .highlightsShadows(let highlights, let shadows):
            try check(highlights, -1...0, "\(path).highlights −1…0")
            try check(shadows, -1...1, "\(path).shadows −1…1")
        case .hsl(let bands):
            guard bands.count <= HueBand.allCases.count else { throw .outOfRange("\(path).bands 最多 8 条") }
            guard Set(bands.map(\.band)).count == bands.count else { throw .outOfRange("\(path).bands 色相段不能重复") }
            for band in bands {
                try check(band.hue, -1...1, "\(path).\(band.band.rawValue).hue −1…1")
                try check(band.saturation, -1...1, "\(path).\(band.band.rawValue).saturation −1…1")
                try check(band.luminance, -1...1, "\(path).\(band.band.rawValue).luminance −1…1")
            }
        case .colorGrade(let grade):
            for (name, wheel) in [("shadows", grade.shadows), ("midtones", grade.midtones), ("highlights", grade.highlights)] {
                try check(wheel.hue, 0...360, "\(path).\(name).hue 0…360")
                try check(wheel.amount, 0...1, "\(path).\(name).amount 0…1")
            }
            try check(grade.balance, -1...1, "\(path).balance −1…1")
        case .grain(let amount, let size):
            try check(amount, 0...1, "\(path).amount 0…1")
            try check(size, 0...1, "\(path).size 0…1")
        case .vignette(let amount, let midpoint):
            try check(amount, -1...1, "\(path).amount −1…1")
            try check(midpoint, 0...1, "\(path).midpoint 0…1")
        case .mono(let red, let green, let blue):
            for (name, value) in [("red", red), ("green", green), ("blue", blue)] { try check(value, 0...1, "\(path).\(name) 0…1") }
            guard red + green + blue > 0.01 else { throw .outOfRange("\(path) 权重之和必须大于 0") }
        case .bloom(let amount): try check(amount, 0...1, "\(path).amount 0…1")
        case .subjectLight(let x, let y, let radius, let amount):
            try check(x, 0...1, "\(path).x 0…1")
            try check(y, 0...1, "\(path).y 0…1")
            try check(radius, 0.05...1, "\(path).radius 0.05…1")
            try check(amount, -1...1, "\(path).amount −1…1")
        case .skyRecover(let amount, let horizon):
            try check(amount, 0...1, "\(path).amount 0…1")
            try check(horizon, 0...1, "\(path).horizon 0…1")
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
