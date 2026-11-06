import Foundation

/// 离线评测的统计指标。
public enum EvalMetrics {
    /// Spearman 等级相关（并列取平均秩）。
    public static func spearman(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let ra = ranks(a), rb = ranks(b)
        let ma = ra.reduce(0, +) / Double(ra.count), mb = rb.reduce(0, +) / Double(rb.count)
        var covariance = 0.0, va = 0.0, vb = 0.0
        for i in ra.indices {
            covariance += (ra[i] - ma) * (rb[i] - mb)
            va += (ra[i] - ma) * (ra[i] - ma)
            vb += (rb[i] - mb) * (rb[i] - mb)
        }
        guard va > 0, vb > 0 else { return 0 }
        return covariance / (va * vb).squareRoot()
    }

    /// AUC（Mann–Whitney）：随机取一好一差，好图得分更高的概率；并列计 0.5。
    public static func auc(positives: [Double], negatives: [Double]) -> Double {
        guard !positives.isEmpty, !negatives.isEmpty else { return 0.5 }
        var wins = 0.0
        for p in positives { for n in negatives { wins += p > n ? 1 : (p == n ? 0.5 : 0) } }
        return wins / Double(positives.count * negatives.count)
    }

    public static func confusion(expected: [GenreID], predicted: [GenreID]) -> [GenreID: [GenreID: Int]] {
        var matrix: [GenreID: [GenreID: Int]] = [:]
        for (e, p) in zip(expected, predicted) { matrix[e, default: [:]][p, default: 0] += 1 }
        return matrix
    }

    private static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var result = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, values[order[j + 1]] == values[order[i]] { j += 1 }
            let rank = Double(i + j) / 2 + 1
            for k in i...j { result[order[k]] = rank }
            i = j + 1
        }
        return result
    }
}

/// 评测清单：仓库只保存图片文件名与标签，图片由开发者自行下载（数据集未声明再分发许可）。
public struct EvalManifest: Codable, Sendable {
    public var dataset: String
    public var items: [EvalItem]

    public init(dataset: String, items: [EvalItem]) {
        self.dataset = dataset
        self.items = items
    }
}

public struct EvalItem: Codable, Sendable, Equatable {
    public var file: String
    public var category: String?
    /// 数据集类别对应的题材（来自题材打法的 spaqCategories）；一个类别可对应多个题材。
    public var expectedGenres: [GenreID]
    /// 数据集自带的人工评分（原始量表）。
    public var humanScore: Double

    public init(file: String, category: String?, expectedGenres: [GenreID], humanScore: Double) {
        self.file = file
        self.category = category
        self.expectedGenres = expectedGenres
        self.humanScore = humanScore
    }
}

/// 从数据集标签（CSV：图片名、人工分、类别三列）生成抽样清单：每个类别取人工分最高与最低各一半。
public enum EvalSampler {
    public struct Row: Sendable, Equatable {
        public let file: String
        public let score: Double
        public let category: String
    }

    public enum SampleError: Error, Equatable {
        case missingColumn(String)
        case badRow(Int)
    }

    /// 表头不区分大小写：图片列含 image / name / file，分数列含 mos / score，类别列含 category / scene / class。
    public static func parseCSV(_ text: String) throws -> [Row] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first?.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) else {
            throw SampleError.missingColumn("header")
        }
        func column(_ keys: [String], _ name: String) throws -> Int {
            guard let index = header.firstIndex(where: { h in keys.contains { h.contains($0) } }) else {
                throw SampleError.missingColumn(name)
            }
            return index
        }
        let file = try column(["image", "name", "file"], "image")
        let score = try column(["mos", "score"], "mos")
        let category = try column(["category", "scene", "class"], "category")
        return try lines.dropFirst().enumerated().compactMap { offset, line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            guard fields.count > max(file, score, category), let value = Double(fields[score]) else {
                throw SampleError.badRow(offset + 2)
            }
            return Row(file: fields[file], score: value, category: fields[category].lowercased())
        }
    }

    public static func sample(_ rows: [Row], perCategory: Int, dataset: String) throws -> EvalManifest {
        let playbooks = try Knowledge.allPlaybooks()
        var items: [EvalItem] = []
        for category in Set(rows.map(\.category)).sorted() {
            let sorted = rows.filter { $0.category == category }.sorted { $0.score < $1.score }
            let half = max(1, perCategory / 2)
            let picked = sorted.count <= perCategory ? sorted : Array(sorted.prefix(half)) + Array(sorted.suffix(perCategory - half))
            let genres = playbooks.filter { $0.spaqCategories.contains(category) }.map(\.id)
            items += picked.map { EvalItem(file: $0.file, category: category, expectedGenres: genres, humanScore: $0.score) }
        }
        return EvalManifest(dataset: dataset, items: items)
    }
}
