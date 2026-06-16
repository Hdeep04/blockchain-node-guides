# 第4部・応用編 第4章：Voluntary Exit（バリデータの正規引退）

> **バリデータを正しい手順で引退させる実録**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第4部・応用編の第4章。バリデータを正規に引退させる手順と記録 |
| 検証環境 | VirtualBox VM（Ubuntu Server 22.04 LTS）× 1台（testnetcsm2） |
| 前提 | 第3章・マイノリティクライアント移行が完了していること |
| 検証日 | 2026年6月16日（Hoodi Testnet） |

> ⚠️ **本書は機密情報を一切含みません。** アドレス類は `<...>` のプレースホルダです。

> 💡 **リンクは右クリック→「新しいタブで開く」を選択すると
> 手順書を表示したまま参照先を確認できます。**

---

## 1. Voluntary Exit とは何か

Voluntary Exit（自発的退出）は、バリデータをEthereumネットワークから**正規の手順で引退させる**仕組みです。

### スラッシングによる強制退出との違い

第2章では「スラッシング」によってバリデータが強制退出されるケースを体験しました。今回はその対極にある「正規の引退」を検証します。

| 項目 | スラッシング（第2章） | Voluntary Exit（本章） |
|---|---|---|
| 原因 | 二重署名（ルール違反） | オペレーターの意思 |
| ペナルティ | あり（残高削減） | なし |
| 強制力 | ネットワークが強制 | オペレーターが申請 |
| 引退後の扱い | Slashedとして記録 | Exitedとして記録 |
| 残高引き出し | 36日後（Withdrawable） | 一定期間後（Withdrawable） |

### なぜVoluntary Exitが必要か

バリデータを「ただ止める」だけでは引退になりません。

```
サービスを停止しただけの場合：
  ネットワーク上のバリデータは「オフライン」扱い
  → 署名ミス（Missed Attestation）が積み上がる
  → ペナルティが発生し続ける
  → 残高が減り続ける

Voluntary Exitを実施した場合：
  ネットワークに「引退申請」を送信
  → active_exiting → exited に遷移
  → 署名義務がなくなる
  → ペナルティが発生しない
```

> 💡 **Voluntary Exitは「ネットワークへの正式な辞表提出」です。**
> 辞表を出さずにただ出社しなくなると欠勤ペナルティが発生するのと同じです。

### 本章の検証構成

```
【検証環境】

testnetcsm2（稼働中）
  クライアント：Geth + Lighthouse
  鍵（index 2）：active_ongoing
  引退対象：この鍵をVoluntary Exitで引退させる

testnetcsm（停止中）
  クライアント：Nethermind + Nimbus
  鍵（index 3）：active_ongoing・アテステーション中
  → 引退後の「後継者」として継続稼働
```

---

## 2. 引退前の確認手順

引退コマンドを実行する前に、対象のバリデータ情報を正確に確認します。

### サービスの稼働確認

```bash
sudo systemctl is-active geth lighthouse lighthouse-vc.service
```

**期待する出力：**
```
active
active
active
```

### 稼働中バリデータの公開鍵を確認する

```bash
TOKEN=$(sudo cat /var/lib/lido-csm/validators/api-token.txt)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:5062/lighthouse/validators | jq '.data[].voting_pubkey'
```

**出力例：**
```
"0xb6b94fc9ed77c57bda08df0614bf3a83a716aa4779d9e3284a113baaa25536662ba1c7424b2ab6d51782f9868d2e4ace"
```

> 💡 **このAPIは第2部で設定した `--http-port 5062` から取得しています。**
> lighthouse-vc.service に `--http` と `--unencrypted-http-transport` が
> 設定されていることが前提です。

### バリデータインデックスとステータスを確認する

公開鍵からネットワーク上のインデックス番号とステータスを確認します。

```bash
curl -s http://127.0.0.1:5052/eth/v1/beacon/states/head/validators/0x<your_pubkey> \
  | jq '{index: .data.index, status: .data.status}'
```

**出力例：**
```json
{
  "index": "1422277",
  "status": "active_ongoing"
}
```

| 項目 | 意味 |
|---|---|
| `index` | ネットワーク上のバリデータID（beaconcha.inでの検索に使用） |
| `active_ongoing` | 正常稼働中・署名中 ✅ |

### keystoreファイルのパスを確認する

引退コマンドにはkeystoreファイルのパスが必要です。

```bash
sudo find /var/lib/lido-csm/validators -name "*.json" | grep -v slashing
```

**出力例：**
```
/var/lib/lido-csm/validators/0xb6b94fc.../keystore-m_12381_3600_2_0_0-1781277236.json
/var/lib/lido-csm/validators/validator_key_cache.json
```

