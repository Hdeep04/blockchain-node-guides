# 第4部・応用編 第5章：Nimbus統合構成（in-process validator）

> **第3章の分離構成から、公式推奨の統合構成へ。同じVMで構築し直して比較する**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第4部・応用編の第5章。Nimbus公式推奨構成を構築し、第3章の分離構成と比較する |
| 検証環境 | VirtualBox VM（Ubuntu Server 22.04 LTS）× 1台（testnetcsm2） |
| 前提 | 第4章・Voluntary Exitが完了していること（testnetcsm2の旧鍵が引退済み） |
| 検証日 | 2026年6月17〜18日（Hoodi Testnet） |

> ⚠️ **本書は機密情報を一切含みません。** アドレス類は `<...>` のプレースホルダです。

> 💡 **リンクは右クリック→「新しいタブで開く」を選択すると
> 手順書を表示したまま参照先を確認できます。**

---

## 1. なぜこの章を書くのか

第3章では Nethermind + Nimbus を**分離構成**（BN/VCを別サービスで動かす構成）で構築しました。しかし第3章の中で以下の公式警告を確認していました。

> Nimbus公式の警告：
> 「これまでに確認されたスラッシングのほとんどは
> BNとVCを分離した複雑なセットアップに起因しています。」

本章では、**引退済みとなったtestnetcsm2のVM**を再利用し、Nimbus公式が推奨する**統合構成（in-process validator）**を構築します。同じVM・同じクライアントバージョンで構成だけを変えることで、構築の手間・トラブルの有無を公平に比較します。

### 本章の検証構成

```
testnetcsm（第3章で構築・分離構成）
  Nethermind + Nimbus（BN/VC分離）
  鍵：index 3（稼働中だったが、本章の作業中は一時停止）

testnetcsm2（第4章でVoluntary Exit済み・本章で作り替え）
  旧構成：Geth + Lighthouse（鍵index 2は引退済み）
  新構成：Nethermind + Nimbus統合構成（本章）
  鍵：index 4（新規生成）
```

---

## 2. Phase 1：旧データの完全削除

testnetcsm2には第1部〜第4章で使ったGeth/Lighthouseのデータと、引退済みの鍵が残っています。クリーンな状態から構築するため、全て削除します。

### 削除前の確認

```bash
# 既存サービスファイルの確認
sudo ls -la /etc/systemd/system/ | grep -E "geth|lighthouse"

# データディレクトリのサイズ確認
sudo du -sh /var/lib/ethereum/geth /var/lib/ethereum/lighthouse 2>/dev/null
```

**実測結果：**
```
93G     /var/lib/ethereum/geth
54G     /var/lib/ethereum/lighthouse
```

### サービスファイルとデータの削除

```bash
# サービスファイルの削除
sudo rm /etc/systemd/system/geth.service
sudo rm /etc/systemd/system/lighthouse.service
sudo rm /etc/systemd/system/lighthouse-vc.service
sudo systemctl daemon-reload

# データディレクトリの削除（約147GB解放）
sudo rm -rf /var/lib/ethereum/geth
sudo rm -rf /var/lib/ethereum/lighthouse
```

### 引退済み鍵・関連ファイルの削除

> 💡 **削除して問題ない理由：**
> index 2の鍵は第4章でVoluntary Exit済みです。二度と署名しないため
> スラッシング保護DBを含め、関連ファイルを全て削除して構いません。
> Nethermind/Nimbusは別のJWT Secret（`/secrets/jwtsecret`）を新規生成して使うため、
> 旧JWTも不要です。

```bash
sudo rm -rf /var/lib/ethereum/jwt
sudo rm /var/lib/lido-csm/validators/api-token.txt
sudo rm -rf /var/lib/lido-csm/validators/logs
sudo rm /var/lib/lido-csm/validators/slashing_protection.sqlite
sudo rm /var/lib/lido-csm/validators/validator_definitions.yml
sudo rm /var/lib/lido-csm/validators/validator_key_cache.json
sudo rm /var/lib/lido-csm/slashing_protection/slashing_protection.json
sudo rm /var/lib/lido-csm/keystore_password.txt
```

> 💡 **ファイルが「No such file or directory」で見つからない場合：**
> ディレクトリ構成を勘違いしている可能性があります。
> `sudo ls -la /var/lib/lido-csm/validators/` で実際の中身を
> 確認してから再実行してください。

### 削除結果の確認

```bash
sudo ls -la /var/lib/ethereum/ 2>/dev/null
sudo ls -la /var/lib/lido-csm/
df -h /
```

