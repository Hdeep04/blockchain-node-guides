# Ethereum バリデータ構築 第3部・分散化（SSV）編

> **自サーバーのリソースを有効活用し、SSVノードも兼業する（二毛作）**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第2部の物理サーバーの余力を使い、DVT(SSV)ノードを兼業稼働 |
| コンセプト | 農業でいう「二毛作」— 同じ畑（サーバー）で2つの作物を育てる |
| SSVクライアント | ssvlabs/ssv-node（Dockerで稼働） |
| 接続先 | 既存のローカル Geth(EL) + 外部Alchemy(CL) ※詳細は後述 |
| テストネット | Hoodi Testnet |
| 前提 | 第2部・ベアメタル編が完了していること |

> ⚠️ **本書は機密情報を一切含みません。** ユーザー名・鍵・アドレスは全て `<...>` のプレースホルダです。

---

## 「二毛作」という発想 — なぜSSVを兼業するのか

### 本来の構成と今回の構成の違い

SSVノードは本来、専用に1台のサーバーを立てて運用するのが推奨とされています。今回はあえて、第2部で構築した既存サーバーの「余力」を活かして兼業します。

| 観点 | 本来推奨（専用ノード） | 今回の構成（二毛作） |
|---|---|---|
| サーバー台数 | SSV専用にもう1台 | 既存の1台で兼業 |
| メリット | 障害の影響を完全分離 | ハード費用・電気代を節約。リソースを有効活用 |
| デメリット | コスト増 | 片方の負荷が他方に影響しうる |
| 向く人 | プロ・大規模運用 | 学習・検証・個人運用 |

> 💡 第2部のサーバーは Geth + Lighthouse の稼働でCPU/メモリにまだ余裕があります。この遊休リソースにSSVノードを「相乗り」させ、同じ電気代で2つの役割（Lido CSMバリデータ + SSVオペレーター）をこなすのが狙いです。

> ⚠️ 二毛作は効率的ですが、本番大規模運用では専用ノード分離が望ましい点は理解しておきましょう。本書は学習・検証目的での兼業構成です。

---

## SSV と DVT の概念解説

### なぜDVT（分散型バリデータ技術）なのか

従来のソロステーキングは秘密鍵を1台に置くため、2つの弱点があります。

- **単一障害点（SPOF）：** そのマシンが落ちると署名が止まりペナルティ
- **鍵の集中リスク：** 鍵が漏洩すれば即座に資産が危険にさらされる

DVT（Distributed Validator Technology）は、1つのバリデータの仕事を複数の独立マシンに分散させ、この弱点を同時に解決します。SSVはその代表的実装の一つです（もう一つの代表がObol）。

### DVTの核となる4技術

| 技術 | 役割 |
|---|---|
| シャミアの秘密分散 | 1つの鍵を複数の「鍵シェア」に分割する |
| 閾値署名 | 例: 4台中3台が署名すれば有効。1台落ちても継続 |
| BLS署名の加算性 | 分割した署名を合算でき、鍵本体を1箇所に復元しなくてよい |
| QBFT/IBFTコンセンサス | オペレーター間で署名内容を合意する仕組み |

> 💡 EthereumのBLS署名は「足し算ができる」性質を持つため、各オペレーターの署名シェアを合算して完全な署名を作れます。ネットワークからは通常の1署名に見えます。

### 3-of-4 構成のイメージ

| 状況 | 署名可否 | 解説 |
|---|---|---|
| 4台すべて稼働 | ✅ 可能 | 通常運転 |
| **1台ダウン** | **✅ 可能** | **残り3台で閾値を満たす（DVTの真価）** |
| 2台ダウン | ❌ 不可 | 閾値（3）を割り込み署名できない |

> ✅ これにより、メンテ・ハード故障・クラウド障害が「ペナルティなしで」吸収できます。従来のソロステーキングにない最大の利点です。

### 用語の整理

| 用語 | 意味 |
|---|---|
| オペレーター | SSVノードを運用する主体。各自が鍵シェアの1つを担当 |
| クラスター | 1バリデータを共同運用するオペレーターの集合（最低4台） |
| KeyShare | 分割されたバリデータ鍵の断片 |
| **オペレーター鍵（RSA）** | SSVネットワーク上で自分を識別する鍵（バリデータ鍵とは別物） |