> 💡 **ファイル名の読み方：**
> `keystore-m_12381_3600_2_0_0-XXXXXXXXXX.json`
>
> | 部分 | 意味 |
> |---|---|
> | `12381` | BLS12-381（Ethereumの署名方式） |
> | `3600` | EIP-2334のバリデータ用パス番号 |
> | `2` | このニーモニックから生成した鍵のインデックス（index 2） |
> | `0_0` | signing key / バリデータ鍵のサブパス |
> | `XXXXXXXXXX` | 生成タイムスタンプ |

> 💡 **`| grep -v slashing` について：**
> `slashing_protection.sqlite` は検索対象から除外しています。
> 引退コマンドに必要なのはkeystoreファイル（`.json`）だけです。

---

## 3. Voluntary Exit の実行

### コマンドの構造を理解する

```bash
sudo lighthouse account validator exit \
  --network hoodi \
  --beacon-node http://127.0.0.1:5052 \
  --datadir /var/lib/lido-csm \
  --keystore <keystoreファイルのフルパス>
```

| オプション | 意味 |
|---|---|
| `lighthouse account validator exit` | lighthouseバイナリの管理コマンド（サービスとは別に手動実行） |
| `--network hoodi` | Hoodi テストネットに接続 |
| `--beacon-node` | ローカルのBeacon Nodeに接続して引退メッセージをブロードキャスト |
| `--datadir` | バリデータデータディレクトリ（スラッシング保護DBの参照に使用） |
| `--keystore` | 引退させるバリデータのkeystoreファイルを指定 |

> 💡 **`lighthouse account validator exit` は「一回だけ実行する管理コマンド」です。**
> `lighthouse bn`（Beacon Node）や `lighthouse vc`（Validator Client）は
> systemdで常時起動しますが、このコマンドは引退申請のために
> 1回だけ手動実行します。
> 引退メッセージはBeacon Node経由でEthereumネットワーク全体に
> ブロードキャストされ、チェーンに記録されます。

### 【実録】eligible期間エラー

引退コマンドを実行したところ、以下のメッセージが表示されました。

```
No logfile path provided, logging to file is disabled
Running account manager for hoodi network
validator-dir path: "/var/lib/lido-csm/validators"
Enter the keystore password for validator in "...":
Password is correct.
Validator 0xb6b94fc... is not eligible for exit.
It will become eligible on epoch 102612
```

**このメッセージの意味：**

```
Validator 0xb6b94fc... is not eligible for exit.
It will become eligible on epoch 102612
↑
「このバリデータはまだ引退申請できません。
 epoch 102612 から申請可能になります。」
```

> 💡 **なぜ引退申請に待機期間があるのか：**
> Ethereumには「最低アクティブ期間（Shard Committee Period）」のルールがあります。
> バリデータがActiveになってから一定のエポック数（約256 epoch）が
> 経過しないと引退申請を受け付けません。
> これはバリデータが署名義務を果たさずにすぐ退出する行為を防ぐためです。

**待機時間の計算（実測）：**

| 項目 | 値 |
|---|---|
| 確認時のエポック | 102486 |
| 引退可能エポック | 102612 |
| 残りエポック数 | 102612 - 102486 = **126 epoch** |
| 1エポックの時間 | 約6.4分 |
| 待機時間の目安 | 126 × 6.4分 ≈ **約13時間** |

> 💡 **引退申請できるまで待つだけでOKです。**
> この間もtestnetcsm2は通常通り稼働・署名し続けます。
> epoch 102612 以降に同じコマンドを再実行してください。

### Voluntary Exit の実行（epoch 102612 以降）

```bash
sudo lighthouse account validator exit \
  --network hoodi \
  --beacon-node http://127.0.0.1:5052 \
  --datadir /var/lib/lido-csm \
  --keystore /var/lib/lido-csm/validators/0xb6b94fc9ed77c57bda08df0614bf3a83a716aa4779d9e3284a113baaa25536662ba1c7424b2ab6d51782f9868d2e4ace/keystore-m_12381_3600_2_0_0-1781277236.json
```

実行するとパスワードの入力と確認文字列の入力が求められます。

```
Enter the keystore password for validator in "...":
→ keystoreのパスワードを入力

Publishing a voluntary exit for validator: 0xb6b94fc...
WARNING: THIS IS AN IRREVERSIBLE OPERATION
PLEASE VISIT https://lighthouse-book.sigmaprime.io/validator_voluntary_exit.html
TO MAKE SURE YOU UNDERSTAND THE IMPLICATIONS OF A VOLUNTARY EXIT.
Enter the exit phrase from the above URL to confirm the voluntary exit:
→ Exit my validator
```

