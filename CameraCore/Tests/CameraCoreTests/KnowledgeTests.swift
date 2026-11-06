import Testing
@testable import CameraCore

@Test func allGenresLoad() throws {
    let playbooks = try Knowledge.allPlaybooks()
    #expect(Set(playbooks.map(\.id)) == Set(GenreID.allCases))
}

@Test func weightsSumToOne() throws {
    for playbook in try Knowledge.allPlaybooks() {
        #expect(Set(playbook.rubricWeights.keys) == Set(RubricCriterion.allCases), "\(playbook.id)")
        #expect(abs(playbook.rubricWeights.values.reduce(0, +) - 1) < 1e-6, "\(playbook.id)")
    }
}

@Test func defaultPlansValidate() throws {
    for playbook in try Knowledge.allPlaybooks() {
        #expect(playbook.defaultPlan.genre == playbook.id)
        try playbook.defaultPlan.validate(against: typicalLimits)
    }
}

@Test func everyGenreHasPrinciples() throws {
    for playbook in try Knowledge.allPlaybooks() {
        let p = playbook.principles
        for group in [p.composition, p.light, p.exposure, p.timing, p.faults] {
            #expect((3...6).contains(group.count), "\(playbook.id)")
        }
        #expect(!playbook.cues.labels.isEmpty || playbook.id == .general)
    }
}

@Test func spaqCategoriesCoverAllNine() throws {
    let covered = Set(try Knowledge.allPlaybooks().flatMap(\.spaqCategories))
    let expected: Set = ["animal", "cityscape", "human", "indoor scene", "landscape", "night scene",
                         "plant", "still life", "others"]
    #expect(expected.isSubset(of: covered))
}

@Test func rubricAnchorsCoverEveryCriterion() throws {
    let anchors = try Knowledge.rubricAnchors()
    #expect(Set(anchors.keys) == Set(RubricCriterion.allCases.filter { $0 != .genre }))
}

@Test func promptsExistAndMentionTools() throws {
    #expect(try Knowledge.prompt(.judge).contains("set_plan"))
    #expect(try Knowledge.prompt(.judge).contains("keep_plan"))
    #expect(try Knowledge.prompt(.scout).contains("classify_scene"))
    #expect(try !Knowledge.prompt(.system).isEmpty)
}
