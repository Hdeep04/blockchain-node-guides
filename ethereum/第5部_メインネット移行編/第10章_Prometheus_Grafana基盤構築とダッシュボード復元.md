# 第5部・メインネット移行編 第10章 Prometheus/Grafana基盤構築とダッシュボード復元 — 過去に作った画面を、土台として使う

> **テストネット時代に組んだダッシュボードのJSONが、そのまま使える形で残っていた**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第9章のディスク対応を終えた同日、node_checkでは追えない「傾向」を可視化するための監視基盤を、メインネットに新規構築する |
| 実施日 | 2026年8月21日 |
| 対象 | Prometheus・Node Exporter・Grafanaの新規インストール、1画面ダッシュボードの復元 |
| 前提 | 第4部第8〜9章（死活監視の設計思想・プッシュ型監視の実装）、第5部第6章（バックアップ実践記録）、第9章（ディスク逼迫対応） |

> ⚠️ 本章は機密情報を一切含みません。

---

## 1. コンソール画面という「型」の必要性

`node_check`はコマンド一発で今の状態を教えてくれるが、あくまで**その瞬間のスナップショット**である。第9章の作業を通じて、「傾向」——増加ペース、変化のタイミング——を追うには、時系列で見られる画面が別途必要だと分かった。

また、読者にとっても、文字だけの手順書より、実際に手を動かして構築できる「コンソール画面」があった方が、理解と再現がしやすい。この2つの理由から、メインネットにもPrometheus/Grafanaを一から構築することにした。

## 2. Prometheusのインストール：v3系での仕様変更

```bash
sudo useradd --no-create-home --shell /bin/false prometheus
sudo mkdir /etc/prometheus /var/lib/prometheus
curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest \
  | grep browser_download_url | grep linux-amd64
```

最新版（v3.14.0）をダウンロード・展開したところ、想定していた手順と食い違いが生じた。

```bash
tar xvf prometheus-3.14.0.linux-amd64.tar.gz
```

```
prometheus-3.14.0.linux-amd64/prometheus.yml
prometheus-3.14.0.linux-amd64/prometheus
prometheus-3.14.0.linux-amd64/NOTICE
prometheus-3.14.0.linux-amd64/LICENSE
prometheus-3.14.0.linux-amd64/promtool
```

`consoles`・`console_libraries`ディレクトリが同梱されていなかった。これはエラーではなく、**Prometheus v3系での仕様変更**である。Web上の簡易コンソール機能（`/consoles`エンドポイント）は、Grafanaでの可視化が主流になった現在ではほぼ使われておらず、最近のリリースから同梱されなくなっている。

> ⚠️ **バージョンが古い記事の手順をそのまま使うと詰まる箇所。** `--web.console.templates`・`--web.console.libraries`といったフラグを指定する古い手順をそのまま使うと、存在しないディレクトリを指すため起動に失敗する。実際に構成を確認してから、必要なフラグだけを含むsystemdサービスファイルを作成した。

```bash
sudo tee /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus Monitoring System
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=90d \
  --web.listen-address=127.0.0.1:9090 \
  --web.enable-lifecycle

[Install]
WantedBy=multi-user.target
EOF
```

`--web.listen-address=127.0.0.1:9090`でローカル限定に制限し、`--web.enable-lifecycle`により設定変更後の再起動なしリロードを可能にした。

## 3. prometheus.ymlの段階的構築

一度に全ターゲットを書くのではなく、稼働確認できたサービスから順に追記していく方式を取った。まずgethのみで起動確認する。

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'geth'
    metrics_path: /debug/metrics/prometheus
    static_configs:
      - targets: ['127.0.0.1:6060']
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus
curl -s http://127.0.0.1:9090/api/v1/targets | python3 -m json.tool
```

`geth`・`prometheus`とも`"health": "up"`を確認した。

## 4. Node Exporterの追加

```bash
sudo useradd --no-create-home --shell /bin/false node_exporter
wget https://github.com/prometheus/node_exporter/releases/download/v1.12.1/node_exporter-1.12.1.linux-amd64.tar.gz
tar xvf node_exporter-1.12.1.linux-amd64.tar.gz
sudo mv node_exporter-1.12.1.linux-amd64/node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter
```

```bash
sudo tee /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=127.0.0.1:9100 \
  --collector.systemd

[Install]
WantedBy=multi-user.target
EOF
```

`--collector.systemd`を有効化し、geth・lighthouse等のsystemdサービス自体の状態もPrometheus側から見られるようにした。起動後、`prometheus.yml`にジョブを追記し、`curl -X POST http://127.0.0.1:9090/-/reload`でリロード。`geth` `node_exporter` `prometheus`の3つが揃って`up`になったことを確認した。

続けて、Lighthouse BN（5054番）・VC（5064番）の実在も確認した。

