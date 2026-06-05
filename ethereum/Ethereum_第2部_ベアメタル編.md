# Ethereum バリデータ構築 第2部・ベアメタル編

> **鍵を専用物理PCへ引っ越し → 10鍵に増設 → 監視を整え長期安定運用へ**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第1部のVMで作った鍵を物理PCへ移行し、本番運用基盤を作る |
| 移行先ハード | 専用ミニPC (Ryzen 7 / 32GB RAM / 2TB NVMe SSD) |
| 移行先OS | Ubuntu Server 24.04 LTS (GUIなし) |
| 鍵の増設 | 1鍵 → 10鍵にスケールアップ |
| 監視 | Prometheus + Grafana（自作ダッシュボード）+ 自作スクリプト |
| 前提 | 第1部・検証編が完了していること |

> ⚠️ **本書は機密情報を一切含みません。** ユーザー名は `<your_user>`、アドレス類は `<...>` のプレースホルダです。ご自身の値に置き換えてください。

---

## 第2部の全体フロー

| Phase | 作業 | 重要度 |
|---|---|---|
| Phase 0 | ブータブルUSB作成・ハード換装・BIOS設定 | ★★ |
| Phase 1 | VMのサービス停止 + スラッシング保護データのエクスポート | ★★★ |
| Phase 2 | 物理PCのOS・ネットワーク・要塞化（SSH/Tailscale/Fail2Ban） | ★★ |
| Phase 3 | Geth/Lighthouse構築 + 鍵移行 + VC起動 | ★★★ |
| Phase 4 | 鍵を10個に増設（無停止スケールアップ） | ★★ |
| Phase 5 | MEV-Boost導入 | ★ |
| Phase 6 | Prometheus + Grafana 監視スタック構築 | ★★ |
| Phase 7 | sudo不要化の設計と自作スクリプトによる日常運用 | ★★ |

> ⚠️ **Phase 1のスラッシング保護データ移行を省略すると、新旧両環境で二重署名が起き「一発退場（スラッシング）」になります。最優先で正しく行ってください。**

---

## Phase 0　ハードウェア準備

### Step 0-1　ブータブルUSBの作成

Ubuntu Server 24.04 LTSのISOをダウンロードし、Rufusでブータブルメディアを作成します。

```
# PowerShellでSHA256ハッシュを検証（Windowsの場合）
Get-FileHash C:\Users\<your_user>\Downloads\ubuntu-24.04.x-live-server-amd64.iso -Algorithm SHA256
```

Rufusの設定：
- **パーティション構成：** GPT
- **ターゲットシステム：** UEFI (CSM非互換)
- **書き込みモード：** ISOイメージモード（推奨）

> 💡 **なぜGPT/UEFIか：** 新しいミニPCはモダンなUEFI環境のため、レガシーBIOS向けのMBRではなくGPT/UEFIで作成することで、ブートローダー周りのトラブルを防ぎます。

### Step 0-2　SSD換装とBIOS設定

Samsung 990 PRO 2TBへ換装後、BIOS設定を行います。

> 💡 **サーマル対策：** 990 PROはGen4 NVMeの中でも最高峰の性能ですが相応の発熱を伴います。付属のヒートシンクや熱伝導シートが正しく密着しているか確認してください。SSDの熱はI/O性能に直結します。

| BIOS項目 | 設定値 | なぜこの設定か |
|---|---|---|
| Restore on AC Power Loss (AC Loss Control) | **Power On / Always On** | 停電後の自動復旧。リモート運用の必須設定 |
| Wake on LAN | **Enabled** | ネットワーク越しのリモート起動を可能に |
| Secure Boot | **Disabled** | DKMSドライバ導入時のカーネルアップデートトラブルを防ぐ |
| Fast Boot / Quiet Boot | **Disabled** | 毎回確実なハードウェア初期化のため |
| Global C-state Control | **Disabled** | CPUのディープスリープがバリデータ署名のレイテンシ増加に繋がるため |
| Boot Order | **#1 USB, #2 NVMe** | OSインストール後はNVMeを1番に変更 |

> 💡 **実機で確認したBIOS設定値（Minisforum AI X1）：** ErP: Disabled / Wake Up by RTC: Disabled

---

## Phase 1　VM側の移行前準備

> ⚠️ **この操作で署名が止まります。物理PCでの起動を速やかに完了させ、長時間オフラインを避けてください。**

### Step 1　VMの全サービスを停止（VC→BN→ELの順）

```bash
# 必ずVC（署名役）を最初に止める。署名が止まれば二重署名リスクがゼロになる
sudo systemctl stop lighthouse-vc
sudo systemctl stop lighthouse
sudo systemctl stop geth

# 全て inactive になったことを確認してから次へ進む
sudo systemctl status geth lighthouse lighthouse-vc
```

### Step 2　スラッシング保護データのエクスポート