> ⚠️ **この操作は元に戻せません。**
> 確認文字列 `Exit my validator` を入力した時点で
> 引退申請がネットワークにブロードキャストされます。

**成功時の出力（実測ログ）：**

```
No logfile path provided, logging to file is disabled
Running account manager for hoodi network
validator-dir path: "/var/lib/lido-csm/validators"
Enter the keystore password for validator in "...":
Password is correct.
Publishing a voluntary exit for validator: 0xb6b94fc...
WARNING: THIS IS AN IRREVERSIBLE OPERATION
PLEASE VISIT https://lighthouse-book.sigmaprime.io/validator_voluntary_exit.html
TO MAKE SURE YOU UNDERSTAND THE IMPLICATIONS OF A VOLUNTARY EXIT.
Enter the exit phrase from the above URL to confirm the voluntary exit:
Exit my validator
Successfully validated and published voluntary exit for validator 0xb6b94fc...
Waiting for voluntary exit to be accepted into the beacon chain...
```

| ログメッセージ | 意味 |
|---|---|
| `Password is correct.` | keystoreパスワード認証成功 ✅ |
| `Publishing a voluntary exit` | 引退申請をネットワークに送信中 |
| `Successfully validated and published` | 引退申請がネットワークに受理された ✅ |
| `Waiting for voluntary exit to be accepted` | ビーコンチェーンへの取り込みを待機中 |

---

## 4. 引退後のステータス変化（観察記録）

### beaconcha.in でのステータス遷移

引退申請後、バリデータのステータスは以下の順で変化します。

```
active_ongoing
    ↓ 引退申請受理
active_exiting
    ↓ 引退キュー処理完了
exited（Withdrawable待ち）
    ↓ 一定期間後
Withdrawable
```

| ステータス | 意味 |
|---|---|
| `active_ongoing` | 正常稼働中・署名中 |
| `active_exiting` | 引退申請受理・署名義務継続（キュー消化まで） |
| `exited` | 引退完了・署名義務なし |
| `withdrawal_possible` | 残高の引き出しが可能 |

> 💡 **`active_exiting` の間も署名義務は続きます。**
> 引退キューが消化されるまでの間は
> アテステーションを継続する必要があります。
> ノードを止めてはいけません。

### 各ステータスでの確認コマンド

```bash
# 現在のステータスをAPIで確認する
curl -s http://127.0.0.1:5052/eth/v1/beacon/states/head/validators/<validator_index> \
  | jq '{index: .data.index, status: .data.status, balance: .data.balance}'
```

**出力例（引退申請後）：**
```json
{
  "index": "1422277",
  "status": "active_exiting",
  "balance": "32001234567"
}
```

> 💡 **balanceの単位はGwei（1 ETH = 1,000,000,000 Gwei）です。**
> `32001234567 Gwei` ≈ `32.001 ETH`

**beaconcha.inで確認：**

📎 `https://hoodi.beaconcha.in/validator/<validator_index>`

（ステータス変化の実録スクリーンショットは exited 確認後に追記予定）

---

## 5. Lido CSM への影響

### Voluntary Exit後のLido CSMでの扱い

Voluntary Exitを実施すると、Lido CSMのダッシュボードでも変化が現れます。

| 項目 | 変化 |
|---|---|
| Keys ステータス | Active → Exiting → Exited |
| Bond | 引退完了後に返還 |
| ペナルティ | なし（正規引退のため） |

> 💡 **Lido CSMへの手動通知は不要です。**
> スマートコントラクトが自動的に処理します。

---

## 6. まとめ

| 知見 | 内容 |
|---|---|
| Voluntary Exitとスラッシングの違い | 正規引退はペナルティなし・Exited記録 |
| ただ止めるだけではダメ | 停止のみだとMissed Attestationペナルティが発生し続ける |
| keystoreファイルのパス | `find`コマンドで実際のパスを確認してから実行する |
| eligible期間 | Activeから約256 epoch経過後に引退申請可能 |
| 待機時間の計算 | 残りepoch数 × 6.4分で推定できる |
| active_exiting中も稼働継続 | 引退申請後もキュー消化まで署名義務がある |
| Lido CSMへの手動通知不要 | スマートコントラクトが自動処理 |

---

> 💡 **第4部・第5章へ続く（執筆予定）**
> 次章ではNimbus統合構成（in-process validator・公式推奨構成）を
> testnetcsmで構築し、第3章の分離構成と比較検証します。
