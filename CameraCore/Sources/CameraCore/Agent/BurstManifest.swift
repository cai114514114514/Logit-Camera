import Foundation

/// 一组连拍的备选记录（规格 §6.4）：存在 `Application Support/Bursts/<photoID>/manifest.json`。
public struct BurstManifest: Codable, Sendable, Equatable {
    public static let maxAge: TimeInterval = 7 * 24 * 3600
    public static let maxCount = 30

    /// 存入相册的那张照片的 id。
    public var photoID: UUID
    public var date: Date
    public var genre: GenreID
    /// AI 选中的序号。
    public var chosen: Int
    /// 按拍摄顺序的文件名（包含选中的那张）。
    public var files: [String]
    public var scores: [Double]
    /// 成片使用的配方；原片 + 配方可以重新渲染。
    public var look: LookRecipe?

    public init(photoID: UUID, date: Date, genre: GenreID, chosen: Int, files: [String], scores: [Double],
                look: LookRecipe? = nil) {
        self.photoID = photoID
        self.date = date
        self.genre = genre
        self.chosen = chosen
        self.files = files
        self.scores = scores
        self.look = look
    }

    /// 应当清理的组：超过 7 天的，以及按时间排在最新 30 组之外的。
    public static func expired(_ manifests: [BurstManifest], now: Date,
                               maxAge: TimeInterval = maxAge, maxCount: Int = maxCount) -> [UUID] {
        let newestFirst = manifests.sorted { $0.date > $1.date }
        return newestFirst.enumerated().compactMap { index, manifest in
            index >= maxCount || now.timeIntervalSince(manifest.date) > maxAge ? manifest.photoID : nil
        }
    }
}
