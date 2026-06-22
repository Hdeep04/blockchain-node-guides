# 第4部・応用編 第6章 SSV DVTクラスター実践検証

> **第3部で構築したSSVオペレーターを使い、実在する他の運用者3者と
> 組んで、本物の4人クラスターによる分散バリデータ（DVT）を構築する検証**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第3部（SSV/DVT編）の応用検証。Lido CSMを経由しない、独立した検証 |
| SSVノード稼働環境 | 第3部で構築したベアメタルサーバ（既存のSSVノードをそのまま活用） |
| 新規バリデータ鍵の生成環境 | テストネット用VM（本番のベアメタル環境を保護するため、検証専用の鍵をここで生成） |
| 検証用ウォレット | SSV検証専用ウォレット（既存の本番運用ウォレットとは分離） |
| 検証日 | 2026年6月（Hoodi Testnet） |
| 進行状況 | 完了。クラスター登録 → Activation → 3-of-4閾値署名の継続安定稼働まで実証済み（4人クラスター） |

> ⚠️ **本書は機密情報を一切含みません。** ウォレットアドレス・他オペレーターの実名・バリデータ識別子は全て匿名化・プレースホルダ化しています。

---

## 本検証の位置づけ

第3部では、SSVノードの構築・起動・P2P接続の確認までを記録しました。
ただし「クラスター運用（実際の鍵分割・複数オペレーターでの署名）」については、
「オペレーター仲間の募集から」として保留していました。

本検証は、その保留事項に実際に着手し、**SSV Explorer上で既にPublicに
公開されている他のオペレーターを自由にクラスターへ組み込める
（permissionless設計）**という仕組みを使って、知人を募集する手間なく
本物の4人クラスターによるDVTを完成させた記録です。

---

## 1. 構成の正しい理解

最初に混同しやすい点を整理しておく。

```
Staker（クラスターのオーナー、鍵を委任する側）= 自分（検証用ウォレット）
Operator 1 = 自分自身のノード（第3部で構築したSSVノード）
Operator 2・3・4 = 実在する他の運用者（A・B・C）
```

> 💡 **「1人で4役を演じる」のではない。** 「Stakerとしての自分」＋「Operatorの1つとしての自分」＋「他の運用者3者」という構成。

> ⚠️ **重要な留保：** SSVのプロトコル設計上、Publicなオペレーターは事前承諾なしでクラスターに組み込める（permissionless設計）。今回組み込んだ運用者A・B・Cには事前連絡をしていない。技術的には問題ないが、相手は知らないうちに新しいクラスターのオペレーターとして動き始める、という点は理解しておく必要がある。

---

## 2. ウォレットの役割分担

| ウォレット | 役割 |
|---|---|
| 検証用ウォレット（Staker） | クラスターオーナー。32 ETHの資金提供元 |
| 自分のOperator owner ウォレット | 自分のオペレーターノードの管理者 |

> 💡 **2つは別ウォレットであり、混同しないこと。** 自分のOperatorのメタデータ編集（名前・アイコン・Location等）はowner ウォレット側からのみ可能。今回はクラスター構築（Stakerの作業）が主目的なので、検証用ウォレットで進める。

---

## 3. 自分のOperatorプロフィール確認（事前準備）

`https://explorer.ssv.network/hoodi/operator/<自分のOperator ID>` で確認。

**確認できた内容（第3部で既に整備済みだった）：**

```
名前: <設定済みの表示名>
Owner: <owner ウォレットアドレス>
Fee (Yearly): 0.0046 ETH 程度
Location: Japan
ETH1 node client: Geth
ETH2 node client: Lighthouse
SSV Client: SSV Node
Status: No Validators（クラスター未構築のため0件）
```

> 💡 **DKG Endpoint: N/A** だった点が、後のステップで重要になる（DKG方式が使えない原因）。

---

## 4. クラスター構築フロー（SSV App / Web UI操作）

### Step 1：Distribute Validators を選択