**確認できた結果：**
```
/var/lib/ethereum/          ← 空
/var/lib/lido-csm/
  ├── secrets/               ← 空
  ├── slashing_protection/   ← 空
  └── validators/            ← 空

Filesystem      Size  Used Avail Use% Mounted on
...             292G  8.4G  271G   4%  /
```

> ✅ **271GBの空き容量が確保できればPhase 1完了です。**

---

## 3. Phase 2：Nethermind（実行レイヤー）の構築

第3章と同じ手順です。

### ユーザー・ディレクトリ作成

```bash
sudo useradd --no-create-home --shell /bin/false nethermind
sudo mkdir -p /var/lib/nethermind
sudo chown -R nethermind:nethermind /var/lib/nethermind
```

### バイナリのインストール

```bash
RELEASE_URL="https://api.github.com/repos/NethermindEth/nethermind/releases/latest"
BINARIES_URL="$(curl -s $RELEASE_URL | jq -r '.assets[] | select(.name) | .browser_download_url' | grep linux-x64 | grep -v asc)"

cd ~
wget -O nethermind.zip $BINARIES_URL
sudo apt install -y unzip
sudo unzip nethermind.zip -d /usr/local/bin/nethermind
rm nethermind.zip

# バージョン確認
/usr/local/bin/nethermind/nethermind --version
```

**実測：**
```
Version: 1.38.1+9c365772
Runtime: .NET 10.0.7
Platform: Linux x64
```

> 💡 **`unzip` コマンドが見つからない場合：**
> Ubuntu Server 22.04の最小構成にはunzipが入っていないことがあります。
> `sudo apt install -y unzip` で導入してから解凍してください。

### JWT Secretの作成

```bash
sudo mkdir -p /secrets
openssl rand -hex 32 | tr -d "\n" | sudo tee /secrets/jwtsecret
sudo chmod 644 /secrets/jwtsecret
```

### systemdサービスの設定

```bash
sudo vi /etc/systemd/system/nethermind.service
```

```ini
[Unit]
Description=Nethermind Execution Layer Client service for Hoodi
Wants=network-online.target
After=network-online.target
Documentation=https://www.coincashew.com

[Service]
Type=simple
User=nethermind
Group=nethermind
Restart=always
RestartSec=3
KillSignal=SIGINT
TimeoutStopSec=900
WorkingDirectory=/var/lib/nethermind
Environment="DOTNET_BUNDLE_EXTRACT_BASE_DIR=/var/lib/nethermind"
ExecStart=/usr/local/bin/nethermind/nethermind \
  --config hoodi \
  --datadir="/var/lib/nethermind" \
  --Network.DiscoveryPort 30303 \
  --Network.P2PPort 30303 \
  --Network.MaxActivePeers 50 \
  --JsonRpc.Port 8545 \
  --JsonRpc.EnginePort 8551 \
  --Metrics.Enabled true \
  --Metrics.ExposePort 6060 \
  --JsonRpc.JwtSecretFile /secrets/jwtsecret

[Install]
WantedBy=multi-user.target
```

### 起動

```bash
sudo systemctl daemon-reload
sudo systemctl enable nethermind
sudo systemctl start nethermind
sudo systemctl is-active nethermind
```

```bash
# ログ確認（Ctrl+Cで終了）
sudo journalctl -fu nethermind
```

**起動直後の正常なログ：**
```
Chain ID: Hoodi
Peers: 4
Waiting for Forkchoice message from Consensus Layer to set fresh pivot block [10s]
```

> 💡 **これは正常な待機状態です。**
> CLクライアント（Nimbus）がまだ起動していないため、
> Nethermindは「指揮官」からの指示を待っています。
> 第1部・第3章でGeth/Nethermind単体起動時と同じ現象です。

---

## 4. Phase 3：Nimbus 統合構成（in-process validator）の構築

ここが第3章との最大の違いです。**サービスファイルが1つだけで完結します。**

### ユーザー・ディレクトリ作成・依存パッケージ

```bash
sudo adduser --system --no-create-home --group consensus
sudo mkdir -p /var/lib/nimbus
sudo chown -R consensus:consensus /var/lib/nimbus

sudo apt install libsnappy-dev libc6-dev libc6 ccze -y
```

> 💡 **第3章との違い：`/var/lib/nimbus-bn/`（BN専用空ディレクトリ）は不要です。**
> 統合構成ではBNとVCが同じディレクトリのkeystoreを正規に共有するため、
> 第3章で必要だったロック回避用のディレクトリは作成しません。

### バイナリのインストール

