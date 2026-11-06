import Testing
@testable import CameraCore

@Test func changedKeepsOnlyParametersWhoseValueMoved() {
    let items = [
        ParameterDelta(id: "aperture", title: "光圈", before: "ƒ/1.8", after: "ƒ/4"),
        ParameterDelta(id: "iso", title: "ISO", before: "100", after: "100"),
        ParameterDelta(id: "ratio", title: "画幅", before: "3:4", after: "1:1")
    ]
    #expect(ParameterDelta.changed(items).map(\.id) == ["aperture", "ratio"])
}