`app.ssv.network/join` → **Distribute Validators** をクリック
（Staker側の入口。"Join as Operator" ではない）

### Step 2：鍵の準備方法を選択

`app.ssv.network/join/validator` 画面：

```
① Generate new key shares（新規鍵を生成して分割）← こちらを選択
② I already have key shares（既存のkeyshareがある場合）
```

### Step 3：オペレーター選定

`app.ssv.network/join/validator/select-operators` 画面：

```
Cluster Size: 4 を選択
検索ボックスで以下を1つずつ検索・選択：
  Operator A（他社）
  Operator B（他社）
  Operator C（他社）
  自分自身のOperator
```

**選定基準：**

実際に使ったフィルターは、SSV Explorer上の「Status」「Verified」「Private」等の
絞り込み機能。具体的には以下を重視した。

```
① コストが低いこと（Fee Yearly）
② Active状態であること（稼働実績があるか）
③ Public（誰でも組み込める公開オペレーター）であること
④ 企業向け運用（大規模商用サービス）ではないこと
   → 個人〜小規模運用者を中心に検討
⑤ 地理的な分散（異なる国・地域の組み合わせ）
⑥ クライアント多様性（EL/CLの組み合わせが揃っていないこと）
```

実際に選定した3者は、Fee Yearlyが0.003〜0.014 ETH程度、Status: Active、
ETH1/ETH2クライアントの組み合わせもそれぞれ異なっており、地理的にも
複数の国に分散していた。

> ⚠️ **「not verified」警告が表示される場合がある。** 未認証オペレーターを含むリスクの警告。テストネット検証目的のため、認識した上で進行可（本番では非推奨）。

**選定結果（実測・匿名化）：**

| オペレーター | Fee (Yearly) | DKG対応 |
|---|---|---|
| A | 約0.0046 ETH | Enabled |
| B | 約0.0139 ETH | **Disabled** |
| C | 約0.0030 ETH | Enabled |
| 自分 | 約0.0046 ETH | **Disabled** |

Operators Yearly Fee 合計：約0.026 ETH

### Step 4：鍵分割方式の選択

`app.ssv.network/join/validator/distribution-method` 画面：

```
① Online（webapp上で分割）
② Offline（自分のPC上で分割）
```

> 💡 **Online/Offlineどちらも「鍵分割の計算」自体はローカル（ブラウザのクライアントサイド）で行われる。** 違いは「インターネット接続を完全に切るかどうか」という追加の安全策の有無。SSVのサーバーに生の秘密鍵を送信する設計ではない。

「Online」を選択 → 実際には以下の選択画面に遷移。

### Step 5：オンライン分割の内訳選択

```
① Command Line Interface（既存鍵から生成）
② DKG（新規鍵を分散生成）
```

> ⚠️ **DKGは選択できなかった。** 「DKG method is unavailable because one or more selected operators have an issue that prevents DKG operations.」
> 原因：選定した4者のうち2者がDKG Disabledだったため。DKGを使うには各オペレーター側でDKG用エンドポイントの設定が必要（自分のプロフィールに表示されていた「DKG Endpoint: N/A」が該当）。

→ 「Command Line Interface」を選択し、既存のkeystoreファイルをアップロードする方式に進む。

### Step 6：Validator Keyのアップロード

```
Upload your validator keystore file below
Keystore Password: [入力]

⚠️ 警告文：
"Please never perform online key splitting on testnet
with a private key that you intend to use on mainnet,
as doing so may put your validators at risk."
```

> 💡 **この警告の意味：** 「メインネットで使う予定の鍵を、テストネットのオンライン分割に使い回してはいけない」という注意。**新しいニーモニックから生成した、テストネット専用・SSV検証専用の鍵を使う**ことで、この警告の条件に違反しない。

---

## 5. 新規バリデータ鍵の生成（SSV検証専用）

### 環境

ベアメタル本番サーバーではなく、**検証用VM**で生成する。