```bash
RELEASE_URL="https://api.github.com/repos/status-im/nimbus-eth2/releases/latest"
BINARIES_URL="$(curl -s $RELEASE_URL | jq -r '.assets[] | select(.name) | .browser_download_url' | grep _Linux_amd64 | grep -v asc)"

cd ~
wget -O nimbus.tar.gz $BINARIES_URL
tar -xzvf nimbus.tar.gz -C ~
mv ~/nimbus-eth2_Linux_amd64_* ~/nimbus
sudo mv ~/nimbus/build/nimbus_beacon_node /usr/local/bin
rm nimbus.tar.gz
rm -rf ~/nimbus

nimbus_beacon_node --version
```

**実測：**
```
Nimbus beacon node v26.5.0-6fb05f-stateofus
Ethereum consensus spec v1.7.0-alpha.7
```

> 💡 **統合構成では `nimbus_validator_client` バイナリは不要です。**
> `nimbus_beacon_node` という1つのバイナリ自体に、BN機能とVC機能の両方が
> 組み込まれています。第3章で使った `--in-process-validators=false` を
> 指定しなければ、デフォルトでこの統合動作になります。

### Checkpoint Syncで高速同期

```bash
sudo -u consensus /usr/local/bin/nimbus_beacon_node trustedNodeSync \
  --network=hoodi \
  --trusted-node-url=https://hoodi.beaconstate.ethstaker.cc \
  --data-dir=/var/lib/nimbus \
  --backfill=false
```

> ⚠️ **このコマンドは1回実行して終わるコマンドです。**
> ログが流れ続けるように見えますが、ストリーミング表示ではありません。
> `NTC Done, your beacon node is ready to serve you!` が出たら完了しており、
> 途中でCtrl+Cで止めてしまっても、実際にはバックグラウンドでは続行されず
> その時点までの処理が完了しています。気長に最後まで見届けてください。

**実測ログ（完了まで約3分）：**
```
NTC Starting trusted node sync
NTC Downloading checkpoint state
NTC Database initialized from genesis
NTC Checkpoint written to database
NTC Done, your beacon node is ready to serve you!
checkpoint=ee8e2854:3289440
```

### systemdサービスの設定（統合構成）

```bash
sudo vi /etc/systemd/system/nimbus.service
```

```ini
[Unit]
Description=Nimbus Consensus Layer Client (BN+VC integrated) service for Hoodi
Wants=network-online.target
After=network-online.target
Documentation=https://nimbus.guide

[Service]
Type=simple
User=consensus
Group=consensus
Restart=on-failure
RestartSec=3
KillSignal=SIGINT
TimeoutStopSec=900
ExecStart=/usr/local/bin/nimbus_beacon_node \
  --network=hoodi \
  --data-dir=/var/lib/nimbus \
  --tcp-port=9000 \
  --udp-port=9000 \
  --max-peers=100 \
  --rest-port=5052 \
  --enr-auto-update=true \
  --non-interactive \
  --status-bar=false \
  --web3-url=http://127.0.0.1:8551 \
  --rest \
  --metrics \
  --metrics-port=8008 \
  --jwt-secret="/secrets/jwtsecret" \
  --suggested-fee-recipient=0x9b108015fe433F173696Af3Aa0CF7CDb3E104258

[Install]
WantedBy=multi-user.target
```

> 💡 **第3章（分離構成）からの削除点：**
> `--in-process-validators=false`、`--validators-dir`、`--secrets-dir` を
> **指定していません。** これらは第3章でBNとVCを分離するために
> 必須だったオプションです。指定しないことで、デフォルトの統合動作になります。

### 起動

```bash
sudo systemctl daemon-reload
sudo systemctl enable nimbus
sudo systemctl start nimbus
sudo systemctl is-active nimbus
```

> ✅ **`active` 1つだけ確認すれば起動完了です。**
> 第3章では `nimbus` と `nimbus-vc` の2つを20秒間隔で順に確認する必要がありましたが、
> 統合構成ではこの手順がありません。

### 同期状態の確認

```bash
curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq
```

```bash
curl -s http://127.0.0.1:8545 -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' | jq
```

両方の出力で `false`（Nimbus側は `is_syncing: false, sync_distance: 0`）になれば同期完了です。

---

## 5. 【実録】フリーズトラブルとホストPC再起動

第3章でも経験したVMフリーズが、本章でも同期中に2回発生しました。

### 1回目のフリーズ

同期中（Nethermind: Snap State Ranges Phase 1 約61%まで進行時点）にVMが応答しなくなりました。

**調査コマンド：**
```bash
journalctl -b -1 --no-pager | tail -30
journalctl -b -1 --no-pager | grep -i "oom\|killed\|out of memory"
free -h
```

**結果：**
```
OOM検索 → 該当なし
Swap使用：68MB（軽微）
フリーズ直前まで正常にログが流れていた
```

