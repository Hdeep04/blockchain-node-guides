# 第5部・メインネット移行編 第3章 本業10鍵のVoluntary Exit実践記録 — 半年間の運用に、正規の手順で幕を下ろす

> **VMでの検証から始まった半年間の運用が、10本すべて正規引退という形で完結した**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第5部第1章のロードマップ「②本業10鍵の正式なVoluntary Exit」の実施記録 |
| 実施日 | 2026年8月14日 |
| 対象 | Hoodiテストネット、Lido CSM本業10鍵 |
| 前提 | 第4部第4章（Voluntary Exit）、第5部第2章（SSVクラスター引退） |

> ⚠️ 本章は機密情報を一切含みません。

---

## 1. 実施前の確認

第4部第4章で確立した手順に沿って、まず10鍵それぞれの公開鍵・インデックス・keystoreパスを一覧化しました。

```bash
TOKEN=$(sudo cat /var/lib/lido-csm/validators/api-token.txt)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:5062/lighthouse/validators | jq '.data[].voting_pubkey'
```

続けて、各鍵のインデックスとステータスを一括確認するシェルループを組み、10鍵すべてが `active_ongoing` で、eligible期間の問題（第4章で遭遇した「まだ引退できません」エラー）が起きない状態であることを確認しました。長期間稼働してきた鍵だったため、今回はeligibleエラーは一件も発生しませんでした。

## 2. Exit実行 — 1鍵ずつ、10回

### なぜ自動化せず、1鍵ずつ実行したか

Lighthouseの`lighthouse account validator exit`コマンドは、`--keystore`オプションで1ファイルしか指定できない仕様です。ループ処理とパスワードの自動入力（`expect`等）を組み合わせれば技術的には一括実行も可能ですが、あえて避けました。

理由は2つです。

1. 各鍵ごとに「不可逆な操作である」という警告と確認文字列の入力が挟まる設計は、意図的な安全装置と考えられる。1鍵ずつ人の目で確認するプロセスを自動化で飛ばすと、想定外の状態に気づかないまま実行されるリスクがある
2. パスワードをスクリプトやコマンド履歴に平文で残したくない

結果として、10鍵分を1本ずつ、以下の形式で実行しました。

```bash
sudo lighthouse account validator exit \
  --network hoodi \
  --beacon-node http://127.0.0.1:5052 \
  --datadir /var/lib/lido-csm \
  --keystore <各鍵のkeystoreファイルのフルパス>
```

パスワード入力 → `Exit my validator` の確認文字列入力、という流れを10回繰り返し、すべて成功しました。

### 【実録】Exit epochを含む詳細出力

いずれの鍵の実行時も、成功メッセージに続けて、詳細な情報が表示されました。

```
Voluntary exit has been accepted into the beacon chain, but not yet finalized.
Finalization may take several minutes or longer. Before finalization there is
a low probability that the exit may be reverted.
Current epoch: 115883, Exit epoch: 115888, Withdrawable epoch: 116144
Please keep your validator running till exit epoch
Exit epoch in approximately 1920 secs
```

> 💡 **なぜ「まだファイナライズされていない」という警告が出るのか：** Ethereumのブロックチェーンは、ブロックが作られた直後は「一応記録された」状態ですが、複数epochを経て「ファイナライズ（確定）」されるまでは、理論上ごく低い確率で覆る可能性があります。Exit申請も例外ではなく、この一文はその仕組みを反映したものです。

### コマンド実行にかかる時間について

1回の実行につき、体感で約20秒程度かかりました。これは単なる「送信」ではなく、ローカルのBeacon Node経由でP2Pネットワークへブロードキャストし、実際にネットワークに受理されたことを確認してからコマンドが結果を返す、という仕組みによるものです。Ethereumのvoluntary exitはガス代のかかるトランザクションではなく、署名済みメッセージをP2Pで伝播させる仕組みのため、EVMトランザクションとは性質が異なります。

## 3. ステータス遷移の観察

10鍵とも、Exit申請直後は `active_exiting` に遷移しました。

```bash
curl -s http://127.0.0.1:5052/eth/v1/beacon/states/head/validators/<pubkey> \
  | jq '{index: .data.index, status: .data.status}'
```

Exit epoch到達を待つ間、`finality_checkpoints` エンドポイントで進捗を確認しました。

```bash
curl -s http://127.0.0.1:5052/eth/v1/beacon/states/head/finality_checkpoints \
  | jq '.data'
```

finalized epochがExit epochに追いつくまで、実測で約30〜40分ほどでした。この間、Grafanaダッシュボード・beaconcha.inのAttestation Success Rateともに100%を維持し続け、`active_exiting`中も署名義務を正しく果たし続けていることを、リアルタイムで確認できました。

最終的に、10鍵すべてが `exited_unslashed`（Slashなしの正規引退）に到達しました。