> 💡 **判断理由：** ベアメタルは本番のLido CSM運用（複数バリデータ・本番資金）が稼働中の重要環境。実験的な作業による操作ミスのリスクを避けるため、検証専用環境（VM）で行うのが安全。ニーモニックがあればどの環境でも鍵を再現できるため、生成環境はどこでも良い。

### 鍵生成コマンド（new-mnemonic）

これまでの`existing-mnemonic`ではなく、**新規ニーモニック生成**を使う。

```bash
cd ~/<deposit-cliのディレクトリ>/
./deposit new-mnemonic \
  --num_validators 1 \
  --chain hoodi \
  --eth1_withdrawal_address <検証用ウォレットのアドレス>
```

**対話フロー：**

```
1. 言語選択 → English
2. インターネット接続警告 → 任意のキー
3. withdrawal address確認入力 → アドレスを再入力
4. ニーモニック言語選択 → English
5. パスワード設定 → 12文字以上
6. パスワード確認 → 同じパスワード再入力
7. Compounding validators？ → no（標準32 ETH・0x01 withdrawal credentials）
```

> ⚠️ **画面に表示される24単語のニーモニックは、SSV検証専用の新しいシードフレーズ。** これまでの本番用ニーモニックとは完全に別物として、安全な場所（紙に手書き等）に記録する。画面のスクリーンショットは、ニーモニックが映っている部分を絶対に共有しない。

**生成結果：**

```
keystore-m_12381_3600_0_0_0-<timestamp>.json
deposit_data-<timestamp>.json
```

### 32 ETHが必要な理由（Lido CSMとの違い）

ここで生成した鍵には、Lido CSMとは異なり32 ETH全額のデポジットが必要になる。

```
Lido CSM経由：ボンド（数ETH程度）のみ自分で用意
            → 残りはLidoプロトコルが補填

SSV単体（Lido CSM非経由）：32 ETH全額を自分で用意する必要がある
            → SSVは「署名の分散」技術であり、「デポジット額の軽減」技術ではない
```

→ Hoodi Testnet上で32 ETH分のテストネットETHを自分で調達する必要がある。

---

## 6. Hoodi Testnet ETH（32 ETH分）の調達

### 試したFaucet一覧

| Faucet | 結果 | 備考 |
|---|---|---|
| faucet.hoodi.ethpandaops.io | ❌ 失敗 | "the faucet is out of funds"（資金枯渇） |
| faucets.chain.link/hoodi | ❌ 失敗 | LINKトークン配布用で、ETH調達には無関係 |
| faucet.chainstack.com | 未実施 | APIキー必須・条件あり（優先度低） |
| **hoodi-faucet.pk910.de** | ✅ **成功** | PoW（マイニング）型。ブラウザを開いたまま放置で蓄積 |

### PoWFaucet（pk910.de）の使い方・実測

```
URL: https://hoodi-faucet.pk910.de
Target Address に検証用ウォレットアドレスを指定
→ ブラウザのタブを開いたままにしておくと自動的にマイニングされる

Number of Workers: 16/16（フル稼働）
Avg. Reward per Hour: 約16〜18 HodETH/h
Maximum Claim Reward: 33 HodETH（32 ETHの目標を超える設定）
→ 約2時間で目標達成。Claim実行 → ウォレットに反映
```

> 💡 **注意点：** ブラウザタブを閉じる・PCがスリープするとマイニングが停止する。完了まで放置できる環境で実行する必要がある。

---

## 7. 通常ソロステーキング方式での32 ETHデポジット

SSVは「署名の分散」技術であり「デポジット額の軽減」技術ではないため、Lido CSMを経由しない場合は公式Launchpadで通常のデポジットを行う。

### 公式Launchpadでのオンボーディングフロー

```
URL: https://hoodi.launchpad.ethereum.org
```

> 💡 **これまでLido CSMのウィジェット経由ばかりだったため、公式Launchpad自体を
> 直接利用するのは今回が初めてだった。** Lido CSMは、この公式フローを
> 「裏側で」自動処理してくれていた、ということが対比的に理解できた。

