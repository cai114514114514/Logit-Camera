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

@Test func everyDefaultPlanIsV2AndValid() throws {
    let focal: [GenreID: Double] = [.portrait: 48, .still: 48, .food: 48, .group: 24, .street: 24, .landscape: 24,
                                    .night: 24, .document: 24, .general: 24, .architecture: 13, .animal: 96]
    for playbook in try Knowledge.allPlaybooks() {
        #expect(playbook.defaultPlan.genre == playbook.id)
        try playbook.defaultPlan.validate(against: typicalLimits)
        #expect(playbook.defaultFocalLength == focal[playbook.id], "\(playbook.id)")
    }
    #expect(try Knowledge.playbook(.portrait).defaultPlan.exposure.motion == .freeze)
    #expect(try Knowledge.playbook(.portrait).defaultPlan.exposure.depth == .shallow)
    #expect(try Knowledge.playbook(.landscape).defaultPlan.exposure.depth == .deep)
    #expect(try Knowledge.playbook(.night).defaultPlan.exposure.isoCeiling == 6400)
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
    #expect(try Knowledge.prompt(.director).contains("set_plan"))
    #expect(try !Knowledge.prompt(.director).contains("keep_plan"))
    #expect(try Knowledge.prompt(.scout).contains("classify_scene"))
    #expect(try !Knowledge.prompt(.system).isEmpty)
}
