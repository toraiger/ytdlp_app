# モバイル回線・Tailscale経由の通信時間

`perf/api-communication` は、iPhoneをモバイル回線に接続し、Tailscale経由でAPIサーバーを利用する場合を対象にしています。

## アプリ側の変更

- API応答後1秒・メディア読み込み前0.4秒の意図的な待ち時間を撤廃。
- iPhoneのAPI通信にURLSessionを利用し、同じセッションを使い回します。サーバーが対応する場合はHTTP/2を自動交渉します。
- 先頭曲の事前読み込み、URL・ヘッダーの短期キャッシュ、処理中の同じ曲へのリクエスト共有を維持。
- HTTPS、API認証、リダイレクト禁止を維持。APIレスポンスのネイティブHTTPキャッシュと自動Cookie送信は使いません。

サーバーのAPI契約の変更は不要です。HTTP/2に対応していないサーバーには、URLSessionが利用可能なプロトコルで接続します。

## iPhoneでAPI時間を確認

1. Wi-Fiをオフにし、モバイル回線とTailscaleをオンにします。
2. アプリでMix一覧を取得し、曲を選びます。
3. 右上の「API サーバー設定」を開き、「直近の API 通信時間」を確認します。

表示はMix取得・再生URL取得・追加取得のうち、先読みも含めて最後に完了した1回の実通信です。サーバーがURLを調べる時間、DNS・TLS・Tailscaleの通信、応答受信を含みます。キャッシュの再利用では新しい通信が発生せず、この値は更新しません。

音声・動画の本体はiPhoneからメディア配信元へ直接接続します。この読み込み時間はAPI通信の計測には含めません。

計測データとして保持するのは処理の種類・所要時間・HTTPステータス・成功可否です。URL、APIキー、Cookie、動画ID、セッションID、レスポンス本文は含めません。

## Tailscaleの経路を確認

iPhoneを同じモバイル回線・Tailscale接続の状態にして、APIサーバーの端末で実行します。`<iPhoneのTailscale IP>` はTailscaleアプリに表示される端末のIPに置き換えます。

```bash
tailscale status
tailscale ping --c=5 <iPhoneのTailscale IP>
tailscale netcheck
```

- IPアドレスとポートが表示される直接接続では、両端末間を直接通信します。
- `DERP` や `relay` が表示される中継接続では、中継地点を経由する分だけ時間が増える場合があります。
- 中継になる場合は、`netcheck` のUDP疎通・IPv6・NATの結果と、端末側のネットワークやファイアウォール設定を確認します。

直接接続にできるかは両端のネットワーク条件によります。アプリ内の変更だけでは接続経路を決定できません。

参考: [Tailscaleの接続方式](https://tailscale.com/kb/1257/connection-types)

## サーバー処理と通信を切り分ける

別のTailscale参加端末で、実際のAPIベースURLの `/health` に対して実行します。`curl --version` のFeaturesにHTTP2がある環境を使います。

```bash
curl --http2 --silent --show-error --output /dev/null \
  --write-out 'status=%{http_code} http=%{http_version} headers=%{time_starttransfer}s total=%{time_total}s\n' \
  https://pi.example.ts.net/health
```

`http=2` なら、その接続ではHTTP/2が使われています。この端末の通信条件はiPhoneのモバイル回線とは異なるため、所要時間は分けて評価します。`/health` が公開されていない構成では、その応答ステータスも確認してください。

`/health` が速く、アプリの「再生URL取得」だけが遅い場合は、サーバー内のメディア情報取得に時間がかかっている可能性があります。サーバーのコードを確認し、同じ動画の重複処理、URLの有効期限を考慮したキャッシュ、情報取得処理の起動コスト、同時実行の上限を調べます。バックエンドのソースはこのリポジトリに含まれていません。

今回のクラウド環境からは、利用中のiPhone・APIサーバーのTailscale接続を実測していません。実際の短縮量は端末での確認が必要です。