**9ステップの流れ（各ステップでチェック・I ACCEPT）：**

```
1. Proof of stake（32 ETHのデポジット原理の説明）
2. The terminal
3. Uptime
4. Bad behavior
5. Key management
6. Withdrawal address（既に鍵生成時に設定済みのため確認のみ）
7. Software（クライアント選択画面 → 既存ノードがあるため内容説明のみ確認）
8. Checklist
9. Confirmation
```

### deposit_dataファイルのアップロード

```
画面: Upload deposit data
要求: deposit_data-[timestamp].json をアップロード（ドラッグ&ドロップ or browse）
```

> ⚠️ **Lido CSMとの違いに注意。** Lido CSMウィジェットは「catコマンドの出力（JSONテキスト）を直接貼り付け」る形式だったが、公式Launchpadは「ファイルそのもの」をアップロードする形式。

### ウォレット接続・デポジット実行

```
Connect wallet → MetaMaskを接続
  確認項目：
    ✅ Network: Hoodi testnet
    ✅ Balance: 必要な32 ETH以上を保有
  ⚠️ withdrawal addressは変更不可。自分が管理するアドレスか必ず確認

Summary → 最終確認（フィッシング対策・二重デポジット防止の注意事項）
  Total amount required: 32 HoodiETH
  全チェックボックスにチェック

Transactions → 「Confirm deposit」or「SEND DEPOSIT」
  → MetaMaskでトランザクション承認
```

**結果：**

```
"Your stake has reached the deposit contract!"
Your stake: 32 HoodiETH
Your validators: 1 validators
```

---

## 8. SSVクラスターへのバリデータ登録

### Step 1：keystoreファイルのアップロード

`app.ssv.network/join/validator/online` でファイルをアップロードし、Keystore Passwordを入力 → 「Generate Key Shares」をクリック。

> ⚠️ **deposit_dataとkeystoreの違いに注意：**
> ```
> deposit_data-*.json → Launchpadへのデポジット用（公開情報・署名なし）
> keystore-*.json → SSVへの分割用（秘密鍵が暗号化されたデータ）
> ```

> 💡 **ブラウザを移動するとオペレーター選択がリセットされることがある。** その場合は4名を再度検索・選択し直す。

### Step 2：Effective Balanceの入力

```
Total Effective Balance: 32 ETH
```

> 💡 **Status: Not Deposited と表示されても問題ない。** beaconcha.in側の「Pending」状態がSSV側にまだ反映されていないだけで、タイムラグがある。

### Step 3：クラスター運用資金（Funding period）の選択

```
Funding Summary:
  Operators Fee: 0.026 ETH程度（年間・4オペレーター合計）
  Network Fee: 0.009 ETH程度
  Liquidation Collateral: 0.001 ETH程度
  ─────────────
  Total（1年）: 0.037 ETH程度
```

> 💡 **これはSSV/ETHトークンではなく、ETHで決済される。**「ETH-only payments」の仕組みが実証された。

### Step 4：Cluster Balances and Feesの警告確認

```
⚠️ "Clusters with insufficient balance are at risk of being
   liquidated, which will result in inactivation (penalties
   on the beacon chain) of their validators..."
```

> 💡 **これは「クラスター運用資金のガス欠」のような仕組み。** 支払った運用費が時間とともに消費され、枯渇すると強制的にバリデータが非アクティブ化されペナルティを受ける。Lido CSMにはこの概念自体が存在しなかった、SSV特有の注意点。

### Step 5：Slashing Warningの確認

```
⚠️ "Running a validator simultaneously to the SSV network
   will cause slashing to your validator. To avoid slashing,
   shut down your existing validator setup (if you have one)
   before importing your validator to run with our network."
```

> 💡 **第2部で経験した「二重署名→スラッシング」の警告そのもの。** 今回の鍵は他のクライアントにインポートしていないため該当しないが、**今後この鍵を別途他クライアントにインポートしてはいけない**という重要な制約が生まれる。署名は今後SSVの4オペレーターのみが担当する。