> 💡 **OOM（メモリ不足）ではありませんでした。**
> このとき同時に別VM（testnetcsm）も稼働させていたため、
> ホストPC全体のリソース競合が原因と考えられます。

**対処：** testnetcsm2を再起動。同期はPhase 1（Snap State Ranges）まで後退して再開しました（完全にゼロからではなく、Pivotブロックは保持されていました）。

### 2回目の判断：testnetcsmを一時停止

再起動後もload averageが12台と高い状態が続いたため、根本対処として以下を実施しました。

```
① testnetcsm（鍵index 3・稼働中）を一時停止
② ホストPC自体を再起動（ブラウザ等のメモリ解放も含む）
```

**testnetcsmの安全停止：**
```bash
sudo systemctl stop nimbus-vc
sudo systemctl stop nimbus
sudo systemctl stop nethermind
sudo systemctl is-active nethermind nimbus nimbus-vc
```

> ⚠️ **唯一の稼働バリデータを止める判断について：**
> 第2章で確認した通り、Lido公式は1時間程度の停止は報酬に影響しないとしています。
> 今回は数時間規模の停止になりましたが、テストネット検証目的のため実害は軽微と判断しました。
> 本番環境ではこの判断は変わります。

**ホストPC再起動後の改善（実測）：**

| 項目 | 再起動前 | 再起動後 |
|---|---|---|
| load average | 12.06 | **5.96** |
| メモリ使用 | 6.3GB | **2.9GB** |
| Swap使用 | 68MB | **0B** |
| ピア数 | 5〜8 | **11** |

ホストPC再起動により、ブラウザ等の常駐プロセスのメモリも解放され、明らかにリソース状況が改善しました。この状態のまま一晩放置し、翌朝確認すると両クライアントとも完全同期が完了していました。

```bash
# 翌朝の確認結果
curl -s http://127.0.0.1:8545 -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' | jq
# → "result": false

curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq
# → is_syncing: false, sync_distance: "0", is_optimistic: false
```

> 💡 **教訓：複数VMを同時に長時間稼働させる検証では、ホストPCのリソースに余裕を持たせることが重要です。** 同期のような重い処理を行う際は、不要なVMを一時停止する判断も有効です。

### 【実録】後日判明した根本原因：VM割り当てメモリがホスト物理メモリと同値だった

上記の対応で同期は完了しましたが、後日改めてホストPC側のリソースを調査したところ、より根本的な原因が判明しました。

**ホストPCの総メモリを確認：**

```powershell
Get-CimInstance Win32_ComputerSystem | Select-Object TotalPhysicalMemory
```

```
TotalPhysicalMemory
-------------------
        34089136128
```

`34089136128 ÷ 1024³ ≈ 31.75GB`。**ホストPCの総メモリは約32GBでした。**

**両VMのメモリ割り当て設定を確認：**

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" showvminfo "lide_csm_testnet3" | findstr "Memory"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" showvminfo "lide_csm_testnet4" | findstr "Memory"
```

```
Memory size:                 16384MB
Memory size:                 16384MB
```

> ⚠️ **判明した根本原因：**
> ```
> ホストPC総メモリ：約32GB
> = testnetcsm（16GB）+ testnetcsm2（16GB）+ ホストOS用（0GB）
> ```
> **2台のVMへの割り当て合計が、ホストPCの物理メモリ総量と完全に同値でした。** ホストOS自体やブラウザ等の常駐プロセスが使う余地がほぼゼロの設定になっていたことが、繰り返しフリーズの根本原因だったと考えられます。
> 実際にこの時点でのホストPC側の空きメモリは `Get-Counter '\Memory\Available MBytes'` で確認すると **2304MB（約2.3GB）** しかありませんでした。

### 対策：VM割り当てメモリを12GB×2に変更

ホストOS用に8GB程度の余裕を持たせる方針で、両VMを16GB→12GBに変更しました。

**両VMを安全に停止（OSアップデートも兼ねる）：**

```bash
sudo apt update && sudo apt upgrade -y
sudo systemctl stop nimbus       # testnetcsm2は nimbus のみ
sudo systemctl stop nimbus-vc    # testnetcsmのみ追加で停止
sudo systemctl stop nethermind
sudo systemctl poweroff
```

**メモリ設定の変更（VBoxManageコマンド・GUI操作不要）：**

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm "lide_csm_testnet3" --memory 12288
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm "lide_csm_testnet4" --memory 12288
```

> 💡 **VirtualBoxマネージャーのGUIで1台ずつ「設定」を開く必要はありません。**
> `VBoxManage modifyvm` コマンドなら2台分の変更が一瞬で完了します。
> （`VBoxManage` が見つからない場合は `C:\Program Files\Oracle\VirtualBox\VBoxManage.exe` のフルパスで実行してください。）

