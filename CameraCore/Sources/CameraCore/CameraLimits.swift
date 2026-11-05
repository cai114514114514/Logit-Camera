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
        exposureModes: [ExposureModeSupport]
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
    }
}