## 4. ノードの安全停止

10鍵すべての `exited_unslashed` を確認した後、`node_safe_stop.sh`（`node_stop`）で全サービスを停止しました。

```bash
node_stop
```

```
[Step 0] Checking Block Proposal Schedule...
 現在のスロット: 3708546（エポック: 115892）
 ✓ 現在のエポックにブロック提案の予定はありません。安全に停止できます。
1. Stopping SSV Node (DVT operator)... - SSV Node not running or not installed. Skipping.
2. Stopping Validator Client (lighthouse-vc)...
3. Stopping Beacon Node and MEV-Boost...
4. Stopping Execution Client (Geth)...
[Verification] Check Service Status:
 - lighthouse-vc: inactive (Safe)
 - lighthouse: inactive (Safe)
 - mev-boost: inactive (Safe)
 - geth: inactive (Safe)
```

> 💡 **`node_safe_stop.sh`を使った理由：** 第4部第4章のオリジナル手順は「VC → Lighthouse → Geth」の3段階でしたが、日常運用向けに整備した`node_safe_stop.sh`は、これにMEV-Boostの停止と、ブロック提案予定の事前チェックが加わっています。今回のような「完全に運用を終える」場面でも、そのまま安全に活用できました。

続けて、自動起動も無効化しました。

```bash
sudo systemctl disable geth lighthouse lighthouse-vc.service mev-boost
```

4サービスすべて `disabled` となり、OS再起動後も二度と自動起動しない状態になったことを確認しました。

## 5. 【実録】監視アラートの実地検証

ノード停止直後、Telegram経由でCSM Sentinelとは別の、第9章で構築した死活監視（Grafana Alerting）から、以下の3件のアラートが時間差で実際に発火しました。

```
23:01 🔴 アラート発生
🚨 Beacon Nodeが同期していません
lighthouse_vcが認識しているBeacon Nodeの同期数が0になりました。
geth/lighthouseのサービス状態を直ちに確認してください。

23:01 🔴 アラート発生
🔴 geth/lighthouseサービスが停止しています
geth・lighthouse_bn・lighthouse_vcのいずれかで応答が取れていません。
node_checkでサービス状態を直ちに確認してください。

23:06 🔴 アラート発生
⚠️ Attestation成功率が低下しています
直近5分間のAttestation成功率が低下しています。
node_checkまたはGrafanaダッシュボードで詳細を確認してください。
```

> 💡 **これは異常ではなく、想定通りの発火です。** 第9章で構築した監視の仕組みが、意図的な計画停止に対しても正しく反応することを、初めて実地で確認できた瞬間でした。構築時のテストとは異なり、「本物のサービス停止」に対して監視が正確に働くことを確認できたのは、監視基盤の信頼性を裏付ける良い実例になりました。

### 発火タイミングの違いから見える、監視の2階層構造

3件のアラートは、同時に発火したわけではありませんでした。1件目・2件目（Beacon Node同期数0、サービス停止）はノード停止とほぼ同時（23:01）に発火した一方、3件目（Attestation成功率低下）は5分後（23:06）に発火しています。

これは、監視の仕組みが2つの異なる性質のチェックで構成されていることの表れです。

| 種類 | 検知対象 | 反応速度 |
|---|---|---|
| 瞬時反応型 | サービスの生死・同期数（ある時点のスナップショット） | 停止とほぼ同時 |
| 集計窓型 | 直近5分間のAttestation成功率（移動窓での集計） | 窓の分だけ遅れて発火 |

Attestation成功率のアラートが5分遅れて発火したのは、「直近5分間」という評価ウィンドウの中に、署名できなかった時間が一定量蓄積されて初めて閾値を超えたためと考えられます。今回、計画停止という安全な状況で、この2階層構造が意図通りに、時間差を伴って機能することを実地で確認できました。

## 6. まとめ

```
① 10鍵とも、eligibleエラーなく一度でExit申請成功
② 1鍵ずつの手動実行を選択（自動化のリスクを避けた）
③ Exit申請から確定（exited_unslashed）まで、実測約30〜40分
④ active_exiting中もAttestation Success Rate 100%を維持
⑤ node_stopで安全に全サービス停止・自動起動を無効化
⑥ 死活監視アラートが、計画停止に対して正しく発火することを確認
⑦ 瞬時反応型・集計窓型という、監視の2階層構造を実地で確認
```

---

## 7. 今後の課題・次のステップ

```
[ ] Bond Claim（stETHで請求、速さ優先）の実施
[ ] ニーモニックからのkeystore復元検証
    （lighthouse account validator recoverの実地検証。
      Exit済みバリデータの鍵を使い、実運用への影響なく
      安全に検証できるタイミングであるため）
[ ] 設定一式のバックアップ取得
[ ] OS再インストール・LVM構成での再構築
```
