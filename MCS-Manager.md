# MCS Manager — 次回開発用メモ

この文書は次回以降の開発・リリース作業で参照する保守メモです。製品紹介ページやアプリUIからはリンクしません。ユーザー向けの確定仕様は `README.md`、変更履歴は `CHANGELOG.md`、品質評価は `QUALITY_AUDIT_REPORT.md` を正とします。

## 公開情報

- リポジトリ: `oriyu90/MCS-Manager`
- macOSアプリの現在バージョン: `v1.0.0`
- Webサイト: `https://mcs-manager.pages.dev/`
- Cloudflare Pagesプロジェクト名: `mcs-manager`
- Cloudflare Pagesのproduction branch表記: `main`
- GitHub Pagesは使用しない。
- Cloudflare PagesのGit source: GitHub `oriyu90/MCS-Manager`
- `main`上の公開用Web資産が更新されると、CloudflareのGit連携ビルドから自動デプロイされる。
- Cloudflareのビルドコマンドで公開用6ファイルだけを`.pages-dist`へコピーする。Swiftソース、レポート、このメモを配信物へ含めない。
- GitHub ActionsによるPagesデプロイは使用しない。Cloudflare側のGit連携を唯一の自動公開経路とする。
- Cloudflare認証情報はソース、コミット、ログ、この文書へ転記しない。必要時は非公開の共通ルール文書を参照する。

## 共通連絡先

- 開発者表記: `Yuki_Orita`
- 著作権表記: `Copyright © 2026 Yuki_Orita`
- Discord: `https://discord.gg/x7KXhNTD8M`
- X: `https://x.com/InovateofRIZI`
- 開発者公式サイト: `https://oriyu90.github.io/official/`

共通連絡先が変更された場合は、`index.html`、`README.md`、構造化データ、OG情報、Release本文を横断して確認する。

## バージョンアップ時の必須更新

1. `Package.swift`、アプリ内バージョン表記、`README.md`、`CHANGELOG.md`を更新する。
2. `index.html`内のナビゲーション、ヒーロー、ダウンロードURL、最終CTA、JSON-LDの`softwareVersion`と`downloadUrl`を更新する。
3. `sitemap.xml`の`lastmod`を実際の公開日に更新する。
4. `og-image.svg`のバージョン表示を更新し、1200×630pxの`og-image.png`を再生成する。
5. DMGのファイル名、容量、SHA-256を確認し、GitHub Releaseへ添付する。
6. Release作成後にWebサイトを更新して`main`へpushし、Cloudflare PagesのGitビルド完了を確認する。
7. 公開URL、DMG、Discord、X、公式サイト、robots、sitemapがHTTP 200を返すことを確認する。
8. Google Search Consoleで新しいサイトマップを再送信する必要があるか確認する。

## 対応バージョン確認

- Minecraft 1.20.0–1.20.4: Java 17以上
- Minecraft 1.20.5–1.21.x: Java 21以上
- Minecraft 26.x: Java 25以上
- Mojang、Paper、Spigot、Purpur側の要件変更があり得るため、新しいMinecraft版を追加する際は公式情報を再確認する。
- 独自の`start.sh`がある場合はスクリプト側のJava指定が優先される仕様を維持する。

## リリース前の重点確認

- 日本語と英語の翻訳キー数・未翻訳・表示切れ。
- Finder／ファイル選択パネルを初回操作から利用できること。
- タブ切替時の不要な再構築、待ち時間、フォーカス移動。
- 540×620の標準ウインドウと小さい画面でUIが重ならないこと。
- 主要操作領域が44px以上で、キーボードフォーカスが見えること。
- 監視タイマー、プロセス出力、HTTP接続、WebSocket相当の長寿命処理が終了時に解放されること。
- 不正な設定、消えたフォルダ、壊れたJSON、権限不足、ポート競合、Java未導入時にクラッシュしないこと。
- サーバーの「削除」が登録解除だけを行い、ワールドデータを消さないこと。
- Web管理を外部公開する場合のパスワード、HTTPS、VPNまたはアクセス元制限の注意文を維持すること。

## Webサイト保守

- 公開対象: `index.html`、`404.html`、`favicon.svg`、`og-image.png`、`robots.txt`、`sitemap.xml`。
- `og-image.svg`はOG画像の編集元であり、通常は公開必須ではない。
- CloudflareのGit連携で監視するパスは上記5ファイル。アプリコードやこのメモだけの変更ではデプロイしない。
- Cloudflare build command: `mkdir -p .pages-dist && cp index.html 404.html favicon.svg og-image.png robots.txt sitemap.xml .pages-dist/`
- Cloudflare build output directory: `.pages-dist`
- 公開対象を増減した場合は、Cloudflareの監視パス、build command、この文書を同時に更新する。
- productionは`main`、その他のブランチはpreview deploymentとして扱う。
- Direct Upload版へは戻せない。通常はGitHubへのpushによるCloudflare Gitビルドを使用する。
- canonical、`og:url`、`og:image`、Twitter画像、JSON-LDの`url`はCloudflare Pagesの正式URLを使用する。
- 標準検索語として、アプリ名の英語・日本語表記、`折田悠希`、`おりたゆうき`、`Yuki_Orita`、`GitHub`を確認する。
- デスクトップと390px幅のモバイルで横スクロール、見出しの孤立、固定ヘッダーとの重なりを確認する。
- 主要リンクと公開資産のHTTP応答、重複ID、壊れたページ内アンカー、ブラウザのエラー／警告を確認する。
- 存在しないURL、`MCS-Manager.md`、`Package.swift`、`Sources/`配下が404を返し、リポジトリ内部ファイルを配信していないことを確認する。
- Search Consoleの所有権確認タグやファイルが発行された場合は、値を正確に追加し、このチェックリストへ追加場所を記録する。

## 今後の候補（未確定）

- Apple Developer IDによる署名とnotarization。
- アプリ内アップデートまたは更新通知。
- 長期間のメトリクス保存と比較表示。
- メモリ増加傾向の判定期間・閾値の設定項目化。
- Cloudflareの独自ドメインと寄付導線。
- アプリの自動テストとRelease作成のCI化。

上記は予定を保証するものではない。実装前に優先度、保守負担、安全性を再評価する。
