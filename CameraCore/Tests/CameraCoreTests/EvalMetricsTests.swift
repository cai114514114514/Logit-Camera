import Foundation
import Testing
@testable import CameraCore

@Test func spearmanOfIdenticalRanksIsOne() {
    #expect(abs(EvalMetrics.spearman([1, 2, 3, 4], [10, 20, 30, 40]) - 1) < 1e-9)
}

@Test func spearmanOfReversedIsMinusOne() {
    #expect(abs(EvalMetrics.spearman([1, 2, 3, 4], [4, 3, 2, 1]) + 1) < 1e-9)
}

@Test func spearmanHandlesTies() {
    let value = EvalMetrics.spearman([1, 1, 2, 3], [1, 2, 3, 4])
    #expect(value > 0.9 && value <= 1)
}

@Test func aucOfSeparatedSetsIsOne() {
    #expect(EvalMetrics.auc(positives: [3, 4], negatives: [1, 2]) == 1)
}

@Test func aucOfIdenticalSetsIsHalf() {
    #expect(EvalMetrics.auc(positives: [2, 2], negatives: [2, 2]) == 0.5)
}

@Test func confusionCountsPairs() {
    let matrix = EvalMetrics.confusion(expected: [.portrait, .portrait, .landscape], predicted: [.portrait, .group, .landscape])
    #expect(matrix[.portrait]?[.portrait] == 1)
    #expect(matrix[.portrait]?[.group] == 1)
    #expect(matrix[.landscape]?[.landscape] == 1)
}

@Test func manifestFixtureDecodes() throws {
    let json = #"{"dataset":"spaq","items":[{"file":"00001.jpg","category":"human","expectedGenres":["portrait","group"],"humanScore":72.5}]}"#
    let manifest = try JSONDecoder().decode(EvalManifest.self, from: Data(json.utf8))
    #expect(manifest.items.first?.expectedGenres == [.portrait, .group])
}

@Test func samplerTakesTopAndBottomPerCategory() throws {
    let csv = "Image,MOS,Category\n" + (1...30).map { "\($0).jpg,\($0),human" }.joined(separator: "\n")
        + "\nx.jpg,50,landscape"
    let rows = try EvalSampler.parseCSV(csv)
    let manifest = try EvalSampler.sample(rows, perCategory: 4, dataset: "spaq")
    let human = manifest.items.filter { $0.category == "human" }.map(\.file)
    #expect(Set(human) == ["1.jpg", "2.jpg", "29.jpg", "30.jpg"])
    #expect(manifest.items.first { $0.category == "landscape" }?.expectedGenres == [.landscape])
}

@Test func samplerRejectsMissingColumns() {
    #expect(throws: EvalSampler.SampleError.self) { try EvalSampler.parseCSV("name,score\na.jpg,1") }
}
