public struct CameraSettings: Codable, Sendable, Equatable {
    public var ratio: FrameRatio
    public var zoom: Double
    public var aperture: Double?
    public var iso: Double?
    public var shutterSeconds: Double?
    public var exposureBias: Double

    /// 曝光参数为 nil 表示由设备自动控制，而非沿用上一次手动值。
    public init(
        ratio: FrameRatio = .standard,
        zoom: Double = 1,
        aperture: Double? = nil,
        iso: Double? = nil,
        shutterSeconds: Double? = nil,
        exposureBias: Double = 0
    ) {
        self.ratio = ratio
        self.zoom = zoom
        self.aperture = aperture
        self.iso = iso
        self.shutterSeconds = shutterSeconds
        self.exposureBias = exposureBias
    }

    public func validate(against limits: CameraLimits) throws {
        try validateValue(zoom, name: "变焦", minimum: limits.minZoom, maximum: limits.maxZoom)
        try validateValue(
            exposureBias, name: "曝光补偿", minimum: limits.minBias,
            maximum: limits.maxBias, requiresPositive: false
        )
        if let aperture {
            try validateValue(
                aperture, name: "光圈", minimum: limits.minAperture, maximum: limits.maxAperture
            )
        }
        if let iso {
            try validateValue(iso, name: "感光度", minimum: limits.minISO, maximum: limits.maxISO)
        }
        if let shutterSeconds {
            try validateValue(
                shutterSeconds, name: "快门时长", minimum: limits.minShutter,
                maximum: limits.maxShutter
            )
        }

        let mode = ExposureModeSupport(
            apertureAuto: aperture == nil,
            shutterAuto: shutterSeconds == nil,
            isoAuto: iso == nil
        )
        guard limits.exposureModes.contains(mode) else {
            throw CameraValidationError.unsupportedExposureMode
        }
        guard aperture == nil || shutterSeconds == nil || iso == nil || exposureBias == 0 else {
            throw CameraValidationError.ineffectiveExposureBias
        }
    }

    private func validateValue(
        _ value: Double,
        name: String,
        minimum: Double,
        maximum: Double,
        requiresPositive: Bool = true
    ) throws {
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum else {
            throw CameraValidationError.invalidHardwareRange(name)
        }
        guard value.isFinite, !requiresPositive || value > 0,
              value >= minimum, value <= maximum else {
            throw CameraValidationError.invalidValue(name)
        }
    }
}
