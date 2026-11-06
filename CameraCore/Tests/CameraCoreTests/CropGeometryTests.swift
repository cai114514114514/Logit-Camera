import CoreGraphics
import Testing
@testable import CameraCore

@Test func pixelRectMatchesRatioExactly() {
    for ratio in FrameRatio.allCases {
        let rect = CropGeometry.pixelRect(NormalizedRect(x: 0.13, y: 0.21, width: 0.55, height: 0.41),
                                          imageWidth: 3024, imageHeight: 4032, ratio: ratio)
        #expect(abs(rect.width / rect.height - ratio.widthToHeight) < 1e-9)
    }
}

@Test func pixelRectStaysInsideImage() {
    let rect = CropGeometry.pixelRect(NormalizedRect(x: 0.9, y: 0.9, width: 0.5, height: 0.375),
                                      imageWidth: 3024, imageHeight: 4032, ratio: .standard)
    #expect(rect.minX >= 0 && rect.minY >= 0)
    #expect(rect.maxX <= 3024 && rect.maxY <= 4032)
}

@Test func pixelRectRespectsOrientation() {
    // 左上角的裁切框：top-left 像素坐标 y 接近 0；换成 Core Image（左下原点）后 y 接近底部。
    // 3:4 传感器上，归一化宽高相等的框才是 3:4。
    let top = CropGeometry.pixelRect(NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                     imageWidth: 3024, imageHeight: 4032, ratio: .standard)
    #expect(top.minX == 0 && top.minY == 0)
    let flipped = CropGeometry.bottomLeft(top, imageHeight: 4032)
    #expect(flipped.minY == 4032 - top.height)
    #expect(flipped.size == top.size)
}

@Test func centeredRectEqualsLegacyCrop() {
    for ratio in FrameRatio.allCases {
        let centered = CropGeometry.centered(ratio: ratio, sensorAspect: 3024.0 / 4032)
        let rect = CropGeometry.pixelRect(centered, imageWidth: 3024, imageHeight: 4032, ratio: ratio)
        #expect(rect == ratio.cropRect(width: 3024, height: 4032))
    }
}