```bash
curl -s http://127.0.0.1:5054/metrics | head -5
systemctl cat mev-boost | grep -i metric
```

Lighthouse BNは正常に応答したが、MEV-Boostには`--metrics`関連のフラグが存在しなかった。過去の記録を検索したところ、テストネット時代の「MEV-Boost Registrations」パネルも、実際にはMEV-Boost自体ではなく**Lighthouse VCが公開するメトリクス**（`builder_validator_registrations_total`）を参照していたことが判明した。専用exporterの追加は不要と分かり、`lighthouse_bn`・`lighthouse_vc`の2ジョブを追記して完了した。

## 5. Grafanaのインストール

```bash
sudo apt-get install -y apt-transport-https software-properties-common wget
sudo mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee -a /etc/apt/sources.list.d/grafana.list
sudo apt-get update
sudo apt-get install -y grafana
sudo systemctl enable --now grafana-server
```

Tailscale経由でブラウザから`http://<Tailscale IP>:3000`にアクセスし、初回ログイン後にユーザー名・パスワードを変更した。「Connections」→「Data sources」でPrometheus（`http://127.0.0.1:9090`）を追加し、「Successfully queried the Prometheus API」の成功メッセージを確認した。

## 6. 公式ダッシュボードのインポート

車輪の再発明を避け、開発元・コミュニティが公開している実績あるダッシュボードを、まず土台として導入した。

| 対象 | ID/取得元 | 備考 |
|---|---|---|
| Node Exporter | grafana.com ID: `1860`（Node Exporter Full） | 事実上の業界標準 |
| Geth | grafana.com ID: `18463`（Go-Ethereum-By-Instance） | `--metrics.expensive`未指定のため一部パネルがNo data |
| Lighthouse BN/VC | `sigp/lighthouse-metrics`のJSON直接インポート | Lighthouse開発元（Sigma Prime）公式 |

> 💡 **grafana.comのIDを最初から確信を持って提示できたわけではない。** 一度、実在しないIDを案内してしまい、web検索で改めて実在するID（16352、15750、18463等）を確認し直す一幕があった。ダッシュボードIDは検証せずに答えると外れることがある、という教訓を得た。

## 7. 「1画面で見たい」という要望

公式ダッシュボードは網羅的だが、Geth用・Lighthouse用と画面が分かれてしまい、日常のヘルスチェックには不向きだった。テストネット時代のダッシュボード（Hoodi Bare-metal環境向け）は、必要な項目だけを1画面に集約する設計だったことを踏まえ、同じ思想の画面を再現することにした。

## 8. 第6章の教訓との再会：JSONは手元に残っていた

第6章の「今後の課題」には、こう記されていた。

```
[ ] Grafanaダッシュボードのエクスポート（カテゴリAへの追加、未着手）
```

サーバー自体はOS再構築で消えており、ダッシュボードのデータベースも失われていた。「復元」ではなく「再現」しかできないと考えていたが、過去のプロジェクトファイル一式を見直したところ、実は各パネルの完全なJSON定義が、テストネット構築当時の記録としてそのまま残っていることが分かった。

```json
{
  "title": "<Operator番号> (Hoodi Bare-metal)",
  "panels": [
    { "title": "Attestation Success Rate", ... },
    { "title": "Network Peers (Geth vs LH)", ... },
    { "title": "CPU Temperature", ... },
    { "title": "Samsung 990 PRO Write Load", ... },
    { "title": "MEV-Boost Registrations", ... }
  ]
}
```

> 💡 **エクスポートを怠っても、別の記録が保険になっていた。** 意図した手段（ダッシュボードJSONの明示的なエクスポート）は実行されていなかったが、結果的に、構築過程を都度記録として残していたことが、代わりの保険として機能した形になった。ただし、これは偶然の産物であり、次に同じ状況に陥らないよう、完成後は都度エクスポートする習慣を徹底する必要がある。

## 9. インポート直後の問題：5パネル中3つがNo data

見つかったJSONを、Grafanaの「Import via panel json」でそのままインポートした。ダッシュボードタイトルは自動的に現在のOperator番号を含む形（<Operator番号> mainnet Bare-metal）に更新されたが、5パネル中3つが`No data`だった。

```
✅ CPU Temperature
✅ Samsung 990 PRO Write Load
❌ MEV-Boost Registrations
❌ Attestation Success Rate
❌ Network Peers
```

原因は2種類あった。

### 9-1. データソースのUID不一致

JSON内には、すべてのパネルにテストネット時代のPrometheusデータソースUID（`afgp2wqtieps0c`）が埋め込まれていた。新規作成したデータソースのUIDとは一致しないため、パネル側が参照先を見失っていた。

