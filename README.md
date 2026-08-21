# MCS Manager

MCS Manager is a native macOS menu-bar application for running and remotely managing multiple Minecraft Java Edition servers. The default UI is Japanese and can be switched to English from the menu-bar window.

Copyright © 2026 Yuki_Orita. Released under the MIT License.

Current release: **v1.0.0**. The post-fix quality assessment is documented in
[`QUALITY_AUDIT_REPORT.md`](QUALITY_AUDIT_REPORT.md).

公式紹介ページ: [MCS Manager](https://studio-rizi.pages.dev/projects/mcs-manager/)

### v1.0.0 UI improvements

- Japanese-first localization with complete Japanese and English resource bundles
- Non-blocking Finder/CSV selection panels designed for the menu-bar window
- High-contrast black and blue native/Web interfaces
- Overlap-resistant 540×620 native layout and responsive Web layout
- Immediate native tab selection and panel-only Web tab updates

## 主な機能

- Paper / Spigot / Purpur / vanilla server JAR と `start.sh` の起動・停止・再起動
- Minecraft 1.20.x、1.21.x、26.x の検出とJava要件の確認
- 複数サーバープロファイル、コンソール、プレイヤー・OP・BAN管理
- ホワイトリストへの追加・削除・有効/無効切替
- 内蔵Web管理画面（サーバー別のステータス、設定、ホワイトリスト、コンソール）
- CPU、Javaプロセスのメモリ、接続遅延、TPS、MSPT、遅延警告、メモリ増加傾向の監視
- JSON REST API（従来の外部ページも引き続き利用可能）

## 動作要件

- macOS 13 Ventura 以降
- Xcode Command Line Tools（ソースからビルドする場合）
- Minecraft 1.20.0–1.20.4: Java 17以上
- Minecraft 1.20.5–1.21.x: Java 21以上
- Minecraft 26.x: Java 25以上

独自の `start.sh` があるサーバーでは、そのスクリプトを優先します。スクリプト内でも対象バージョンに合うJavaを指定してください。

## ビルド

```sh
./build.sh
```

`MCServerManager.app` が生成されます。配布用DMGは次で作成します。

```sh
./package_release.sh
```

## Web管理画面

アプリの「設定」でWebページ/APIを有効化し、管理パスワードを設定します。同一Macでは `http://127.0.0.1:25580/`、LANでは画面に表示されたIPアドレスを開きます。

インターネットへ公開する場合、管理ポートを直接無認証で公開しないでください。必ず長いパスワードを設定し、HTTPS対応のリバースプロキシ、VPN、アクセス元制限のいずれかを併用してください。GitHub Pages版（`https://oriyu90.github.io/Minecraft/`）からHTTP APIへ接続するとブラウザのMixed Content制限を受けるため、内蔵ページまたはHTTPS化した接続先を使用します。

サーバー一覧の「削除」は登録だけを解除します。Minecraftサーバーフォルダやワールドデータは削除しません。

## メトリクスについて

メモリとCPUは管理対象Javaプロセスを計測します。TPS/MSPTはPaper系の `tps` または spark の出力から取得するため、停止中や未対応サーバーでは `—` になります。メモリリーク表示は短時間の増加傾向を知らせる注意喚起であり、リークの確定診断ではありません。

## License

[MIT License](LICENSE) — Yuki_Orita
