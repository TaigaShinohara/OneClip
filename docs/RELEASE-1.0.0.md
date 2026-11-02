# OneClip 1.0.0 最小公開確認

[最小公開条件](ROADMAP.md#minimum-release-checks)について、以下の版・環境・代表経路の範囲で確認を完了しました。旧M4の詳細評価、全OS・全CPU・全面アクセシビリティの合格を表すものではありません。

## 配布物

- 公開先：[GitHub Release v1.0.0](https://github.com/TaigaShinohara/OneClip/releases/tag/v1.0.0)。表示版1.0.0、build 3、stable。
- 製品ソース：`d8ba16b4c2141a1ef6c5ef60bee3faaf0beac889`。固定した54製品入力のSHA256は `50bba04029707d9ac1b67e80d1d1aa69cecccfcd998e97ad1f8e826fa87938c0`。
- 最終ZIP：`OneClip-1.0.0.zip`、3,792,035 bytes、SHA256 `658d2cb7fe6f600a8fab08fb2ca6635e39168ba776442a3c710375dba38fcbcd`。
- 公開時の署名フィード：1,821 bytes、SHA256 `f005988befcc052c770d1851f410e6095061f0758562a95e33388033cbf5ca4a`。旧0.2.0のURL・署名・itemを保持。後続版を追加するとフィードhashは変わります。
- 最終app manifest SHA256：`0d31dae5c81f0a42f359433add4a583116415e3069ac9ed4738e9dda3af2a71d`。

## 結果と継承範囲

実行条件はmacOS 27.2 / arm64です。universal Releaseビルドの成功をIntel実機の成功とは扱いません。

| 最小条件 | 根拠と結果 |
| --- | --- |
| ビルド・配布物 | arm64 / x86_64のReleaseビルド成功。Developer ID署名、既知6code ownerの権限・Hardened Runtime・timestamp、Apple公証Accepted・指摘0、staple、Gatekeeper、ZIP再展開manifestが成功 |
| 起動・案内・基本操作 | 製品の使い方・設定・アプリ情報を表示。更新後の製品画面で1.0.0 (3)を確認 |
| 単発・代表まとめ | 0.2.0から撮影・収集・保存・注釈・更新ロジックが不変。既存の通常Releaseでの単発、1枚/2枚まとめの実取得・貼り付け・順序・可読性・取消保持を継承。詳細は[M4の限定結果](M4-VERIFICATION.md) |
| 注釈・保存・失敗 | 製品UIで日本語コメントの保存・コピー成功を確認。保存・コピーの失敗分離、遅い結果、未保存作業の保護はロジック不変の既存回帰を継承。公開デモの日本語コメント・矢印・囲みは実際の合成・注釈rendererから生成した架空出力例で、操作録画ではない |
| 公開先照合 | 公開URLからZIPと固定URLのフィードを取得し、最終hash・長さの一致と、アプリに同梱した公開鍵によるfeed/archive両方の署名を確認 |
| 製品更新 | 0.2.0/build 2の製品UIから公開フィードを確認し、1.0.0/build 3をダウンロード・適用・再起動。新PIDの実行物vnodeと配置実行物が一致し、配置app manifestが最終配布物と一致 |
| データ保持 | 更新前からのPNG一覧・サイズ・inode・mtimeを保持。架空の保存PNGのbytesと、撮影キー・案内既読等の6設定を保持。既存の私的画像の内容は読み取らず、記録・外部送信もしない |
| 案内 | READMEにダウンロード、配置、必要時の許可、保存と通信、既知制限、不具合窓口、架空の機能紹介を掲載 |

既存0.2.0との製品差分はアイコン、版/build、メニュー文言です。既存結果の継承と、今回の配布物・実更新の確認を区別します。権限・Gatekeeperの設定変更や既存データの消去を成立条件にしていません。

## 残る境界

macOS 14・Intel実機、全面VoiceOver、全画面構成・全権限遷移は未実証です。旧RSS/footprint・cold UI・実SCK 1px等の失敗記録は解消済みへ書き換えません。これらの詳細評価は公開必須条件から外し、通常利用に具体的な支障が出た場合だけ影響範囲を扱います。App Storeへの提出・審査はこの配布に含みません。

必要な最小確認を満たしたため、追加検証は終了します。新しい変更・不具合がある場合だけ関連する確認を行います。
