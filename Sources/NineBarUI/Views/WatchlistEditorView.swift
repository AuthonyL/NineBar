import SwiftUI
import NineBarCore

struct WatchlistEditorView: View {
    @ObservedObject private var model: RadarViewModel
    private let onClose: () -> Void
    @State private var text = ""
    @State private var isLoading = true
    @State private var isSaving = false

    init(model: RadarViewModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t(
                "每行一个标的，可填写“六位代码”或“六位代码 名称”。支持沪深 A 股和场内 ETF，名称留空会在刷新后自动补全。保存后会完整替换当前监控列表，清空后保存即删除全部自选。",
                "One symbol per line: a six-digit code, optionally followed by a name. Shanghai and Shenzhen A-shares and ETFs are supported; missing names are filled in after the next refresh. Saving replaces the whole list, and saving an empty list removes every symbol."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.body.monospaced())
                .padding(6)
                .background(Color.primary.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(isLoading)

            if let message = model.watchlistErrorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.t("取消", "Cancel"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(isSaving ? L10n.t("保存中", "Saving") : L10n.t("保存并刷新", "Save and refresh")) {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || isLoading)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 460)
        .task {
            text = await model.watchlistEditingText()
            isLoading = false
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await model.replaceWatchlist(text: text) {
            onClose()
        }
    }
}
