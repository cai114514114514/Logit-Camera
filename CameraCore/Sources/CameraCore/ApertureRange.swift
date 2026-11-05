public struct ApertureRange: Sendable {
    public let minimum: Float
    public let maximum: Float
    public let stops: [Float]

    public init?(minimum: Float, maximum: Float, stops: [Float]) {
        guard minimum.isFinite, maximum.isFinite,
              minimum > 0, maximum >= minimum else { return nil }
        self.minimum = minimum
        self.maximum = maximum
        self.stops = Array(Set(stops.filter {
            $0.isFinite && $0 >= minimum && $0 <= maximum
        })).sorted()
    }

    public var isVariable: Bool { maximum > minimum }

    public func contains(_ aperture: Float) -> Bool {
        aperture.isFinite && aperture >= minimum && aperture <= maximum
    }
}