**変更後の確認：**

```
Memory size:                 12288MB
Memory size:                 12288MB
```

GUI（VirtualBoxマネージャー）の詳細画面でも、メインメモリーが正しく12288MBに変わっていることを確認しました。

### 変更後の起動・安定性確認

両VMを起動し、再同期を確認しました。

```bash
echo "=== Host ===" && hostname && echo "" && echo "=== Memory ===" && free -h && echo "" && echo "=== Sync ===" && curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq && echo "" && echo "=== Validator Duties ===" && sudo journalctl -u nimbus -n 3 --no-pager | grep "Slot start"
```

**起動直後（再起動の影響で一時的にズレあり）：**
```
testnetcsm2： sync_distance: "24"、is_optimistic: true
testnetcsm ： sync_distance: "27"、sync="almost synced"
```

**60秒後（自動的に解消）：**
```bash
sleep 60 && curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq
```
```
両VMとも sync_distance: "0"、is_optimistic: false ✅
```

**ホストPC側メモリの改善：**

```powershell
Get-Counter '\Processor(_Total)\% Processor Time', '\Memory\Available MBytes'
```

| 項目 | 変更前（16GB×2） | 変更後（12GB×2） |
|---|---|---|
| ホストPC Available Memory | 2304MB | **6109MB** |

Windowsタスクマネージャーで内訳を確認すると、VirtualBox VM 2台で実際に使用していたのは約7.8GBずつ（設定上限の12GBまでは使っていない）、Google Chromeも約3GB使用していました。

> 💡 **発見：VMは設定した最大値を常に使い切るわけではありません。**
> 16GB設定時点でも通常時の実使用量はもっと少なかったはずですが、Nethermind/Nimbusの同期処理がスパイク的に高いメモリを要求する瞬間があり、その瞬間にホストOS側の余裕がゼロだったことが、繰り返しフリーズを引き起こしていたと考えられます。
>
> **教訓：VMのメモリ割り当ては「平常時の使用量」ではなく「ホストPCの物理メモリに対する余裕」で決めるべきです。** 目安として、ホストOS用に物理メモリの2割程度（今回は32GBに対し8GB）を残すと安定しました。

---

## 6. Phase 4：新規鍵の生成（index 4）

### 既存のCLIツールを再利用

```bash
ls ~/csm-artifacts/ 2>/dev/null || echo "csm-artifactsが存在しません"
```

第3章で使ったディレクトリが残っていたため、再ダウンロードせず再利用しました。

```bash
ls ~/csm-artifacts/ethstaker_deposit-cli-d8016bc-linux-amd64/validator_keys/
```

> ⚠️ **古い鍵ファイルが残っている場合は削除してください。**
> 今回は引退済みのindex 2の鍵ファイル（`keystore-m_12381_3600_2_0_0-...json`）が
> 残っていたため、新しい鍵の生成前に削除しました。

```bash
rm ~/csm-artifacts/ethstaker_deposit-cli-d8016bc-linux-amd64/validator_keys/deposit_data-<旧タイムスタンプ>.json
rm ~/csm-artifacts/ethstaker_deposit-cli-d8016bc-linux-amd64/validator_keys/keystore-m_12381_3600_2_0_0-<旧タイムスタンプ>.json
```

### 鍵の生成（index 4・日本語インターフェースでの実録）

```bash
cd ~/csm-artifacts/ethstaker_deposit-cli-d8016bc-linux-amd64/
./deposit existing-mnemonic \
  --num_validators 1 \
  --validator_start_index 4 \
  --chain hoodi \
  --eth1_withdrawal_address 0x4473dCDDbf77679A643BdB654dbd86D67F8d32f2
```

> 💡 **今回は日本語インターフェース（`7`を選択）で実行しました。**
> ただし全てのメッセージが日本語化されているわけではなく、
> 一部の警告文（インターネット接続警告・withdrawal address確認）は
> 英語のまま表示されました。

**実際の対話フロー（日英混在の実録）：**

| プロンプト（表示言語） | 入力 |
|---|---|
| `Please choose your language` | `7`（日本語） |
| `*** Internet connectivity detected ***`（英語） | 任意のキー |
| `さらにキーの生成を開始するインデックス...`（日本語） | `4` |
| `確認のために繰り返し入力してください` | `4` |
| `Repeat your withdrawal address for confirmation.`（英語） | `0x4473dCDDbf77679A643BdB654dbd86D67F8d32f2` |
| `スペースで区切られたニーモニックを入力してください` | （24単語） |
| `キーストアを保護するパスワード` | （パスワード入力） |
| `確認のために繰り返し入力してください` | （同じパスワード再入力） |
| `Please enter yes if you want to generate compounding validators...`（英語） | Enterキー（no） |

