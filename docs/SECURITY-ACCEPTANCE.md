# セキュリティ限定受入

仕様は[ROADMAP](ROADMAP.md)、安全条件は[SECURITY-VERIFICATION](SECURITY-VERIFICATION.md)、
実行結果は[M4-VERIFICATION](M4-VERIFICATION.md)を正本とします。本書は試験の対応と判定方法です。
実装・自動試験、特定Macでの実証、宣言環境全体の受入を別々に判定します。
現在は公開`2eb97e0`の自動保存・注釈を保持した統合版が対象です。[最新の実行結果](M4-VERIFICATION.md#security-integrated-2eb97e0-20261031)へ対応付け、開始版や途中版の証拠を消しません。

## 要件と証拠の対応

| 対象 | 関連要件 | 必要な証拠 |
| --- | --- | --- |
| 範囲・倍率・自アプリ除外 | R01/R08、T01/T07、D02/D08 | 独立した整数pixel oracle、設定窓metadata/lifecycle、架空窓の実SCK比較。別画面・全画面へのfallbackなし |
| 失効と結果の利用 | R05/R07/R10、T05/T07、D06 | Native/router/CG・SC monitorからAnnotation・Result・両coordinatorへの配線、遅い成功・失敗、表示とwriterの棄却 |
| コピー後・非表示・候補 | R03/R05/R10、T03/T05/T09、D12〜D14 | 状態matrix、実Viewの非表示/解体、古い確認応答・候補の拒否、保持と終了の区別 |
| 共有枠・画像予算 | R09、T04/T09、D05 | 実worker返却まで占有、4owner・候補・完成物・PNG・UI借用の合算、境界/overflow/実stride拒否 |
| 書込みと寿命 | R04/R05/R10、T02/T06、D07 | 同期prepare/write、currentHostOnly、専用board競合、別process受領とproducer終了後のPNG |
| 入力・復旧 | R06/R07、T05/T08、D01 | 遅延入力/旧世代/確認応答の拒否、登録失敗、明示操作のみの再開、焦点の不変 |
| 資源と取消 | R09/R10、T09、D05/D06 | source/provider/owner/PNG/workerを区別した有限計測、MainActor応答、取消からslot解放 |
| 公開・配布 | R12、T11/T12、D08〜D10 | 公開refsの到達履歴、metadata/添付物、通常build、実署名/公証、ZIP内容とhash対応、初回/upgrade/rollback |
| 永続保存・結果表示 | R13、T13、D15 | private archiveとsafe source、全byteのcache同一性、実disk/編集worker返却、独立thumbnail、予算、旧UI・外部openの棄却 |
| 注釈の読込み・出力 | R14、T14、D16 | safe FDのPNG snapshot、encoded 2 storesとdecode/normalize、実workerと4owner予算、失効後のvector/画像/旧PNG利用の棄却 |

R11/T10の全面VoiceOver、M4総合のUX評価、一般向け配布はこの限定受入と別です。
API availabilityやuniversal buildを最低OS・Intel実機での実行成功へ読み替えません。

## 観測と決定的試験

`CaptureSecurityTrace`は既定off、1試行最大8,192件です。entryは固定enum、試行内番号、sequence、
相対単調時刻、mode/phase/outcomeだけです。画像・窓名・UID・clipboard本文・任意のerror文は受け取りません。
上限超過は先頭を上書きせず欠落数を増やし、欠落した試行を合格にしません。

通知center、CG/SC backend、診断を内部依存として差し替えます。通常initはlive、試験initは専用centerと
架空backendを使い、グローバルhotkey・foreground記憶・activation購読を開始しません。
通常Releaseの遠隔操作入口や診断の自動保存はありません。

安全上のmode/段階/失効原因/結果の組合せは全列挙します。入口や外観の同一分岐だけは組合せを削減できます。
到達不能な条件は理由付き対象外とし、未成立と混同しません。

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

`CaptureViewSecurityTests`は実NSPanelに架空画像だけを表示する別のGUI試験です。前面appが変わった/不明なら
そこで`NOT_ESTABLISHED`として止めます。架空通知の成功を実OS遷移や実SCK中の成功にしません。
設定scopeの`--grid-oracle`は画面外描画だけ、`--capture-grid`は既存許可による実取得を伴います。
追加のpadding系列は別cellであり、元の失敗を消しません。pixelはメモリ上で比較し保存しません。
`--sampling-oracle`はraw alpha判定14対照とflat color resampling 4条件の画面外検証です。
`--capture-sampling`は取得サイズとalphaの原因調査用で最大5取得、明示指定するorigin追加系列のみ最大8取得です。
これらの成功も、実SCKの1px境界の正しさを代替しません。

## 有限資源判定

`scripts/build_security_tools.sh`は実行物をbuildするだけです。各compile前に他build・メモリ・diskを確認し、
前後の入力hashを照合します。manifestはGit commitとは別の`build-inputs-sha1`と実binary SHA-256を記録します。
資源計測には同じ`-O`実行物を使い、source-only/render-before-encode/sync/asyncと製品状態を分離します。

判定値は計測拡大前に凍結します。画像予算384MiBとRSS/footprintは別の指標です。

- 観測peak: `min(1GiB, physicalRAM/8)`。sampled maximumと取得できたhigh-waterを区別する。
- 対照3 fresh processのwarmup後変動幅BをRSS/footprint別に求める。B>8MiBは計測不成立。
- 各許容帯Eは`max(8MiB, 2B)`。30cycle blockの末尾5点medianを比較し、E超の未説明増加は未合格。
- 通常baseline10回の最大が15秒を超えたら拡大前に停止する。取消回復Tはworkload・owner別に`min(30秒, max(2秒, baseline最大×2))`。
- 製品async経路は50ms周期のMainActor callback間隔最大250ms。同期診断やOS遷移中へ適用しない。
- 取消回復はcoordinator要求から実worker返却・slot解放まで。M0 wrapper単独の計測とは別系列にする。

欠測・途中終了・PNGの取消後返却・owner残留・slot早期解放は成功にしません。
60/90cycle・idle60/120秒への延長は、同条件の調査結果がある場合だけです。
後の安定したfresh processで前の超過を自動的に合格へ変えません。
局所修正後の`rebind`は元の閾値を保持し、再校正で上限を緩めません。
画面外の実View生成・所有を、実際のdraw・窓表示・VoiceOverの証拠にしません。
warmup/measured別のheartbeatは切分け用です。cold warmupを含むaggregateの不合格を除外しません。
子processのtimeout・中断・wait失敗では、自分が起動したhandleだけを有限時間で終了・回収しようとします。
handle未取得や回収確認不能は成功にせず、以後の試行を止めます。

## 本人開始式の実OS試験

`SecurityRuntimeTrial`は専用の試験実行物です。通常起動/`--help`/`--self-test`ではOS操作やboardに触れません。
親runnerはbuild manifestと自分自身のSHA-256を固定し、自分で起動したfresh fixtureのPID/path/SHAと固定ready markerを確認します。
Runtimeは窓・表示・cropの同一性、可視性・不透明性・遮蔽を取得前後で再確認します。
一般clipboardやTCC要求・変更、lock/sleepの自動実行はありません。

親runnerのprivate ledgerで、開始前の予約を原子的に保存します。1枠900秒/最大3予約、cellごとにsessionをまたいで
最大5試行/成立3回です。最初のFAILを保持し、欠測や中断を無限に再試行しません。
起動した子のcleanupが不明なら以後を停止し、本人が所有子の終了を確認するまで再開しません。
ledgerは画像を含まず、既存の作業管理DBとは別の技術証拠です。

両mode×選択/実SCK/実合成/保持×lock2経路/system sleep/display sleepの32cellを別判定します。
Singleの保持にwriter拒否を注入した場合は混合試験と明記します。選択UIはfixture内固定範囲の試験UIであり、
通常Releaseの選択UIや実panelを行使した結果とは分けます。
実SCK call〜callbackまたは実合成の区間に遷移が重ならなければ`NOT_ESTABLISHED`です。
callback後の人工保留を実取得中と呼びません。
失効観測の成立は別flagへ保存し、その観測だけではfull cellを合格にせず`NOT_ESTABLISHED`とします。
同一processで旧worker返却・画像解放・slot解放を確認した後にだけ、回復確認用buttonを有効化します。
新しい本人clickから実SCK・画像worker・専用board書込み・実返却を行い、親もtraceから別々に検査します。
callbackと取得返却は両方のsuccessを要求し、矛盾したfailure/noneを下流の成功で埋め合わせません。
両区間が成立した`PASS_LIMITED_OBSERVATION`だけを必要な3成立へ数えます。metadataの回復flagだけは採用しません。
新しい明示操作より前の撮影開始・権限要求の企図、回復中の新たな失効後の利用も失敗として検出します。
このハーネスをbuild・自己試験したことは実OS試行の成立ではありません。

一般clipboardは別の手動確認です。既存内容をツールで読み出さず、架空PNGだけを本人がコピー・貼り付けます。
競合process・write拒否・自動寿命試験は専用boardで行います。

## 自動保存を含む版の追加境界

`72c0d2a`でD15のPNG自動保存が追加されたため、開始版`062f1bd`のmemory-onlyな出口を現在版全体へ継承しません。
保存済みfileと編集用copyは永続化し、失効時も以前依頼した保存自体は継続します。停止対象は新しい要求、
pending/thumbnail/表示と古い完了の採用です。clipboardの失効後書込み禁止とは別に検査します。

保存・編集はprivate一時archiveと架空PNGで自動検証します。結果controllerの実workerを止めたままNativeの全9経路を配送し、
両modeでpending/thumbnailの解放、実返却までの予約・gate、古い完了の棄却、以前依頼したfileの存続を確認します。
通常のarchiveや実画面・一般clipboardを試験素材にしません。
`SecurityRuntimeTrial`の取得・取消セルと従来の資源probeはD15の保存・結果表示を行使していません。
それらだけで新保存経路の実OS遷移・RSS/footprint総合を受入済みにしません。

`2eb97e0`の注釈機能も保持して統合します。Annotation、Result、単発、収集は同じ失効sinkへ同期配送し、
test initは実singletonへ接続しません。画像の読込みは安全なdescriptorで取得したPNGDataを使い、URLをImageIOで再openしません。
注釈の画像・出力・vector・履歴を失効させても、実load/render workerの返却まで借用とgateを維持します。
4ownerの予約、candidate、完成物、PNG、退役UIを合算し、await後も外部保持量を再読します。
Nativeの18結合ケースは実FD load／実render後にgateを置く混合試験です。実OS・表示・IME・全面VoiceOverの代替ではありません。
通常のRuntimeは`archive_exercised=false`と`annotation_exercised=false`を保存し、それらの利用が現れた試行を受け入れません。
`product_image_view_exercised=false`も維持し、通常の結果窓や注釈画面の表示を試したとは扱いません。
親ledger v2はtoolsとparent runnerのhashを固定し、過去PASSの証拠も再読込します。旧schemaは黙って移行しません。

## 成果物と最終判定

source/built inputs→署名app manifest→提出ZIP/公証log→staple後app→最終ZIP/再展開manifestの対応を保持します。
製品コード・署名対象・ID・権限が変われば該当する証拠を取り直し、旧候補の成功を新候補へ移しません。
Releaseでは署名前にdebugging symbolを除去し、実binary/ZIPの内部パス等も値を出さず点検します。
現在の統合候補はDebug/署名済みuniversal Release・再展開後の署名preflightまで成功しています。
最低OS設定と両architectureの存在は、macOS14やIntel実機での実行成功ではありません。新候補の公証は未実施で、旧候補のAcceptedを継承しません。

各必須項目は`PASS`/`FAIL`/`NOT_ESTABLISHED`/`BLOCKED`/根拠付き対象外に分類し、別担当が同じ版と証拠を照合します。
未実証・未解決の必須項目が残れば、対応する受入は未完了です。
最低OS/Intel、未保有表示、FUS/TCC、新規quarantine/offline起動、upgrade/rollback、別環境clone→buildは
環境がない間も残件として維持します。全GUI lock即時検知、OSとの原子性、物理メモリの完全消去は保証しません。
