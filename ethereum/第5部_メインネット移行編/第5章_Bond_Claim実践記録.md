# 第5部・メインネット移行編 第5章 Bond Claim実践記録 — テストネット運用、最後の資金回収

> **CSM UIでの1回の操作で、着金まで完結した**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第5部第1章のロードマップ「③Bond Claim（完全フロー）実施」の実施記録 |
| 実施日 | 2026年8月13日〜16日 |
| 対象 | Lido CSM本業10鍵分の32ETH本体出金、およびExcess Bond・Rewardsのクレーム |
| 前提 | 第4部第4章8-1〜8-3節（Bond Claimの3層構造）、第5部第3章（本業10鍵Voluntary Exit） |

> ⚠️ 本章は機密情報を一切含みません。

---

## 1. 32ETH本体の出金プロセスを追う

第5部第3章でVoluntary Exitを実行した後、32ETH本体の行方とBondの解放は、それぞれ独立したタイムラインで進みました。

> ⚠️ **32ETH本体は、運用者のウォレットには戻りません。** 以前確認した通り、32ETHはLidoプロトコルが供給したものであり、運用者自身が拠出したものではありません。Voluntary Exit後、この32ETHは**Lidoのプロトコル側（Withdrawal Vault）に返却される**のが正しい流れです。運用者が実際に手にするのは、自分で拠出していたBond（担保金）の余剰分と報酬（Rewards）のみです。beaconcha.in上で見える「Balance 0.00000 ETH」は、あくまで「バリデータの残高がゼロになった＝Lido側へ全額移動した」ことを示すもので、運用者個人の資産増加を意味するものではありません。

### 1-1. Exit直後の状態（8/14）

beaconcha.inで確認すると、最初にExitしたバリデータ（インデックス1280904）は以下の状態でした。

```
Status: Withdrawing
Exited since: 2026年8月13日 8:28
Withdrawable: 2026年8月14日 11:46
推定最終出金まで: 約10日3時間
```

> 💡 **Ethereumの出金は3段階に分かれています。** ①Exitキュー通過、②Withdrawableになるまでの固定待機（256エポック≒約27時間）、③Withdrawal Sweep（掃き出し処理、ネットワーク混雑状況により数時間〜10日超）。今回、③の見積もりは約10日でした。

### 1-2. CSM UI側の反映には別のタイムラグがあった

ビーコンチェーン側で`exited_unslashed`が確定した後も、CSM UI（`csm.testnet.fi`）のKeys Breakdownは、**丸1日近く「Active: 10」のまま**でした。翌朝になって初めて「Withdrawn: 10」に切り替わりました。

これは、オンチェーンのステータス変化を、Lido側のOracleレポートが集計・反映するまでに、一定の周期を要するためと考えられます。CSM Sentinelからの通知が来ていないことも、判断材料として活用しました（通知が来ていない＝まだ内部反映が終わっていない、という目安）。

### 1-3. 実際の出金完了（8/16）

CSM Sentinelから、Telegram経由で以下のような通知が届きました。

```
Validator withdrawals confirmed

Withdrawn validators:
- Validator 1: 0x95b018ed...89a9d602
  Exit balance: 32 ether
- Validator 2: 0x96d73b90...4814d908
  Exit balance: 32 ether

nodeOperatorId: <your_operator_id>
Blocks: 3427971 ... 3427972
```

10鍵分、すべて数分〜十数分の間隔で通知が届き、**Exit確定からわずか2日で、320 ETH全額のプロトコルへの返却が完了**しました。第2章のSSVクラスター（約10日）と比べて、大幅に早いペースでした。

beaconcha.inでも、Balance 32.00000 ETH → **0.00000 ETH**、Status: **Withdrawn** への変化を確認しています。

---

## 2. Bond側の反映を確認する

10鍵分の32ETHがプロトコルへ返却された後、CSM UIのBond & Rewardsも変化を見せ始めました。

| 時点 | Available to claim | Bond balance |
|---|---|---|
| 8/14夜（10鍵Exit直後） | 65.5628 stETH | 79.6549 stETH |
| 8/15朝 | 65.5672 stETH | 79.6549 stETH |
| 8/16 10鍵分返却完了直後 | **79.6716 stETH** | 79.6593 stETH |

