import Foundation
import CoreGraphics
import Testing
@testable import CameraCore

@Test func fullSensorFrameDoesNotLosePixelsAtItsNativeRatio() {
    #expect(FrameRatio.standard.cropRect(width: 3024, height: 4032)
        == CGRect(x: 0, y: 0, width: 3024, height: 4032))
}

@Test func portraitSensorProducesCenteredCropsForEveryOfferedRatio() {
    #expect(FrameRatio.tall.cropRect(width: 3024, height: 4032)
        == CGRect(x: 378, y: 0, width: 2268, height: 4032))
    #expect(FrameRatio.square.cropRect(width: 3024, height: 4032)
        == CGRect(x: 0, y: 504, width: 3024, height: 3024))
    #expect(FrameRatio.standard.cropRect(width: 4032, height: 3024)
        == CGRect(x: 882, y: 0, width: 2268, height: 3024))
}

@Test func oddDimensionsStayPixelAlignedWithoutChangingTheRequestedRatio() {
    #expect(FrameRatio.standard.cropRect(width: 100, height: 101)
        == CGRect(x: 12, y: 0, width: 75, height: 100))
    #expect(FrameRatio.tall.cropRect(width: 101, height: 100)
        == CGRect(x: 23, y: 2, width: 54, height: 96))
}

@Test func tinyImagesKeepAtLeastOnePixelAndNeverEscapeTheirBounds() throws {
    for ratio in FrameRatio.allCases {
        #expect(ratio.cropRect(width: 1, height: 1)
            == CGRect(x: 0, y: 0, width: 1, height: 1))
        let crop = try #require(ratio.cropRect(width: 2, height: 3))
        #expect(crop.width >= 1 && crop.height >= 1)
        #expect(CGRect(x: 0, y: 0, width: 2, height: 3).contains(crop))
    }
}

@Test func nonexistentImagesDoNotProduceCropRectangles() {
    for ratio in FrameRatio.allCases {
        #expect(ratio.cropRect(width: 0, height: 20) == nil)
        #expect(ratio.cropRect(width: 20, height: 0) == nil)
        #expect(ratio.cropRect(width: -1, height: 20) == nil)
        #expect(ratio.cropRect(width: 20, height: -1) == nil)
    }
}

@Test func unofferedRatiosCannotEnterThroughModelJSON() {
    for value in ["4:3", "16:9", "portrait", "", "3/4"] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FrameRatio.self, from: Data("\"\(value)\"".utf8))
        }
    }
}