### Step 6：登録トランザクションの実行・完了

```
"Welcome to the SSV Network!"
Your new validator is managed by the following cluster:
Validator Cluster <cluster_id>

✅ 4オペレーター登録完了
"Your cluster operators have been notified and will start
your validator operation instantly."
```

**クラスター管理ダッシュボード（確認できた内容）：**

```
Effective Balance: 32 ETH（Depositing）
Est. Operational Runway: 365 days
  Burn Rate / day: 0.0001 ETH程度
Balance: 0.037 ETH程度
Validators: 1（Status: Pending、Effective Balance: 32 ETH）
Operators: 4
```

---

## 9. 作業完了後の整理（鍵ファイルの削除）

SSVクラスターに分割済みとなった鍵は、今後どのクライアントにも単独でインポートする予定がないため、関連ファイルを削除して整理した。

```bash
# 共有フォルダー・生成元ディレクトリ・転送先ディレクトリすべてから削除
rm <共有フォルダー>/deposit_data-<timestamp>.json
rm <共有フォルダー>/keystore-m_12381_3600_0_0_0-<timestamp>.json
rm <鍵生成元ディレクトリ>/deposit_data-<timestamp>.json
rm <鍵生成元ディレクトリ>/keystore-m_12381_3600_0_0_0-<timestamp>.json
```

> 💡 **削除して問題ない理由：** ニーモニック（24単語、紙に手書きで保管済み）があれば、いつでも`existing-mnemonic`コマンドで同じ鍵を再現できる。ファイル自体は不要になったら削除するのが望ましい（keystoreは暗号化されているが、パスワード強度に依存するリスクをゼロにしておく）。

> ⚠️ **本検証はベアメタル本番サーバには一切コマンドを実行していない。** 自分のOperatorがクラスターに「組み込まれた」のはオンチェーン・論理的な話であり、ベアメタル側のSSVノード設定変更は発生していない（permissionless設計のため、裏側で自動的に新しいタスクを検知して動き出す想定）。

---

## 10. 構成の本質的な理解（振り返り）

今回の検証を通じて、「資金の分散」と「運用の分散」が別物であることが体感的に理解できた。

```
今回のSSV単体クラスター：
  Staker（出資者・32 ETH全額）= あなた1人
  Operator（運用者・鍵管理）= 4人（あなた含む）

これまでのLido CSM（第1〜2部）：
  Staker（出資者）= Lidoプロトコル（多数のstETHホルダー）
  Operator（運用者）= あなた1人（DVTなし、単独運用）
```

| | 出資（資金）の分散 | 運用（鍵管理）の分散 |
|---|---|---|
| Lido CSM | ✅ 分散（多数のstETHホルダー） | ❌ 分散なし（Operator 1人） |
| 今回のSSV単体 | ❌ 分散なし（Staker 1人） | ✅ 分散（Operator 4人） |
| 理想形（SafeStake等の組み合わせ） | ✅ 分散（Lido CSMのボンド） | ✅ 分散（DVTの4人） |

> 💡 **Lido CSMは「お金の分散」、SSV/DVTは「運用責任の分散」という、別の課題を解決する技術。** 両者は両立可能（SafeStakeのような第三者サービスでLido CSM + DKG/DVTを組み合わせる例が存在する）。今回は基礎を理解するため、意図的に「SSV単体（資金は自前）」というシンプルな構成から検証した。

---

## 11. 【実録】Activation〜閾値署名成功の確認

### Activation前後のステータス遷移（ベアメタルSSVノードログ）

```bash
cd /opt/ssv && docker compose logs -f --tail 5 | grep --line-buffered --color=always -E "activated|recording validator status"
```

**ステータス遷移の実測タイムライン（概要）：**

