# Ethereum バリデータ構築 第1部・検証編

> **VirtualBox VM で Lido CSM バリデータを検証する**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | まず仮想環境(VM)で構築を練習し、本番移行の足がかりにする |
| ホスト環境 | Windows 11 (Ryzen / 16GB RAM / NVMe SSD) |
| 仮想化 | Oracle VirtualBox 7.x |
| ゲストOS | Ubuntu Server 22.04 LTS |
| クライアント | Geth (EL) + Lighthouse (CL/VC) |
| テストネット | Hoodi Testnet |
| 後続 | 第2部・ベアメタル編 / 第3部・分散化(SSV)編 |

> ⚠️ **本書は学習用の手順書です。** 秘密鍵・ニーモニック・パスワード等の機密情報は一切含みません。`<...>` のプレースホルダをご自身の値に置き換えてください。

---

## この3部作の全体ストーリー

| 部 | テーマ | 何をするか / なぜ |
|---|---|---|
| **第1部** | 検証編（本書） | VMで構築を練習。だがSSDのI/O不足などリソースの限界に直面する |
| **第2部** | ベアメタル編 | VMの鍵を専用物理PCへ引っ越し。鍵を10個に増設し、監視を整え長期安定運用へ |
| **第3部** | 分散化(SSV)編 | 余ったサーバーリソースを活かしSSVノードも兼業（二毛作）。分散化に貢献 |

> 💡 **第1部のゴールは「完璧な本番ノード」ではなく「本番で失敗しないための予行演習」です。** VMはいつでも壊して作り直せるので、思い切って試行錯誤できます。

---

## 前提知識

### Ethereum の2層構造（最重要概念）

Ethereum は2つのソフトウェアを連携させて動かします。これは Cardano の単一ノード構成と大きく異なる点です。

| レイヤー | 略称 | ソフト | 役割 |
|---|---|---|---|
| 実行レイヤー | EL | Geth | トランザクション実行・ETH残高・スマートコントラクト |
| 合意レイヤー | CL | Lighthouse (BN) | PoS合意形成・ブロック検証 |
| バリデータ | VC | Lighthouse (VC) | 自分の鍵で署名（アテステーション）・報酬獲得 |

> 💡 **ELとCLはJWT（認証トークン）を介して安全に通信します。** このJWTが両者の共通パスワードです。片方だけでは動きません。

### Lido CSM とは

| 概念 | 説明 |
|---|---|
| 通常のバリデータ | 32 ETH のデポジットが必要 |
| Lido CSM | 少額のボンド（担保）で参加可能。Lidoが32 ETHを補填する |
| Withdrawal Vault | 引き出し先を個人でなくLido指定アドレスにする必要がある |
| スラッシング | 二重署名すると担保が没収される。これを避けるのが最重要 |

---

## Step 1　VM作成とOSインストール

### VirtualBox VM の作成

| 設定項目 | 推奨値 | なぜこの設定か |
|---|---|---|
| メモリ | 16384 MB | Gethキャッシュ + Lighthouse動作に必要 |
| CPU | 4コア | 署名検証の並列処理 |
| ストレージ | 300GB（可変サイズ） | Hoodiの同期DB容量 |
| **コントローラー** | **NVMe（SATAから変更）** | **I/O速度向上。最重要設定** |

> ⚠️ **ストレージコントローラーは必ず SATA → NVMe に変更してください。** これを怠ると後述のI/O不足に直結します（本書最大の教訓）。

### NATポートフォワーディング設定

VirtualBox の「設定 → ネットワーク → 高度 → ポートフォワーディング」で追加します。

| 名称 | プロトコル | ホストPort | ゲストPort |
|---|---|---|---|
| SSH | TCP | 2222 | 22 |
| Geth P2P | TCP/UDP | 30303 | 30303 |
| Lighthouse P2P | TCP/UDP | 9000 | 9000 |

### OS初期セットアップ

