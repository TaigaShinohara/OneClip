# 手動アップデート

OneClipメニューと設定の「アップデートを確認…」から更新を確認します。起動時・定期的な確認、自動ダウンロード・自動インストール、システムプロファイル送信は行いません。確認・取得の通信には、固定のGitHubフィードと、そのフィードにあるOneClipの配布ZIPだけを使います。画像・コメント・クリップボードは送信しません。

初回の更新用公開版は[0.2.0／build 2](https://github.com/TaigaShinohara/OneClip/releases/tag/v0.2.0)です。署名・公証・チケット添付済みのZIPと署名付きフィードを公開しています。初回配置と製品版同士の実更新は別の受入項目で、2版間の製品実更新は未実証です。ソース実装・内部試験・署名・公証・配布・インストールの結果を区別し、未設定・404・取得失敗を「最新版」と扱いません。

## 利用するチャンネル

- 通常のボタンは公開版だけを対象にします。「公開版」は配布区分で、安定性の認定ではありません。
- 設定の「開発用」から「開発版を確認…」を押した回だけ、開発版も候補に含めます。選択は永続化せず、次の通常確認は公開版へ戻ります。
- 版の比較はSparkleへ委ねます。開発版より古い公開版へ自動降格せず、公開版が新しくなった後で通常の更新を使います。
- `CFBundleVersion`は全チャンネルで単調増加させます。同じ番号の再配布や、同じtagのZIP差し替えは行いません。`CFBundleShortVersionString`は表示用です。

確認だけで未保存内容を破棄しません。撮影・画像処理・ショートカット設定・確認ダイアログの途中は更新UIを待機させます。適用は未保存画像・コメント・収集素材を解決してから行い、ダウンロード後にも状態を再確認します。再起動の最終段階は通常の終了確認へ接続します。

## 初回の切り替え

更新機能が入っていない既存アプリは、この機能で自分自身を更新できません。最初だけ、完成した更新機能入りのアプリを手動で配置します。現アプリを戻せる形で残し、保存画像と`local.OneClip`の設定を保持し、実workerと未保存内容を解決して通常終了してから置き換えます。

配置後は版・署名・実行物と、起動中プロセスの対応を再確認します。旧版を失効させたり、保存データ・画面収録権限・Gatekeeper設定を消したりして導入を成立させません。この初回配置と、後続のアプリ内更新は別の受入項目です。

## 固定する入力と鍵

- SparkleはSwift Package Managerで2.10.1へ完全固定します。初回の依存解決には通信が必要です。依存の通知は[THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md)に含めます。
- `SUFeedURL`は`https://raw.githubusercontent.com/TaigaShinohara/OneClip/main/updates/appcast.xml`に固定します。設定・引数・UserDefaultsで別の更新先へ切り替えません。
- 通常の公開itemは既定チャンネル、開発itemは`development`を使います。取得するZIPは`TaigaShinohara/OneClip`のtagごとのRelease添付へ固定します。ブランチのsource ZIPや可変のlatest download URLをアプリ本体として使いません。
- 更新アーカイブ用のEd25519秘密鍵はKeychainのaccount `OneClip-Update-Signing`に保持します。秘密鍵をexportしてGit・設定・環境ファイル・ログへ置きません。アプリの`SUPublicEDKey`へ入れるのは対応する公開鍵だけです。既存クライアントがある鍵を黙って作り直しません。
- Developer ID署名とEd25519署名は役割が異なります。ReleaseはHardened Runtime・同じbundle ID・必要最小権限を維持し、既知のSparkle nested codeを含めて署名・検証します。DebugだけのLibrary Validation緩和を配布物へ含めません。
- 既存の単一executable policy `oneclip-minimal-v1`は変更しません。Sparkle同梱版は`verify_update_distribution.py`の専用policyで検証します。

## 更新用候補を準備する順序

1. ソースcommit、製品build入力、表示版、build番号、チャンネル、bundle ID、配布予定tagとZIP名を固定します。現在の初回候補は0.2.0／build 2ですが、公開前の試験候補と実際に公開する版を混同しません。
2. 実行中build・メモリ・空き容量を確認してReleaseを作ります。Developer IDで各既知nested codeから外側へ署名し、主アプリを最後に署名します。`--deep`による署名で未知コードを一括許可せず、専用policyが列挙する所有者だけを扱います。
3. 下記の`signed` preflightを実行し、source入力とapp manifestを保存します。提出用ZIPを作った後、ZIPのhashと展開物の同一性も照合します。
4. 完成した署名済み提出候補の版・hash・提出先と、予定tag・公開先・初回配置先を提示し、Apple提出から検証成功後の公開・初回配置までの承認を得ます。ソースPRの承認だけを外部提出や配布物の公開承認へ広げません。同じ対象・手順が既に承認されている場合は確認を繰り返しません。
5. 承認済みZIPを既存の認証経路でAppleへ提出し、同じ提出の`Accepted`とlogを確認します。秘密値をコマンド引数へ渡さず、公証結果を別のアプリへ流用しません。
6. 同じappへticketをstapleしvalidateします。`distribution` preflightを実行し、staple後のappから最終ZIPを作ります。再展開したappのmanifest・署名・ticketを再確認し、最終ZIPのhashと長さを固定します。提出前ZIPと配布ZIPは別の識別情報です。
7. 最終ZIPに対して、同じSparkle 2.10.1の`generate_appcast`とKeychain account `OneClip-Update-Signing`を使い、アーカイブ署名・appcastを生成します。URL prefixはその版のimmutable Release添付先にします。既存itemの版・URL・署名を保持し、公開版／開発版のチャンネルと対象OS・build番号を照合します。
8. `SURequireSignedFeed`を含むアプリでは、`generate_appcast`によるフィード署名も必要です。署名後のXMLを手で書き換えて公開しません。itemやURLを変更した場合は、最終bytesに対して署名を生成し直します。アプリは署名検証失敗の期限切れを使って未署名フィードへfallbackしません。
9. 公証後の最終ZIPと署名付きフィードの版・hash・公開先を揃え、承認した候補・対象・手順に一致することを確認します。承認範囲が変わった場合だけ再確認します。承認済みのtagへ最終ZIPだけを添付し、完成した署名付き`updates/appcast.xml`を通常のPRで公開します。既存tag・添付を上書きせず、新しい版を使います。フィードだけ先に公開して存在しないZIPへ誘導しません。
10. 公開先から再取得したZIPのhash・長さ、展開物のmanifest、フィード署名、itemのアーカイブ署名を照合します。初回手動配置後、別の新buildを使ってアプリ内確認→取得→未保存内容の保護→再起動→新実行物の起動を確認します。取消・通信失敗・破損・rollbackは既存データを使わない有限試験で別に確認します。

Sparkleの[導入資料](https://sparkle-project.org/documentation/)と[更新公開手順](https://sparkle-project.org/documentation/publishing/)を参照します。`generate_appcast`は、同梱アプリが署名付きフィードを要求している場合にフィードも署名します。CLIの引数は固定した2.10.1の`--help`と照合し、秘密鍵ファイルやinline private keyを使う手順へ置き換えません。

専用preflightは候補を変更・起動・署名・公開しません。環境変数の値を全表示せず、次の必要な値だけを渡します。`ONECLIP_EXPECTED_TEAM_ID`は承認したDeveloper IDの公開識別子です。

```sh
python3 scripts/verify_update_distribution.py --app "$ONECLIP_UPDATE_APP" \
  --stage signed --policy oneclip-sparkle-2.10.1-v1 \
  --expected-team-id "$ONECLIP_EXPECTED_TEAM_ID" --expected-bundle-id local.OneClip

python3 scripts/verify_update_distribution.py --app "$ONECLIP_UPDATE_APP" \
  --stage distribution --policy oneclip-sparkle-2.10.1-v1 \
  --expected-team-id "$ONECLIP_EXPECTED_TEAM_ID" --expected-bundle-id local.OneClip
```

## 未完了の確認を維持する

手動更新のソース実装と、初回の配布物公開・導入・2版間の実更新は別です。署名や公証の成功だけで、初回起動・offline・macOS 14／Intel・全環境の更新とrollbackが成立したとは扱いません。

M4総合、対象Collection VoiceOver、表示・IMEなどの未実証は継続します。今回の更新候補公開を一般向けv1の品質合格へ広げません。候補の署名・公証・公開・インストールが実際に終わった場合だけ、その版とhashに結び付けて結果を追記します。既存の[公開方針](PUBLICATION.md)、[開発計画](ROADMAP.md)、[検証記録](M4-VERIFICATION.md)も参照してください。


## 2026-11-02の限定検証

- Sparkle 2.10.1の実SDKを含むReleaseビルドが成功しました。主アプリと同梱SDKはarm64／x86_64のuniversal候補です。ビルド入力42ファイルのhashをビルド前に固定しています。
- Pythonの架空fixture検証279件が成功しました。このうち更新用の配布物policyは12件です。既存の単一executable用policyは変更していません。
- Swiftの関連回帰8スイート・172グループが成功しました。更新モデル9、環境ルート14、ショートカット30、設定5、注釈controller14、結果controller14、単発coordinator43、まとめ撮りcoordinator43です。実画面・一般pasteboardは使っていません。
- 別bundle IDの署名済みSandboxテストアプリで、署名付きローカルfeedからの正常更新・再起動と、架空の保存データ／設定の保持を確認しました。不正なアーカイブ署名はSparkleの署名エラーで拒否され、旧appのmanifestが不変でした。OS保護設定は変更していません。
- 0.2.0／build 2の専用候補をDeveloper IDで署名し、既知6code ownerの両CPU sliceに対する署名・Hardened Runtime・権限の専用preflightが成功しました。ZIP再展開後の同じpreflightとapp manifest一致も確認しました。公証提出・staple・公開・初回配置は未実施です。
- 同候補のアーカイブ署名と署名付きappcastを、Keychainの既定アカウントでローカル生成・検証しました。予定先はGitHub Releaseのv0.2.0です。公証後のstapleでbytesが変わるため、配布前にZIP・hash・署名・feedを作り直します。候補feedは公開していません。
- 公開履歴の内容監査は追加した外部package参照を要レビューとして検出しました。Sparkle 2.10.1の固定revision、公式SPM配布checksum、ライセンス全文と既知同梱コードを確認して採用しています。外部依存がなくなったという判定や全面的な脆弱性監査の合格には置き換えません。
- 上記の実更新fixtureは独自user driverを使います。製品のforwarding driver、編集の保留・取消、通常終了の表示や人間による操作体験の実証へは拡張しません。製品adapterのセッション・チャンネル認可、延期、最終gate、lockはソースレビューと架空サービスの試験で確認しています。

候補作成時点では、公開feedからの製品版の取得、初回配置、製品版同士の実更新、macOS 14／Intel実機、UI・IME・VoiceOverの追加確認は未実施でした。一般向け配布の承認やM4総合合格の記録ではありません。


## 0.2.0の初回公開

0.2.0／build 2の署名済み候補について、Apple公証のAcceptedと審査logのアーカイブhash一致・指摘0件を確認しました。同じコードへticketをstapleし、appと最終ZIP再展開物の両方で専用distribution preflightが成功しました。全CPUの署名・権限・Hardened Runtime・timestamp、staple、GatekeeperのNotarized Developer ID判定、app manifest一致を含みます。

公開物は[GitHub Release v0.2.0](https://github.com/TaigaShinohara/OneClip/releases/tag/v0.2.0)です。tagのソースは`66b018bd553e82fcc2bac7d3ae01e97bba11847c`、製品コードの由来は`0f07430a5b953a35f85d4d98bbe41c5e3e175406`で、ビルド前に固定した42製品入力のbytesは両commitで一致します。

- `OneClip-0.2.0.zip`: 2,502,156 bytes。SHA256 `e3e49aa00617d8cae82c916fe82df7b48a3bbf81ab868d78eba0c8e4664c06ab`。
- 初回の`updates/appcast.xml`: 1,188 bytes。SHA256 `e11f6bd4d12a6300a632a516d4ffaf5cdcba012c96010c3b859c9d5d6fd69b1c`。新しいitemを追加した後はfeedのhashが変わります。
- appに同梱した公開鍵だけを使い、最終ZIPの全bytesとSparkle 2.10.1の署名block抽出仕様に対応するfeedのEd25519署名を別々に検証しました。公開URLからZIPを再取得して、HTTP 200・長さ・hash・アーカイブ署名の一致も確認しました。

これは署名・公証・初回配布物の個別検証です。初回の手動配置、製品UIの操作、製品版同士の更新・rollback、offline起動、macOS 14／Intel実機などの受入へ拡張しません。M4総合と対象Collection VoiceOverの保留は継続します。保存画像・設定・権限やGatekeeperの設定を変更して公開を成立させていません。