> ⚠️ **「オペレーター鍵（RSA）」と「バリデータ鍵（BLS）」は別物です。** 前者はSSVでの本人確認用、後者は実際にETHをステークする鍵です。

---

## 今回の接続構成

SSVノードをDockerで追加し、第2部で稼働中のローカルGethと外部Alchemy（理由は後述）に接続します。

| 接続先 | プロトコル | アドレス | 用途 |
|---|---|---|---|
| EL (Geth) | WebSocket | `ws://127.0.0.1:8546` | スマートコントラクトのイベント監視 |
| CL (Beacon) | HTTPS | Alchemy Hoodi Beacon | ビーコンチェーンの状態取得・署名 |

> 💡 **なぜCLに外部Alchemyを使うのか** — これは次章「実録トラブル」で詳しく説明します。

---

## Phase 1　Dockerのインストール

```bash
# 公式リポジトリの準備
sudo apt update && sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu noble stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update

# Docker Engine + Compose プラグインのインストール
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
docker --version && docker compose version

# sudo なしで docker を実行できるようにする
sudo usermod -aG docker $USER
newgrp docker

# 動作確認
docker run hello-world
```

> ✅ 「Hello from Docker!」が表示されれば Phase 1 完了です。

---

## Phase 2　オペレーター鍵の生成

```bash
# ディレクトリ作成
sudo mkdir -p /opt/ssv/data /opt/ssv/config
sudo chown -R <your_user>:<your_user> /opt/ssv

# パスワードファイルの作成（所有者のみ読み書き可能）
echo '<your_strong_password>' > /opt/ssv/data/password.txt
chmod 600 /opt/ssv/data/password.txt
```

```bash
# 使い捨てコンテナでオペレーター鍵を生成
# --rm: 終了後にコンテナを自動削除（一時使い捨て）
docker run --rm -it \
  -v /opt/ssv/data:/data -w /data \
  ssvlabs/ssv-node:latest \
  /go/bin/ssvnode generate-operator-keys \
  --password-file=/data/password.txt

# 生成確認
ls -l /opt/ssv/data/
```

生成される2ファイル：

| ファイル | 内容 |
|---|---|
| `encrypted_private_key.json` | 暗号化されたオペレーター秘密鍵（pubkeyも内包） |
| `password.txt` | 復号用パスワード |

```bash
# 公開鍵（pubkey）の取り出し → Phase 6の登録で使用
cat /opt/ssv/data/encrypted_private_key.json | jq -r '.pubkey'
```

> ⚠️ **`encrypted_private_key.json` と `password.txt` は必ず別デバイスにバックアップしてください。** 失うと二度と同じオペレーターを操作できません。

---

## Phase 3　設定ファイルの作成

```bash
# config.yaml（最小構成）
cat <<EOF > /opt/ssv/config/config.yaml
global:
  LogLevel: "info"
EOF
```

```bash
# 権限設定
sudo chown -R <your_user>:<your_user> /opt/ssv
sudo find /opt/ssv -type d -exec chmod 700 {} +
sudo find /opt/ssv -type f -exec chmod 600 {} +
```

```yaml
# /opt/ssv/docker-compose.yaml
# network_mode: host により、コンテナがホストの127.0.0.1に直接アクセス可能
services:
  ssv-node:
    image: ssvlabs/ssv-node:latest
    container_name: ssv-node
    restart: unless-stopped
    network_mode: "host"
    environment:
      - CONFIG_PATH=/config.yaml
      - NETWORK=hoodi
      - PRIVATE_KEY_FILE=/data/encrypted_private_key.json
      - PASSWORD_FILE=/data/password.txt
      - ETH_1_ADDR=ws://127.0.0.1:8546
      - BEACON_NODE_ADDR=https://eth-hoodibeacon.<rpc_provider>/v2/<API_KEY>
      - METRICS_API_PORT=15000
    volumes:
      - /opt/ssv/data:/data
      - /opt/ssv/config/config.yaml:/config.yaml
    command: /go/bin/ssvnode start-node --config /config.yaml
```

---

## Phase 4　起動と生存確認

```bash
cd /opt/ssv
docker compose up -d
docker compose ps
```