```bash
# パッケージ更新と基本ツール
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl wget jq chrony ufw

# 時刻同期（PoSは12秒ごとのスロットで厳格に動くため必須）
sudo systemctl enable --now chrony
chronyc tracking

# ファイアウォール（必要ポートのみ開ける）
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 30303/tcp && sudo ufw allow 30303/udp
sudo ufw allow 9000/tcp  && sudo ufw allow 9000/udp
sudo ufw --force enable

# ノード専用の非特権ユーザー作成
# --no-create-home: ホームディレクトリ不要
# --shell /bin/false: このユーザーでのログインを禁止（セキュリティ）
sudo useradd --no-create-home --shell /bin/false ethereum

# データディレクトリとJWTトークン生成
sudo mkdir -p /var/lib/ethereum/{jwt,geth,lighthouse}
sudo mkdir -p /var/lib/lido-csm
sudo openssl rand -hex 32 | sudo tee /var/lib/ethereum/jwt/jwt.hex > /dev/null
sudo chown -R ethereum:ethereum /var/lib/ethereum /var/lib/lido-csm
sudo chmod 600 /var/lib/ethereum/jwt/jwt.hex
```

> ✅ `chronyc tracking` で `System time` の offset が 0.01秒以内であればOKです。

---

## Step 2　Geth（実行クライアント）の構築

### インストール

```bash
# Ethereum公式PPAから導入（常に最新版が提供される）
sudo add-apt-repository -y ppa:ethereum/ethereum
sudo apt-get update && sudo apt-get install -y geth
geth version
```

### Systemdサービスの作成

```bash
sudo vi /etc/systemd/system/geth.service
```

```ini
[Unit]
Description=Geth Execution Client (Hoodi)
After=network.target

[Service]
User=ethereum
Group=ethereum
Type=simple
Restart=always
RestartSec=5
ExecStart=/usr/bin/geth \
  --hoodi \
  --datadir /var/lib/ethereum/geth \
  --authrpc.addr 127.0.0.1 \
  --authrpc.port 8551 \
  --authrpc.jwtsecret /var/lib/ethereum/jwt/jwt.hex \
  --http \
  --http.api eth,net,engine,admin \
  --metrics \
  --metrics.addr 127.0.0.1 \
  --cache 4096 \
  --maxpeers 15

[Install]
WantedBy=multi-user.target
```

> 💡 **VM環境でのピア制限：** `--maxpeers 15` と `--cache 4096` でリソースを抑制しています。後述のVM限界問題の応急処置としても有効です。

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now geth
sudo journalctl -u geth -f -o cat
```

| ログメッセージ | 意味 |
|---|---|
| `Starting Geth on Hoodi testnet...` | Hoodi接続開始 ✅ |
| `Engine API enabled` | JWT準備完了（Lighthouseが接続可能）✅ |
| `Snap sync in progress` | スナップ同期中（正常） |

---

## Step 3　Lighthouse（合意クライアント）の構築

### バイナリの配置

```bash
cd ~
# 公式GitHubから最新安定版を自動取得
RELEASE_URL=$(curl -s https://api.github.com/repos/sigp/lighthouse/releases/latest \
  | jq -r '.assets[] | select(.name | contains("x86_64-unknown-linux-gnu") and (contains("portable")|not)) | .browser_download_url')
curl -L $RELEASE_URL -o lighthouse.tar.gz && tar -xvf lighthouse.tar.gz
sudo mv lighthouse /usr/local/bin/ && lighthouse --version
```

### Beacon Node サービスの作成

```bash
sudo vi /etc/systemd/system/lighthouse.service
```

```ini
[Unit]
Description=Lighthouse Beacon Node (Hoodi)
After=network.target geth.service

[Service]
User=ethereum
Group=ethereum
Type=simple
Restart=always
RestartSec=5
ExecStart=/usr/local/bin/lighthouse bn \
  --network hoodi \
  --datadir /var/lib/ethereum/lighthouse \
  --execution-endpoint http://127.0.0.1:8551 \
  --execution-jwt /var/lib/ethereum/jwt/jwt.hex \
  --checkpoint-sync-url https://checkpoint-sync.hoodi.ethpandaops.io \
  --http \
  --http-address 127.0.0.1 \
  --metrics \
  --target-peers 30

