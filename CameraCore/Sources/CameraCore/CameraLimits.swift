public struct ExposureModeSupport: Codable, Sendable, Equatable {
    public var apertureAuto: Bool
    public var shutterAuto: Bool
    public var isoAuto: Bool

    public init(apertureAuto: Bool, shutterAuto: Bool, isoAuto: Bool) {
        self.apertureAuto = apertureAuto
        self.shutterAuto = shutterAuto
        self.isoAuto = isoAuto
    }
}

/// 当前镜头与格式实际报告的能力；切换镜头或格式后应重新读取。
public struct CameraLimits: Codable, Sendable {
    public var minAperture: Double
    public var maxAperture: Double
    public var apertureStops: [Double]
    public var minISO: Double
    public var maxISO: Double
    public var minShutter: Double
    public var maxShutter: Double
    public var minZoom: Double
    public var maxZoom: Double
    public var minBias: Double
    public var maxBias: Double
    public var exposureModes: [ExposureModeSupport]
    /// 可用的物理镜头档（等效焦距 mm），例如 [13, 24, 48, 96]。
    public var lensStops: [Double]

    public init(
        minAperture: Double,
        maxAperture: Double,
        apertureStops: [Double],
        minISO: Double,
        maxISO: Double,
        minShutter: Double,
        maxShutter: Double,
        minZoom: Double,
        maxZoom: Double,
        minBias: Double,
        maxBias: Double,
        exposureModes: [ExposureModeSupport],
        lensStops: [Double] = []
    ) {
        self.minAperture = minAperture
        self.maxAperture = maxAperture
        self.apertureStops = apertureStops
        self.minISO = minISO
        self.maxISO = maxISO
        self.minShutter = minShutter
        self.maxShutter = maxShutter
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.minBias = minBias
        self.maxBias = maxBias
        self.exposureModes = exposureModes
        self.lensStops = lensStops
    }

    private enum CodingKeys: String, CodingKey {
        case minAperture, maxAperture, apertureStops, minISO, maxISO, minShutter, maxShutter
        case minZoom, maxZoom, minBias, maxBias, exposureModes, lensStops
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minAperture = try c.decode(Double.self, forKey: .minAperture)
        maxAperture = try c.decode(Double.self, forKey: .maxAperture)
        apertureStops = try c.decode([Double].self, forKey: .apertureStops)
        minISO = try c.decode(Double.self, forKey: .minISO)
        maxISO = try c.decode(Double.self, forKey: .maxISO)
        minShutter = try c.decode(Double.self, forKey: .minShutter)
        maxShutter = try c.decode(Double.self, forKey: .maxShutter)
        minZoom = try c.decode(Double.self, forKey: .minZoom)
        maxZoom = try c.decode(Double.self, forKey: .maxZoom)
        minBias = try c.decode(Double.self, forKey: .minBias)
        maxBias = try c.decode(Double.self, forKey: .maxBias)
        exposureModes = try c.decode([ExposureModeSupport].self, forKey: .exposureModes)
        lensStops = try c.decodeIfPresent([Double].self, forKey: .lensStops) ?? []
    }
}