```bash
# ログの健康診断
docker compose logs -f --tail 50
```

| ログメッセージ | 意味 |
|---|---|
| `successfully loaded operator keys` | オペレーター鍵の読み込み成功 ✅ |
| `received head event {slot:...}` | CLからの新スロット通知受信 ✅ |
| `fetched registry events {progress:100%}` | ELからのイベント取得完了 ✅ |
| `submitted validator registrations {count:0}` | 担当バリデータ0個で待機中（登録前は正常） |

```bash
# P2Pピア接続数の確認
curl -s http://127.0.0.1:15000/metrics | grep ssv_p2p_peers_connected
```

---

## Phase 5　Geth に WebSocket を追加

SSVノードはELにWebSocket（ws）で接続します。第2部のGethはHTTPのみ公開していたため追加が必要です。

> ⚠️ **この作業中はバリデータ署名が一時停止します。短時間で完了させてください。**

```bash
sudo vi /etc/systemd/system/geth.service
```

`ExecStart` に以下を追記します：

```ini
  --ws \
  --ws.api eth,net,engine \
  --ws.addr 127.0.0.1 \
  --ws.port 8546 \
```

```bash
sudo systemctl daemon-reload && sudo systemctl restart geth

# WSが有効になったか確認
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  http://127.0.0.1:8545
```

---

## 【最重要実録・世界初記録】SSV v2.4.2 + Lido CSM(Hoodi) 環境でのネットワーク名競合とハイブリッド構成の確立

この問題は日本語・英語を問わず公開情報として存在しない一次記録です。

### 1. 発生した課題

SSVノードをローカルのLighthouse（Hoodi）に接続すると、起動直後に `nil pointer dereference` パニックを起こしてコンテナがRestarting ループに陥りました。

```bash
# 確認したバージョン
docker run --rm ssvlabs/ssv-node:v2.4.2 /go/bin/ssvnode version
# 出力: v2.4.2-9117de68763017de6711515fb6e9dcad44bcc0e1
```

### 2. 根本原因：ネットワーク名のアイデンティティ不一致

| コンポーネント | ネットワーク名 | 挙動 |
|---|---|---|
| Lighthouse（CSM側） | `hoodi`（Lido公式手順に従い `--network hoodi` で起動） | APIが自身を `"hoodi"` と返答 |
| SSV ノード v2.4.2 | `holesky`（標準的なテストネット名を期待） | `"hoodi"` という未知の名前を受け取りパニック |

> ⚠️ **SSV v2.4.2 はネットワーク名の検証が極めて厳格で、`"holesky"` 以外のテストネット名を受け取ると強制終了します。** Lido CSM が Hoodi に移行したことで生じた互換性の断絶です。

### 3. 対応方針の大前提

既存の Lido CSM（本業の10バリデータ稼働環境）の安定性を最優先とするため、**Lighthouse 側の設定（`--network hoodi`）は絶対に変更しない。SSV 側で回避策を講じる。**

### 4. 暫定対応：完全外部API（Alchemy）への退避

まずSSVノード自体の動作確認を優先し、EL・CL 両方の接続先を Alchemy に向けることでパニックを回避して起動に成功しました。

```yaml
# 切り分け用：両方Alchemyに向ける（検証のみ）
- ETH_1_ADDR=wss://eth-hoodi.g.alchemy.com/v2/<API_KEY>
- BEACON_NODE_ADDR=https://eth-hoodibeacon.g.alchemy.com/v2/<API_KEY>
```

> ✅ **切り分けの結論：** SSVノード本体・オペレーター鍵は正常。問題は接続先にあった。

しかし新たな問題が浮上しました。

> ⚠️ **SSVノードはミリ秒単位でELのイベントを監視するため、ELのトラフィックがAlchemyのコンピュートユニット（CU）を猛烈な勢いで消費し、無料枠では到底持たないことが判明しました。**

### 5. 最適化：ELのみローカル回帰（ハイブリッド構成の確立）

CU消費問題を解決しつつ、ネットワーク名パニックも回避するため、以下の分析に基づいてアーキテクチャを最適化しました。