> ⚠️ **1回目はパスワード確認で `Aborted!` になり失敗しました。**
> パスワードの再入力時にタイプミスがあったと考えられます。
> 2回目は確実に同じパスワードを入力し、成功しました。

**成功時の出力：**
```
Creating your keys.
Creating your keys:               1/1
Creating your keystore-*.json file(s): 1/1
Creating your deposit_data-*.json file(s): 1/1
Verifying your keystore-*.json file(s): 1/1
Verifying your deposit_data-*.json file(s): 1/1
Success!
```

### 生成結果の確認

```bash
ls ~/csm-artifacts/ethstaker_deposit-cli-d8016bc-linux-amd64/validator_keys/
```

**出力：**
```
deposit_data-1781736855.json
keystore-m_12381_3600_4_0_0-1781736855.json
```

> ✅ **`4_0_0` がファイル名に含まれていることを確認してください。** これが index 4 の証拠です。

---

## 7. Phase 5：鍵のインポートとサービス再起動

### インポート（/tmp経由）

```bash
sudo mkdir -p /tmp/keys_import
sudo cp -r ~/csm-artifacts/ethstaker_deposit-cli-d8016bc-linux-amd64/validator_keys /tmp/keys_import/
sudo chown -R consensus:consensus /tmp/keys_import

sudo -u consensus /usr/local/bin/nimbus_beacon_node deposits import \
  --data-dir=/var/lib/nimbus \
  /tmp/keys_import/validator_keys

sudo rm -rf /tmp/keys_import
```

**成功メッセージ：**
```
NTC Keystore imported
file=/tmp/keys_import/validator_keys/keystore-m_12381_3600_4_0_0-1781736855.json
```

### サービス再起動（これだけで鍵が認識される）

```bash
sudo systemctl restart nimbus
sudo systemctl is-active nimbus
```

> 💡 **第3章との決定的な違いがここです。**
>
> | 構成 | 鍵追加の手順 |
> |---|---|
> | 第3章（分離構成） | VC停止 → インポート → BN起動確認 → 20秒待機 → VC起動 |
> | 第5章（統合構成） | インポート → `systemctl restart nimbus` のみ |
>
> 統合構成では起動順序を気にする必要が一切ありません。

### 【実録】再起動直後の一時的な警告

```bash
sudo journalctl -fu nimbus | grep -i "validator\|attestation"
```

**再起動直後に表示されたログ：**
```
Execution client not in sync; skipping validator duties for now
```

> 💡 **これは一時的な状態でした。**
> Nethermind自体は `eth_syncing: false`（同期完了済み）でしたが、
> Nimbus再起動直後はELとの同期確認がリセットされ、
> 数分後に自動的に解消されました。

**数分後の正常化ログ：**
```
sync=synced peers=10〜11
```

---

## 8. Phase 6：Lido CSMへの登録

### deposit_dataの確認・登録

```bash
cat ~/csm-artifacts/ethstaker_deposit-cli-d8016bc-linux-amd64/validator_keys/deposit_data-1781736855.json
```

`csm.testnet.fi` のウィジェットに `[` `]` を含めて貼り付けます。

### 【実録】必要ボンドが32 ETHではなかった

登録画面で表示されたETH量は次の通りでした。

```
Excess bond: 0.0015 stETH
ETH amount: 1.298434911362121417 ETH
```

> 💡 **Lido CSMでは、鍵1本あたり32 ETH全額を用意する必要はありません。**
> 必要なのは「ボンド（担保）」のみで、公式パラメータ（`csm.lido.fi/type/parameters`）では
> Default（DEF）タイプの場合、以下のボンド額が定められています。
>
> | 対象 | ボンド額 |
> |---|---|
> | 1本目の鍵 | 2.4 ETH |
> | 2本目以降の鍵 | 1.3 ETH |
>
> 今回は5本目の鍵（index 4）の追加だったため「2本目以降」の単価が適用され、
> 実測1.298 ETHとほぼ一致しました。残りの大部分（約30.7 ETH）は
> Lidoプロトコル側が補填する仕組みです（第1部参照）。
> これがLido CSMの最大のメリットで、個人運用者でもホームステーキングに
> 参加しやすくしています。

トランザクション承認後の結果：

```
Your keys have been uploaded
Uploading operation was successful.
```

### CSM Sentinel通知（実録）

```
👀 New keys uploaded
Keys count: 4 -> 5
nodeOperatorId: <your_node_operator_id>
```

