import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardHistoryView: View {
    @ObservedObject var model: AppModel
    @State private var confirmation: ClipboardConfirmation?
    @State private var searchQuery = ""

    private var filteredItems: [ClipboardHistoryItem] {
        model.clipboardHistoryItems.filter { $0.matches(searchQuery: searchQuery) }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 11) {
                toolbar

                if model.clipboardHistoryEnabled {
                    searchField
                }

                if !model.clipboardHistoryEnabled {
                    optInCard
                } else if model.clipboardHistoryItems.isEmpty {
                    emptyState
                } else if filteredItems.isEmpty {
                    searchEmptyState
                } else {
                    historyList
                }

                storageFooter
                feedbackBar
            }

            if let confirmation {
                confirmationOverlay(confirmation)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.14), value: confirmation != nil)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                model.appLanguage == .english ? "Search history…" : "搜索历史关键词…",
                text: $searchQuery
            )
            .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 10))
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)
            Text(model.appLanguage == .english ? "No matches" : "没有匹配的历史")
                .font(.headline)
            Text(model.appLanguage == .english
                 ? "Try another keyword, or clear the search."
                 : "换个关键词试试，或清空搜索框。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelGroupSurface(cornerRadius: 19)
    }

    private var storageFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.tertiary)
            Text(storageLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if model.clipboardRetentionPolicy.persistsAcrossLaunches,
               ClipboardStore.defaultPersistenceURL() != nil {
                Button(model.appLanguage == .english ? "Reveal" : "在访达中显示") {
                    revealPersistenceInFinder()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
    }

    private var storageLabel: String {
        guard let url = ClipboardStore.defaultPersistenceURL() else {
            return model.appLanguage == .english
                ? "Local store unavailable"
                : "本机存储路径不可用"
        }
        if !model.clipboardRetentionPolicy.persistsAcrossLaunches {
            return model.appLanguage == .english
                ? "Memory only (choose 1 day / 7 days / Until deleted to save)"
                : "仅内存（选 1天/7天/直到手动删除 才会写入磁盘）"
        }
        return url.path
    }

    private func revealPersistenceInFinder() {
        guard let url = ClipboardStore.defaultPersistenceURL() else { return }
        let folder = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(LocalizedStringKey(statusTitle))
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(model.appLanguage == .english
                     ? "Stored locally · \(filteredItems.count)/\(model.clipboardHistoryItems.count) shown · max \(ClipboardStore.maximumItemCount)"
                     : "本机保存 · 显示 \(filteredItems.count)/\(model.clipboardHistoryItems.count) · 上限 \(ClipboardStore.maximumItemCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Picker(
                "保留期限",
                selection: Binding(
                    get: { model.clipboardRetentionPolicy },
                    set: { model.setClipboardRetentionPolicy($0) }
                )
            ) {
                ForEach(ClipboardRetentionPolicy.allCases) { policy in
                    Text(LocalizedStringKey(policy.title)).tag(policy)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 128)
            .help(model.clipboardRetentionPolicy.privacyDescription)

            if model.clipboardHistoryEnabled {
                Button("关闭") { confirmation = .disable }
                    .buttonStyle(.borderless)
            } else {
                Button("启用") { model.enableClipboardHistory() }
                    .buttonStyle(.borderedProminent)
            }

            Button(role: .destructive) { confirmation = .clear } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.clipboardHistoryItems.isEmpty)
            .help("清空历史，不影响系统剪贴板")
        }
        .frame(height: 30)
    }

    private func confirmationOverlay(_ confirmation: ClipboardConfirmation) -> some View {
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { self.confirmation = nil }

            VStack(alignment: .leading, spacing: 12) {
                Label(LocalizedStringKey(confirmation.title), systemImage: confirmation.symbol)
                    .font(.headline)

                Text(LocalizedStringKey(confirmation.message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    switch confirmation {
                    case .disable:
                        Button("关闭并保留已有历史") {
                            self.confirmation = nil
                            model.disableClipboardHistory(clearHistory: false)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("关闭并清除历史", role: .destructive) {
                            self.confirmation = nil
                            model.disableClipboardHistory(clearHistory: true)
                        }
                        .buttonStyle(.bordered)
                    case .clear:
                        Button("清空历史", role: .destructive) {
                            self.confirmation = nil
                            model.clearClipboardHistory()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }

                    Button("取消") {
                        self.confirmation = nil
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(18)
            .frame(width: 300)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        if !model.clipboardHistoryEnabled { return "剪贴板历史已关闭" }
        if model.isBackgroundRefreshPaused { return "剪贴板监控已暂停" }
        return model.isClipboardMonitoringActive ? "剪贴板历史已启用" : "剪贴板访问受阻"
    }

    private var statusColor: Color {
        if !model.clipboardHistoryEnabled { return .secondary }
        return model.isClipboardMonitoringActive ? .green : .orange
    }

    private var optInCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "clipboard.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(.tint.opacity(0.11), in: .rect(cornerRadius: 15))

            Text("由你决定何时开始读取")
                .font(.headline)

            Text("启用后只记录纯文本、图片和本地文件。内容仅保存在本机 Application Support；可选保留期限，也可随时单条删除或清空。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)

            if let notice = model.clipboardAccessNotice {
                Label(notice, systemImage: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("启用剪贴板历史") {
                model.enableClipboardHistory()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .panelGroupSurface(cornerRadius: 19)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clipboard")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("等待新的复制内容")
                .font(.headline)
            Text("启用前的内容和锁屏、休眠期间的内容不会补录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let notice = model.clipboardAccessNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Button("重新检查访问状态") {
                model.recheckClipboardAccess()
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelGroupSurface(cornerRadius: 19)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredItems) { item in
                    ClipboardHistoryRow(model: model, item: item)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var feedbackBar: some View {
        if let feedback = model.clipboardFeedback {
            Label(feedback, systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Label(
                model.clipboardRetentionPolicy.privacyDescription,
                systemImage: "lock.shield"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum ClipboardConfirmation: Equatable {
    case disable
    case clear

    var title: String {
        switch self {
        case .disable: "关闭剪贴板历史？"
        case .clear: "清空全部剪贴板历史？"
        }
    }

    var message: String {
        switch self {
        case .disable:
            "关闭后立即停止监控。无论选择哪一项，都不会更改当前系统剪贴板。"
        case .clear:
            "只删除 Notch Triage 保存的历史，不会清空当前系统剪贴板。"
        }
    }

    var symbol: String {
        switch self {
        case .disable: "pause.circle"
        case .clear: "trash"
        }
    }
}

private struct ClipboardHistoryRow: View {
    @ObservedObject var model: AppModel
    let item: ClipboardHistoryItem

    var body: some View {
        HStack(spacing: 10) {
            preview

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 5)

            if case .image = item.payload {
                Button {
                    previewImageIfPossible()
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .help("预览图片")
            }

            Button {
                model.restoreClipboardHistoryItem(item)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("重新复制")

            Button(role: .destructive) {
                model.removeClipboardHistoryItem(item)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("从历史中移除")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture {
            if case .image = item.payload {
                previewImageIfPossible()
            } else {
                model.restoreClipboardHistoryItem(item)
            }
        }
        .contextMenu {
            if case .image = item.payload {
                Button("预览图片", systemImage: "eye") {
                    previewImageIfPossible()
                }
            }
            Button("重新复制", systemImage: "doc.on.doc") {
                model.restoreClipboardHistoryItem(item)
            }
            Button("从历史中移除", systemImage: "trash", role: .destructive) {
                model.removeClipboardHistoryItem(item)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title)，\(detail)")
        .accessibilityHint(imageHint)
    }

    private var imageHint: String {
        if case .image = item.payload {
            return "单击预览图片"
        }
        return "单击重新复制"
    }

    private func previewImageIfPossible() {
        guard case .image(let data, _) = item.payload else { return }
        ClipboardImagePreviewController.shared.show(data: data, title: item.title)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.payload {
        case .text:
            historyIcon("text.alignleft", tint: .blue)
        case .fileURLs(let urls):
            historyIcon(urls.count > 1 ? "doc.on.doc.fill" : "doc.fill", tint: .orange)
        case .image(let data, _):
            ClipboardImageThumbnail(id: item.id, data: data)
                .onTapGesture {
                    previewImageIfPossible()
                }
                .help("点击预览")
        }
    }

    private func historyIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.1), in: .rect(cornerRadius: 11))
    }

    private var detail: String {
        "\(model.localized(item.payload.kind.localizedTitle)) · \(item.capturedAt.formatted(date: .omitted, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))"
    }
}

private struct ClipboardImageThumbnail: View {
    let id: UUID
    let data: Data
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.purple)
            }
        }
        .frame(width: 40, height: 40)
        .background(.purple.opacity(0.1), in: .rect(cornerRadius: 11))
        .clipShape(.rect(cornerRadius: 11))
        .task(id: id) {
            let thumbnailData = await Task.detached(priority: .utility) {
                Self.makeThumbnailData(from: data)
            }.value
            guard !Task.isCancelled, let thumbnailData else { return }
            thumbnail = NSImage(data: thumbnailData)
        }
    }

    nonisolated private static func makeThumbnailData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private extension ClipboardPayload.Kind {
    var localizedTitle: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .fileURLs: return "文件"
        }
    }
}
