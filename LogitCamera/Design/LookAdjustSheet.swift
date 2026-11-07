import CameraCore
import SwiftUI

/// 滤镜微调：11 个滑杆实时作用在取景上；可以存为「我的滤镜」。
struct LookAdjustSheet: View {
    @Bindable var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section("光线") {
                    slider("曝光", \.exposure, -1...1)
                    slider("高光", \.highlights, -1...0)
                    slider("阴影", \.shadows, -1...1)
                    slider("对比", \.contrast, -1...1)
                }
                Section("颜色") {
                    slider("色温", \.temperature, -1...1)
                    slider("色调", \.tint, -1...1)
                    slider("饱和", \.saturation, -1...1)
                    slider("自然饱和", \.vibrance, -1...1)
                }
                Section("质感") {
                    slider("褪色", \.fade, 0...1)
                    slider("颗粒", \.grain, 0...1)
                    slider("暗角", \.vignette, -1...1)
                }
                Section {
                    Button("存为我的滤镜") {
                        name = model.lookBase.isIdentity ? "我的滤镜" : "\(model.lookBase.name) · 调整"
                        naming = true
                    }
                    .accessibilityIdentifier("look.save")
                    Button("全部重置", role: .destructive) { model.lookAdjustments = .zero }
                        .disabled(model.lookAdjustments.isZero)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle(model.lookBase.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .alert("给这个滤镜起个名字", isPresented: $naming) {
                TextField("名字", text: $name)
                Button("保存") { model.saveMyLook(named: name) }
                Button("取消", role: .cancel) {}
            }
        }
        .tint(Theme.Palette.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.fraction(0.45), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
        .accessibilityIdentifier("look.adjustSheet")
    }

    private func slider(_ title: String, _ key: WritableKeyPath<LookAdjustments, Double>,
                        _ range: ClosedRange<Double>) -> some View {
        let value = model.lookAdjustments[keyPath: key]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(value == 0 ? "0" : String(format: "%+.0f", value * 100))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }
            Slider(value: Binding(get: { model.lookAdjustments[keyPath: key] },
                                  set: { model.lookAdjustments[keyPath: key] = ($0 * 100).rounded() / 100 }),
                   in: range)
        }
        .onTapGesture(count: 2) { model.lookAdjustments[keyPath: key] = 0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
