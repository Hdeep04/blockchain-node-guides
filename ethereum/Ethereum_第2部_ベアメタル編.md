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
| Phase 1 | 物理PCのOS・ネットワーク・要塞化（SSH/Tailscale/Fail2Ban） | ★★ |
| Phase 2 | VMのサービス停止 + スラッシング保護データのエクスポート | ★★★ |
| Phase 3 | Geth/Lighthouse構築 + 鍵移行 + VC起動 | ★★★ |
| Phase 4 | 鍵を10個に増設（無停止スケールアップ） | ★★ |
| Phase 5 | MEV-Boost導入 | ★ |
| Phase 6 | Prometheus + Grafana 監視スタック構築 | ★★ |
| Phase 7 | sudo不要化の設計と自作スクリプトによる日常運用 | ★★ |

> ⚠️ **Phase 2のスラッシング保護データ移行を省略すると、新旧両環境で二重署名が起き「一発退場（スラッシング）」になります。最優先で正しく行ってください。**

---

## 第2部を読み進める前に

### sudo とは何か

`sudo` = **Super User DO** の略。管理者（root）権限でコマンドを実行するための指示です。

| コマンド | 実行者 | できること |
|---|---|---|
| `ls /var/lib/` | 一般ユーザー | 参照のみ |
| `sudo ls /var/lib/` | root として実行 | 参照・変更・削除すべて可能 |

例え：「ビルの入館証」のようなものです。通常は1階のみ入れますが、`sudo` を付けると全フロアのドアが開きます。だからこそ **必要な場面だけに絞って使う** ことが重要です。

`/var/lib/` 配下のファイルやSystemdサービスの操作はroot権限が必要なため、本書のコマンドに `sudo` が頻繁に登場します。

### vi エディタの基本操作

本書では設定ファイルの編集に `vi` を使います。以下の操作を覚えておけば困りません。

| キー操作 | 意味 |
|---|---|
| `i` | 入力モード開始（文字を打てる状態にする） |
| `Esc` | 入力モード終了 |
| `:wq` | 保存して終了（write + quit） |
| `:q!` | 保存せず強制終了（変更を破棄） |
| 矢印キー | カーソル移動 |

viに不慣れな場合は `nano` エディタも使用できます：
- 起動: `sudo nano /path/to/file`
- 保存: `Ctrl + O` → Enter
- 終了: `Ctrl + X`

### 第2部がなぜ本番なのか

第1部（VM環境）と第2部（ベアメタル）の根本的な違いを図で示します。

```
【第1部：VM環境】

Windows OS（ホスト）
├─ CPU / RAM / SSD（物理ハードウェア）
└─ VirtualBox（仮想化レイヤー）← ここにオーバーヘッドが発生
   └─ Ubuntu VM
      └─ Geth + Lighthouse
              ↓
      SSD アクセスが仮想化レイヤーを経由するため遅い
      ブロック検証が追いつかず → 署名失敗（BeaconScore 90.31%）

【第2部：ベアメタル環境】

Ubuntu OS（ベアメタル）← OS がハードウェアに直接乗る
├─ CPU / RAM / SSD（物理ハードウェア）← 直接アクセス
└─ Geth + Lighthouse
              ↓
      SSD へ直接アクセスで高速
      ブロック検証が安定 → 署名成功率向上（BeaconScore 97.39%）
```

> 💡 **「ベアメタル」とは：** 仮想化ソフトウェアを挟まず、OS をハードウェアに直接インストールした状態のことです。第2部ではこの構成で運用します。

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

## Phase 1　OS・ネットワーク・要塞化

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

> 💡 **viエディタの基本操作：** `i` で入力モード開始 → 編集 → `Esc` → `:wq` で保存終了。viが苦手な場合は `sudo nano /etc/netplan/01-netcfg.yaml`（Ctrl+O 保存・Ctrl+X 終了）でも可。

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
# 600 = 所有者（root）だけ読み書き可能。グループ・他ユーザーはアクセス不可
sudo chmod 600 /etc/netplan/01-netcfg.yaml
sudo netplan apply
```

### Step 6　SSH要塞化

```bash
# SSH公開鍵認証の設定
mkdir -p ~/.ssh && chmod 700 ~/.ssh   # 700: 自分だけ読み書き実行可能（SSHはこれより広い権限だと接続を拒否する）
# ~/.ssh/authorized_keys にホストPCの公開鍵（ed25519推奨）を貼り付け
chmod 600 ~/.ssh/authorized_keys   # 600: 自分だけ読み書き可能

# rootのパスワードをロック
sudo passwd -l root
```

```bash
# /etc/ssh/sshd_config を編集
sudo vi /etc/ssh/sshd_config
```

> 💡 **viエディタの基本操作：** `i` で入力モード開始 → 編集 → `Esc` → `:wq` で保存終了。viが苦手な場合は `sudo nano /etc/ssh/sshd_config` でも可。

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

**Tailscaleとは：**
各デバイスに `100.x.x.x` の仮想IPを割り当て、インターネット上の第三者からは見えないプライベートな通路を作るVPNです。これを使うことでSSHを完全に外部から隠すことができます。

**なぜSSHをTailscale経由に限定するか：**
外部IPでSSHを公開すると、世界中からブルートフォース（総当たり）攻撃を受けます。`tailscale0` インターフェース経由のみに制限することで、認証済みデバイスからしか接続できなくなります。

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# → ブラウザで認証URLを開いてデバイスを承認する
# → 認証後、ip addr show tailscale0 で 100.x.x.x のIPが割り当てられれば成功
```

> 💡 **このTailscale設定が完了して初めて、Phase 2のVMからの安全な鍵転送が可能になります。**

### Step 8　Fail2Ban の設定

**Fail2Banとは：**
ログを監視して不正ログイン試行を検知し、一定回数失敗したIPを自動的にブロックするツールです。Tailscaleで外部を遮断しつつ、万が一の侵入試行に対する第2の防衛線として機能します。