[Install]
WantedBy=multi-user.target
```

> 💡 **`--checkpoint-sync-url` について：** 通常数日かかる同期を数分で完了できます。信頼できるノードの「最新状態のスナップショット」から始める高速同期方式です。

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now lighthouse

# 同期確認（is_syncing: false かつ sync_distance: 0 で完了）
curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq
curl -s http://127.0.0.1:5052/eth/v1/node/peer_count | jq
```

---

## Step 4　バリデータ鍵の生成

> ⚠️ **最重要！** `chain` 名と `withdrawal_address` のミスがスラッシングや鍵の無効化につながります。手順を正確に実施してください。

### ethstaker-deposit-cli の取得

```bash
cd ~/csm-artifacts
# Hoodi対応版のdeposit-cliを公式リリースページからダウンロード
tar -xvf ethstaker_deposit-cli-*-linux-amd64.tar.gz
cd ethstaker_deposit-cli-*-linux-amd64
```

### 新規ニーモニックで鍵を生成

```bash
# --chain hoodi        : Hoodi専用のfork_versionで生成（重要）
# --eth1_withdrawal_address : Lido指定のWithdrawal Vaultアドレスを必ず指定
./deposit new-mnemonic \
  --num_validators 1 \
  --chain hoodi \
  --eth1_withdrawal_address <Lido_Withdrawal_Vault_Address>
```

対話フローへの回答：

| プロンプト | 入力 |
|---|---|
| Language | English を選択 |
| Network/Chain | `hoodi`（リストになければ手動入力） |
| Keystore password | 任意の強力なパスワード（必ず紙に控える） |
| Compounding (0x02) | `no`（Lido CSMは0x01標準） |

> ⚠️ **24単語のニーモニックは画面に一度だけ表示されます。必ず紙に書き留めてオフライン保管してください。デジタル保存・撮影は厳禁です。**

### 生成内容の確認

```bash
# network_name が hoodi、withdrawal_credentials が 0x01 始まりか確認
cat validator_keys/deposit_data-*.json | jq '.[] | {network_name, withdrawal_credentials}'
```

| 確認項目 | 正しい値 |
|---|---|
| `network_name` | `hoodi` |
| `withdrawal_credentials` | `0x01` で始まる（Lido Vault アドレス） |

---

## Step 5　Lighthouse VC 起動と Lido CSM 登録

### 鍵のインポート

```bash
# パスワードファイルを先に用意
echo '<keystore_password>' | sudo tee /var/lib/lido-csm/keystore_password.txt
sudo chown ethereum:ethereum /var/lib/lido-csm/keystore_password.txt
sudo chmod 600 /var/lib/lido-csm/keystore_password.txt

# ethereumユーザーとしてインポート
sudo -u ethereum lighthouse account validator import \
  --network hoodi \
  --datadir /var/lib/lido-csm \
  --directory ~/csm-artifacts/ethstaker_deposit-cli-*-linux-amd64/validator_keys \
  --reuse-password
```

### Lighthouse VC サービスの作成

> ⚠️ **`--suggested-fee-recipient` は必ずLido公式のEL Rewards Vaultアドレスを指定すること。自分のウォレットアドレスを入れると MEV stealing 判定でペナルティを受けます。**

| ネットワーク | fee-recipientに設定するアドレス |
|---|---|
| Hoodi Testnet | `0x9b108015fe433F173696Af3Aa0CF7CDb3E104258` |
| Mainnet（本番） | `0x388C818CA8B9251b393131C08a736A67ccB19297` |

```bash
sudo vi /etc/systemd/system/lighthouse-vc.service
```

