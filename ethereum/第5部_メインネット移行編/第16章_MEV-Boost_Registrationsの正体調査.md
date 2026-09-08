# 第5部・メインネット移行編 第16章 「No data」の正体 — MEV-Boost Registrations調査記録

> **異常を疑って調べたら、まだ何も始まっていないだけだった**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | Grafanaで継続していた「MEV-Boost Registrations: No data」の原因調査 |
| 実施日 | 2026年9月8日 |
| 対象 | lighthouse-vc、mev-boost、ビーコンノードAPIの横断調査 |
| 前提 | 第5部第10章（Prometheus/Grafana基盤構築）、Deposit queue順位#13,186（beaconcha.in） |

> ⚠️ 本章は機密情報を一切含みません。

---

## 1. きっかけ：ずっと「No data」のままのパネル

Grafanaダッシュボード上、「MEV-Boost Registrations」のパネルは、メインネット移行後ずっと「No data」の表示のままだった。他のパネル（Peer数、Disk Usage、CPU温度等）はすべて実データが表示されている中、この項目だけが空白のままという状態が続いていた。

MEV-BoostのBuilder API自体は`Online`と表示されており、サービスとしては正常に見える。一方でRegistrations（バリデータ登録）関連の数値だけがまったく取れていないのは、以下のいずれかを意味すると考えられた。

```
仮説A：Grafana側のクエリ・メトリクス名の設定ミス（表示だけの問題）
仮説B：登録処理自体が実際に失敗している（実害のある問題）
仮説C：登録処理がまだ実行されるフェーズに至っていない（正常な状態）
```

どれに該当するかを、ログとAPIを直接叩いて切り分けることにした。

## 2. 調査ステップ1：ログの確認

まず両サービスのログを確認した。

```bash
sudo journalctl -u lighthouse-vc --since "24 hours ago" | grep -i "regist"
sudo journalctl -u mev-boost --since "24 hours ago" | grep -i "regist"
```

結果：

```
lighthouse-vc: "Validator registration service started" のみ（起動ログのみ）
mev-boost    : 該当ログなし（完全にゼロ件）
```

サービス自体は起動しているが、実際の登録試行のログが一切見当たらない。ただしこの時点では、単に**infoレベルのログには出力されないだけ**という可能性も残っていたため、次の調査に進んだ。

## 3. 調査ステップ2：メトリクスとAPIを直接確認

ログではなく、メトリクスエンドポイントとAPIを直接叩いて実態を確認した。

```bash
curl -s http://127.0.0.1:5064/metrics | grep -i regist
```

```
async_tasks_count{async_task_count="validator_registration_service"} 1
async_tasks_time_histogram_count{async_task_hist="validator_registration_service"} 0
async_tasks_time_histogram_sum{async_task_hist="validator_registration_service"} 0
```

登録タスク自体はスケジュールされている（`count 1`）が、**一度も完了実行された記録がない**（`histogram_count` `histogram_sum`ともに0）ことが分かった。

```bash
curl -s http://127.0.0.1:18550/eth/v1/builder/status
```

```
{}
```

MEV-Boost側のBuilder APIは空のJSON（正常応答）を返しており、サービスとしての疎通自体には問題がない。

この時点で「仮説A（表示だけの問題）」は除外できた。実際に登録タスクが一度も完了していないという、メトリクス側の実態と一致していたためである。

## 4. 調査ステップ3：デバッグログでの直接観察

infoレベルでは記録されない詳細な挙動を捉えるため、一時的に`lighthouse-vc.service`に`--debug-level debug`を追加し、再起動した。Pending activation中で署名業務が発生していないため、この一時的な再起動による実害はない。

```bash
sudo journalctl -u lighthouse-vc -f | grep -iE "regist|builder|publish_validator"
```

数分間監視を続けたが、**登録関連のログは一切出力されなかった**。これは「登録処理がエラーで失敗している」のではなく、「登録処理自体がそもそも実行サイクルに乗っていない」ことを示唆していた。

## 5. 調査ステップ4：決定打 — ビーコンチェーンへの直接照会

