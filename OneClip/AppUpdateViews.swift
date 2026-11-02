import SwiftUI

struct AppUpdateSettingsSection: View {
    @ObservedObject private var updates = AppUpdateController.shared
    @ObservedObject private var capture = SingleCaptureCoordinator.shared
    @ObservedObject private var collection = CollectionCaptureCoordinator.shared
    @ObservedObject private var results = CaptureResultController.shared
    @ObservedObject private var annotation = CaptureAnnotationController.shared
    @State private var showsDevelopment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("アップデート", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            Text("現在のバージョン：\(updates.currentVersion.displayText)")
                .font(.callout).foregroundStyle(.secondary)
            Button("アップデートを確認…") { updates.checkForUpdates(channel: .stable) }
                .disabled(!updates.canCheckForUpdates)
            if let reason = updates.checkBlockReason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            Text(updates.statusText)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if updates.hasPostponedInstallation {
                Button("更新して再起動") { updates.resumeInstallationIfReady() }
                    .disabled(!updates.canResumeInstallation)
            }
            Text("ボタンを押したときだけ更新を確認します。保存した画像やクリップボードの内容は送信しません。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("開発用", isExpanded: $showsDevelopment) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("開発中の版も更新候補に含めます。通常の更新確認は公開版のみです。")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("開発版を確認…") { updates.checkForUpdates(channel: .development) }
                        .disabled(!updates.canCheckForUpdates)
                    Text("開発版より古い公開版への自動切り替えは行いません。新しい公開版が出たときに通常の更新を利用できます。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
