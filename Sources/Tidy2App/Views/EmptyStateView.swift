import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var action: (() -> Void)? = nil
    var actionLabel: String? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            if let action, let label = actionLabel {
                Button(label, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                    .accessibilityLabel(label)
                    .accessibilityHint("执行当前空状态中的推荐操作")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

extension View {
    func tidyAccessibility(label: String, hint: String? = nil) -> some View {
        var view = AnyView(self.accessibilityLabel(label))
        if let hint, !hint.isEmpty {
            view = AnyView(view.accessibilityHint(hint))
        }
        return view
    }

    func tidyFileRowAccessibility(name: String, value: String) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityLabel(name)
            .accessibilityValue(value)
    }

    func tidyProgressAccessibility(_ label: String = "处理中") -> some View {
        accessibilityLabel(label)
    }

    @ViewBuilder
    func tidyFileContextMenu(path: String, onTrash: (() -> Void)? = nil) -> some View {
        contextMenu {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            Button("快速预览") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            if let onTrash {
                Divider()
                Button("移到废纸篓", role: .destructive, action: onTrash)
            }
        }
    }
}