最後に、このバリデータがビーコンチェーン上でどう認識されているかを直接確認した。

```bash
curl -s http://127.0.0.1:5052/eth/v1/beacon/states/head/validators/<voting_pubkey> | python3 -m json.tool
```

```json
{
    "code": 404,
    "message": "NOT_FOUND: unknown validator: <voting_pubkey>",
    "stacktraces": []
}
```

**「unknown validator」——ビーコンチェーン上に、このバリデータはまだ一切存在していなかった。** インデックス番号すら割り当てられていない状態である。

## 6. 結論：仮説C（正常な状態）が正解だった

```
① Lighthouseの登録サービスは「登録対象となるバリデータ情報」を
   ビーコンチェーンから取得しようとする
② しかしビーコンチェーンは、このバリデータをまだ認識していない
   （インデックス未割当、404 unknown validator）
③ 登録対象が存在しないため、登録リクエストがそもそも作られない
④ 結果として、MEV-Boost側にも何も届かず、
   Grafanaのパネルも「No data」のまま
```

バグでも異常でもなく、**Deposit queue段階における、想定通りの状態**だった。デバッグ設定は調査後に元に戻し、通常のinfoレベルログでの運用に復帰させている。

## 7. beaconcha.inとの突き合わせ：次の観察ポイント

調査後、beaconcha.in上でこのバリデータの状態を確認したところ、以下のタイムラインが示されていた（9/8時点、Deposit queue順位#13,186）。

| 段階 | 見込み日時 | epoch |
|---|---|---|
| Deposit credited（デポジット反映） | 2026年9月28日 7:40頃 | 478450 |
| Activation（正式活性化） | 2026年9月28日 8:25頃 | 478457 |

Deposit creditedとActivationの間には、約45分（7エポック分）の間隔がある。

今回確認した「unknown validator」という404応答は、この表でいう「Deposited（完了）→ Pending（Deposit queue、現在地点）」の段階に対応していたと考えられる。

> 💡 **未検証の仮説**：ビーコンチェーン上でインデックスが割り当てられるのは、Activation本体（8:25頃）ではなく、その45分前のDeposit credited（7:40頃）のタイミングである可能性がある。もしそうであれば、MEV-Boost Registrationsのメトリクスも、正式なActivationを待たずに7:40頃から動き始めるかもしれない。ただしこれは今回の調査結果とタイムラインを組み合わせた推測に過ぎず、Lighthouseの内部実装として確定した情報ではない。9/28当日の実測で検証する。

---

## 8. まとめ

```
① Grafanaで「No data」のままだったMEV-Boost Registrationsパネルの
   原因を、ログ・メトリクス・API照会を段階的に組み合わせて調査した
② ログだけでは分からず、メトリクス直接確認（histogram count=0）と
   デバッグログでの直接観察を経て、最終的にビーコンチェーンへの
   直接照会（404 unknown validator）で原因を特定した
③ 原因は「登録処理の失敗」ではなく「バリデータがまだビーコンチェーン上に
   一切認識されていない」という、Deposit queue段階における正常な状態
   だった
④ beaconcha.inのタイムライン（Deposit credited→Activation、
   約45分差）と突き合わせ、インデックス割当のタイミングについて
   未検証の仮説を立てた
⑤ 「No data」という表示だけを見て異常を疑うのではなく、
   ログ→メトリクス→API照会と、段階を追って一次情報に当たることで、
   正確な原因特定にたどり着けた
```

## 今後の課題

```
[ ] 9/28のDeposit credited（7:40頃）およびActivation（8:25頃）の
    タイミングで、以下を実測・記録する
    - ビーコンチェーンのバリデータ状態（unknown → pending_queued等）
      が、どちらのタイミングで変化するか
    - MEV-Boost Registrationsのメトリクスが、実際にいつから
      動き始めるか
[ ] 上記の実測結果をもって、本章7節の仮説を検証・確定する
[ ] Doppelganger Protectionの様子見期間の実測（第15章からの継続課題）も、
    同じくActivation当日にあわせて記録する
```
