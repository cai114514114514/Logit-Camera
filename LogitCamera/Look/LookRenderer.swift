import CameraCore
import CoreImage
import ImageIO
import Metal

/// 把配方编译成 Core Image 滤镜图（规格 §1）。取景与成片共用同一份实现。
enum LookRenderer {
    /// 成片渲染用的半精度浮点上下文。
    static let photoContext: CIContext = {
        let options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        if let device = ShaderCompiler.shared.device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    /// - Parameter synchronous: 成片时为 true：自定义着色器当场编译；取景时为 false：没编译好就先跳过。
    static func apply(_ recipe: LookRecipe, to image: CIImage, time: Double = 0, synchronous: Bool = false) -> CIImage {
        guard !recipe.isIdentity else { return image }
        var output = image
        for op in recipe.allOps {
            output = apply(op, to: output, extent: image.extent, time: time, synchronous: synchronous)
        }
        output = output.cropped(to: image.extent)
        if recipe.strength < 1 {
            output = output.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: output, kCIInputImageKey: image, kCIInputTimeKey: recipe.strength
            ]).cropped(to: image.extent)
        }
        return output
    }

    private static func apply(_ op: LookOp, to image: CIImage, extent: CGRect, time: Double, synchronous: Bool) -> CIImage {
        switch op {
        case .exposure(let ev):
            return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        case .whiteBalance(let temperature, let tint):
            // 方向已验证：中性点色温升高 → 画面变暖；中性点 y 为正 → 偏品红。
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + 3000 * temperature, y: 50 * tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        case .contrast(let amount):
            return image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + 0.5 * amount])
        case .saturation(let amount):
            return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + amount])
        case .vibrance(let amount):
            return image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: amount])
        case .toneCurve(let points):
            // 曲线在 sRGB 编码空间中计算，手感与常见修图软件一致。
            let p = ToneCurveMath.fivePoints(points)
            return perceptual(image) {
                $0.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: p[0].x, y: p[0].y), "inputPoint1": CIVector(x: p[1].x, y: p[1].y),
                    "inputPoint2": CIVector(x: p[2].x, y: p[2].y), "inputPoint3": CIVector(x: p[3].x, y: p[3].y),
                    "inputPoint4": CIVector(x: p[4].x, y: p[4].y)
                ])
            }
        case .fade(let amount):
            let lift = 0.15 * amount
            return perceptual(image) {
                $0.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1 - lift, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1 - lift, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1 - lift, w: 0),
                    "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0)
                ])
            }
        case .highlightsShadows(let highlights, let shadows):
            return image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + highlights, "inputShadowAmount": shadows,
                kCIInputRadiusKey: shortSide(extent) * 0.01
            ]).cropped(to: image.extent)
        case .hsl(let bands):
            var params = [Float](repeating: 0, count: 24)
            for band in bands {
                guard let index = HueBand.allCases.firstIndex(of: band.band) else { continue }
                params[index * 3] = Float(band.hue)
                params[index * 3 + 1] = Float(band.saturation)
                params[index * 3 + 2] = Float(band.luminance)
            }
            return builtin(BuiltinShaders.hsl, params, image, extent: extent, time: time, synchronous: synchronous)
        case .colorGrade(let g):
            let params: [Float] = [g.shadows.hue / 360, g.shadows.amount, g.midtones.hue / 360, g.midtones.amount,
                                   g.highlights.hue / 360, g.highlights.amount, g.balance].map(Float.init)
            return builtin(BuiltinShaders.colorGrade, params, image, extent: extent, time: time, synchronous: synchronous)
        case .grain(let amount, let size):
            let params: [Float] = [Float(amount), Float(size), Float(aspect(extent)), synchronous ? 0 : 1]
            return builtin(BuiltinShaders.grain, params, image, extent: extent, time: time, synchronous: synchronous)
        case .vignette(let amount, let midpoint):
            let params: [Float] = [Float(amount), Float(midpoint), Float(aspect(extent))]
            return builtin(BuiltinShaders.vignette, params, image, extent: extent, time: time, synchronous: synchronous)
        case .mono(let red, let green, let blue):
            return builtin(BuiltinShaders.mono, [red, green, blue].map(Float.init), image, extent: extent, time: time,
                           synchronous: synchronous)
        case .bloom(let amount):
            return image.applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: shortSide(extent) * 0.02, kCIInputIntensityKey: amount
            ]).cropped(to: image.extent)
        case .custom(let shader):
            let compiler = ShaderCompiler.shared
            guard let pipeline = synchronous ? compiler.pipelineNow(for: shader.body) : compiler.pipeline(for: shader.body)
            else { return image }
            let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
            do {
                let shaded = try CustomShaderKernel.apply(withExtent: image.extent, inputs: [encoded], arguments: [
                    "pipeline": pipeline, "params": shader.params.map(Float.init), "time": Float(time), "full": extent
                ])
                return shaded.applyingFilter("CISRGBToneCurveToLinear")
            } catch {
                return image
            }
        }
    }

    private static func shortSide(_ extent: CGRect) -> Double { Double(max(1, min(extent.width, extent.height))) }
    private static func aspect(_ extent: CGRect) -> Double { Double(extent.width / max(extent.height, 1)) }

    /// 在 sRGB 编码空间中执行一步操作。
    private static func perceptual(_ image: CIImage, _ body: (CIImage) -> CIImage) -> CIImage {
        body(image.applyingFilter("CILinearToSRGBToneCurve")).applyingFilter("CISRGBToneCurveToLinear")
    }

    /// 执行内置着色器；还没编译好（仅取景）时跳过这一步。
    private static func builtin(_ body: String, _ params: [Float], _ image: CIImage, extent: CGRect, time: Double,
                                synchronous: Bool) -> CIImage {
        let compiler = ShaderCompiler.shared
        guard let pipeline = synchronous ? compiler.pipelineNow(for: body, trusted: true)
                : compiler.pipeline(for: body, trusted: true) else { return image }
        do {
            let shaded = try CustomShaderKernel.apply(withExtent: image.extent,
                                                      inputs: [image.applyingFilter("CILinearToSRGBToneCurve")],
                                                      arguments: ["pipeline": pipeline, "params": params,
                                                                  "time": Float(time), "full": extent])
            return shaded.applyingFilter("CISRGBToneCurveToLinear")
        } catch {
            return image
        }
    }

    /// 成片：按配方渲染已裁切的原片，输出 10-bit HEIC（Display P3），保留拍摄元数据。
    static func renderPhoto(_ data: Data, recipe: LookRecipe) throws -> Data {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw CameraFailure.capture }
        let graded = apply(recipe, to: image, synchronous: true)
        var properties = image.properties
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        return try photoContext.heif10Representation(
            of: graded.settingProperties(properties), colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
    }
}