```
クラスター登録直後  "not_found"        （まだBeacon Chainに未認識）
  ↓
deposit_dataがBeacon Chain側で見つかると "not_activated" に変化
  ↓
"attesting" / "participating" / "not_activated" が同時出力される過渡状態
  ↓
"active" が初出現（"not_activated"が消える）
  ↓
"active" / "attesting" / "participating" で安定
```

> 💡 **beaconcha.in側のActivation予測時刻とほぼ一致するタイミングで、
> ベアメタルのSSVノードもActiveを認識した。** UTC/JSTの変換を忘れずに
> 行うこと（9時間差）。

### 実際の閾値署名（DVT）成功ログ

```bash
docker compose logs --since 3m | grep -iE "submit|sign|consensus|partial"
```

**Activation直後・初回の成功例：**

```
✅ successfully submitted attestations
  {
    "runner_role": "COMMITTEE",
    "duty_id": "COMMITTEE-A_B_C_<自分>-e<epoch>-s<slot>",
    "msg_type": "partial_signature",
    "validators": ["<validator_index>"],
    "took": "328.57244ms"
  }
✔️ finished duty processing (100% success)
  {
    "consensus_time": "0.19943s",
    "consensus_rounds": 1,
    "total_duty_time": "1.43027s"
  }
```

> ✅ **これが本検証の核心的な成果です。** `duty_id`に4つのオペレーターIDが
> 刻まれており、本物の4人クラスターによる（3-of-4の）閾値署名（partial_signature
> の収集・合算）が、`consensus_rounds: 1`・`100% success` で成功した
> ことを確認した。

### beaconcha.inでの確認（読者向け確認手順）

```
URL: https://hoodi.beaconcha.in/validator/<バリデータの公開鍵フル文字列>
```

**Activation直後に確認できた状態：**

```
Status: Active ✅
Balance: 32.00000 ETH
Atts: 3 (100%)
```

### 【追加検証】継続安定稼働の確認

Activation直後の初回確認だけで判断するのは早計のため、同日中に改めて
稼働状況を再確認した。

**beaconcha.in（Activationから約50エポック経過時点）：**

```
Status: Active
Balance: 32.00031 ETH
BeaconScore (30d): 94.43%
Atts: 50 (100% ✅)
Total Rewards: +0.00031 ETH（プラス。正常稼働の証拠）
Total missed rewards: 0.00002 ETH（ごくわずか）
```

**SSV App（Web UI）：**

```
自分のOperator: Status Active, Validators 1, Total ETH Managed 32
Cluster（4オペレーター構成）: Validators 1, Status Active, Effective Balance 32 ETH
```

> 💡 **初回確認時に見られたSSV App側の表示遅延（"Inactive"/"Pending Validators"）は、
> この時点で完全に解消し、実態と一致した表示になっていた。**

**ベアメタルSSVノードログ（10エポック連続の成功実績）：**

```bash
cd /opt/ssv && docker compose logs --since 1h | grep -iE "COMMITTEE-A_B_C_<自分>" | tail -30
```

| 結果 |
|---|
| ✅ 100% success（consensus_rounds: 1） |
| ✅ 100% success（consensus_rounds: 1） |
| ✅ 100% success（consensus_rounds: 1） |
| ✅ 100% success（consensus_rounds: 1） |
| ✅ 100% success（consensus_rounds: 1） |
| ✅ 100% success（consensus_rounds: 1） |
| ✅ 100% success（consensus_rounds: 1） |
| ✅ 100% success（consensus_rounds: 1） |
| ✅ 100% success（consensus_rounds: 1） |
| ✅ 100% success（consensus_rounds: 1） |

> ✅ **すべてのエポックで `consensus_rounds: 1`（再投票なし・一発合意）かつ
> `100% success`。** Activation直後だけでなく、数十エポックを経た今も
> 継続して安定動作していることが、ベアメタルの一次ログとbeaconcha.in
> の双方から裏付けられた。「初回成功」止まりではなく「継続安定稼働」と
> 言える状態になっている。

### 【発見】SSV App（Web UI）の表示遅延