| レイヤー | パニックを起こすか | 最終接続先 | 理由 |
|---|---|---|---|
| **CL（Beacon Node）** | **起こす**（`"hoodi"` 名を厳格に検証） | 外部Alchemy継続 | ネットワーク名問題を回避するため |
| **EL（Geth）** | 起こさない（ネットワーク名を検証しない） | ローカルGeth（`ws://127.0.0.1:8546`） | CUコスト削減・自律性確保のため |

**「目（CL）はクラウドのAlchemyを借り、体（EL）はローカルのGethを使う」ハイブリッド構成です。**

```yaml
# docker-compose.yaml の最終設定
- ETH_1_ADDR=ws://127.0.0.1:8546                                        # ローカルGeth
- BEACON_NODE_ADDR=https://eth-hoodibeacon.g.alchemy.com/v2/<API_KEY>   # 外部Alchemy継続
```

```bash
cd /opt/ssv && docker compose down && docker compose up -d
docker compose logs -f --tail 30
```

### 6. 最終確認：ハイブリッド構成の成功

| ログ | 意味 |
|---|---|
| `fetched registry events {address: ws://127.0.0.1:8546, progress: 100%}` | EL = ローカルGethとの接続成功 ✅ |
| `received head event {slot: ...}` | CL = Alchemy Beacon からの最新スロット受信 ✅ |
| `Following Chain Head` | 1スロットの遅延もなくチェーン追従中 ✅ |

### 7. このハイブリッド構成が実現したもの

| 効果 | 内容 |
|---|---|
| Lido CSM環境の完全保護 | 既存のLighthouseの設定を一切変更せず、バリデータ署名成功率100%を維持 |
| APIコストの大幅削減 | 最も通信量の多いELトラフィックをローカルGethで吸収。Alchemyの無料枠内で長期稼働 |
| SSVノードの完全同期 | パニックを回避し、1スロットの遅延もなく最新チェーンヘッドを追従 |
| 知見の記録 | 日本語・英語を問わず公開情報として存在しない一次記録 |

### 8. バージョンアップによる解決見通し

| 対応策 | 現実性 | 備考 |
|---|---|---|
| SSV バージョンアップ | △ 未リリース | v2.5.x以降でhoodi名の許容を期待。リリース後に再検証 |
| **現状維持（ハイブリッド）** | **✅ 推奨** | **実績あり・安定稼働中** |

> 💡 現時点（2025年6月）では `latest` = `v2.4.2` が最新安定版です。v2.5.x がリリースされた際は、ローカルLighthouseへの接続を再検証してください。

---

## Phase 6　SSVネットワークへのオペレーター登録

| 手順 | 操作 |
|---|---|
| 1. WebApp接続 | https://app.ssv.network/ にアクセス、ウォレット接続（Hoodi） |
| 2. Register Operator | 「Join as Operator」→「Register Operator」 |
| 3. 公開鍵を貼付 | Phase 2 で取り出した `pubkey` を入力 |
| 4. 手数料設定 | オペレーター手数料を設定（テストネットは低めでOK） |
| 5. TX承認 | 承認すると Operator ID が発行される |

### SSV WebApp での Fee Recipient 設定（必須）

> ⚠️ **SSV Network 経由でバリデータを運用する場合も、fee-recipient は Lido 公式の EL Rewards Vault アドレスに設定する義務があります。**

| ネットワーク | fee-recipientに設定するアドレス |
|---|---|
| Hoodi Testnet | `0x9b108015fe433F173696Af3Aa0CF7CDb3E104258` |
| Mainnet（本番） | `0x388C818CA8B9251b393131C08a736A67ccB19297` |

SSV dApp での設定手順：
1. https://app.ssv.network/ → 右上「Fee Address」をクリック
2. 上記の Lido EL Rewards Vault アドレスを入力
3. 「Update」ボタンをクリックしてTXを承認

> ⚠️ **Fee Recipient はウォレット単位で設定されます。** SSVで他のプロトコルも並行運用する場合は、Lido用と別ウォレットを使ってください。

### ファイアウォール（P2Pポート開放）

```bash
sudo ufw allow 12001/udp   # P2Pピア探索（discv5）
sudo ufw allow 13001/tcp   # P2Pピア接続維持
# ルーター側でも 12001/UDP・13001/TCP のポートフォワーディングが必要
```

