# セキュリティの保証境界と検証

本書はR05/R07/R09/R10/R13/R14、T05〜T09/T13/T14、D05〜D07/D13〜D16に関係する安全条件を記録します。
要件ごとの証拠・統合試験・資源基準・本人開始式の手順は[セキュリティ限定受入](SECURITY-ACCEPTANCE.md)を参照してください。
仕様の正本は[ROADMAP](ROADMAP.md)、実行結果の要約は[M4検証記録](M4-VERIFICATION.md)です。
コード・架空試験・実OS・配布物の証拠を分け、未実施を合格へ数えません。

## アプリが管理する安全条件

| 境界 | 条件 |
| --- | --- |
| 撮影対象 | 選択した表示と範囲を固定し、表示構成・権限・利用状態が一致しない場合は停止する。別表示や全画面取得へ切り替えない |
| 設定窓の例外 | 明示的に対象となった自アプリ設定窓だけを、所有者・世代・windowID・PID・frame・display・可視性で照合する。別窓やDebug練習scopeと合成しない |
| 結果の採用 | 失効した操作・session・内容版・候補を、遅い成功や失敗から再採用・再表示・コピーしない |
| 利用状態の回復 | 不明・監視失敗は停止し、状態回復や前面化だけで撮影・権限要求を再開しない。新しい明示操作を必要とする |
| 保持 | 非表示、処理取消、候補破棄、編集終了、環境失効を区別する。コピー後・非表示・候補比較中の画像も失効対象に含める |
| 同時処理 | 単発と収集の保持は共存できるが、撮影・合成の共有枠は旧workerが実際に戻るまで占有する。Annotationのload/renderとResultの保存/編集も実返却まで入口gateと予算を維持する |
| 画像予算 | 単発・収集・Result・Annotationの素材、候補と旧画像、完成物、PNG・encoded snapshot/bridge、実worker、UI借用を区別して算入する。384MiBは画像バッファの見積予算でありRSS上限ではない |
| コピー | 完成PNGを同期的に書き、currentHostOnlyを使う。旧clipboard本文を読取・保存・復元せず、コピー済み画像を勝手に消去しない |
| 保存 | D15の完成PNG・編集用コピーはローカルに永続化する。環境失効で保存済みfileを消さず、以前依頼したdisk workerは実返却までgateと予算を維持する。clipboardの停止条件と分ける |

## 取消とメモリの寿命

単発と収集は共通の非同期画像workerを使い、呼出し側のTask取消をdetached workerへ伝えます。
画像領域の確保前、素材描画の間、PNG生成の前後、Dataコピーと一時領域の解放後に取消を検査します。
結果を返す直前にも呼出し側の取消を確認します。

CoreGraphicsやImageIOの同期呼出しの途中を強制停止する仕組みではありません。
取消後も実workerの終了まで画像参照が残る場合があります。参照の解放、追跡providerの解放、
allocatorやOSの回収、物理メモリの消去は別の事象です。すでにOSや貼り付け先へ渡した画像は回収しません。

自動保存は画像処理の共有枠とは別のdisk workerです。Nativeの共通失効sinkはAnnotation、Result、単発、収集の順に配送し、
pending PNG・thumbnail・旧表示を失効させます。disk workerがすでに保持するPNGは実返却まで残り、古い完了をUIへ採用しません。
両モードのworker local画像も実返却まで予約し、候補・完成bitmap/PNG・退役UIとResultの保持・作業領域を同じ384MiBへ算入します。
thumbnailは最大480pxの独立RGBA bitmapへ変換し、decoder/context/outputの3領域を予約します。編集用copyのdisk I/OもMainActorから分離します。

保存先はOSのApplication Supportを起点にprivate directory/file mode、owner、ACL、非symlinkを確認し、directory FDで操作します。
編集元と保存cacheの再利用はsafe FDの同一性・上限・内容を検査し、変更済み原本へ成功表示を流用しません。
既存fileの上書き・削除で復旧せず、競合時は拒否します。保存済みPNGは非表示・素材破棄・環境失効・終了後も残ります。
注釈の読込みも同じFD境界を使い、encoded snapshotとbridgeを予算へ含めてからImageIOへ渡します。
注釈を含む4ownerの画像・実worker予約を合算し、実画面のdrawと画面外の所有試験を分けます。
注釈のload/render結果はawait後にも外部保持量と世代を再検査し、取消を無視した依存先の遅い成功にも採用を許しません。
失効で本文・vector・Undo/Redoを破棄し、依存先の生error文をstatusや固定code traceへ渡しません。
標準Previewへの受渡しは固定のOS appとApple署名・identifierを検査し、新しい操作で旧起動intent・遅いerrorを失効させます。

## 決定的な架空試験

次のコマンドは架空サービス・架空画像・専用設定領域・専用pasteboardを使います。
実撮影、画面収録の許可変更、一般pasteboard、実Carbonキー登録は行いません。
各コンパイルの前に実行中build・メモリ・ディスクを確認します。