```
ベアメタルログ・beaconcha.in：既にActive・署名成功を確認済み

一方、app.ssv.network のクラスターページ・自分のOperatorページでは
しばらく "Inactive" / "Pending Validators" の表示が残った
```

> 💡 **これは実態とWeb UI表示のタイムラグであり、実害はない。** SSV Appの表示データは別のインデクサーから取得しているため、反映に数分〜十数分のずれが生じることがある。「実際の署名成功（ログ・beaconcha.in）」を一次情報として信頼すべきで、Web UI表示はあくまで参考情報という位置づけ。

### 【発見】Lido CSM自動ダッシュボードとSSV単体運用の違い

```
Lido CSM経由の複数バリデータ：
  csm.testnet.fi の「Monitoring」リンクから、
  Lido側が自動生成したbeaconcha.inカスタムダッシュボードで
  複数バリデータを一括俯瞰できる

今回のSSV検証バリデータ（Lido CSM非経由）：
  この自動ダッシュボードには出てこない
  （Lidoが関与していないため検出されない）
  → 個別の公開鍵URLで都度確認する運用、
    または自分で新規にbeaconcha.inのカスタムダッシュボードを
    作成する必要がある
```

> 💡 **これも「Lido CSMのメリット」の一つとして発見した点。** 資金面の補填だけでなく、運用監視の便利機能（自動ダッシュボード）も付帯している。SSV単体運用ではこうした付加機能はなく、自分で構築・管理が必要。

---

## 12. 本検証全体の成果まとめ

```
✅ Staker（資金提供）= 自分（検証用ウォレット、32 ETH自前調達）
✅ Operator（運用）= 自分＋実在する他の運用者3者の本物の4人クラスターによるDVT
✅ 新規ニーモニックでのバリデータ鍵生成（SSV専用・既存鍵と完全分離）
✅ PoWFaucetでの32 ETH調達
✅ 公式Launchpad（Lido非経由）での通常デポジット
✅ SSV App（Web UI・CLI方式）でのKeyShare生成・クラスター登録
✅ Activation成功
✅ 3-of-4閾値署名（QBFT/IBFTコンセンサス、4人クラスター）の複数回連続成功を実証
   （consensus_rounds: 1、100% success）
✅ ベアメタル本番環境への影響ゼロ（permissionless設計の実証）
✅ 使用した鍵ファイル（keystore/deposit_data）は全環境からすべて削除済み
   （ニーモニックは手書き保管）
```

---

## 13. 【最重要】従来のVC構成とSSV構成の本質的な違い

今回の検証で最も重要な発見であり、初めて聞く人には直感的に分かりにくい点。**「鍵のインポート」という作業が、SSV構成には存在しない。**

### 従来のソロステーキング構成（第1部・第2部で構築したもの）

```
① EL（Geth / Nethermind）
② CL-BN（Lighthouse / Nimbus の Beacon Node）
③ CL-VC（Lighthouse / Nimbus の Validator Client）
   ↑ ここに「鍵（keystore）」をインポートして、
     あなた1人がこの鍵で署名する
```

```bash
# 従来：鍵をVCにインポートする手順（第1部・第2部で実施）
sudo -u ethereum lighthouse account validator import \
  --datadir /var/lib/lido-csm \
  --directory /tmp/keys_import/validator_keys
```

> この「import」コマンドが、**鍵という単一のファイルを、単一のVCプロセスに登録する**操作だった。

### SSV構成（第3部・本検証）

```
① EL（ベアメタルの既存Geth、ローカル接続）
② CL-BN（外部RPCのBeacon、第3部のハイブリッド構成）
③ CL-VC →  存在しない！
③' SSV Node（Dockerコンテナ）が「VCの役割」を代替する
```

**SSV構成では、③（VC）への「インポート」という手順が一切発生しない。** 代わりに行うのは：