```bash
# 過去の署名履歴を世界標準JSONで書き出す。これが二重署名防止の生命線
sudo -u ethereum lighthouse account validator slashing-protection export \
  --network hoodi \
  --datadir /var/lib/ethereum/lighthouse \
  /tmp/slashing_protection.json

# 所有者を自分に変更（scpでコピーできるようにする）
sudo chown $USER:$USER /tmp/slashing_protection.json
```

### Step 3　鍵データの転送（VM → ホストPC → 物理PC）

```powershell
# VM → ホストPC（Windows PowerShell）
scp -P 2222 <user>@127.0.0.1:/tmp/slashing_protection.json .
scp -P 2222 -r <user>@127.0.0.1:/var/lib/ethereum/lighthouse/validators/* ./validators/
```

```bash
# ホストPC → 物理PC（Tailscale IP経由）
scp ./slashing_protection.json <user>@<dest_tailscale_ip>:/var/lib/lido-csm/slashing_protection/
scp -r ./validators/* <user>@<dest_tailscale_ip>:/var/lib/lido-csm/validators/
```

> 💡 **なぜTailscale IP経由か：** 公開ネットワークに鍵を晒さないため、必ずTailscale IP（100.x.x.x）を使います。

---

## Phase 2　OS・ネットワーク・要塞化

### Step 4　Ubuntu Server 24.04 クリーンインストール後の初期設定

```bash
# 1. OSの最新化と必須パッケージ
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y chrony curl ufw openssl jq ca-certificates

# 2. 時刻同期（PoSは12秒ごとのスロットで厳格に動くため必須）
sudo systemctl enable --now chrony
chronyc tracking
# → System time の offset が 0.01秒以内であればOK
```

### Step 5　Netplan ネットワーク設定

```bash
sudo vi /etc/netplan/01-netcfg.yaml
```

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp1s0:      # インターフェース名は ip a で確認
      dhcp4: true
```

```bash
# パーミッションを必ず 600 に設定（Netplanのセキュリティ要件）
sudo chmod 600 /etc/netplan/01-netcfg.yaml
sudo netplan apply
```

### Step 6　SSH要塞化

```bash
# SSH公開鍵認証の設定
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# ~/.ssh/authorized_keys にホストPCの公開鍵（ed25519推奨）を貼り付け
chmod 600 ~/.ssh/authorized_keys

# rootのパスワードをロック
sudo passwd -l root
```

```bash
# /etc/ssh/sshd_config を編集
sudo vi /etc/ssh/sshd_config
```

設定すべき項目：

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

```bash
sudo systemctl restart sshd
```

### Step 7　Tailscale VPN のインストール

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# → ブラウザで認証URLを開いてデバイスを承認
```

> 💡 **SSHアクセスはTailscale経由のみに限定します。** これにより、インターネットからのSSH総当たり攻撃を完全に遮断できます。

### Step 8　Fail2Ban の設定

```bash
sudo apt install -y fail2ban
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sudo vi /etc/fail2ban/jail.local
# → [sshd] セクションの enabled = true を確認
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

> 💡 **TailscaleのIPをFail2Banのホワイトリストに追加：**
> `/etc/fail2ban/jail.local` の `[DEFAULT]` セクションに
> `ignoreip = 127.0.0.1/8 100.64.0.0/10` を追加します。
> これで自分のVPNアクセスで誤BANされません。

### Step 9　UFW ファイアウォール設定

```bash
# 既存ルールをリセットしてクリーンな状態から設定
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSHはTailscale経由のみ（外部公開IPからの接続は全て遮断）
sudo ufw allow in on tailscale0 to any port 22 proto tcp

# Geth P2P（実行層）
sudo ufw allow 30303/tcp
sudo ufw allow 30303/udp

# Lighthouse P2P（合意層）
sudo ufw allow 9000/tcp
sudo ufw allow 9000/udp

sudo ufw --force enable
sudo ufw status verbose
```

---

## Phase 3　クライアント構築と鍵移行

### Step 10　サービスユーザーとディレクトリの作成

```bash
# ログイン不可・ホームディレクトリなしの専用ユーザー（セキュリティ）
sudo useradd --no-create-home --shell /bin/false ethereum

# ディレクトリ構成
sudo mkdir -p /var/lib/ethereum/{jwt,geth,lighthouse}
sudo mkdir -p /var/lib/lido-csm/{validators,slashing_protection,secrets}

# JWT認証トークン生成（GethとLighthouseの共通パスワード）
sudo openssl rand -hex 32 | sudo tee /var/lib/ethereum/jwt/jwt.hex > /dev/null

# 権限設定
sudo chown -R ethereum:ethereum /var/lib/ethereum /var/lib/lido-csm
sudo chmod 600 /var/lib/ethereum/jwt/jwt.hex
```

### Step 11　Geth のインストールとサービス化

```bash
sudo add-apt-repository -y ppa:ethereum/ethereum
sudo apt-get update && sudo apt-get install -y geth
geth version
```

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
  --metrics.port 6060 \
  --cache 8192

[Install]
WantedBy=multi-user.target
```