```bash
# fail2banをインストールして設定ファイルを複製する
sudo apt install -y fail2ban
# jail.confはパッケージ更新で上書きされる可能性がある
# jail.localはユーザー設定専用ファイルで更新後も設定が保持される
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
```

```bash
# 設定ファイルを編集する
sudo vi /etc/fail2ban/jail.local
```

> 💡 **viエディタの基本操作：** `i` で入力モード開始 → 編集 → `Esc` → `:wq` で保存終了。viが苦手な場合は `sudo nano /etc/fail2ban/jail.local` でも可。
> `[sshd]` セクションを探し `enabled = true` になっていることを確認します。

```bash
# fail2banを有効化して起動・動作確認する
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

> 💡 **TailscaleのIPをFail2Banのホワイトリストに追加：**
> `/etc/fail2ban/jail.local` の `[DEFAULT]` セクションに
> `ignoreip = 127.0.0.1/8 100.64.0.0/10` を追加します。
> `100.64.0.0/10` はTailscaleのIPレンジです。これを設定することで
> 自分のTailscaleアクセスで誤BANされることを防ぎます。

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

> ✅ **これで新PCの「箱」が完成しました。**
> TailscaleによるVPN経路が確立し、SSH要塞化・Fail2Ban・UFWによる多層防御が整いました。
> 次のPhase 2でVMから安全に鍵転送が可能になります。

---

## Phase 2　VM側の移行前準備

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

> 💡 **`--datadir` のパスについて：**
> スラッシング保護データはLighthouse Beacon Node（`/var/lib/ethereum/lighthouse`）に保存されます。
> バリデータ鍵（`/var/lib/lido-csm`）とは保存場所が異なります。
> - `/var/lib/ethereum/lighthouse` → BNのデータ（スラッシング保護DB・同期データ）
> - `/var/lib/lido-csm` → バリデータ鍵・VCのデータ
>
> 第1部でLido CSM用にインポートした際の `--datadir /var/lib/lido-csm` と
> 混同しやすいポイントです。エクスポートは必ず `/var/lib/ethereum/lighthouse` で行ってください。

### Step 3　鍵データの転送（VM → ホストPC → 物理PC）

> ⚠️ **Phase 1でTailscaleの設定が完了していることを確認してから実施してください。**
> Tailscale IP（100.x.x.x）が割り当てられていない場合、鍵転送が完了しません。

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
# chown: ディレクトリの所有者をethereum専用ユーザーに変更する（-R は再帰的に全サブディレクトリへ適用）
sudo chown -R ethereum:ethereum /var/lib/ethereum /var/lib/lido-csm
# chmod 600: 所有者（ethereum）だけが読み書きできる（6=読4+書2）。他ユーザーはアクセス不可
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

> 💡 **viエディタの基本操作：** `i` で入力モード開始 → 編集 → `Esc` → `:wq` で保存終了。viが苦手な場合は `sudo nano /etc/systemd/system/geth.service` でも可。

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
  --authrpc.vhosts localhost \
  --authrpc.jwtsecret /var/lib/ethereum/jwt/jwt.hex \
  --http \
  --http.addr 127.0.0.1 \
  --http.api eth,net,engine,admin \
  --ws \
  --ws.addr 127.0.0.1 \
  --ws.port 8546 \
  --ws.api eth,net,engine,admin \
  --metrics \
  --metrics.addr 127.0.0.1

[Install]
WantedBy=multi-user.target
```

> 💡 **サービス設定の各項目について：**
> - `User=ethereum` / `Group=ethereum` : 専用の非特権ユーザーで実行します。rootで動かすよりも、万が一の侵害時の被害を最小限に抑えられます。
> - `Restart=always` : プロセスが何らかの理由で終了した場合、自動的に再起動します。ノードがクラッシュしてもサービスが自力で復帰します。
> - `RestartSec=5` : 再起動前に5秒待ちます。即座に再起動するとエラーループに陥るリスクがあるためバッファを設けています。
> - `--hoodi` : Hoodi テストネットに接続します。
> - `--datadir` : ブロックチェーンデータの保存先を指定します。
> - `--authrpc.*` : LighthouseとのEngine API通信の設定です（JWT認証）。
> - `--http` / `--http.addr` / `--http.api` : JSON-RPC APIを有効にします（同期状態確認などに使用）。
> - `--ws` / `--ws.addr` / `--ws.port 8546` / `--ws.api` : WebSocket APIを有効化します。JSON-RPCのHTTPに加え、WebSocketによるリアルタイム通信を可能にします。
> - `--metrics` / `--metrics.addr` : Prometheusがメトリクスを収集するためのエンドポイントを有効にします。

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

> 💡 **viエディタの基本操作：** `i` で入力モード開始 → 編集 → `Esc` → `:wq` で保存終了。viが苦手な場合は `sudo nano /etc/systemd/system/lighthouse.service` でも可。

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
ExecStart=/usr/local/bin/lighthouse beacon_node \
  --network hoodi \
  --datadir /var/lib/ethereum/lighthouse \
  --execution-endpoint http://127.0.0.1:8551 \
  --execution-jwt /var/lib/ethereum/jwt/jwt.hex \
  --checkpoint-sync-url https://checkpoint-sync.hoodi.ethpandaops.io \
  --builder http://127.0.0.1:18550 \
  --http \
  --http-address 127.0.0.1 \
  --metrics

[Install]
WantedBy=multi-user.target
```

> 💡 **サービス設定の各項目について：**
> - `User=ethereum` / `Group=ethereum` : 専用の非特権ユーザーで実行します。
> - `Restart=always` / `RestartSec=5` : クラッシュ時に5秒後自動再起動します。
> - `--network hoodi` : Hoodi テストネットに接続します。
> - `--execution-endpoint` : GethのEngine APIエンドポイントを指定します（JWT認証で通信）。
> - `--checkpoint-sync-url` : ethpandaops（Ethereum Foundation公式チーム）が提供するチェックポイント同期URLです。初回起動時に数日かかる同期を数分で完了できます。
> - `--builder http://127.0.0.1:18550` : MEV-Boostとの連携エンドポイントを指定します（Phase 5で起動するMEV-Boostに接続）。
> - `--http` / `--http-address` : Validator ClientからBNに接続するためのAPIを有効にします。
> - `--metrics` : Prometheusがメトリクスを収集するためのエンドポイントを有効にします。

