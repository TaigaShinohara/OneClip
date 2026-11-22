import SwiftUI

struct AppUpdateSettingsSection: View {
    @ObservedObject private var updates = AppUpdateController.shared
    // Availability is derived from these controllers; observe them even when idle text is hidden.
    @ObservedObject private var capture = SingleCaptureCoordinator.shared
    @ObservedObject private var collection = CollectionCaptureCoordinator.shared
    @ObservedObject private var results = CaptureResultController.shared
    @ObservedObject private var annotation = CaptureAnnotationController.shared
    @State private var showsDetails = false

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
            } else if updates.statusText != AppUpdateSessionState.initialStatusText {
                Text(updates.statusText)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if updates.hasPostponedInstallation {
                Button("更新して再起動") { updates.resumeInstallationIfReady() }
                    .disabled(!updates.canResumeInstallation)
            }
            DisclosureGroup("更新について", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ボタンを押したときだけ更新を確認します。保存した画像やクリップボードの内容は送信しません。")
                    Divider()
                    Text("開発版を含めて確認できます。古い公開版へは自動で戻しません。")
                    Button("開発版を確認…") { updates.checkForUpdates(channel: .development) }
                        .disabled(!updates.canCheckForUpdates)
                }
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
        }
        .oneClipCard()
    }
}