| ポート | プロトコル | 用途 |
|---|---|---|
| 12001 | UDP | P2Pピア探索（discv5） |
| 13001 | TCP | P2Pピア接続維持 |
| 15000 | TCP | Metrics API（監視用） |

---

## Phase 7　監視スクリプトへのSSV項目追加

第2部の `node_check.sh` に `[12] SSV Node` を追記します（スクリプト末尾の `====` 区切りの直前）。

```bash
# ==========================================
# [12] SSV Node (DVT) Status
# ==========================================
echo -e "\n${YELLOW}[12] SSV Node (DVT) Status${NC}"

if command -v docker >/dev/null 2>&1 && \
   docker ps -a --format '{{.Names}}' | grep -q "^ssv-node$"; then
    SSV_STATUS=$(docker inspect -f '{{.State.Status}}' ssv-node 2>/dev/null)
    if [ "$SSV_STATUS" == "running" ]; then
        echo -e " - Container : ${GREEN}active (running)${NC}"
        # P2Pピア数（Metrics APIから取得）
        SSV_PEERS=$(curl -m 3 -s http://127.0.0.1:15000/metrics \
          | grep '^ssv_p2p_peers_connected' | awk '{print $2}')
        echo -e " - P2P Peers : ${CYAN}${SSV_PEERS:-Error}${NC}"
        # 最新の同期スロット（生ログから抽出）
        SSV_SLOT=$(docker logs ssv-node --tail 100 2>&1 \
          | grep "DutyScheduler" | grep "received head event" | tail -n 1 \
          | awk -F'"slot": ' '{print $2}' | awk -F',' '{print $1}')
        echo -e " - Sync Slot : ${GREEN}${SSV_SLOT:-Waiting...}${NC} (Following Chain Head)"
    else
        echo -e " - Container : ${RED}${SSV_STATUS}${NC}"
    fi
else
    echo -e " - Container : ${YELLOW}Not installed${NC}"
fi
```

| 項目 | 確認内容 |
|---|---|
| Container | docker inspect でRestarting ループに陥っていないか |
| P2P Peers | Metrics APIから、外の世界と繋がっているか（孤立検知） |
| Sync Slot | 生ログから最新のHead Event受信を抽出し、EL/CL連携を証明 |

### 運用コマンド集

```bash
# バージョン確認
docker run --rm ssvlabs/ssv-node:v2.4.2 /go/bin/ssvnode version

# ノードの更新（最新イメージに入れ替え）
cd /opt/ssv && docker compose pull && docker compose up -d

# リアルタイムログ
docker compose logs -f --tail 50
```

---

## トラブルシューティング事例

| 症状 | 原因 | 対処 |
|---|---|---|
| 起動直後に `nil pointer dereference` | **ネットワーク名の競合（`hoodi` vs `holesky`）** | **CLを外部Alchemyに向けるハイブリッド構成へ（本書参照）** |
| Restartingを繰り返す（上記以外） | config.yaml や環境変数の設定ミス | `docker compose logs` でエラー行を確認 |
| `fetched registry events` が出ない | Geth の `--ws` が無効 | Phase 5 で `--ws` を追加して再起動 |
| P2P Peers が 0 のまま | ルーターのポート開放不足 | 12001/UDP・13001/TCP を開放 |
| `received head event` が出ない | Beacon API への接続失敗 | `BEACON_NODE_ADDR` と Alchemy API キーを確認 |
| 鍵ファイルが読めない | ファイル所有者の不整合 | `chown` と `chmod 600` を再設定 |

---

## 3部作を終えて

- **第1部：** VMでの検証と、I/Oリソース限界の体感。移行の必要性を自ら発見
- **第2部：** 物理PCへの安全な鍵移行・10鍵への増設・Prometheus/Grafana/自作スクリプトによる長期安定運用
- **第3部：** 余剰リソースを活かしたSSV(DVT)の兼業（二毛作）＋ネットワーク名競合の自力解決とハイブリッド構成の確立

> ✅ **ソロステーキング（Lido CSM）とDVT（SSV）の両方を1台のサーバーで「二毛作」として実機運用し、さらに SSV v2.4.2 の未報告バグ（Hoodi ネットワーク名の非対応）を自力で発見・特定・回避しました。この構成と知見は、日本語・英語を問わず公開情報として存在しない一次記録です。**