> 📎 **Hoodi チェックポイント同期URL：** [checkpoint-sync.hoodi.ethpandaops.io](https://checkpoint-sync.hoodi.ethpandaops.io)

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now lighthouse
# 同期確認
curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq
```

### Step 13　移行データの権限設定

```bash
# 転送した鍵の所有者をethereumに変更（これをしないとLighthouseが読めない）
# chown -R: ディレクトリとその中のファイル全ての所有者を再帰的に変更する
sudo chown -R ethereum:ethereum /var/lib/lido-csm/validators
sudo chown -R ethereum:ethereum /var/lib/lido-csm/slashing_protection
# chmod 700: 所有者（ethereum）だけが読み書き実行できる（7=読4+書2+実行1）。他ユーザーはアクセス不可
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

> 💡 **viエディタの基本操作：** `i` で入力モード開始 → 編集 → `Esc` → `:wq` で保存終了。viが苦手な場合は `sudo nano /etc/systemd/system/lighthouse-vc.service` でも可。

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
  --secrets-dir /var/lib/lido-csm/secrets \
  --builder-proposals \
  --metrics \
  --metrics-address 127.0.0.1 \
  --metrics-port 5064 \
  --http \
  --unencrypted-http-transport \
  --http-address 127.0.0.1 \
  --http-port 5062

[Install]
WantedBy=multi-user.target
```

> 💡 **サービス設定の各項目について：**
> - `User=ethereum` / `Group=ethereum` : 専用の非特権ユーザーで実行します。バリデータ鍵を扱うため特に権限の最小化が重要です。
> - `Restart=always` / `RestartSec=5` : クラッシュ時に5秒後自動再起動します。
> - `--beacon-nodes` : Beacon Nodeのエンドポイントを指定します（VCはBN経由でELと通信するためこれだけでOK）。
> - `--suggested-fee-recipient` : ブロック提案時の手数料の送り先です。必ずLido公式のEL Rewards Vaultアドレスを指定します（自分のウォレットを指定するとMEV stealing判定でペナルティ）。
> - `--metrics` / `--metrics-address` / `--metrics-port 5064` : Prometheusメトリクス収集エンドポイントです。
> - `--secrets-dir /var/lib/lido-csm/secrets` : バリデータキーストアのパスワードファイルが格納されているディレクトリを指定します。
> - `--builder-proposals` : MEV-Boost経由のブロック提案を有効にします。
> - `--http` / `--unencrypted-http-transport` / `--http-address` / `--http-port 5062` : node_check.sh がバリデータ状態をAPIで取得するために使用します（ローカルのみのためHTTPで可）。

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

> 📎 **公式リリースページ：** [ethstaker-deposit-cli releases](https://github.com/ethstaker/ethstaker-deposit-cli/releases)

```bash
# 作業ディレクトリの作成
mkdir -p ~/csm-artifacts
cd ~/csm-artifacts

# 最新バージョンのダウンロードURLを自動取得
RELEASE_URL=$(curl -s https://api.github.com/repos/ethstaker/ethstaker-deposit-cli/releases/latest \
  | jq -r '.assets[] | select(.name | contains("linux-amd64")) | .browser_download_url')
wget $RELEASE_URL -O ethstaker_deposit-cli-linux-amd64.tar.gz

# 解凍（ファイル名が変わっても動作する）
tar -xvf ethstaker_deposit-cli-*-linux-amd64.tar.gz
cd ethstaker_deposit-cli-*-linux-amd64
```

```bash
./deposit existing-mnemonic \
  --num_validators <追加する個数> \
  --validator_start_index <次のインデックス番号> \
  --chain hoodi \
  --eth1_withdrawal_address 0x4473dCDDbf77679A643BdB654dbd86D67F8d32f2 \
  --folder ./validator_keys_additional
```

> | ネットワーク | Withdrawal Vault アドレス（proxy）|
> |---|---|
> | Hoodi Testnet | `0x4473dCDDbf77679A643BdB654dbd86D67F8d32f2` |
> | Mainnet（本番） | `0xB9D7934878B5FB9610B3fE8A5e441e8fad7E293f` |
>
> 📎 公式確認先: https://docs.lido.fi/deployed-contracts/hoodi
>
> ⚠️ 必ず **`proxy`** アドレスを使用すること。`impl`（実装アドレス）は内部処理用のため使用しない。

> ⚠️ **追加鍵のパスワードは既存鍵と同じパスワードにしてください。** これで同じパスワードファイルを再利用でき、VCを長時間停止せずにインポートが可能になります。

### Step 17　追加鍵のインポート（/tmp経由）

#### なぜ /tmp 経由でインポートするのか

```
ホームディレクトリの「700の壁」と /tmp 経由の設計思想：

┌─────────────────────────────────────────────────────────────┐
│                    問題：直接インポートできない理由              │
│                                                              │
│  /home/<your_user>/              ← パーミッション 700         │
│  ├── validator_keys/             ← <your_user> が所有        │
│  │                                                           │
│  ethereum ユーザー ──────────────────────────────────────── X │
│               ↑                                              │
│  lighthouse account validator import は                      │
│  ethereum ユーザーとして実行する必要がある                      │
│  しかし /home/<your_user>/ は他ユーザーが通過できない（700の壁）│
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    解決策：/tmp を中立地帯として使う             │
│                                                              │
│  /tmp/keys_import/               ← パーミッション 777（誰でも）│
│  ├── <your_user>   ────→ cp ────→ /tmp/keys_import/  ✅     │
│  └── ethereum ユーザー ──→ read ─→ /tmp/keys_import/  ✅     │
│                                                              │
│  /tmp は全ユーザーがアクセスできる「中立地帯」                   │
│  1. sudo cp で鍵を /tmp にコピー                               │
│  2. sudo chown で ethereum に所有権を渡す                      │
│  3. ethereum として lighthouse import を実行                   │
│  4. sudo rm -rf で /tmp の機密データを即座に削除（必須）         │
└─────────────────────────────────────────────────────────────┘
```

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

### MEV-Boost とは何か

#### 概念

通常のブロック提案（あなたのバリデータが「今回のブロックを作る担当」に選ばれた瞬間）では、
Lighthouseが自分でブロックを組み立てて提案します。

MEV-Boostを導入すると、外部の「ブロックビルダー」と呼ばれる専門業者が
より収益性の高いブロックを事前に組み立てて入札してきます。
あなたのバリデータはその中から最も報酬が高いブロックを選んで提案します。

```
MEV-Boostなし：
バリデータ → 自分でブロックを組み立てる → 提案
（普通の報酬）

MEV-Boost あり：
バリデータ → リレー業者A・B・Cが組み立てたブロックを受け取る
          → 最も報酬が高いものを選ぶ → 提案
（より高い報酬）
```

#### 登場人物の役割

| 名称 | 役割 |
|---|---|
| バリデータ（あなた） | ブロック提案の担当者。最も高い入札を選ぶ |
| リレー | ビルダーとバリデータの仲介者。信頼できる業者を選ぶことが重要 |
| ブロックビルダー | MEVを最大化したブロックを組み立てる専門業者 |
| MEV-Boost | 上記の仕組みを動かすソフトウェア（flashbots製） |

#### Lido CSMでの注意点

> ⚠️ **`--suggested-fee-recipient` は必ずLido公式のEL Rewards Vaultアドレスを指定すること。**
> MEV-Boost経由のブロック提案でも同様です。
> 自分のウォレットアドレスを指定すると「MEV stealing」と判定され
> ボンドロック＋罰金ペナルティが科せられます。

#### MEV-Boostを入れると報酬はどう変わるか

通常のアテステーション報酬に加え、ブロック提案時（数週間〜数ヶ月に1回）に
追加報酬が発生します。提案機会を無駄にしないためにも導入を推奨します。

---

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

> 💡 **viエディタの基本操作：** `i` で入力モード開始 → 編集 → `Esc` → `:wq` で保存終了。viが苦手な場合は `sudo nano /etc/systemd/system/mev-boost.service` でも可。

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
  -relays https://0xafa4c6985aa049fb79dd37010438cfebeb0f2bd42b115b89dd678dab0670c1de38da0c4e9138c9290a398ecd9a0b3110@boost-relay-hoodi.flashbots.net,https://0x821f2a65afb70e7f2e820a925a9b4c80a159620582c1766b1b09729fec178b11ea22abb3a51f07b288be815a1a2ff516@bloxroute.hoodi.blxrbdn.com

[Install]
WantedBy=multi-user.target
```

> 💡 **サービス設定の各項目について：**
> - `User=ethereum` / `Group=ethereum` : 専用の非特権ユーザーで実行します。
> - `Restart=always` / `RestartSec=5` : クラッシュ時に5秒後自動再起動します。
> - `-hoodi` : Hoodi テストネット用のリレーと通信します。
> - `-addr 127.0.0.1:18550` : Lighthouse BNがMEV-Boostに接続するためのローカルアドレス・ポートです。
> - `-relay-check` : 起動時にリレーの疎通確認を行います。
> - `-relays` : 使用するMEV-BoostリレーのURLをカンマ区切りで指定します。

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now mev-boost
```

### Step 20　Lighthouse BN/VC にMEV-Boost連携を追加

Step 12のlighthouse.serviceには既に `--builder http://127.0.0.1:18550` が含まれています。MEV-Boostを起動すればBNが自動的に接続します。

```bash
# MEV-Boostを起動してからBN/VCを再起動する（接続を有効化）
sudo systemctl daemon-reload
sudo systemctl restart lighthouse lighthouse-vc
```

> 💡 **MEV-Boostのログ確認：** `POST /eth/v1/builder/validators 200` が出ればリレーへの登録成功です。

---

### 【実録】ブロックプロポーザル成功ログ

> 参考実測値（Hoodi Testnet / ベアメタル環境 / 2026年6月 slot: 3209896）

MEV-Boost導入後、ブロック提案が成功した際の実際のログです。
**「正常な状態のベースライン」として記録しておきます。**

将来メインネットでブロック提案に失敗（Missed Block）した際、
この成功時のタイムラインと見比べることで原因の切り分けが即座にできます。

> 💡 **「正常な状態（ベースライン）を知っている者だけが、異常を正確に検知できる」**

#### 成功時のタイムライン
```
07:49:12.005  Requesting unsigned block    ← VCがBNにブロックを要求
07:49:12.015  MEV-Boost: getHeader start   ← MEV-Boostがリレーに入札を要求（スロット開始15ms後）
07:49:12.788  MEV-Boost: best bid          ← Flashbotsリレーが最高入札を返答（773ms後）
07:49:12.849  Received unsigned block      ← VCがブロックを受信
07:49:12.873  Publishing signed block      ← VCが署名（signing_time_ms: 23）
07:49:12.876  submitBlindedBlock start     ← MEV-BoostがリレーにBlinded Blockを提出
07:49:13.103  successfully submitted       ← Flashbotsへの提出成功 ✅
07:49:13.104  Successfully published block ← ブロックがチェーンに刻まれた ✅
```

**スロット開始から提出完了まで：約1.1秒**

#### 各ポイントの読み方

**① 署名時間 23ms はベアメタルの実力**
```
signing_time_ms: 23
```

署名処理がわずか23msで完了しています。
VMでは100ms超えることもあります。ベアメタル専用機の応答速度が
そのままブロック提案の成功率に直結します。

**② MEV報酬が発生**
```
value=0.004134718343723172
```

約0.0041 ETHの追加報酬が発生しました。
通常のアテステーション報酬に加え、ブロック提案時だけ得られる報酬です。
MEV-Boostを入れることで、この報酬が最大化されます。

**③ 2リレーの競争入札と context canceled は正常動作**

| リレー | 結果 | 理由 |
|---|---|---|
| Flashbots | ✅ 成功 | 最高入札を提示・提出成功 |
| bloxroute | ⚠️ context canceled | Flashbotsが先に成功したため自動キャンセル |

```
warning: error calling getPayloadV2 on relay
error="context canceled"
```

これは**エラーではなく正常動作**です。
2つのリレーに同時に入札を要求し、先に返ってきた方（Flashbots）を採用、
もう一方（bloxroute）は自動的にキャンセルされます。
競争入札の仕組みが正しく機能している証拠です。

**④ block_type: Blinded とは**
```
block_type: Blinded
```

MEV-Boost経由のブロックは「Blinded Block（封筒に入った状態）」として処理されます。
バリデータはブロックの中身を見ずに署名し、
リレーが中身を開封してチェーンに提出します。
これがMEV-Boostの設計上の重要な特徴で、
バリデータがMEVを横取りできない仕組みになっています。

#### 報酬の行き先（Lido CSMの仕組み）
```
ブロックプロポーザル報酬（0.0041 ETH）
↓
fee-recipient に設定したアドレス
↓
Lido EL Rewards Vault（0x9b108015...）
↓
Lidoのスマートコントラクトが自動分配
├── ステーカー（ETHを預けた人たち）→ 大部分
├── あなた（CSMオペレーター）→ オペレーター手数料分
└── Lido DAO → プロトコル手数料
```

自分のウォレットに直接は入りません。
Lidoのプールを経由して自動分配されます。
累積報酬はLido CSMダッシュボードで確認できます。

#### Missed Block 発生時の切り分けチェックリスト

将来、ブロック提案に失敗した際はこのベースラインと比較してください。

| 確認項目 | 正常値（今回の実測） | 異常のサイン |
|---|---|---|
| signing_time_ms | **23ms** | 500ms超 → CPUまたはメモリ逼迫を疑う |
| getHeader応答時間 | **773ms** | 2000ms超 → リレー側の問題を疑う |
| best bid が返るか | **返った（Flashbots）** | 返らない → リレーURLを確認 |
| context canceled | **bloxroute側で発生（正常）** | 両リレーともに失敗 → ネットワーク障害を疑う |
| スロット開始からの総時間 | **約1.1秒** | 11秒超 → タイムアウト（ほぼ確実にMissed） |

> 💡 **node_check.sh でブロック提案の成功を確認するには：**
> ```bash
> journalctl -u lighthouse-vc --no-pager | grep "Successfully published block" | tail -5
> ```

---

## Phase 6　Prometheus + Grafana 監視スタック

Prometheusが各クライアントからメトリクスを収集し、Grafanaがグラフ化します。

| 役割 | ソフト | ポート | 内容 |
|---|---|---|---|
| 収集役 | Prometheus | 9090 | 各クライアントから15秒ごとに数値を収集 |
| 可視化役 | Grafana | 3000 | ダッシュボードで可視化 |
| OS監視 | Node Exporter | 9100 | CPU温度・SSD負荷・メモリ等 |

#### データの流れ（全体像）

```
┌──────────────────────────────────────────────────────────────┐
│                    監視スタック データフロー                    │
│                                                               │
│  ┌─────────────┐  :6060   ┌──────────────────────────────┐  │
│  │    Geth     │ ──────→  │                              │  │
│  └─────────────┘          │                              │  │
│  ┌─────────────┐  :5054   │      Prometheus              │  │
│  │ Lighthouse  │ ──────→  │      （15秒ごとに収集）       │  │
│  │    BN       │          │      port: 9090              │  │
│  └─────────────┘          │                              │  │
│  ┌─────────────┐  :5064   │                              │  │
│  │ Lighthouse  │ ──────→  │                              │  │
│  │    VC       │          └──────────────┬───────────────┘  │
│  └─────────────┘                         │                   │
│  ┌─────────────┐  :9100                  │ データ提供         │
│  │   Node      │ ──────→ Prometheus      ↓                   │
│  │  Exporter   │         （OS指標）  ┌──────────┐            │
│  └─────────────┘                    │ Grafana  │            │
│                                     │ port:3000│            │
│  ブラウザ ←── Tailscale VPN ────────│ダッシュボ│            │
│  （あなたのPC）                      │  ード    │            │
│                                     └──────────┘            │
└──────────────────────────────────────────────────────────────┘
```

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

> 💡 **viエディタの基本操作：** `vi ~/node_check.sh` を実行後、`i` で入力モード開始 → 下記スクリプトを貼り付け → `Esc` → `:wq` で保存終了。

```bash
vi ~/node_check.sh   # 下記内容を貼り付け
chmod +x ~/node_check.sh   # +x: 実行権限を付与する
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

# [1] サービスの稼働状況
# geth/lighthouse/mev-boost/lighthouse-vcの4つが全てactiveか確認する
# どれかがinactiveの場合はjournalctl -u <サービス名> -n 50 で原因を調査する
# ※ systemctl is-active は sudo 不要なのでスクリプトから直接呼べる
echo -e "\n${YELLOW}[1] System Services Status${NC}"
for svc in geth lighthouse mev-boost lighthouse-vc; do
    STATUS=$(systemctl is-active $svc)
    if [ "$STATUS" = "active" ]; then
        echo -e " - $svc: ${GREEN}$STATUS${NC}"
    else
        echo -e " - $svc: ${RED}$STATUS${NC}"
    fi
done

# [2] リソース使用状況
# ディスク使用率が85%を超えたらgeth snapshot pruneを検討する
# メモリ不足（free -h でAvailableが少ない）の場合は--cache値を下げる
echo -e "\n${YELLOW}[2] Resource Usage${NC}"
df -h / | awk 'NR==1 || NR==2'
echo ""
free -h

# [3] 同期ステータス
# is_syncing: false かつ sync_distance: 0 が正常稼働状態
# is_syncing: true の場合はまだ同期中（新規構築直後は正常）
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
# Lighthouse: 50以上、Geth: 10以上あれば正常
# 0のまま続く場合はUFWのポート開放（9000/30303）を確認する
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

# [5] 直近の署名活動（アテステーション）
# "Successfully published attestations"が定期的に出ていれば報酬発生中
# 出ていない場合はbeaconcha.inでバリデータのステータスを確認する
echo -e "\n${YELLOW}[5] Recent Attestations (Last 3)${NC}"
journalctl -u lighthouse-vc --no-pager -n 100 | \
  grep "Successfully published attestations" | tail -n 3

# [6] MEV-Boostステータス
# Builder API: Online であればMEV-Boostがリレーと正常通信中
# Offline の場合はjournalctl -u mev-boost -n 30 でログを確認する
echo -e "\n${YELLOW}[6] MEV-Boost Status${NC}"
MEV_STATUS=$(curl -m 5 -s http://127.0.0.1:18550/eth/v1/builder/status)
if [ "$MEV_STATUS" = "{}" ] || [ -n "$MEV_STATUS" ]; then
    echo -e " - Builder API: ${GREEN}Online${NC}"
else
    echo -e " - Builder API: ${RED}Offline${NC}"
fi

# [7] バリデータステータスと残高
# active_ongoing: 正常稼働中、pending: デポジット処理待ち
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

# [8] 時刻同期ステータス
# Last Offset が 0.01秒以内であれば正常
# PoSは12秒ごとのスロットで動くため時刻同期は必須
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

# [9] セキュリティ・リモートアクセス状況
# fail2ban: Banned数が増えている場合は不正アクセス試行が発生している証拠
#           Fail2Banが自動でブロック済みのため通常は対処不要
#           fail2ban-client は visudo で NOPASSWD 設定済みのため sudo なしで実行される
# Tailscale: onlineであればVPN経由のリモートアクセスが正常に維持されている
#            offlineになった場合は sudo tailscale up で再接続する
echo -e "\n${YELLOW}[9] Security & Remote Access${NC}"
F2B=$(sudo fail2ban-client status sshd | grep "Currently banned" | awk '{print $4}')
echo -e " - fail2ban  : ${GREEN}active${NC} (Banned: ${F2B:-0})"
echo -e " - Tailscale : ${GREEN}online${NC}"

# [10] ネットワーク通信量
# 月間1〜2.5TBが正常範囲（10バリデータ / ピア数80〜200前後）
# 通信量が多い場合は --target-peers を下げることで調整できる
# vnstatが未インストールの場合はsudo apt install vnstatで導入する
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
# Restart Required: YES の場合は ./node_safe_stop.sh 実行後に sudo reboot する
# Updates Available の場合は定期的に sudo apt-get upgrade -y を実施する
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

echo -e "\n${CYAN}====================================================${NC}"
```

### node_check の出力例と読み方

> 参考実測値（Hoodi Testnet / バリデータ10個 / ベアメタル環境 / 2026年6月時点）

実際にコマンドを実行した際の出力と、各項目の読み方を解説します。

#### [1] System Services Status

```
 - geth: active
 - lighthouse: active
 - mev-boost: active
 - lighthouse-vc: active
```

4つ全てが `active` であれば正常です。
`inactive` が表示された場合は以下のコマンドで原因を調査してください。

```
journalctl -u <サービス名> -n 50
```

#### [2] Resource Usage

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  1.8T  189G  1.6T  11% /

               total   used   free  available
Mem:            29Gi   10Gi  753Mi       18Gi
Swap:          8.0Gi  1.3Gi  6.7Gi
```

- `Use% 11%` → 余裕十分。**85%を超えたら `geth snapshot prune` を検討する**
- `available 18Gi` → 問題なし。**2GB以下になったら `--cache` 値を下げる**

#### [3] Sync Status

```
 - is_syncing:    false
 - sync_distance: 0
```

`false` / `0` が正常稼働状態です。
新規構築直後は `true` から始まり、同期が進むにつれて `0` に近づきます。

#### [4] Peer Count

```
 - Lighthouse Peers: 185
 - Geth Peers:       50
```

- Lighthouse: **50以上**、Geth: **10以上** あれば正常です
- `0` のまま続く場合は UFW のポート開放（9000 / 30303）を確認してください

#### [5] Recent Attestations

```
INFO Successfully published attestations count: 1, validator_indices: [XXXXXX], slot: XXXXXXX
```

`Successfully published attestations` が約6.4分ごとに出ていれば報酬発生中です。
出ていない場合は [beaconcha.in](https://hoodi.beaconcha.in/) でバリデータのステータスを確認してください。

#### [6] MEV-Boost Status

```
 - Builder API: Online
```

`Online` であればMEV-Boostがリレーと正常通信中です。
`Offline` の場合は `journalctl -u mev-boost -n 30` でログを確認してください。

#### [7] Validator Status & Balance

```
PUBKEY (SHORT)  | STATUS           | BALANCE
------------------------------------------------------
0xb4f66315...   | active_ongoing   | 32.0008 ETH
0x98310086...   | active_ongoing   | 32.0007 ETH
（以下10鍵分）
```

- `active_ongoing` → 正常稼働中
- `pending` → デポジット処理待ち（登録直後は正常）
- 残高が `32.000x ETH` と増加していれば報酬が積み上がっている証拠です

#### [8] Time Synchronization Status

```
 - Status      : Synchronized
 - Last Offset : -0.000006s (Ideal: < 0.01s)
 - Reference ID: 67016A45 (ntp-a2.nict.go.jp)
```

`Last Offset` が **±0.01秒以内** であれば正常です。
EthereumのPoSは12秒ごとのスロットで厳格に動くため、時刻同期は署名成功率に直結します。

#### [9] Security & Remote Access

```
 - fail2ban  : active (Banned: 0)
 - Tailscale : online
```

- `fail2ban Banned: 0` → 不正アクセスなし。数字が増えていてもFail2Banが自動ブロック済みのため通常は対処不要
- `Tailscale: online` → VPN経由のSSHアクセスが正常に維持されている。`offline` になった場合は `sudo tailscale up` で再接続する

#### [10] Network Usage

```
 - Yesterday : ↓ 66.83 GiB | ↑ 73.24 GiB | Total: 140.07 GiB
 - Today     : ↓ 31.42 GiB | ↑ 30.00 GiB | Total: 61.42 GiB (Est: 134.01 GiB)
```

1日あたり100〜140 GiBが正常範囲です（月換算 約3〜4TB）。
通信量を減らしたい場合は lighthouse.service の `--target-peers` を50程度に下げてください（報酬への影響なし）。

#### [11] OS Update & Restart Status

```
 - Restart Required : NO
 - Pending Updates  : Updates Available!
```

- `Restart Required: YES` → 以下の手順で安全に再起動する
- `Updates Available` → 定期的に以下を実施する

いずれの場合も手順は同じです。
node_stop エイリアスでサービスを安全停止し、アップデート後に再起動します。
systemctl enable 設定済みのため、再起動後に全サービスが自動起動します。
また再起動によりメモリの解放・スワップのクリアも行われます。

```bash
# 1. サービスを安全停止（node_safe_stop.shのエイリアス）
node_stop

# 2. パッケージを更新
sudo apt update && sudo apt upgrade -y

# 3. 不要パッケージを削除
sudo apt autoremove -y

# 4. 再起動（enable済みのため全サービスが自動起動する）
sudo systemctl reboot
```

> 💡 **なぜ `systemctl start` で手動起動しないのか：**
> 全サービスは `systemctl enable` 設定済みのため、
> OS再起動時に自動で起動します。
> 再起動することでメモリの解放・スワップのクリアも同時に行われるため、
> 手動startより再起動の方が推奨されます。

---

### Step 28　node_safe_stop.sh の作成

> 💡 **viエディタの基本操作：** `vi ~/node_safe_stop.sh` を実行後、`i` で入力モード開始 → 下記スクリプトを貼り付け → `Esc` → `:wq` で保存終了。

```bash
vi ~/node_safe_stop.sh   # 下記内容を貼り付け
chmod +x ~/node_safe_stop.sh   # +x: 実行権限を付与する
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

### Step 29　node_backup.sh の作成

> 💡 **viエディタの操作：** `vi ~/node_backup.sh` を実行後、`i` で入力モード開始 → 下記スクリプトを貼り付け → `Esc` → `:wq` で保存終了。

```bash
vi ~/node_backup.sh
chmod +x ~/node_backup.sh
```

スクリプトの内容：

```bash
#!/bin/bash

# バックアップ先ディレクトリ（存在しない場合は自動作成）
BACKUP_DIR="/home/<your_user>/backups"
mkdir -p "$BACKUP_DIR"

# バックアップファイル名（日付・時刻付き）
BACKUP_FILE="$BACKUP_DIR/node_backup_$(date +%Y%m%d_%H%M%S).tar.gz"

# バックアップ実行
# -c : 新規アーカイブ作成（create）
# -z : gzip圧縮（zip）
# -p : パーミッション情報を保持（preserve）
# -f : ファイル名を指定（file）
# --exclude : 鍵本体とパスワードを除外（バックアップ経路での漏洩リスク排除）
tar -czpf "$BACKUP_FILE" \
    --exclude='/var/lib/lido-csm/validators/*/*.json' \
    --exclude='/var/lib/lido-csm/secrets' \
    --exclude='/var/lib/lido-csm/keystore_password.txt' \
    /var/lib/lido-csm/ \
    /etc/systemd/system/geth.service \
    /etc/systemd/system/lighthouse.service \
    /etc/systemd/system/lighthouse-vc.service \
    /etc/systemd/system/mev-boost.service \
    /home/<your_user>/node_check.sh \
    /home/<your_user>/node_safe_stop.sh \
    /etc/chrony/chrony.conf 2>/dev/null

# 30日以上前の古いバックアップを自動削除（ディスク節約）
find "$BACKUP_DIR" -name "node_backup_*.tar.gz" -mtime +30 -delete

echo "Backup completed: $BACKUP_FILE"
echo "Backup size: $(du -sh $BACKUP_FILE | cut -f1)"
```

### Step 30　cron による自動バックアップの設定

```bash
# cron = 定期的にコマンドを自動実行するLinuxのスケジューラー
crontab -e
```

> 💡 **viエディタの操作：** ファイルが開いたら `i` で入力モード → 下記1行を末尾に追記 → `Esc` → `:wq` で保存終了。

追記する内容：

```
# 毎日午前3時にバックアップを自動実行
0 3 * * * /home/<your_user>/node_backup.sh >> /home/<your_user>/backups/backup.log 2>&1
```

> 💡 **cron書式の読み方：**
>
> | 分 | 時 | 日 | 月 | 曜日 | 意味 |
> |---|---|---|---|---|---|
> | 0 | 3 | * | * | * | 毎日午前3時に実行 |
>
> `>> backup.log 2>&1` : 実行結果をログファイルに追記する

```bash
# 設定確認
crontab -l
```

### Step 31　バックアップファイルのホストPCへの自動転送

物理PCのバックアップをサーバー内だけに置くのは危険です。
SSD故障時にバックアップごと失うリスクがあります。
Windowsのタスクスケジューラーで定期的に自動転送します。

#### 設計の考え方

```
転送の流れ：
┌─────────────┐  cron 毎日3時   ┌──────────────────┐
│  物理PC     │ ─────────────► │  ~/node_backups/ │
│ (Ubuntu)    │  バックアップ作成 │  （サーバー内）   │
└─────────────┘                └──────────────────┘
                                        │
                                        │ タスクスケジューラー
                                        │ 週1回（自動転送）
                                        ▼
                               ┌──────────────────┐
                               │  ホストPC        │
                               │  （Windows）     │
                               │  iCloud等に保存  │
                               └──────────────────┘
```

> 💡 **なぜ転送先をiCloud等にするのか：**
> ホストPC内のフォルダに保存するだけでなく、
> クラウドストレージに同期することで
> ホストPCが故障しても復元できる「3重の保護」になります。

#### ホストPC（Windows）側の設定

任意の場所に以下の内容で `auto_backup.bat` を作成してください。
（例：`C:\Users\<your_user>\scripts\auto_backup.bat`）

```bat
@echo off
echo Waiting for Tailscale connection...
:: PC起動後、Tailscaleが安定するまで60秒待機
timeout /t 60 /nobreak >nul

echo Starting Backup Download...
:: 最新のバックアップをサーバーからダウンロード
scp -p "<your_user>@<your_tailscale_ip>:~/node_backups/lido_csm_backup_*.tar.gz" "C:\Users\<your_user>\<backup_dest>"

echo Cleaning up old backups...
:: ダウンロード先フォルダ内の7日より古いファイルを自動削除
forfiles /P "C:\Users\<your_user>\<backup_dest>" /M lido_csm_backup_*.tar.gz /D -7 /C "cmd /c del @path"

echo Backup and Cleanup Completed.
```

> 💡 **各コマンドの意味：**
>
> | コマンド | 意味 |
> |---|---|
> | `timeout /t 60` | 60秒待機。PC起動直後はTailscaleの接続が安定していないため |
> | `scp -p` | SSH経由でファイルをダウンロード。`-p` でタイムスタンプを保持 |
> | `forfiles /D -7` | 7日より古いファイルを自動削除。ディスク容量を節約する |

> 💡 **なぜTailscale IP（100.x.x.x）を使うのか：**
> 自宅内でもTailscale経由にすることで、
> 将来的に外出先からでも同じスクリプトが動作します。

#### タスクスケジューラーへの登録手順

1. Windowsの検索で「タスクスケジューラー」を開く
2. 右ペインの「基本タスクの作成」をクリック
3. 以下の設定で登録する

| 項目 | 設定値 |
|---|---|
| 名前 | `Ethereum Node Backup Transfer` |
| トリガー | 毎週 日曜日 午前4時（cronの1時間後） |
| 操作 | プログラムの開始 |
| プログラム | `C:\Users\<your_user>\scripts\auto_backup.bat` |

> 💡 **なぜcronの1時間後（午前4時）に設定するのか：**
> cronが午前3時にバックアップを作成します。
> タスクスケジューラーを1時間後の午前4時に設定することで
> 「作成完了後に転送する」という確実な順序を保てます。

### バックアップの確認とリストア手順

```bash
# バックアップファイルの一覧確認
ls -lh ~/backups/

# バックアップの中身を確認（展開せずに内容を表示）
tar -tzvf ~/backups/node_backup_<日付>.tar.gz

# リストア例：Systemdファイルだけを復元する場合
sudo tar -xzvf ~/backups/node_backup_<日付>.tar.gz \
    -C / \
    etc/systemd/system/geth.service
sudo systemctl daemon-reload
```

---

## 運用の心得とまとめ

### ネットワーク通信量の管理

Ethereumノードは継続的に通信します。vnstatで日次・月次の通信量を把握することが重要です。

参考実測値（Hoodi Testnet / バリデータ10個 / ベアメタル環境）：
- 昨日の通信量：↓ 66.83 GiB | ↑ 73.24 GiB | 合計 140.07 GiB
- 本日推定：134 GiB → 月換算 約 4TB

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

### バックアップ設計の考え方

バックアップには「含めるべきもの」と「絶対に含めてはいけないもの」があります。

| 種別 | 対象 | 理由 |
|---|---|---|
| ✅ 含める | スラッシング保護DB `/var/lib/lido-csm/slashing_protection/` | 二重署名防止の生命線 |
| ✅ 含める | Systemd設定 `/etc/systemd/system/*.service` | 復旧の高速化 |
| ✅ 含める | 自作スクリプト `node_check.sh` / `node_safe_stop.sh` | 運用環境の再現 |
| ✅ 含める | chrony設定 `/etc/chrony/chrony.conf` | 時刻同期設定の再現 |
| ❌ 除外 | バリデータ鍵本体 `validators/*/*.json` | バックアップ経路での漏洩リスク |
| ❌ 除外 | keystoreパスワード `keystore_password.txt` / `secrets/` | 同上 |

> 💡 **なぜ鍵本体をバックアップしないのか：**
> バリデータ鍵は最初に生成した際のニーモニック（24単語）から復元できます。
> バックアップファイルに鍵を含めると、そのファイルが漏洩した瞬間にスラッシングリスクが生まれます。
> 鍵はニーモニックを紙に書いてオフラインで保管することが唯一の正しい方法です。

> 💡 **GethやLighthouseの数百GBのブロックチェーンデータはバックアップ不要です。**
> 再同期すれば済みます。バックアップするのは少量の「設定とDB」だけです。

---

> ✅ **第2部ゴール達成：** VMの鍵を物理PCへ安全移行し、10鍵に増設、Prometheus + Grafana自作ダッシュボード + 自作スクリプトで「長期安定運用」の基盤が完成しました。
>
> さらにステップアップしたい方は、同じサーバーの余力を活かしてSSVノードを兼業する **第3部・分散化SSV編** へどうぞ。