```sh
bash scripts/test_settings_capture.sh \
  M0ImageCoreTests SingleCaptureCoordinatorTests CollectionCaptureCoordinatorTests \
  CaptureEnvironmentIntegrationTests CaptureBoundarySecurityTests ClipboardLifetimeTests \
  CaptureArchiveTests CaptureResultControllerTests \
  CaptureAnnotationsTests CaptureAnnotationControllerTests TrustedPreviewApplicationTests \
  ProductHotKeyTests SettingsCaptureScopeTests CollectionPreviewNavigationTests \
  RegionGeometryTests ScreenshotBudgetTests CaptureSessionMonitorTests \
  CaptureConsoleUserMonitorTests CaptureSessionNotificationTests M0ClipboardProbeTests
python3 -B -m unittest discover -s Tests -p '*Tests.py' -v
```

取消試験では、最初から取消済みの呼出し、素材間・PNG前後・返却前の取消、detached workerへの伝播を検査します。
コーディネータの偽エンコーダは意図的に取消を無視して遅い結果を返し、workerの協調的取消だけに頼らず採用側の防御も検査します。

収集の追加matrixは、全9種の`CaptureEnvironmentEvent`について、未コピー・コピー後・コピー後編集と候補・表示有無の108条件、
取得待ち・合成待ちの遅い成功・失敗の36条件を扱います。失効後のwriter呼出し、成功表示、旧候補の採用を拒否し、
旧worker終了前の新規開始も拒否します。これらは注入したイベントの試験であり、実OSの通知配送を証明しません。
結果表示は9経路×両modeの18結合ケースで実保存workerの寿命とNative gateを検査します。
注釈も9経路×load/renderの18結合ケースで実FD読込み・実描画後のgate、画像・vector・履歴・旧PNGの棄却を検査します。
どちらも架空通知と制御gateを組み合わせた試験であり、実OS遷移や実表示は別です。

## 実OSと配布物の判定

実OSでは、遷移の発生、通知またはpollの観測、アプリのtoken失効、worker返却、consumer呼出しを別に確認します。
順序や実SCK処理区間が成立しない試行は未実証です。OSが終了させた試行を同一processの権限遷移成功とは数えません。
macOS14.0/14.1と14.2以降のAPI差、CPU、表示構成、lock/FUS/TCCの経路を個別に記録します。

署名設定が存在することと、配布物が保護されていることは別です。
`scripts/verify_distribution.py`は、明示した候補を変更・起動せず、承認した署名Teamと最小権限policyへ照合します。
承認したbundle IDも必須で照合し、同じTeamの別アプリを拒否します。結果には候補bundleの相対path・permission・
entry種別・各ファイル内容から作るmanifest SHA-256を残し、配置場所に依存せず検証証拠を実bytesへ結び付けます。
このmanifestはquarantine等のxattrを含めず、継続的・原子的な不変性も保証しません。
`signed`段階の成功は署名のpreflightだけを意味し、公証済み配布物や初回起動の合格ではありません。
`distribution`段階でも、実際の新規環境・quarantine付きの起動・offline起動の証拠は別途必要です。
現在のpolicyは単一executableのOneClip用であり、追加helper・framework等のnested codeは未対応として拒否します。

```sh
python3 scripts/verify_distribution.py --app 'path/to/OneClip.app' \
  --stage signed --policy oneclip-minimal-v1 --expected-team-id "$ONECLIP_EXPECTED_TEAM_ID" \
  --expected-bundle-id local.OneClip
```

配布にはDeveloper ID、Hardened Runtime、secure timestamp、必要最小限の実entitlements、
`get-task-allow`非true、公証結果とlog、staple済みticket、Gatekeeperの確認を同じ最終成果物へ結び付けます。
Gatekeeperのraw plistは、Booleanの`assessment:verdict`と、`assessment:authority`内の
`assessment:authority:source`が`Notarized Developer ID`であることを厳密に確認します。
キー名は[Appleの定義](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/SecAssessment.cpp#L122-L131)と実tool応答に照合し、短縮した`source`等を代替として受け入れません。
公証投入物、staple後のapp/container、最終配布物のhashは区別します。
ZIPはstapleしたappから作り、ticket付きDMG/PKGを作り直した場合は必要な検証へ戻ります。
quarantineを除いたりGatekeeperを無効にしたりして合格を代替しません。

本人開始式Runtimeは、旧失効区間と、その後の新しい本人操作による実SCK/PNG/専用board/worker返却を同一processで分けて観測します。
親はtraceの順序と実worker/slot対を再検査し、回復flagだけを合格理由にしません。Runtime自身は保存・注釈・通常の画像Viewを行使しません。
ledger v2はbinary manifestと親runnerのhashを固定し、過去の受理済み証拠を再読込します。自己試験の成功は実OS試行の成立ではありません。

## 残る保証境界

- 公開通知と状態確認は、全GUI lock経路の即時検知やOSとの原子的処理を保証しない。
- 画像バッファの予算や参照解放は、プロセス全体のRSS上限・物理メモリの即時完全消去を保証しない。
- 共有clipboardのchangeCount検査はbest effortであり、他アプリとのatomic compare-and-swapではない。
- コピー先、clipboard管理アプリ、OSがすでに保持する画像の消去・外部処理をOneClipから保証しない。
- 架空試験・このMacの限定結果・正式署名のそれぞれを、全OS/CPU/経路・M4総合・VoiceOver・一般配布の合格へ拡張しない。

参考: [Apple DTSのGUI lockとprotected dataの説明](https://developer.apple.com/forums/thread/850327)、
[currentHostOnly](https://developer.apple.com/documentation/appkit/nspasteboard/contentsoptions/currenthostonly)、
[Appleの公証要件](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
