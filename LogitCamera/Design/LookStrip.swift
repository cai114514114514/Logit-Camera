import CameraCore
import SwiftUI

/// 滤镜条：带实时缩略图的预设与「我的滤镜」，选中后可调强度与打开调整面板。
struct LookStrip: View {
    @Bindable var model: CameraModel
    @State private var thumbnails: [String: UIImage] = [:]

    private var looks: [LookRecipe] { model.presets + model.myLooks }

    var body: some View {
        VStack(spacing: 10) {
            if !model.lookBase.isIdentity {
                HStack(spacing: 12) {
                    Text(model.lookBase.name)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    Slider(value: $model.lookStrength, in: 0...1)
                        .tint(.white)
                        .accessibilityLabel("滤镜强度")
                        .accessibilityValue("\(Int(model.lookStrength * 100))%")
                        .accessibilityIdentifier("look.strength")
                    Text("\(Int(model.lookStrength * 100))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.Palette.inkSecondary)
                        .frame(width: 26, alignment: .trailing)
                    Button("调整") { model.showsLookAdjust = true }
                        .font(.system(.caption, weight: .semibold))
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityIdentifier("look.adjust")
                }
                .padding(.horizontal, Theme.Metric.gutter)
                .transition(.opacity)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(looks, id: \.name) { look in
                            item(look).id(look.name)
                        }
                    }
                    .padding(.horizontal, Theme.Metric.gutter)
                }
                .onAppear { proxy.scrollTo(model.lookBase.name, anchor: .center) }
            }
            .accessibilityIdentifier("look.strip")
        }
        .animation(.snappy(duration: 0.2), value: model.lookBase.name)
        .hudTypeSize()
        .task { await refreshLoop() }
    }

    private func item(_ look: LookRecipe) -> some View {
        let selected = model.lookBase.name == look.name
        let mine = model.myLooks.contains { $0.name == look.name }
        return Button { model.selectLook(look) } label: {
            VStack(spacing: 4) {
                Group {
                    if let image = thumbnails[look.name] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Theme.Palette.hairline)
                    }
                }
                .frame(width: 52, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.white : .clear, lineWidth: 2))
                Text(look.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.Palette.ink : Theme.Palette.inkSecondary)
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if mine {
                Button("删除这个滤镜", role: .destructive) { model.deleteMyLook(named: look.name) }
            }
        }
        .accessibilityLabel(look.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("look.\(look.name)")
    }

    /// 每 0.6 秒用最新取景帧刷新缩略图（后台低优先级）。
    private func refreshLoop() async {
        while !Task.isCancelled {
            let frames = model.capture.frames
            let looks = self.looks
            let rendered = await Task.detached(priority: .utility) { () -> [String: UIImage] in
                guard let source = LookThumbnails.source(from: frames) else { return [:] }
                var result: [String: UIImage] = [:]
                for look in looks { result[look.name] = LookThumbnails.render(source, look) }
                return result
            }.value
            if !rendered.isEmpty { thumbnails = rendered }
            try? await Task.sleep(for: .milliseconds(600))
        }
    }
}