各パネルを一度「Edit」で開くと、Grafanaが自動的に現在のデータソースへ再紐付けし、3パネル（CPU Temperature、Network Peers、Samsung 990 PRO Write Load）が復活した。

### 9-2. メトリクス名自体の変更

残る2パネルは、UIDの問題ではなく、**参照しているメトリクス名が現行のLighthouseバージョンに存在しない**ことが原因だった。

```bash
curl -s http://127.0.0.1:5064/metrics | grep -i attestation
# → vc_signed_attestations_total は存在せず
```

Beacon Node側のメトリクス一覧を確認したところ、`validator_monitor_attestation_simulator_head_attester_hit_total`という、シミュレーションベースの代替メトリクスが見つかった。

```promql
sum(rate(validator_monitor_attestation_simulator_head_attester_hit_total[5m]))
/
(sum(rate(validator_monitor_attestation_simulator_head_attester_hit_total[5m])) + sum(rate(validator_monitor_attestation_simulator_head_attester_miss_total[5m])))
* 100
```

このクエリに差し替え、パネル名も実態に即して「Attestation Readiness (Simulated)」に変更した。なぜこの値が、Pending activation中でも100%近い値を示すのか——「もし今Activeだったら正しく振る舞えていたか」という、Lighthouse内部の予測評価であるため、と説明できる。

一方「MEV-Boost Registrations」（`builder_validator_registrations_total{status="success"}`）は、Beacon Node側にも代替メトリクスが見つからず、`No data`のまま保留とした。

## 10. Network Peersの数値差、テストネットとの比較

ダッシュボードが動き出した後、Network Peersパネルの値がテストネット時代のスクリーンショット（Lighthouse Peers 180〜200前後）より少なく感じられた。実測を比較した。

| | テストネット時代 | メインネット（現在） |
|---|---|---|
| Lighthouse Peers | 180〜200 | 100〜140 |

`lighthouse.service`の起動オプションを両者で比較したが、`--target-peers`はどちらにも明示指定がなかった。公式ドキュメントを確認したところ、Lighthouseのデフォルト値は`80`であり、2022年のv2.1.4以降変わっていない。テストネット時代の高い値は、当時何らかの形で`--target-peers`が上乗せ指定されていた可能性が高いが、現存する設定ファイルからは特定できなかった。

> 💡 **ピア数は「多いほど良い」わけではない。** Lighthouse公式ドキュメントには、ピア数が多すぎるとノードへの負荷が増え、かえって性能が落ちる場合があるとの記載がある。同期速度のボトルネックは帯域幅ではなくCPU処理速度であり、少数のピアを超えて増やしても恩恵は薄い。今回の100〜140という値は、デフォルト（80）を上回っており、健全な範囲と判断した。

---

## 11. まとめ

```
① Prometheus v3系ではconsoles/console_librariesが同梱されなくなり、
   古い手順書のフラグ指定（--web.console.templates等）は
   そのままでは使えない
② prometheus.ymlは一度に全部書かず、稼働確認できたサービスから
   段階的に追記する方が、問題の切り分けがしやすい
③ MEV-Boost自体には専用メトリクスがなく、当時の「MEV-Boost
   Registrations」もLighthouse VC側のメトリクスを参照していた
④ 公式ダッシュボード（Node Exporter Full、Geth、Lighthouse BN/VC）は
   網羅的だが画面が分かれるため、日常監視には1画面の統合
   ダッシュボードを別途用意する方針とした
⑤ 第6章で「エクスポート未着手」としていたダッシュボードJSONは、
   実際には過去のプロジェクトファイル（会話の記録）に残っており、
   復元の土台として活用できた。ただし偶然の産物であり、今後は
   都度の明示的なエクスポートを徹底する
⑥ インポート直後の「No data」は、原因が2種類あった。
   データソースのUID不一致（Editで開くと自動解消）と、
   メトリクス名自体のバージョン変更（クエリの手動修正が必要）
⑦ Attestation Success Rateは、現行バージョンでは存在しない
   メトリクスだったため、シミュレーションベースの代替に
   差し替え、パネル名も実態に即して変更した
⑧ Network Peersの数値差は、設定の違いではなく、テストネット
   時代の高いピア数の根拠が特定できなかったことによる。
   現在の値（100〜140）はLighthouseのデフォルト（80）を
   上回っており、健全な範囲と判断した
```

---

## 12. 今後の課題・次のステップ

```
[ ] ダッシュボード完成後のJSONエクスポート・バックアップ（都度実施）
[ ] MEV-Boost Registrationsパネルの扱い決定（削除 or 保留のまま）
[ ] node_checkでは追えない傾向（ディスク・メモリ・スワップ）の
    可視化パネル追加（第11章にて対応）
[ ] Grafana Alertingによるプッシュ型通知の再構築（第11章にて対応）
```