> 💡 **「4 -> 5」の意味：**
> 第2章のスラッシング済み2本＋第4章の引退済み1本＋testnetcsm稼働中1本＝4本
> （登録の集計対象になっている既存鍵の数）に、今回のindex 4が追加され5本になりました。

---

## 9. 【実録】Active化〜アテステーション成功確認

deposit登録（New keys uploaded）から約半日後に「Keys were deposited」通知を受信し、その後Active化を待ちました。

**CSM Sentinel通知の流れ：**

```
👀 New keys uploaded（登録当日朝）
    ↓ 約半日
🤩 Keys were deposited
Deposited keys count: 4 -> 5
    ↓ 約1日
Active（Lido CSMダッシュボードで確認）
```

> 💡 **第3章実測（登録から約2日でActive）と比較すると、今回はやや早めでした。**
> Active化までの時間はテストネットの混雑状況に依存するため、目安として参考にしてください。

### Active化の確認

Lido CSMダッシュボード（`csm.testnet.fi`）の Keys 画面で確認：

```
0x879709...efc5a789 → Active ✅
```

### アテステーション成功ログ

```bash
sudo journalctl -u nimbus --since "23:08:00" --until "23:09:30" --no-pager | grep -i "attestation"
```

**実測ログ（1回目の署名）：**
```
NTC Slot end ... nextAttestationSlot=3300891
NTC Attestation sent  topics="message_router"
  attestation="(committee_index: 40, attester_index: 1424491,
  data: (slot: 3300891, ...), signature: 8729c500)"
  delay=-476ms912us848ns subnet_id=40
NTC Slot end ... nextAttestationSlot=3300919
```

> 💡 **ログの文言が第3章と異なります。**
> 第3章（分離構成・`nimbus-vc`サービス）では `Attestation published`、
> 本章（統合構成・`nimbus`サービスの`message_router`トピック）では
> `Attestation sent` という表記でした。同じ「署名成功」を意味しますが、
> サービス構成によってログの出どころ・文言が変わる点は、ログを読む際の
> 注意点として記録しておきます。

**2回目の署名（次のエポックでも継続成功）：**
```bash
sudo journalctl -u nimbus -n 30 --no-pager | grep -i "attestation sent"
```
```
NTC Attestation sent
  attestation="(... data: (slot: 3300919, ...), signature: b49f6a8b)"
  delay=1s156ms308us89ns subnet_id=58
```

> ✅ **`attester_index: 1424491`（鍵index 4のバリデータインデックス）が、
> 連続するエポックでアテステーションに成功していることを確認しました。**
> これで第5章の検証は完了です。

### 【実録】Active化直後の一時的な警告

Active化直後のログには、以下の警告も一度だけ見られました。

```
NTC Previous epoch attestation missing
topics="chaindag" epoch=103151 validator=87970927
```

> 💡 **Active化してから最初のエポックでは、まだ署名履歴が無いため
> 一時的にこの警告が出ることがあります。** 直後のエポック以降は
> 正常にアテステーションが送信され続けたため、問題ありませんでした。

---

## 10. 【参考値】testnetcsm vs testnetcsm2 リソース・署名遅延の実測比較

両VM・両鍵が同時に稼働している状態で、参考値として比較データを記録します。

> ⚠️ **この比較は厳密な優劣判定ではありません。**
> 以下の理由から、構成（分離 vs 統合）そのものの性能差を示すものではなく、
> あくまで参考値として捉えてください。
> - **稼働期間が異なる**：testnetcsm（鍵index 3）は数週間の安定稼働後、
>   testnetcsm2（鍵index 4）はActive化からまだ数時間
> - **1回のスナップショット測定**：時系列の平均ではなく、ある瞬間の値
> - **VM環境**：ホストPC上で2台が同時稼働しており、相互のリソース競合の
>   影響を受ける
> - **異なるバリデータ**：committee割り当てやピアの構成も完全には同一でない

### リソース比較（測定コマンド）

```bash
echo "=== Resource ===" && free -h && echo "" && top -bn1 | head -12 && echo "" && echo "=== Disk ===" && df -h /
```

| 項目 | testnetcsm（分離構成） | testnetcsm2（統合構成） |
|---|---|---|
| Nimbus CPU | 90.5% | 133.3% |
| Nimbus メモリ（RES） | 3.2GB | 3.1GB |
| Nethermind CPU | 28.6% | 41.7% |
| Nethermind メモリ | 1.5GB | 1.4GB |
| 全体使用メモリ | 5.0GB | 4.7GB |
| load average | 0.73 | 0.77 |
| ディスク使用 | 113GB | 118GB |