> 💡 **`--cache 8192` について：** ベアメタル環境（RAM 32GB）ではVMの4096から倍増できます。UTXO セットをRAMに乗せることでSSDへのI/Oを激減させ、ブロック検証速度が大幅に向上します。

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now geth
sudo journalctl -u geth -f -o cat
```

### Step 12　Lighthouse のインストールとBeacon Node サービス化

```bash
cd ~
RELEASE_URL=$(curl -s https://api.github.com/repos/sigp/lighthouse/releases/latest \
  | jq -r '.assets[] | select(.name | contains("x86_64-unknown-linux-gnu") and (contains("portable")|not)) | .browser_download_url')
curl -L $RELEASE_URL -o lighthouse.tar.gz && tar -xvf lighthouse.tar.gz
sudo mv lighthouse /usr/local/bin/ && lighthouse --version
```

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
  --metrics-address 127.0.0.1 \
  --metrics-port 5054 \
  --target-peers 80

[Install]
WantedBy=multi-user.target
```

> 📎 **Hoodi チェックポイント同期URL：** [checkpoint-sync.hoodi.ethpandaops.io](https://checkpoint-sync.hoodi.ethpandaops.io)

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now lighthouse
# 同期確認
curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq
```

### Step 13　移行データの権限設定

```bash
# 転送した鍵の所有者をethereumに変更（これをしないとLighthouseが読めない）
sudo chown -R ethereum:ethereum /var/lib/lido-csm/validators
sudo chown -R ethereum:ethereum /var/lib/lido-csm/slashing_protection
sudo chmod -R 700 /var/lib/lido-csm/validators
sudo chmod -R 700 /var/lib/lido-csm/slashing_protection
```

### Step 14　スラッシング保護データのインポート

```bash
# 過去の署名履歴を引き継ぎ、二重署名を防ぐ
sudo -u ethereum lighthouse account validator slashing-protection import \
  --network hoodi \
  --datadir /var/lib/lido-csm \
  /var/lib/lido-csm/slashing_protection/slashing_protection.json
```

### Step 15　Lighthouse VC のサービス化と起動

> ⚠️ **`--suggested-fee-recipient` は必ずLido公式のEL Rewards Vaultアドレスを指定すること。自分のウォレットアドレスを入れると MEV stealing 判定となり、ボンドロック＋罰金ペナルティが科せられます。**

| ネットワーク | fee-recipientに設定するアドレス |
|---|---|
| Hoodi Testnet | `0x9b108015fe433F173696Af3Aa0CF7CDb3E104258` |
| Mainnet（本番） | `0x388C818CA8B9251b393131C08a736A67ccB19297` |

> 📎 **fee-recipient の設定についての公式ドキュメント：** [Setting the fee recipient for CSM validators](https://docs.lido.fi/run-on-lido/csm/troubleshooting/setting-the-fee-recipient-for-csm-validators/)

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
  --metrics \
  --metrics-address 127.0.0.1 \
  --metrics-port 5064 \
  --http \
  --http-address 127.0.0.1 \
  --http-port 5062 \
  --builder-proposals

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now lighthouse-vc
sudo journalctl -u lighthouse-vc -n 20 -o cat
```

> ✅ **`Successfully published attestations` が出れば、物理PCへの移行成功です。**

---

## Phase 4　鍵を10個に増設（無停止スケールアップ）

### 【実録】鍵の生成履歴

| フェーズ | インデックス | 状態 | 備考 |
|---|---|---|---|
| 初期（失敗） | 0, 1 | 破棄 | 初回の試行錯誤。chain名・withdrawal_credentialsのミス |
| 初期（成功） | 2 | 稼働中 (#1) | 初めて正常に動作した1個目 |
| 増設 第1回 | 3, 4 | 稼働中 (#2, #3) | 2個追加して計3個体制 |
| 増設 第2回 | 5 〜 11 | 稼働中 (#4〜#10) | 7個追加して計10個体制 |

> 💡 **失敗インデックス（0, 1）について：** deposit-cliで生成した鍵を使わなかった場合、そのインデックスは「消費済み」として扱われます。次に生成する際は必ず `--validator_start_index` に続きのインデックスを指定します。飛び番になっても技術的に問題はありません。

### Step 16　既存ニーモニックから追加鍵を生成

> 📎 **公式リリースページ：** [ethstaker-deposit-cli releases](https://github.com/eth-educators/ethstaker-deposit-cli/releases)

```bash
./deposit existing-mnemonic \
  --num_validators <追加する個数> \
  --validator_start_index <次のインデックス番号> \
  --chain hoodi \
  --eth1_withdrawal_address <Lido_Withdrawal_Vault_Address> \
  --folder ./validator_keys_additional
```

> 📎 **Withdrawal Vault アドレスの確認：** [Lido Deployed Contracts - Hoodi](https://docs.lido.fi/deployed-contracts/hoodi)

> ⚠️ **追加鍵のパスワードは既存鍵と同じパスワードにしてください。** これで同じパスワードファイルを再利用でき、VCを長時間停止せずにインポートが可能になります。

### Step 17　追加鍵のインポート（/tmp経由）

```bash
# なぜ /tmp 経由か：
# インポートコマンドは ethereum ユーザーとして実行するが、
# /home/<your_user>/ は他ユーザーが通過できない（パーミッション 700 の壁）。
# /tmp は誰でもアクセスできる「中立地帯」なので、権限問題を安全に回避できる。

sudo systemctl stop lighthouse-vc

sudo cp -r ./validator_keys_additional/validator_keys /tmp/keys_import
sudo chown -R ethereum:ethereum /tmp/keys_import

sudo -u ethereum lighthouse account validator import \
  --network hoodi \
  --datadir /var/lib/lido-csm \
  --directory /tmp/keys_import \
  --reuse-password

# 一時ファイルを削除してVCを再起動
sudo rm -rf /tmp/keys_import
sudo systemctl start lighthouse-vc
```

### Step 18　鍵数の確認

```bash
# 全鍵のリスト確認（10個 + enabled 表示）
sudo -u ethereum lighthouse account validator list \
  --network hoodi \
  --datadir /var/lib/lido-csm

# ディレクトリ数で確認（0x始まりのディレクトリのみカウント）
sudo ls -l /var/lib/lido-csm/validators/ | grep 'drwx.*0x' | wc -l
# → 10 と表示されれば成功
```

> ⚠️ **相関ペナルティについて：** 1台のPCに鍵を詰め込みすぎると、そのPCが故障したとき全鍵が同時にオフラインになり「相関ペナルティ」が重くなります。1台運用なら最大10〜20鍵程度が個人のリスク分散として賢明なラインです（本書で10鍵に留めた理由）。

---

## Phase 5　MEV-Boost の導入

### Step 19　MEV-Boostのインストール

```bash
cd ~
# 公式GitHubから最新版をダウンロード
wget https://github.com/flashbots/mev-boost/releases/latest/download/mev-boost_linux_amd64.tar.gz
tar -xvf mev-boost_linux_amd64.tar.gz
sudo mv mev-boost /usr/local/bin/
mev-boost --version
```

```bash
sudo vi /etc/systemd/system/mev-boost.service
```

```ini
[Unit]
Description=mev-boost (Hoodi)
After=network.target

[Service]
User=ethereum
Group=ethereum
Type=simple
Restart=always
RestartSec=5
ExecStart=/usr/local/bin/mev-boost \
  -hoodi \
  -addr 127.0.0.1:18550 \
  -relay-check \
  -relays <relay_url_1>,<relay_url_2>

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now mev-boost
```

### Step 20　Lighthouse BN/VC にMEV-Boost連携を追加

```bash
# lighthouse.service の ExecStart に追記
sudo vi /etc/systemd/system/lighthouse.service
# --builder http://127.0.0.1:18550  ← 追加

# VC側は Step 15 で --builder-proposals 設定済み

sudo systemctl daemon-reload
sudo systemctl restart lighthouse lighthouse-vc
```

> 💡 **MEV-Boostのログ確認：** `POST /eth/v1/builder/validators 200` が出ればリレーへの登録成功です。

---

## Phase 6　Prometheus + Grafana 監視スタック

Prometheusが各クライアントからメトリクスを収集し、Grafanaがグラフ化します。

| 役割 | ソフト | ポート | 内容 |
|---|---|---|---|
| 収集役 | Prometheus | 9090 | 各クライアントから15秒ごとに数値を収集 |
| 可視化役 | Grafana | 3000 | ダッシュボードで可視化 |
| OS監視 | Node Exporter | 9100 | CPU温度・SSD負荷・メモリ等 |

### Step 21　Node Exporter のインストール

```bash
# OS/ハードウェアのメトリクスを9100番ポートで公開
sudo apt install -y prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter
```

### Step 22　Prometheus のインストールと設定

```bash
sudo apt install -y prometheus
sudo cp /etc/prometheus/prometheus.yml /etc/prometheus/prometheus.yml.bak
```

```bash
cat <<EOF | sudo tee /etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'geth'
    metrics_path: /debug/metrics/prometheus
    static_configs:
      - targets: ['localhost:6060']

  - job_name: 'lighthouse_bn'
    static_configs:
      - targets: ['localhost:5054']

  - job_name: 'lighthouse_vc'
    static_configs:
      - targets: ['localhost:5064']
EOF
```

```bash
sudo systemctl restart prometheus && sudo systemctl enable prometheus
```

### Step 23　Grafana のインストール

```bash
sudo apt-get install -y apt-transport-https software-properties-common wget
sudo mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | \
  sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
  sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt-get update && sudo apt-get install -y grafana-enterprise
sudo systemctl enable --now grafana-server

# GrafanaはTailscale経由のみ許可
sudo ufw allow in on tailscale0 to any port 3000 proto tcp
```

> ⚠️ **初期ログインは `admin / admin` です。ログイン後すぐに強力なパスワードへ変更してください。**

### Step 24　自作ダッシュボードの構築

既製のダッシュボードID（1860・13351）はメトリクスの構成が合わない場合があるため、以下のPromQLで自作しました。

#### 自作パネルと PromQL 一覧

**① Attestation Success Rate（署名成功率）**

```promql
rate(vc_signed_attestations_total{status="success"}[5m])
/ rate(vc_signed_attestations_total[5m]) * 100
```

> 💡 単位: percent / Visualization: Stat / 正常値: **100%**。`rate()` で割り算することで、瞬間値ではなく5分間の平均成功率を計算します。

---

**② Network Peers（Geth vs Lighthouse）**

```promql
# Geth
p2p_peers

# Lighthouse
libp2p_peers
```

> 💡 Visualization: Time series / 2つのクエリを重ねてGethとLighthouseのピア数を比較します。

---

**③ CPU Temperature（CPU温度）**

```promql
max(node_hwmon_temp_celsius)
```

> 💡 単位: celsius / Visualization: Gauge / 正常値: **〜50°C**（ベアメタル稼働時の実測値: 44.9°C）

---

**④ Samsung 990 PRO Write Load（SSD書き込み負荷）**

```promql
rate(node_disk_written_bytes_total{device="nvme0n1"}[5m])
```

> 💡 単位: bytes/sec (bps) / Visualization: Time series / 通常: 2〜5 Mb/s、ピーク時: 〜15 Mb/s

---

**⑤ MEV-Boost Registrations（MEV登録バリデータ数）**

```promql
builder_validator_registrations_total{status="success"}
```

> 💡 Visualization: Stat / 正常値: **バリデータ数（10）と一致すること**。10鍵運用なら `10` と表示されます。

---

## Phase 7　sudo不要化の設計と自作スクリプト

### 設計の背景

`node_check.sh` を一般ユーザーで実行した際、いくつかのコマンドが `sudo` を要求して止まってしまいました。セキュリティを維持しつつ `sudo` 不要で動かすために、以下の2つの工夫を施しました。

### Step 25　ACLによるディレクトリ権限の付与

バリデータ鍵のディレクトリ（`/var/lib/lido-csm/validators/`）は `ethereum` ユーザーが所有しており、一般ユーザーは `ls` すら実行できません。`setfacl` でピンポイントに読み取り・通過権限を付与します。

```bash
# <your_user> に対して validators/ ディレクトリの
# 「読み取り(r)」と「通過(x)」権限だけを付与
sudo setfacl -m u:<your_user>:rx /var/lib/lido-csm/validators/

# 設定確認
getfacl /var/lib/lido-csm/validators/
# → user:<your_user>:r-x と表示されれば成功
```

> 💡 **`chmod 777` との違い：** `chmod` は「全員に権限を与える」のに対し、`setfacl` は「特定のユーザーにだけ」ピンポイントに付与できます。ethereum ユーザーの厳格な保護を維持したまま、監視スクリプトだけが参照できる状態を実現しています。

### Step 26　visudo による NOPASSWD 設定

`fail2ban-client status` と `systemctl stop` は root 権限が必要です。スクリプト実行時にパスワードプロンプトが出ないよう、visudo で特定コマンドのみ NOPASSWD を設定します。

```bash
sudo visudo -f /etc/sudoers.d/node-ops
```

```
# node_check.sh 用：fail2ban の状態確認のみ sudo 不要
<your_user> ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client status sshd

# node_safe_stop.sh 用：サービス停止のみ sudo 不要
<your_user> ALL=(ALL) NOPASSWD: /bin/systemctl stop geth
<your_user> ALL=(ALL) NOPASSWD: /bin/systemctl stop lighthouse
<your_user> ALL=(ALL) NOPASSWD: /bin/systemctl stop lighthouse-vc
<your_user> ALL=(ALL) NOPASSWD: /bin/systemctl stop mev-boost
```

> ⚠️ **`NOPASSWD: ALL` は絶対に設定しないでください。** コマンドを1行ずつ列挙することで、万が一の不正侵入時の被害を最小限に抑えます。

### Step 27　node_check.sh の作成

```bash
vi ~/node_check.sh   # 下記内容を貼り付け
chmod +x ~/node_check.sh
echo "alias node_check='~/node_check.sh'" >> ~/.bashrc && source ~/.bashrc
```

```bash
#!/bin/bash

# 色の定義
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}   Ethereum Node Health Check (Hoodi Bare-metal)    ${NC}"
echo -e "${CYAN}   Lido CSM Operator #XXX | SSV Operator #XXX       ${NC}"
echo -e "${CYAN}====================================================${NC}"
TZ="Asia/Tokyo" date "+%Y-%m-%d %H:%M:%S (JST)"

# [1] サービスの稼働状況（systemctl is-active は sudo 不要）
echo -e "\n${YELLOW}[1] System Services Status${NC}"
for svc in geth lighthouse mev-boost lighthouse-vc; do
    STATUS=$(systemctl is-active $svc)
    if [ "$STATUS" = "active" ]; then
        echo -e " - $svc: ${GREEN}$STATUS${NC}"
    else
        echo -e " - $svc: ${RED}$STATUS${NC}"
    fi
done

# [2] リソース
echo -e "\n${YELLOW}[2] Resource Usage${NC}"
df -h / | awk 'NR==1 || NR==2'
echo ""
free -h

# [3] 同期ステータス
echo -e "\n${YELLOW}[3] Sync Status${NC}"
SYNC_INFO=$(curl -m 5 -s http://127.0.0.1:5052/eth/v1/node/syncing 2>/dev/null)
if [ -n "$SYNC_INFO" ]; then
    IS_SYNCING=$(echo $SYNC_INFO | jq -r '.data.is_syncing')
    SYNC_DISTANCE=$(echo $SYNC_INFO | jq -r '.data.sync_distance')
    [ "$IS_SYNCING" = "false" ] && SYNC_STATUS="${GREEN}$IS_SYNCING${NC}" || SYNC_STATUS="${RED}$IS_SYNCING${NC}"
    echo -e " - is_syncing:    $SYNC_STATUS"
    echo " - sync_distance: $SYNC_DISTANCE"
else
    echo -e "${RED}Error: Cannot connect to BN API.${NC}"
fi

# [4] ピア数
echo -e "\n${YELLOW}[4] Peer Count${NC}"
LH_PEERS=$(curl -m 5 -s http://127.0.0.1:5052/eth/v1/node/peer_count | jq -r '.data.connected' 2>/dev/null)
GETH_HEX=$(curl -m 5 -s -H "Content-Type: application/json" -X POST \
  --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
  http://127.0.0.1:8545 | jq -r '.result' 2>/dev/null)
if [[ "$GETH_HEX" == 0x* ]]; then
    GETH_PEERS=$(printf "%d" "$GETH_HEX" 2>/dev/null)
else
    GETH_PEERS="Error"
fi
echo " - Lighthouse Peers: ${LH_PEERS:-Error}"
echo " - Geth Peers:       ${GETH_PEERS:-Error}"

# [5] 直近の署名活動
echo -e "\n${YELLOW}[5] Recent Attestations (Last 3)${NC}"
journalctl -u lighthouse-vc --no-pager -n 100 | \
  grep "Successfully published attestations" | tail -n 3

# [6] MEV-Boost
echo -e "\n${YELLOW}[6] MEV-Boost Status${NC}"
MEV_STATUS=$(curl -m 5 -s http://127.0.0.1:18550/eth/v1/builder/status)
if [ "$MEV_STATUS" = "{}" ] || [ -n "$MEV_STATUS" ]; then
    echo -e " - Builder API: ${GREEN}Online${NC}"
else
    echo -e " - Builder API: ${RED}Offline${NC}"
fi

# [7] Validator Status & Balance
# ACL（setfacl）で権限付与済みのため、sudo なしでディレクトリ名を読み取れる
echo -e "\n${YELLOW}[7] Validator Status & Balance${NC}"
PUBKEYS=$(ls -1 /var/lib/lido-csm/validators/ 2>/dev/null | grep "^0x" | paste -sd "," -)
if [ -z "$PUBKEYS" ]; then
    echo -e "${RED}Error: Cannot read validator directories.${NC}"
    echo -e "${YELLOW}Hint: Run 'sudo setfacl -m u:$(whoami):rx /var/lib/lido-csm/validators/'${NC}"
else
    BN_DATA=$(curl -m 5 -s \
      "http://127.0.0.1:5052/eth/v1/beacon/states/head/validators?id=$PUBKEYS")
    if [ -n "$BN_DATA" ] && [ "$(echo "$BN_DATA" | jq -e '.data' 2>/dev/null)" != "null" ]; then
        echo "PUBKEY (SHORT)  | STATUS           | BALANCE"
        echo "------------------------------------------------------"
        echo "$BN_DATA" | jq -r \
          '.data[] | "\(.validator.pubkey[0:10]) \(.status) \((.balance | tonumber) / 1000000000)"' \
          | while read pk st bal; do
            if [[ "$st" == *"active"* ]]; then
                printf "${CYAN}%-16s${NC} | ${GREEN}%-16s${NC} | %.4f ETH\n" "${pk}..." "$st" "$bal"
            elif [[ "$st" == *"pending"* ]]; then
                printf "${CYAN}%-16s${NC} | ${YELLOW}%-16s${NC} | %.4f ETH\n" "${pk}..." "$st" "$bal"
            else
                printf "${CYAN}%-16s${NC} | %-16s | %.4f ETH\n" "${pk}..." "$st" "$bal"
            fi
        done
    else
        echo -e "${RED}Error: Cannot fetch data from Beacon Node.${NC}"
    fi
fi

# [8] 時刻同期
echo -e "\n${YELLOW}[8] Time Synchronization Status${NC}"
CHRONY_TRACKING=$(chronyc tracking)
OFFSET=$(echo "$CHRONY_TRACKING" | grep "Last offset" | awk '{printf "%.6f", $4}')
REF_ID=$(echo "$CHRONY_TRACKING" | grep "Reference ID" | awk '{print $4 " (" $5 ")"}')
IS_OK=$(echo "$OFFSET" | awk '{if ($1 < 0.01 && $1 > -0.01) print "true"; else print "false"}')
if [ "$IS_OK" = "true" ]; then
    echo -e " - Status      : ${GREEN}Synchronized${NC}"
    echo -e " - Last Offset : ${GREEN}${OFFSET}s${NC} (Ideal: < 0.01s)"
else
    echo -e " - Status      : ${RED}Large Offset Warning!${NC}"
    echo -e " - Last Offset : ${RED}${OFFSET}s${NC}"
fi
echo -e " - Reference ID: $REF_ID"

# [9] セキュリティ
# fail2ban-client は visudo で NOPASSWD 設定済みのため sudo が通る
echo -e "\n${YELLOW}[9] Security & Remote Access${NC}"
F2B=$(sudo fail2ban-client status sshd | grep "Currently banned" | awk '{print $4}')
echo -e " - fail2ban  : ${GREEN}active${NC} (Banned: ${F2B:-0})"
echo -e " - Tailscale : ${GREEN}online${NC}"

# [10] ネットワーク通信量
echo -e "\n${YELLOW}[10] Network Usage (rx:Down / tx:Up / total)${NC}"
if command -v vnstat >/dev/null 2>&1; then
    IFACE="enp1s0"
    vnstat -i $IFACE | grep "yesterday" | awk '{
        printf " - Yesterday : ↓ %-8s | ↑ %-8s | Total: %-8s\n", $2" "$3, $5" "$6, $8" "$9
    }'
    T_DATA=$(vnstat -i $IFACE | grep "today")
    T_RX=$(echo "$T_DATA" | awk '{print $2" "$3}')
    T_TX=$(echo "$T_DATA" | awk '{print $5" "$6}')
    T_TOT=$(echo "$T_DATA" | awk '{print $8" "$9}')
    T_EST=$(vnstat -i $IFACE -d | grep "estimated" | awk '{print $8" "$9}')
    printf " - Today     : ↓ %-8s | ↑ %-8s | Total: %-8s (Est: %-8s)\n" \
      "$T_RX" "$T_TX" "$T_TOT" "$T_EST"
else
    echo -e "${RED} - vnstat is not installed. Run: sudo apt install vnstat${NC}"
fi

# [11] OSアップデート・再起動要否
echo -e "\n${YELLOW}[11] OS Update & Restart Status${NC}"
if [ -f /var/run/reboot-required ]; then
    echo -e " - Restart Required : ${RED}YES${NC}"
    echo -e "   → Run: ./node_safe_stop.sh && sudo reboot"
else
    echo -e " - Restart Required : ${GREEN}NO${NC}"
fi
UPDATE_INFO=$(/usr/lib/update-notifier/apt-check --human-readable 2>&1)
if echo "$UPDATE_INFO" | grep -q "0 packages can be updated"; then
    echo -e " - Pending Updates  : ${GREEN}0 updates${NC}"
else
    echo -e " - Pending Updates  : ${YELLOW}Updates Available!${NC}"
    echo "$UPDATE_INFO" | sed 's/^/    /'
fi

# [12] SSV Node（第3部で追加）
echo -e "\n${YELLOW}[12] SSV Node (DVT) Status${NC}"
if command -v docker >/dev/null 2>&1 && \
   docker ps -a --format '{{.Names}}' | grep -q "^ssv-node$"; then
    SSV_STATUS=$(docker inspect -f '{{.State.Status}}' ssv-node 2>/dev/null)
    if [ "$SSV_STATUS" == "running" ]; then
        echo -e " - Container : ${GREEN}active (running)${NC}"
        SSV_PEERS=$(curl -m 3 -s http://127.0.0.1:15000/metrics \
          | grep '^ssv_p2p_peers_connected' | awk '{print $2}')
        echo -e " - P2P Peers : ${CYAN}${SSV_PEERS:-Error}${NC}"
        SSV_SLOT=$(docker logs ssv-node --tail 100 2>&1 \
          | grep "DutyScheduler" | grep "received head event" | tail -n 1 \
          | awk -F'"slot": ' '{print $2}' | awk -F',' '{print $1}')
        echo -e " - Sync Slot : ${GREEN}${SSV_SLOT:-Waiting...}${NC}"
    else
        echo -e " - Container : ${RED}${SSV_STATUS}${NC}"
    fi
else
    echo -e " - Container : ${YELLOW}Not installed${NC}"
fi

echo -e "\n${CYAN}====================================================${NC}"
```

### Step 28　node_safe_stop.sh の作成

```bash
vi ~/node_safe_stop.sh   # 下記内容を貼り付け
chmod +x ~/node_safe_stop.sh
```

```bash
#!/bin/bash

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}Starting Safe Shutdown Sequence for Ethereum Node...${NC}"

# 1. 署名役（VC）を真っ先に停止
# 【Why】署名を止めることが最優先。これが止まれば二重署名リスクはゼロ
echo -e "\n1. Stopping Validator Client (lighthouse-vc)..."
sudo systemctl stop lighthouse-vc
sleep 2

# 2. 同期役と収益機能を停止
echo -e "2. Stopping Beacon Node and MEV-Boost..."
sudo systemctl stop lighthouse
sudo systemctl stop mev-boost

# 3. 実行層（Geth）を最後に停止
# 【Why】GethはメモリのデータをSSDに書き出す（Flush）のに時間がかかる
# 他を止めてから最後にGethを止めることでDB破損のリスクを最小化する
echo -e "3. Stopping Execution Client (Geth)..."
sudo systemctl stop geth

# 4. 全サービスの完全停止を確認
echo -e "\n${YELLOW}[Verification] Check Service Status:${NC}"
for svc in lighthouse-vc lighthouse mev-boost geth; do
    STATUS=$(systemctl is-active $svc)
    if [ "$STATUS" = "inactive" ]; then
        echo -e " - $svc: ${GREEN}$STATUS (Safe)${NC}"
    else
        echo -e " - $svc: ${RED}$STATUS (Warning: Still active!)${NC}"
        EXIT_CODE=1
    fi
done

if [ "$EXIT_CODE" = "1" ]; then
    echo -e "\n${RED}Error: Some services failed to stop. Do NOT reboot yet!${NC}"
    exit 1
else
    echo -e "\n${GREEN}All services stopped safely. You can now reboot or power off.${NC}"
    echo -e "To reboot, run: ${YELLOW}sudo reboot${NC}"
fi
```

> ⚠️ **再起動・電源オフの前は必ずこのスクリプトを実行し、全サービスが `inactive` になったことを確認してから `sudo reboot` してください。いきなり再起動するとGethのDBが破損する恐れがあります。**

---

## 運用の心得とまとめ

### ネットワーク通信量の管理

Ethereumノードは継続的に通信します。vnstatで日次・月次の通信量を把握することが重要です。

```bash
sudo apt install -y vnstat
vnstat -d   # 日次表示（1日後から利用可能）
vnstat -m   # 月次表示
```

**目安（10バリデータ / ピア数80〜200前後）：**

| 期間 | 通信量目安 |
|---|---|
| 日次 | 30〜80 GB |
| 月次 | 1〜2.5 TB |

通信量が多すぎる場合はLighthouseの `--target-peers` を下げることで調整できます（50でも報酬に影響なし）。

### ディスク容量の管理

| 使用率 | 判断 | 対処 |
|---|---|---|
| 〜70% | 正常 | 放置でOK |
| 70〜85% | 検討開始 | Gethのプルーニング計画 |
| 85%〜 | 危険 | 早急に `geth snapshot prune` を実施 |

> 💡 GethのデータはSSD容量の大半を占めます（週10〜15GBペースで増加）。Lighthouseは自動で古いデータを整理するため、主に監視すべきはGethです。2TB SSDなら数ヶ月〜1年は余裕があります。

### バックアップすべき「命のデータ」

| 対象 | パス | 理由 |
|---|---|---|
| バリデータ鍵 | `/var/lib/lido-csm/validators/` | 失うと運用不能 |
| スラッシング保護DB | `/var/lib/lido-csm/slashing_protection/` | 二重署名防止の生命線 |
| Systemd設定 | `/etc/systemd/system/*.service` | 復旧の高速化 |

> 💡 GethやLighthouseの数百GBのブロックチェーンデータはバックアップ不要です。再同期すれば済みます。バックアップするのは少量の「鍵と設定」だけです。

---

> ✅ **第2部ゴール達成：** VMの鍵を物理PCへ安全移行し、10鍵に増設、Prometheus + Grafana自作ダッシュボード + 自作スクリプトで「長期安定運用」の基盤が完成しました。次は第3部で、このサーバーの余力を使ってSSVノードも兼業します。
