extension CameraSettings {
    private enum CodingKeys: String, CodingKey {
        case ratio
        case zoom
        case aperture
        case iso
        case shutterSeconds
        case exposureBias
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ratio: try values.decode(FrameRatio.self, forKey: .ratio),
            zoom: try values.decode(Double.self, forKey: .zoom),
            // decode 可空类型会接受 null，但仍会拒绝缺失的键。
            aperture: try values.decode(Double?.self, forKey: .aperture),
            iso: try values.decode(Double?.self, forKey: .iso),
            shutterSeconds: try values.decode(Double?.self, forKey: .shutterSeconds),
            exposureBias: try values.decode(Double.self, forKey: .exposureBias)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ratio, forKey: .ratio)
        try values.encode(zoom, forKey: .zoom)
        // 保留显式 null，让设备上下文明确表达每项参数的自动状态。
        try values.encode(aperture, forKey: .aperture)
        try values.encode(iso, forKey: .iso)
        try values.encode(shutterSeconds, forKey: .shutterSeconds)
        try values.encode(exposureBias, forKey: .exposureBias)
    }
}