```
鍵生成（new-mnemonic） → SSV App上で4つのKeyShareに分割
  → 4人それぞれのSSVノードに、KeyShareが配布される
  → 元の単一の鍵（秘密鍵）は、分割が完了した時点で
    実質的に「誰の手元にも単独では存在しない」状態になる
```

### 図で見る違い

```
【従来：1人のVCが署名】

  あなたの鍵（1つのファイル）
        ↓ import
  あなたのVC（1プロセス）
        ↓
     署名（1人で完結）


【SSV：4人のSSVノードが分散して署名】

  あなたの鍵（1つのファイル）
        ↓ SSV Appで4分割（Generate Key Shares）
        ↓
  ┌─────────┬─────────┬─────────┬─────────┐
  │KeyShare1│KeyShare2│KeyShare3│KeyShare4│
  ↓         ↓         ↓         ↓
Operator   Operator  Operator  Operator
   A         B         C        自分
（他社）    （他社）   （他社）  （自分の
                                  ベアメタル）
  ↓         ↓         ↓         ↓
  └─────────┴────┬────┴─────────┘
                  ↓
        4つの部分署名(partial_signature)を
        QBFT/IBFTコンセンサスで合算
                  ↓
          1つの完全な署名として
          ネットワークに提出
```

### なぜ「インポートしていない」という印象になるのか（正確な理解）

```
通常のVC：
  「あなたの鍵」を「あなたのVC」に
  インポートするという1対1の関係

SSV：
  「あなたの鍵」は分割された時点で実質的に消滅し、
  KeyShareという別物に変わる
  → これは「インポート」ではなく「分割・配布・登録」という
    まったく別の概念
```

**つまり、SSV Appで行う操作（Generate Key Shares → クラスター登録トランザクション）こそが、従来の「VCへのインポート」に相当する、SSV独自の手順である。** 手順の見た目（コマンドを打つ、ファイルをアップロードする）は似ていても、行われている処理の本質は全く異なる。

---

## 14. 学んだこと・教訓

- **DKGとCLI方式の違い**：DKGは各オペレーターのノード側に専用エンドポイント設定が必要で、対応していないオペレーターを含むクラスターでは使えない。CLI方式（既存鍵をアップロードして分割）は環境を問わず使える代替手段。
- **Online/Offlineの本質的な違い**：どちらも分割計算はローカルで行われる。Offlineは「念のためネット接続を切る」という追加の安全策であり、Onlineが直ちに危険というわけではない。ただし「メインネット用の鍵をテストネットのオンライン分割で使い回す」のは明確に禁止される。
- **SSV単体とLido CSMの資金面の違い**：Lido CSMはボンド（数ETH）のみで32 ETHの壁を超えられるが、SSV単体ではその仕組みがなく、32 ETH全額が必要。
- **クラスター運用費という新しい概念**：SSVには「運用資金が枯渇すると強制的にバリデータが停止・ペナルティを受ける」という、Lido CSMにはなかった仕組みがある。事前に十分な運用資金（年単位等）を確保しておく必要がある。
- **Faucetの実情**：公式Faucetは資金枯渇していることが多く、PoW型（マイニングしてじわじわ貯める方式）が最も確実だった。
- **VM↔ホストPC間のファイル転送**：VirtualBoxの共有フォルダー機能（`mount -t vboxsf`）で、deposit_data・keystoreファイルをブラウザ環境に渡せる。
- **資金の分散 vs 運用の分散**：Lido CSMとSSV/DVTは、それぞれ別の課題（資金面の参入障壁／単一障害点リスク）を解決する技術であり、両立可能。
- **本番環境への影響なし**：Web UI（SSV App）でのクラスター登録は、permissionless設計により、ベアメタル側のオペレーターノードに対する直接操作を必要としない。

---

## 今後の課題

```
[ ] 1〜2オペレーターを意図的に停止し、閾値（3-of-4等）でも
    署名が継続するか実験（DVTの真価の検証）
[ ] 次の検証候補：Lido CSM（ボンド）+ SSV DKGの組み合わせ
```