8/14〜15の間は、リベース分に相当するごく僅かな増加のみでした。しかし8/16、10鍵分の返却がすべて完了した直後、**Available to claimがBond balanceとほぼ同額まで一気に増加**しました。これは、10鍵分に紐づいていた必要Bondが、返却確定を受けて解放されたことを意味します。

---

## 3. Claim実施

### 3-1. Claiming optionとtokenの選択

`csm.testnet.fi/bond/claim`のClaim画面では、以下の3つのクレーミングオプションがありました。

```
① All → Rewards Address（Excess BondとRewards両方を請求）
② Excess Bond → Rewards Address（Excess Bondのみ請求、Rewardsは未請求のまま残す）
③ Rewards → Excess Bond（Rewardsを全てBondへ移動、鍵追加のBondに充てるのに最適）
```

今回は①「All → Rewards Address」を選択しました。

Tokenの選択肢は3種類あり、それぞれ処理時間が明確に異なっていました。

| Token | 金額 | Waiting time | 受け取り方式 |
|---|---|---|---|
| ETH | 79.6716 ETH | 約1日 | withdrawal NFT |
| **stETH** | 79.6716 stETH | **約1分** | stETH |
| wstETH | 77.3948 wstETH | 約1分 | wstETH |

速さを優先し、**stETH**を選択しました。

### 3-2. Claim実行と結果

Claimボタンを押すと、以下の内容が表示されました。

```
You are claiming bond and rewards

Rewards Address    79.6716 stETH
0xe3Bb...c42C68
Excess bond        -79.6593 stETH
```

MetaMaskでの署名後、「Requested amount has been successfully claimed」と表示され、即座に完了しました。

### 3-3. Etherscanでの最終確認

トランザクションを確認すると、以下の内容が記録されていました。

```
Status: Success
Transaction Fee: 0.000245918496885684 ETH

ERC-20 Tokens Transferred: 2
- 0.012305485187059306 stETH （Rewards distribution分）
- 79.671632491452289253 stETH （Excess Bond分）
```

**79.671632... stETHが、Rewards Address（`0xe3Bb...c42C68`）に着金したことを、トランザクションレベルで確認できました。**

内訳として、0.0123 stETH程度が別途「Rewards distribution」分として合算されていたことも判明し、以前確認していた「Latest rewards distribution: 0.0123 stETH」の実体がこれだったと裏付けが取れました。

---

## 4. 第4部第4章8-3節の教訓との対比

第4部第4章8-3節では、CSM UIでの操作だけでは完了しておらず、Lido本体側での最終Claimまで必要という教訓を得ていました（この見落としにより、47日間資金が放置されていた実例がありました）。

今回、**stETHを選択したことで、CSM UI上の1回のClaim操作だけで、着金まで完全に完結**しました。ETHを選択していた場合は、withdrawal NFTの発行を経て、別途もう一段階の操作が必要だった可能性があります。速さだけでなく、手順のシンプルさという観点でも、stETH選択は理にかなった判断でした。

また、「操作した」で終わらせず、Etherscanで実際の着金を確認するという原則も、引き続き徹底しました。

---

## 5. まとめ

```
① 32ETH本体はLidoプロトコル側（Withdrawal Vault）へ返却されるものであり、
   運用者のウォレットには戻らない。運用者が実際に受け取るのは
   Bondの余剰分と報酬のみ
② 10鍵分の返却は、Exit確定から約2日で完了
   （SSVクラスターの約10日より大幅に早かった）
③ CSM UI側のステータス反映には、ビーコンチェーンの確定から
   さらに時間差がある（Oracleレポートの反映待ち）
④ Bond Claimの実行条件は、10鍵分の返却完了と連動していた
⑤ stETH選択により、CSM UI上の1回の操作で着金まで完結
⑥ Etherscanでの最終確認により、着金額・内訳（Excess Bond分と
   Rewards distribution分の合算）まで裏付けが取れた
```

---

## 6. 今後の課題・次のステップ

```
[ ] OS再インストール・LVM構成での再構築
[ ] メインネット用の新規鍵生成・1鍵運用開始
```