### 署名遅延（delay）比較

```bash
# testnetcsm（分離構成）
sudo journalctl -u nimbus-vc --no-pager | grep "Attestation published" | tail -5

# testnetcsm2（統合構成）
sudo journalctl -u nimbus --no-pager | grep "Attestation sent" | tail -5
```

| | testnetcsm（分離構成） | testnetcsm2（統合構成） |
|---|---|---|
| delay 1 | -67ms | -161ms |
| delay 2 | 363ms | 306ms |
| delay 3 | -196ms | **-3805ms** |
| delay 4 | 45ms | -476ms |
| delay 5 | 46ms | 1156ms |

> 💡 **testnetcsm2の `-3805ms` という大きな値について：**
> マイナスのdelayは「予定時刻より早く送信した」ことを意味しますが、
> 3.8秒も早いのは明らかな異常値です。記録した時刻（22:57:36）は
> Active化から1時間も経っていないタイミングであり、**統合構成自体の
> 問題ではなく、稼働初期特有の一時的な不安定さ**と考えられます。

### ホストPC側のリソース（参考）

```powershell
Get-Counter '\Processor(_Total)\% Processor Time', '\Memory\Available MBytes'
Get-Process | Where-Object {$_.ProcessName -like "*VirtualBox*"} | Select-Object ProcessName, Id, @{Name="Memory(MB)";Expression={[math]::Round($_.WorkingSet64/1MB,1)}}, CPU
```

```
ホストPC CPU使用率：29.1%
ホストPC Available Memory：5138MB（約5GB）

VirtualBox VMプロセス別メモリ：
  testnetcsm相当：約6.7GB
  testnetcsm2相当：約5.7GB
  累積CPU時間：両VMともほぼ同等（約12.9時間）
```

> ✅ **12GB×2（24GB）設定にした効果が確認できました。**
> 両VM同時稼働中でもホストPC側に約5GBの余裕が残っており、
> 第5章前半で発生したフリーズのような状況は再発していません。

### 結論：今回の比較データから言えること

```
✅ 確認できたこと：
  両構成とも正常にアテステーションを継続できている
  ホストPCのメモリ配分（12GB×2）が安定稼働の土台になっている

❌ 判断できないこと：
  リソース効率・署名精度の構成間の優劣
  （公平な比較には、稼働期間を揃えた長期データが必要）
```

> 💡 **構築・運用面の「手間の差」（セクション12参照）は明確に統合構成が
> 優れていましたが、稼働中の性能面の優劣については、今回のデータでは
> 結論を出さないことが誠実な姿勢だと考えます。** 興味のある読者は、
> 本書のコマンドを参考に、ご自身の環境で稼働期間を揃えた比較を
> 試してみてください。

---

## 11. 確認コマンド一覧（読者自身が再現する用）



本章の状態を再現・確認するための主要コマンドをまとめます。

```bash
# サービス稼働確認
sudo systemctl is-active nethermind nimbus

# Nethermind同期確認
curl -s http://127.0.0.1:8545 -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' | jq

# Nimbus同期確認
curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq

# アテステーション・バリデータ状況確認
sudo journalctl -u nimbus -n 50 --no-pager | grep -i "validator\|attestation"

# リソース確認
free -h
top -bn1 | head -15
df -h /

# OOM発生確認（フリーズ調査用）
journalctl -b -1 --no-pager | grep -i "oom\|killed"
```

---

## 12. まとめ：分離構成 vs 統合構成

| 観点 | 第3章（分離構成） | 第5章（統合構成） |
|---|---|---|
| サービスファイル数 | 2つ（nimbus + nimbus-vc） | **1つ（nimbus）** |
| 鍵追加の手順 | VC停止→インポート→起動順序を守って再起動 | **インポート→restartのみ** |
| keystoreロック問題 | 発生（BN用空ディレクトリで回避が必要） | **発生しない** |
| 起動順序の制約 | BN起動確認→20秒待機→VC起動 | **制約なし** |
| Nimbus公式の位置づけ | 上級者向け・リスク高 | **公式推奨構成** |
| リソース効率 | 同程度 | 同程度 |

> ✅ **今回の検証で、Nimbus公式が統合構成を推奨する理由を実感できました。**
> 分離構成で発生した「keystoreロックエラー」「VMフリーズ」「起動順序ミス」は、
> いずれも統合構成では発生しませんでした。リソース効率に大きな差はないため、
> ホームステーキングにおいては**まず統合構成を試し、分散運用などの
> 特別な理由がある場合のみ分離構成を検討する**のが合理的だと考えられます。

---

> 💡 **第4部・第6章へ続く（執筆予定）**