```ini
[Unit]
Description=Lighthouse Validator Client (Hoodi)
After=network.target lighthouse.service

[Service]
User=ethereum
Group=ethereum
Type=simple
Restart=always
RestartSec=5
ExecStart=/usr/local/bin/lighthouse vc \
  --network hoodi \
  --datadir /var/lib/lido-csm \
  --beacon-nodes http://127.0.0.1:5052 \
  --suggested-fee-recipient 0x9b108015fe433F173696Af3Aa0CF7CDb3E104258 \
  --metrics

[Install]
WantedBy=multi-user.target
```

> 💡 **VCは `--execution-endpoint` を受け付けません。** BN経由でELと通信するため `--beacon-nodes` を指定します（よくある間違い）。

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now lighthouse-vc
sudo journalctl -u lighthouse-vc -f -o cat
```

### Lido CSM ウィジェットへの登録

ブラウザで https://csm.testnet.fi/ にアクセスします。

| 手順 | 操作 |
|---|---|
| 1. Wallet接続 | MetaMask等を接続（Hoodiテストネットであることを確認） |
| 2. Create Operator | 「Join as a Node Operator」を選択 |
| 3. Deposit Data | `deposit_data-*.json` の中身をそのまま貼り付け |
| 4. Bond支払い | 必要なBond（テストETH）をデポジット |
| 5. 確認 | Operator ID が発行されれば登録完了 |

---

## Step 6　動作確認と「移行の決断」

### 全サービスの確認

```bash
sudo systemctl status geth lighthouse lighthouse-vc
sudo journalctl -u lighthouse-vc -n 20 -o cat | grep attestation
```

| ログメッセージ | 意味 |
|---|---|
| `Successfully published attestations` | 署名成功・報酬発生 ✅ |
| `All validators inactive` | Lidoのデポジット処理待ち（数時間〜） |
| `is_optimistic: true` | まだ完全同期していない（待機） |

---

## 【実録】VMの限界 — なぜベアメタルへ移行したか

VM環境でバリデータは稼働しましたが、運用を続けるうちに複数の問題に直面しました。これが第2部（ベアメタル移行）へ進む直接の理由です。

| 直面した問題 | 内容 |
|---|---|
| **SSDのI/O不足** | VM経由のディスクアクセスはオーバーヘッドが大きく、Gethのブロック検証が遅延しがちだった |
| **ピア過多による負荷** | 一時ピアが479に達し、CPU/メモリが逼迫。検証が雪だるま式に遅延（デススパイラル） |
| **Windows再起動リスク** | ホストのWindows Updateが勝手に再起動し、ノードが巻き添えで停止する危険 |
| **UPnP拒否** | VirtualBoxの壁でインバウンド通信が弾かれ、ピア接続が制限された |

> 💡 **応急処置として `--maxpeers 15` / `--target-peers 30` でピアを絞り、リソースを検証に集中させることで急場はしのげました。しかし根本解決は専用の物理マシン（ベアメタル）への移行でした。**

> ✅ **第1部の最大の学び：VMは学習と検証には最適だが、I/Oがシビアな本番バリデータ運用には専用ハードウェアが望ましい。この気づきこそが第1部の成果です。**

---

## トラブルシューティング事例

| 症状 | 原因 | 対処 |
|---|---|---|
| `deposit_data` の `network_name` が `holesky` | `--chain holesky` を選択してしまった | 削除して `--chain hoodi` で再生成 |
| `withdrawal_credentials` が `0x00` 始まり | `--eth1_withdrawal_address` を未指定 | Lido Vault アドレスを指定して再生成 |
| VCで `--execution-endpoint` エラー | VCはこのオプションを受け付けない | `--beacon-nodes http://127.0.0.1:5052` に変更 |
| ピア数が0のまま | NVMeコントローラー未設定 / ポート不足 | NVMe確認・ポートフォワーディング再設定 |
| 同期が遅すぎる | VMのI/O不足 | ピア数を絞る → 根本的にはベアメタル移行 |

---

> 次は **第2部・ベアメタル編** です。ここで作った鍵を専用物理PCへ安全に引っ越し、鍵を10個に増設し、Prometheus + Grafana で長期安定運用へと育てます。
