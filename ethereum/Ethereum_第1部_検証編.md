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

Ethereum は2つのソフトウェアを連携させて動かします。この2層構造を理解することが、構築作業の全ての基本になります。

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

> 📎 **Lido Withdrawal Vault アドレス（Hoodi）：** [Lido Deployed Contracts - Hoodi](https://docs.lido.fi/deployed-contracts/hoodi)

---

## Step 1　VM作成とOSインストール

### VirtualBox VM の作成

| 設定項目 | 推奨値 | なぜこの設定か |
|---|---|---|
| メモリ | 16384 MB | Gethキャッシュ + Lighthouse動作に必要 |
| CPU | 4コア | 署名検証の並列処理 |
| ストレージ | 300GB（可変サイズ） | Hoodiの同期DB容量 |
| **コントローラー** | **NVMe（SATAから変更）** | **I/O速度向上。最重要設定** |
| **EFI有効化** | **システム → マザーボード → 「EFIを有効化」にチェック** | **これを忘れるとUbuntu Server 24.04が起動しない** |

> ⚠️ **ストレージコントローラーは必ず SATA → NVMe に変更してください。** これを怠ると後述のI/O不足に直結します（本書最大の教訓）。

> ⚠️ **EFIの有効化は必須です。**
> VirtualBox の「設定 → システム → マザーボード」タブを開き、
> 「EFIを有効化（特定のOSのみ）」に **必ずチェックを入れてください。**
> これを忘れるとUbuntu Server 24.04がインストール後に起動しません。
> （実際に3回作り直して気づいた実録）

### NATポートフォワーディング設定

VirtualBox の「設定 → ネットワーク → 高度 → ポートフォワーディング」で追加します。

| 名称 | プロトコル | ホストPort | ゲストPort |
|---|---|---|---|
| SSH | TCP | 2222 | 22 |
| Geth P2P | TCP/UDP | 30303 | 30303 |
| Lighthouse P2P | TCP/UDP | 9000 | 9000 |

> ⚠️ **ホストIPは空白のままにすること。**
> `127.0.0.1` 以外の値（`172.x.x.x` 等）を入力すると
> SSH接続が `Connection refused` になります。
> ホストIP欄は空白のまま保存してください。

### SSH接続と公開鍵認証の設定

VirtualBoxのポートフォワーディング設定後、ホストPCから
SSH接続できるようにします。

### 127.0.0.1 とポートフォワーディングの仕組み

#### 127.0.0.1（ループバックアドレス）とは

127.0.0.1 = 「自分自身」を指す特別なIPアドレスです。
通常のIPアドレスは外部ネットワークに向かいますが、
127.0.0.1 だけは「自分のPC内だけで完結する」特別なアドレスです。
localhost という名前でも呼ばれます。

譬え：自分宛てに手紙を書くようなもの。外に出ることなく、自分のポストに直接届きます。

#### ポートフォワーディング（NATトンネル）の仕組み

VirtualBoxのNAT設定で「ポート2222への通信をVM内のポート22に転送する」トンネルを作っています。

図解：

```
あなたのPC（Windows）
┌──────────────────────────────────────┐
│                                      │
│  ssh -p 2222 user@127.0.0.1          │
│            ↓                         │
│       自分のポート2222                │
│            ↓ NATトンネル（転送）      │
│  ┌────────────────────────┐          │
│  │  Ubuntu VM（仮想PC）   │          │
│  │  ポート22（SSH受付口）  │          │
│  └────────────────────────┘          │
│                                      │
│  外部インターネットには出ない！        │
└──────────────────────────────────────┘
```

要素の意味：
- `127.0.0.1` : 自分のPC（外に出ない）
- `:2222`      : ホストPCの受付窓口（ポート番号）
- `→ :22`      : VMのSSH受付窓口に転送

なぜ直接VMのIPアドレスを使わないのか：
VirtualBoxのNAT構成では、VMはホストPCの「内側」にいるため
外部からは見えないIPアドレス（10.x.x.x等）が割り当てられます。
ポートフォワーディングを使うことで、
ホストPCを「中継点」としてVMに安全に接続できます。

#### ポートとは何か

ポートはIPアドレスの「部屋番号」のようなものです。

| ポート番号 | 用途 |
|---|---|
| 22 | SSH（安全なリモート接続） |
| 80 | HTTP（ウェブサイト） |
| 443 | HTTPS（安全なウェブサイト） |
| 2222 | 今回のSSH転送用（任意で設定） |
| 30303 | Geth P2P通信 |
| 9000 | Lighthouse P2P通信 |

ポート2222を使う理由：
22番はホストPCのSSHがすでに使っている可能性があるため、
衝突を避けて2222番を使います。
どの番号でも動きますが、1024以上の番号を使うのが慣例です。

#### 公開鍵の生成（ホストPC側）

```bash
ssh-keygen -t ed25519 -C "your_comment"
```

このコマンドの各オプションの意味：

| オプション | 意味 | 今回の値 |
|---|---|---|
| `ssh-keygen` | SSH鍵ペアを生成するコマンド | - |
| `-t` | 鍵の種類（type）を指定 | `ed25519` |
| `-C` | コメントを付ける（comment） | `"your_comment"` |

#### -t ed25519 について

鍵の暗号方式を指定します。

| 方式 | 特徴 | 推奨度 |
|---|---|---|
| `ed25519` | 新しい方式。短くて安全・高速 | ★★★ 推奨 |
| `rsa` | 古くから使われる方式。互換性が高い | ★★ |
| `ecdsa` | ed25519より古い楕円曲線方式 | ★ |

ed25519は現在最も推奨される方式です。
鍵が短いにもかかわらず非常に安全で、
接続速度も速いため特別な理由がなければこれを選びます。

#### -C "your_comment" について

鍵に説明文（コメント）を付けます。
技術的な動作には影響しません。

用途：複数の鍵を管理するときに「どの鍵か」を識別するためのメモです。

```bash
# 例：用途や日付をコメントに入れると管理しやすい
ssh-keygen -t ed25519 -C "homeserver-2025"
ssh-keygen -t ed25519 -C "ethereum-node"

# コメントなしでも作成可能（-C を省略）
ssh-keygen -t ed25519
```

公開鍵ファイルの末尾にコメントが表示されます：
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... homeserver-2025
                                         ↑ ここがコメント
```

#### 実行の流れ（全体）

```bash
$ ssh-keygen -t ed25519 -C "ethereum-node"

# 保存先を聞かれる（そのままEnterでデフォルト）
Generating public/private ed25519 key pair.
Enter file in which to save the key (/home/user/.ssh/id_ed25519): [Enter]

# パスフレーズを聞かれる（不要ならEnterを2回）
Enter passphrase (empty for no passphrase): [Enter]
Enter same passphrase again: [Enter]

# 完了メッセージ
Your identification has been saved in /home/user/.ssh/id_ed25519
Your public key has been saved in /home/user/.ssh/id_ed25519.pub
The key fingerprint is:
SHA256:XXXXXXXXXXXXXXXXXXXXXXXXXXXX ethereum-node
```

```bash
# 公開鍵の内容を表示（コピーしておく）
cat ~/.ssh/id_ed25519.pub
```

### パスフレーズについて

ssh-keygen 実行時に以下のプロンプトが表示されます：

```
Enter passphrase (empty for no passphrase):
Enter same passphrase again:
```

| 選択 | 方法 | メリット | デメリット |
|---|---|---|---|
| パスフレーズなし | Enterを2回押す | 接続がシンプル | 鍵ファイルが盗まれると危険 |
| パスフレーズあり | 任意の文字列を入力 | 鍵が盗まれても安全 | SSH接続のたびに入力が必要 |

個人のホームサーバー用途では、パスフレーズなし（Enterを2回押す）で問題ありません。重要なのは秘密鍵ファイル（id_ed25519）を外部に漏らさないことです。

### 生成されるファイルの確認

```bash
ls -la ~/.ssh/
# id_ed25519     ← 秘密鍵（絶対に外に出さない・共有しない）
# id_ed25519.pub ← 公開鍵（サーバーに登録する・見られても問題ない）
```

秘密鍵と公開鍵の関係：
南京錠（公開鍵）をサーバーに取り付け、鍵（秘密鍵）を自分だけが持つイメージです。
南京錠は誰が見ても問題ありませんが、鍵は絶対に渡してはいけません。

#### 公開鍵をVMに登録
```bash
# VM側で実行
mkdir -p ~/.ssh && chmod 700 ~/.ssh
vi ~/.ssh/authorized_keys
# → 上記でコピーした公開鍵を貼り付けて保存
chmod 600 ~/.ssh/authorized_keys
```

> 💡 **パーミッションの意味：**
> - `700` = 自分だけ読み書き実行可能
> - `600` = 自分だけ読み書き可能
> SSHは権限が広すぎると接続を拒否するため、この設定が必須です。

#### ホストPCからSSH接続
```bash
# ポート2222経由でVMに接続
ssh -p 2222 <your_user>@127.0.0.1
```

### 初回SSH接続時のフィンガープリント確認

初めてSSH接続するとき、必ず以下のメッセージが表示されます：

```
The authenticity of host '[127.0.0.1]:2222' can't be established.
ED25519 key fingerprint is SHA256:XXXXXXXXXXXXXXXXXXXXXXXXXXXX
This key is not known by any other names.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

これは攻撃ではありません。
「このサーバーに初めて接続しますが、本当に信頼しますか？」という確認メッセージです。

yes と入力してEnterを押してください。

```
Warning: Permanently added '[127.0.0.1]:2222' (ED25519) to the list of known hosts.
```

この情報は ~/.ssh/known_hosts に保存されます。
次回からは同じメッセージは表示されません。

### SSH関連ファイルの役割

```bash
cat ~/.ssh/known_hosts
# → 接続したことのあるサーバーの「顔」（フィンガープリント）が記録されている
```

| ファイル | 役割 |
|---|---|
| ~/.ssh/id_ed25519 | 自分の秘密鍵 |
| ~/.ssh/id_ed25519.pub | 自分の公開鍵 |
| ~/.ssh/authorized_keys | 接続を許可する公開鍵のリスト（サーバー側） |
| ~/.ssh/known_hosts | 接続したことのあるサーバーの記録（クライアント側） |

### フィンガープリントとは

サーバーの「顔認証」のようなものです。
同じIPアドレスでも、フィンガープリントが変わると以下の警告が表示されます：

```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```

これが表示された場合は以下のどちらかです：
- VMを作り直した（正常）
- 中間者攻撃の可能性（要注意）

VMの再構築後に表示された場合は以下のコマンドで古い記録を削除してください：

```bash
ssh-keygen -R "[127.0.0.1]:2222"
```

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

> 📎 **Geth公式ドキュメント（インストール手順）：** [Installing Geth](https://geth.ethereum.org/docs/getting-started/installing-geth)

Gethは **PPA（Personal Package Archive）** を使ってインストールします。
PPAとはUbuntu向けの追加ソフトウェア配布元です。
Ethereumチームが公式に提供しているリポジトリを登録することで、
`apt` コマンドから常に最新版のGethを入手できます。

```bash
# ① PPA（Ethereumの公式リポジトリ）をシステムに登録する
# これがないと apt が geth を見つけられず install が失敗する
sudo add-apt-repository -y ppa:ethereum/ethereum
sudo apt-get update

# ② Gethをインストールする
sudo apt-get install -y geth

# ③ インストール成功の確認（バージョン番号が表示されればOK）
geth version
```

### Systemdサービスの作成

```bash
sudo vi /etc/systemd/system/geth.service
```

> 💡 **viエディタの基本操作：**
> - `i` : 入力モードを開始する（文字が打てるようになる）
> - `Esc` : 入力モードを終了する
> - `:wq` : 保存して終了（write + quit）
> - `:q!` : 保存せずに強制終了（変更を破棄する場合）
> - 矢印キー : カーソル移動
>
> viに不慣れな場合はnanoエディタも使用可能：`sudo nano /etc/systemd/system/geth.service`（Ctrl+O で保存、Ctrl+X で終了）

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

> 💡 **サービス設定の各項目について：**
> - `User=ethereum` / `Group=ethereum` : 専用の非特権ユーザーで実行します。rootで動かすよりも、万が一の侵害時の被害を最小限に抑えられます。
> - `Restart=always` : プロセスが何らかの理由で終了した場合、自動的に再起動します。ノードが突然クラッシュしてもサービスが自力で復帰します。
> - `RestartSec=5` : 再起動前に5秒待ちます。即座に再起動するとエラーループに陥るリスクがあるため、バッファを設けています。

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

### Geth起動後の動作確認

Gethを起動したら、サービスが正常に立ち上がっているか確認します。

```bash
# 同期状態を確認（繰り返し実行して監視）
curl -s http://127.0.0.1:8545 \
  -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' | jq

# false と表示されれば同期完了
# true の場合はまだ同期中（しばらく待つ）
```

各オプションの意味：

| オプション | 意味 |
|---|---|
| `-s` | silent モード。進捗バーなどの余分な出力を抑制します |
| `http://127.0.0.1:8545` | Geth の JSON-RPC エンドポイント（ローカル限定） |
| `-X POST` | HTTP メソッドを POST に指定。JSON-RPC はすべて POST です |
| `-H "Content-Type: application/json"` | リクエストヘッダーにJSONを送ることを宣言します |
| `--data '...'` | リクエストボディ（JSON-RPC のコマンド本文） |
| `\| jq` | レスポンスJSON を整形して見やすく表示します（`jq` = JSON整形ツール） |

> 💡 **Geth起動直後の正常な状態について**
> この時点ではまだLighthouse（Consensus Client）が
> いないため、ブロックの同期は始まりません。
> ログにエラーが出ずサービスが落ちなければOKです。
>
> 次のStep3でLighthouseを起動することで初めて、
> Engine API経由でGethに同期指示が出され、
> ブロックの本格的な取り込みがスタートします。

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

> 💡 **viエディタの基本操作：**
> - `i` : 入力モードを開始する（文字が打てるようになる）
> - `Esc` : 入力モードを終了する
> - `:wq` : 保存して終了（write + quit）
> - `:q!` : 保存せずに強制終了（変更を破棄する場合）
> - 矢印キー : カーソル移動
>
> viに不慣れな場合はnanoエディタも使用可能：`sudo nano /etc/systemd/system/lighthouse.service`（Ctrl+O で保存、Ctrl+X で終了）

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

> 💡 **サービス設定の各項目について：**
> - `User=ethereum` / `Group=ethereum` : 専用の非特権ユーザーで実行します。rootで動かすよりも、万が一の侵害時の被害を最小限に抑えられます。
> - `Restart=always` : プロセスが何らかの理由で終了した場合、自動的に再起動します。ノードが突然クラッシュしてもサービスが自力で復帰します。
> - `RestartSec=5` : 再起動前に5秒待ちます。即座に再起動するとエラーループに陥るリスクがあるため、バッファを設けています。

> 💡 **`--checkpoint-sync-url` について：**
> 通常数日かかる同期を数分で完了できます。信頼できるノードの「最新状態のスナップショット」から始める高速同期方式です。
>
> **提供元：** [ethpandaops](https://checkpoint-sync.hoodi.ethpandaops.io) は Ethereum Foundation の公式開発チームが運営しています。
>
> **サイトで確認できる情報：**
>
> | 項目 | 意味 |
> |---|---|
> | Latest Finalized Epoch | 確定済みの最新ブロック（Lighthouseはここから同期開始） |
> | Latest Justified Epoch | 承認待ちの最新ブロック |
> | Block Root | 同期開始ブロックの識別ハッシュ |
>
> **Lighthouse の使い方：** このサイトを「出発点」として参照し、そこから最新状態まで追いかけます。
>
> **いつ使うか：** 初回構築と再構築時のみ。通常稼働中はLighthouseが自動で同期するため参照不要です。
>
> 📎 **Hoodi チェックポイント同期URL：** [checkpoint-sync.hoodi.ethpandaops.io](https://checkpoint-sync.hoodi.ethpandaops.io)

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
tar -xvf ethstaker_deposit-cli-linux-amd64.tar.gz
cd ethstaker_deposit-cli-*-linux-amd64
```

### 新規ニーモニックで鍵を生成

```bash
./deposit new-mnemonic \
  --num_validators 1 \
  --chain hoodi \
  --eth1_withdrawal_address 0x4473dCDDbf77679A643BdB654dbd86D67F8d32f2
```

> ⚠️ **Withdrawal Vaultアドレスについて**
>
> | ネットワーク | Withdrawal Vault アドレス（proxy）|
> |---|---|
> | Hoodi Testnet | `0x4473dCDDbf77679A643BdB654dbd86D67F8d32f2` |
> | Mainnet（本番） | `0xB9D7934878B5FB9610B3fE8A5e441e8fad7E293f` |
>
> 📎 公式確認先: https://docs.lido.fi/deployed-contracts/hoodi
>
> 💡 公式ページには `proxy` と `impl` の2種類が表示されますが、
> 指定するのは必ず **`proxy`** のアドレスです。
> `impl`（実装アドレス）は内部処理用のため使用しません。

対話フローへの回答（全ステップ）：

| # | プロンプト | 入力 | 補足 |
|---|---|---|---|
| 1 | `Please choose your language` | `3`（English）を選択してEnter | CLIの表示言語 |
| 2 | `Internet connectivity detected` | anyキーで続行 | オンライン環境での警告。テストネットは続行OK |
| 3 | `Repeat your withdrawal address` | `0x4473dCDDbf77679A643BdB654dbd86D67F8d32f2` を再入力 | アドレスの確認入力 |
| 4 | `Please choose the language of the mnemonic` | Enterキー（English） | ニーモニックの言語。Englishが世界標準 |
| 5 | `Create a password` | 12文字以上のパスワードを入力 | **12文字未満はエラー。必ず紙に控える** |
| 6 | `Repeat your keystore password` | 同じパスワードを再入力 | 確認入力 |
| 7 | `Compounding validators (0x02)?` | Enterキー（no） | **Lido CSMは必ずno。yesにするとWithdrawal Vaultと非互換** |
| 8 | ニーモニック表示 | **紙に手書きで24単語を書き写す** | スクリーンショット・デジタルメモ厳禁 |
| 9 | `Please type your mnemonic` | 書き写した24単語をスペース区切りで入力 | 各単語の最初の4文字だけでもOK |
| 10 | `WARNING: Your clipboard will be CLEARED` | anyキーで続行 | クリップボードの自動消去（安全機能） |

> ⚠️ **ステップ7（Compounding）はPectra fork以降に追加された新しい選択肢です。**
> 手順書作成時には存在しなかった質問のため、必ず `no`（Enter）を選択してください。

> ⚠️ **ステップ8のニーモニードは必ず紙に手書きで保管してください。**
> これを失うとバリデータ鍵の復元が不可能になります。

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
# echo の出力をそのままファイルに書き込む
# <keystore_password> は鍵生成時に設定した12文字以上のパスワードに置き換える
echo '<keystore_password>' | sudo tee /var/lib/lido-csm/keystore_password.txt
sudo chown ethereum:ethereum /var/lib/lido-csm/keystore_password.txt
# 600 = 所有者のみ読み書き可能。パスワードファイルなので厳格に保護する
sudo chmod 600 /var/lib/lido-csm/keystore_password.txt
```

> ⚠️ **なぜ ~/csm-artifacts/ から直接インポートできないのか：**
> `/home/<your_user>/` ディレクトリのパーミッションは `700`（本人以外アクセス不可）です。
> `lighthouse` は `ethereum` ユーザーとして実行するため、
> `/home/<your_user>/` 配下のファイルは `Permission denied` になります。
> `/tmp` を中継地点として使うことで解決します。

```bash
# 1. 一時ディレクトリの作成
sudo mkdir -p /tmp/keys_import

# 2. 鍵ファイルをコピー
sudo cp -r ~/csm-artifacts/ethstaker_deposit-cli-*-linux-amd64/validator_keys /tmp/keys_import/

# 3. 所有者をethereumに変更（これがないとlighthouseが読めない）
sudo chown -R ethereum:ethereum /tmp/keys_import

# 4. インポート実行
sudo -u ethereum lighthouse account validator import \
  --network hoodi \
  --datadir /var/lib/lido-csm \
  --directory /tmp/keys_import/validator_keys \
  --reuse-password

# 5. 一時ファイルの削除（機密データのクリーンアップ・必須）
sudo rm -rf /tmp/keys_import
```

### Lighthouse VC サービスの作成

> ⚠️ **`--suggested-fee-recipient` は必ずLido公式のEL Rewards Vaultアドレスを指定すること。自分のウォレットアドレスを入れると MEV stealing 判定でペナルティを受けます。**

| ネットワーク | fee-recipientに設定するアドレス |
|---|---|
| Hoodi Testnet | `0x9b108015fe433F173696Af3Aa0CF7CDb3E104258` |
| Mainnet（本番） | `0x388C818CA8B9251b393131C08a736A67ccB19297` |

> 📎 **fee-recipient の設定についての公式ドキュメント：** [Setting the fee recipient for CSM validators](https://docs.lido.fi/run-on-lido/csm/troubleshooting/setting-the-fee-recipient-for-csm-validators/)

```bash
sudo vi /etc/systemd/system/lighthouse-vc.service
```

> 💡 **viエディタの基本操作：**
> - `i` : 入力モードを開始する（文字が打てるようになる）
> - `Esc` : 入力モードを終了する
> - `:wq` : 保存して終了（write + quit）
> - `:q!` : 保存せずに強制終了（変更を破棄する場合）
> - 矢印キー : カーソル移動
>
> viに不慣れな場合はnanoエディタも使用可能：`sudo nano /etc/systemd/system/lighthouse-vc.service`（Ctrl+O で保存、Ctrl+X で終了）

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
  --http \
  --http-address 127.0.0.1 \
  --http-port 5062

[Install]
WantedBy=multi-user.target
```

> 💡 **`--http-port 5062` は第2部の監視スクリプト（node_check.sh）で
> バリデータの状態をAPIから取得するために使用します。
> ここで有効にしておくことで第2部へスムーズに移行できます。**

> 💡 **サービス設定の各項目について：**
> - `User=ethereum` / `Group=ethereum` : 専用の非特権ユーザーで実行します。バリデータ鍵を扱うため、特に権限の最小化が重要です。
> - `Restart=always` : プロセスが何らかの理由で終了した場合、自動的に再起動します。ノードが突然クラッシュしてもサービスが自力で復帰します。
> - `RestartSec=5` : 再起動前に5秒待ちます。即座に再起動するとエラーループに陥るリスクがあるため、バッファを設けています。

> 💡 **VCは `--execution-endpoint` を受け付けません。** BN経由でELと通信するため `--beacon-nodes` を指定します（よくある間違い）。

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now lighthouse-vc
sudo journalctl -u lighthouse-vc -f -o cat
```

### Lido CSM ウィジェットへの登録

ブラウザで [https://csm.testnet.fi/](https://csm.testnet.fi/) にアクセスします。

| 手順 | 操作 |
|---|---|
| 1. Wallet接続 | MetaMask等を接続（Hoodiテストネットであることを確認） |
| 2. Create Operator | 「Join as a Node Operator」を選択 |
| 3. Deposit Data | `deposit_data-*.json` の中身をそのまま貼り付け |
| 4. Bond支払い | 必要なBond（テストETH）をデポジット |
| 5. 確認 | Operator ID が発行されれば登録完了 |

#### deposit_dataの内容確認方法
```bash
# 生成されたdeposit_dataの内容を確認
cat validator_keys/deposit_data-*.json | jq '.[] | {
  network_name,
  withdrawal_credentials,
  pubkey
}'
```

> ✅ **確認ポイント：**
> - `network_name` が `hoodi` であること
> - `withdrawal_credentials` が `0x01` で始まること
>   （`0x00` 始まりは個人アドレス指定ミスのサイン）
> - `pubkey` が表示されること

> 💡 **テストETH（Bond用）の入手方法**
>
> 以下のFaucetからHoodiテストETHを入手できます：
>
> 📎 https://hoodi-faucet.pk910.de/#/
>
> PoWマイニング方式のため、ブラウザを開いたまま
> 数分〜数時間待つことでテストETHが貯まります。
>
> 参考資料: https://note.com/buythedipams/n/nad4bf66b02b1

---

## Step 6　動作確認

### 全サービスの稼働確認

```bash
sudo systemctl status geth lighthouse lighthouse-vc
```

### 署名ログの確認

```bash
sudo journalctl -u lighthouse-vc -n 20 -o cat | grep attestation
```

| ログメッセージ | 意味 |
|---|---|
| `Successfully published attestations` | 署名成功・報酬発生 ✅ |
| `All validators inactive` | Lidoのデポジット処理待ち（数時間〜） |
| `is_optimistic: true` | まだ完全同期していない（待機） |

### beaconcha.in で確認

📎 **URL：** https://hoodi.beaconcha.in/

**アクセス方法：** バリデータの公開鍵（`0x` 始まり）で検索します。
Lido CSMウィジェットの「Monitoring」リンクからも直接アクセスできます。

#### ダッシュボード各項目の読み方

| 項目 | 意味 | 正常値 |
|---|---|---|
| Validators Live | アクティブなバリデータ数 | 登録数と一致 |
| BeaconScore | バリデータ総合スコア | 95%以上 |
| Attestations | 署名成功数 / 失敗数 | 失敗0が理想 |
| Att. Efficiency | アテステーション効率 | 95%以上 |
| Slashings | スラッシング発生数 | 必ず0 |
| APR | 年利回り | ネットワーク平均前後 |
| Sync Efficiency | 同期効率 | 100% |
| Source / Target / Head | アテステーションの種類別成功数 | 全て緑 |
| Avg. Incl. Distance | 署名がブロックに含まれるまでの平均距離 | 1.0〜1.5が理想 |

#### スロットマップの色の意味

| 色 | 意味 |
|---|---|
| 緑（塗りつぶし） | 署名成功 ✅ |
| 緑（枠のみ） | 同期委員会参加 |
| 赤枠 | その瞬間だけ遅延（軽微・問題なし） |
| グレー | 未来のスロット（未確定） |

#### 参考実測値（Hoodi Testnet / バリデータ1個 / VM環境）

| 指標 | VM環境での実測値 | 備考 |
|---|---|---|
| Validators Live | 1 | 1鍵のみで稼働中 |
| BeaconScore | 90.31% | VMのI/O負荷の影響が出ている |
| Attestations | 217 / 8（失敗8回） | 失敗がゼロにならないのがVM環境の限界 |
| Att. Efficiency | 90.31% | ベアメタル環境（97.39%）より低い |
| APR | 1.63% | |
| Avg. Incl. Distance | 1.27 | 理想値1.0〜1.13より高め |
| Slashings | 0 / 0 | スラッシングなし ✅ |

> 💡 **この数値がベアメタル移行の動機になりました。**
> 同じ設定でもVM環境ではBeaconScoreが90%台前半に留まり、
> 署名の失敗が散発的に発生しています。
> 第2部でベアメタルに移行後、BeaconScore 97.39%・
> 失敗ゼロを達成しました。
> VMの限界を数字で証明する実録データです。

> ✅ ほぼ全部緑であれば正常稼働中です。数個の赤枠はネットワークの一時的な遅延で発生するため、連続しない限り問題ありません。BeaconScoreが90%を下回る場合はノードの状態を確認してください。

> ✅ **ここまで来たら第1部の構築は完了です。**
> 引き続きトラブルシューティングを確認してから
> 第2部・ベアメタル編に進みましょう。

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

## 【実録】VMの限界 — なぜベアメタルへ移行したか

VM環境でバリデータは稼働しましたが、運用を続けるうちに複数の問題に直面しました。これが第2部（ベアメタル移行）へ進む直接の理由です。

| 直面した問題 | 内容 |
|---|---|
| **SSDのI/O不足** | VM経由のディスクアクセスはオーバーヘッドが大きく、Gethのブロック検証が遅延しがちだった |
| **ピア過多による負荷** | 一時ピアが479に達し、CPU/メモリが逼迫。検証が雪だるま式に遅延（デススパイラル） |
| **Windows再起動リスク** | ホストのWindows Updateが勝手に再起動し、ノードが巻き添えで停止する危険 |
| **UPnP拒否** | VirtualBoxの壁でインバウンド通信が弾かれ、ピア接続が制限された |

> 💡 **応急処置として `--maxpeers 15` / `--target-peers 30` でピアを絞り、リソースを検証に集中させることで急場はしのげました。しかし根本解決は専用の物理マシン（ベアメタル）への移行でした。**

---

> ✅ **第1部の最大の学び：**
> VMは学習と検証には最適ですが、
> I/Oがシビアな本番バリデータ運用には専用ハードウェアが望ましい。
> この気づきこそが第1部の成果です。
>
> 次は **第2部・ベアメタル編** で、
> ここで作った鍵を専用物理PCへ安全に引っ越し、
> 鍵を10個に増設し、長期安定運用の基盤を作ります。
