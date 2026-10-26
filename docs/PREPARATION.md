# 開発構成と設計方針

この文書は開発準備段階で選んだ構成の公開用要約です。
現在の仕様・優先順位・受入条件は[ROADMAP](ROADMAP.md)、機能とビルド方法は[README](../README.md)を参照してください。

## 目的

画面の必要な範囲をコピーし、貼り付け先の作業へ戻れるメニューバーアプリを目指します。
単発コピーと、複数箇所を一枚のPNGにまとめる操作を提供します。

## 開発構成

- SwiftUIとAppKitを使うmacOSアプリです。
- 撮影にはScreenCaptureKitの単発取得APIを使います。
- AppKitの選択UIと撮影座標系を分け、画面の倍率・境界・構成変更を検査します。
- ショートカットは登録型ホットキーを使い、登録失敗・衝突・解除を扱います。
- 外部パッケージは使用していません。通常ビルドに個人の認証設定や配布証明書は不要です。
- App Sandboxを有効にしています。署名・公証・配布条件の確認は通常ビルドと分けます。

## データと操作の原則

- 起動だけでは撮影・権限要求・コピーを行いません。
- 許可設定から戻っただけで撮影を再開せず、新しい明示操作を必要とします。
- 撮影画像と収集セッションはメモリ上で扱い、画像のファイル保存・履歴・通信を行いません。
- 取消・撮影失敗をコピー成功として扱わず、失敗段階に応じて再選択・再コピー・破棄を案内します。
- 検証には架空素材と専用pasteboardを優先し、実画面・クリップボード内容を公開記録へ含めません。

## 検証の区分

準備段階のビルド・メニューバー・終了動作の確認は、製品の撮影・権限遷移・貼り付け・操作性の検証とは別です。
各段階の結果と未実証事項は[M0](M0-VERIFICATION.md)、[M1](M1-VERIFICATION.md)、
[M2](M2-VERIFICATION.md)、[M3](M3-VERIFICATION.md)、[M4](M4-VERIFICATION.md)に要約しています。
限定条件での成功を全OS・全構成・一般向け配布の合格へ広げません。

## 技術資料

- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)
