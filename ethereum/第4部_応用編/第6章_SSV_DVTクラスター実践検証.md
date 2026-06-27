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

### 【追加検証】3-of-4閾値の冗長性実証 — 自分（578）を意図的に止めてみる

これまでの検証は「4人クラスターが全員揃っている、正常な状態」を確認
するものでした。本節では、3-of-4閾値という設計が実際に機能している
かを確かめるため、**自分（Operator 578）のSSVノードのみを意図的に
停止**し、残り3人（Operator A・B・C相当）だけでクラスターの署名が
継続するかを実機検証しました。

> ⚠️ **この検証は「自分のノードだけ」を操作するものです。** 他社
> （クラスター相手3社）に依頼・協力を求める必要はなく、自分のSSV
> ノードを止めて、その影響範囲を外側（beaconcha.in等）から観察する、
> という安全な方法で実施しました。

**検証手順：**

```bash
cd /opt/ssv
docker compose stop
```

geth/lighthouse等の本業（Lido CSM側10バリデータ）は一切止めず、
SSVノードのみを停止しました。

```
[12] SSV Node (DVT) Status
 - Container : exited
```

**約11分間停止した結果（beaconcha.inでの確認）：**

```
Epoch 104,979（停止中）：Attested ✅
Epoch 104,978（停止中）：Attested ✅
Epoch 104,977（停止中）：Attested ✅
Epoch 104,976（停止中）：Attested ✅
```

**自分のSSVノードが完全に停止していた間も、クラスター全体としての
アテステーションは1件も欠かさず成功し続けていました。** これは、
残り3人（Operator A・B・C）だけで3-of-4閾値を満たし、合意形成
（QBFTコンセンサス）が成立していたことの、実機による直接的な証拠
です。

> ✅ **これで「4人中3人いれば署名は成立する」という、DVT（分散
> バリデータ技術）の中核となる設計が、理論上の仕様の説明だけでなく、
> 実際に動いて確認できました。** 第6章でこれまで確認していたのは
> 「全員揃っている正常時の動作」でしたが、本検証により「誰か1人が
> 欠けても、クラスター全体としては機能し続ける」という、まさに
> DVTを採用する最大のメリットを、自分の目で確かめることができました。

**SSV Explorerの即時性についての発見：**

検証中、SSV Explorer（`explorer.ssv.network`・`app.ssv.network`の
Operatorページ）で自分の状態を確認しましたが、停止中も「Active」
「99.3% / 98.18%」という表示が変化しませんでした。調査すると、
これらの数値は「指定期間内におけるduty遂行率」という、長期の集計
指標であり、数分〜十数分程度の短い停止は、ほとんど数字に影響しない
ことが分かりました。

> 💡 **SSV Explorerは、長期的な傾向を見るには適していますが、
> 「今この瞬間、本当に動いているか」というリアルタイムの死活監視
> には向いていません。** これは、第8章・第9章で自前の死活監視
> （node_check.sh・Grafana Alerting）を構築してきた判断の正しさを、
> 改めて裏付ける結果でした。「クラスター相手3社の定期確認」という
> 課題には、SSV Explorerを定期的に目視確認する運用で十分対応できる
> 一方、「自分のノードの即時的な異常検知」には、別の専用の仕組みが
> 必要であるという、両者の役割の違いが明確になりました。

検証後、SSVノードを再開しました。

```bash
cd /opt/ssv
docker compose start
```

`node_check`で、`[12] SSV Node (DVT) Status`の`Container`が`active
(running)`に戻り、`Validator`が`attesting`に復帰していることを確認
し、検証を終了しました。

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

## 15. 運用Tips：死活監視・安全停止スクリプトの拡張

クラスターが実際に継続稼働を始めると、第2部で作成した自作スクリプト
（`node_check.sh`・`node_safe_stop.sh`）にも見直しが必要になりました。
「SSVノードが起動しているか」だけでなく「実際に署名タスクを完遂できているか」
「安全な順序で停止できるか」まで踏み込んで拡張し、実機での停止・OS更新・
再起動まで含めて検証した記録です。

### 15-1. node_check.sh：閾値署名の成功状況とCL接続先の可視化

第3部で追加した`[12] SSV Node (DVT) Status`セクションは、コンテナの
稼働状態・P2Pピア数・同期スロットまでは確認できますが、**「動いている」
ことと「4人クラスターの一員として署名タスクを完遂できているか」は
別の話**です。以下の2点を追加しました。

**① CL接続先の表示（片肺運転の可視化）**

```bash
# CL接続先の表示（片肺運転の可視化）
# 【Why】SSVノードのCL（Beacon）接続は外部RPC（Alchemy等）に依存する
# ハイブリッド構成のため、無料枠の枯渇や接続障害に気づけるよう
# 「今どこに繋がっているか」を毎回明示する。
SSV_BEACON_ADDR=$(docker inspect ssv-node --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^BEACON_NODE_ADDR=' | cut -d'=' -f2-)
if [ -n "$SSV_BEACON_ADDR" ]; then
    if [[ "$SSV_BEACON_ADDR" == *"127.0.0.1"* ]]; then
        echo -e " - CL Source : ${GREEN}Local${NC} (${SSV_BEACON_ADDR})"
    else
        SSV_BEACON_HOST=$(echo "$SSV_BEACON_ADDR" | awk -F/ '{print $3}')
        echo -e " - CL Source : ${YELLOW}External (${SSV_BEACON_HOST})${NC} (Single point of dependency)"
    fi
fi
```

> 💡 **なぜホスト名だけを表示するのか：** `BEACON_NODE_ADDR`にはAPIキーが
> 含まれている場合があります。`awk -F/ '{print $3}'`でホスト部分のみを
> 抜き出すことで、健康診断の出力をそのまま画面共有・スクリーンショットで
> 共有してもAPIキーが漏れない設計にしています。

**② 閾値署名（COMMITTEE duty）の成功状況**

```bash
# 閾値署名（COMMITTEE duty）の成功状況
# 【Why】「動いている」ことと「署名タスクを完遂できているか」は別。
# 直近のCOMMITTEE duty処理ログから成功・失敗を集計し、
# 4人クラスターの一員として実際に責務を果たせているか確認する。
SSV_DUTY_LOG=$(docker logs ssv-node --since 1h 2>&1 | grep -i "finished duty processing")
if [ -n "$SSV_DUTY_LOG" ]; then
    SSV_DUTY_TOTAL=$(echo "$SSV_DUTY_LOG" | wc -l)
    SSV_DUTY_SUCCESS=$(echo "$SSV_DUTY_LOG" | grep -c "100% success")
    if [ "$SSV_DUTY_SUCCESS" -eq "$SSV_DUTY_TOTAL" ]; then
        echo -e " - Duty (1h) : ${GREEN}${SSV_DUTY_SUCCESS}/${SSV_DUTY_TOTAL} success${NC}"
    else
        echo -e " - Duty (1h) : ${RED}${SSV_DUTY_SUCCESS}/${SSV_DUTY_TOTAL} success (check logs!)${NC}"
    fi
else
    echo -e " - Duty (1h) : ${YELLOW}No duty activity in last 1h${NC}"
fi
```

> 💡 **「100% success」の数え方：** SSVノードのログには、duty処理完了時に
> `finished duty processing (100% success)`という形式で結果が出力されます。
> 直近1時間分のログ件数と、その中の成功件数を比較することで、
> 一目で「すべて成功しているか」「一部失敗していないか」が分かります。

> ⚠️ **このチェックは、他の項目より実行に時間がかかる場合があります。**
> `docker logs --since 1h`は、コンテナの累積ログ量に応じて読み出しコストが
> 変わるため、SSVノードを長期間稼働させているほど、この行の表示に
> 数秒〜十数秒かかることがあります。`--since`の時間窓を短く（例：15分）
> しても改善は見られなかったため、情報量を優先して1時間のまま採用して
> います。スクリプトが固まったように見えても、壊れているわけではなく、
> ログ読み出しの待ち時間です。気になる場合は`--since`の値を環境に応じて
> 調整してください。

### 15-2. node_safe_stop.sh：停止順序の見直し

クラスターに参加する前のSSVノードは「起動・同期確認まで」が目的でしたが、
今は実際に4人クラスターの署名責務の1/4（3-of-4閾値）を担っています。
これは、Lido CSMのValidator Clientと同じ「署名役」として扱う必要がある
ことに気づきました。

**変更前の停止順序：**
```
1. lighthouse-vc（Lido CSM署名役）
2. lighthouse + mev-boost
3. geth
```

**変更後の停止順序：**
```
1. SSVノード（DVT署名役）← 新規追加・最優先
2. lighthouse-vc（Lido CSM署名役）
3. lighthouse + mev-boost
4. geth
```

> ⚠️ **SSVノードを一番最初に止める理由は2つあります。**
> 1つ目は、Lido CSMの署名役と同じ理由（署名タスクをいち早く安全に
> 終了させる）。2つ目は、**SSVノードがローカルGethのWebSocketに
> 依存している**ため、Gethより後に止めるとEL接続エラーが出続けてしまう
> からです。「署名役を優先して止める」「ELは皆が依存するので最後に
> 止める」という第2部の思想に、SSVノードもそのまま当てはめた結果です。

```bash
# 1. SSVノード（DVT署名役）を真っ先に停止
echo -e "\n1. Stopping SSV Node (DVT operator)..."
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q "^ssv-node$"; then
    cd /opt/ssv && docker compose stop
else
    echo -e " - SSV Node not running or not installed. Skipping."
fi
sleep 2

# 2. 署名役 (Validator Client) を停止
echo -e "\n2. Stopping Validator Client (lighthouse-vc)..."
sudo systemctl stop lighthouse-vc
sleep 2

# （以降、3. Beacon Node・MEV-Boost、4. Geth の順は第2部から変更なし）
```

停止後の検証にも、SSVコンテナの状態確認を追加しています。

```bash
# SSVコンテナの停止確認（systemdサービスではないため別途確認）
if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -q "^ssv-node$"; then
    SSV_STATUS=$(docker inspect -f '{{.State.Status}}' ssv-node 2>/dev/null)
    if [ "$SSV_STATUS" = "exited" ]; then
        echo -e " - ssv-node: ${GREEN}${SSV_STATUS} (Safe)${NC}"
    else
        echo -e " - ssv-node: ${RED}${SSV_STATUS} (Warning: Still active!)${NC}"
        EXIT_CODE=1
    fi
fi
```

> 💡 **SSVコンテナはsystemdサービスではないため、`systemctl is-active`
> による確認の対象に入りません。** `docker inspect`で別途状態を確認する
> 必要がある点が、既存サービス群との違いです。

### 15-3. 【実機検証】停止 → OS更新 → 再起動の通し確認

スクリプトの拡張は、画面上のレビューだけでなく、実際にベアメタル本番環境
で「止める→OSを更新する→再起動する→確認する」という一連の運用フローを
通しで実施し、検証しました。

```
実施フロー：
① node_safe_stop.sh 実行
② OSアップデート（sudo apt update && sudo apt upgrade -y）
③ サーバー再起動（sudo systemctl reboot）
④ node_check.sh で全項目を確認
```

**①の結果（抜粋）：**

```
1. Stopping SSV Node (DVT operator)...
 ✔ Container ssv-node Stopped
2. Stopping Validator Client (lighthouse-vc)...
3. Stopping Beacon Node and MEV-Boost...
4. Stopping Execution Client (Geth)...
[Verification] Check Service Status:
 - lighthouse-vc: inactive (Safe)
 - lighthouse: inactive (Safe)
 - mev-boost: inactive (Safe)
 - geth: inactive (Safe)
 - ssv-node: exited (Safe)
All services stopped safely. You can now reboot or power off.
```

SSVノードを含む全サービスが、想定した順序通りに安全停止できることを確認
しました。

### 15-4. 【新発見】再起動後、SSVコンテナだけ自動復帰しない問題

③のサーバー再起動後、想定外の挙動に気づきました。

```bash
sudo systemctl is-active geth lighthouse lighthouse-vc mev-boost
# → すべて active（systemdの enabled設定通り、自動復帰していた）

node_check
# → [1] System Services Status はすべて active
# → [12] SSV Node (DVT) Status の Container が exited のまま
```

**原因：Dockerの`restart`ポリシーの仕組み**

第3部で設定していた`docker-compose.yaml`の`restart`ポリシーは
`unless-stopped`でした。このポリシーには、systemdの`enabled`設定とは
異なる、見落としやすい仕様があります。

```
restart: unless-stopped の挙動：
  - OSがいきなり落ちた・クラッシュした場合
    → 「意図しない停止」と判定され、再起動後は自動的に復帰する
  - docker compose stop / docker stop で明示的に止めた場合
    → 「意図した停止」と記録され、次にDocker・OSが再起動しても
      自動的には復帰しない（手動で起動するまで止まったまま）
```

つまり、**「安全に・丁寧に手順通り停止させたこと」自体が、次回の自動復帰を
妨げる原因になっていた**という、直感に反する仕様でした。これまで（丁寧な
安全停止スクリプトを使う前）にサーバーをそのまま再起動していた場合は、
むしろ「意図しない停止」扱いとなり自動復帰していた可能性が高く、今回の
スクリプト改善によって初めて表面化した問題です。

**対応：再起動ポリシーをsystemdと同じ挙動に統一**

「安全に止めることを最優先しつつ、OS再起動時はsystemdサービスと同じ
ように自動復帰してほしい」という方針のもと、`restart`ポリシーを
`always`に変更しました。

```yaml
# /opt/ssv/docker-compose.yaml
services:
  ssv-node:
    restart: always  # unless-stopped から変更
```

```bash
cd /opt/ssv && docker compose up -d
```

> 💡 **`node_safe_stop.sh`での安全停止と`restart: always`は矛盾しません。**
> `docker compose stop`による「今、動いているものを安全に止める」操作と、
> `restart`ポリシーが決める「次にOS・Dockerが再起動した時、自動的に
> 立ち上げるかどうか」は、時間軸が異なる別の設定です。`always`に変更
> しても、`node_safe_stop.sh`を使った手動の安全停止フローは今までと
> 同じように機能します。変わるのは「OS再起動後の自動復帰」だけです。

変更後、実際に再度`docker compose up -d`で反映し、`node_check.sh`で
正常稼働（Container active、Sync Slot更新、Duty success）を確認しました。

> ⚠️ **設定変更直後は、`P2P Peers`の取得が一時的に`Error fetching
> metrics`になることがあります。** コンテナを再作成した直後はMetrics
> APIやP2P接続がまだ温まっておらず、1〜2分待って再実行すると正常な
> 数値に戻ります。一時的なエラー表示で慌てる必要はありません。

### 15-5. なぜEL（Geth）側は個別チェックを追加しなかったのか

CLの接続先（外部Alchemy）は新しく表示項目を追加しましたが、EL（Geth）の
接続先については、あえて個別のチェック項目を追加していません。これは
見落としではなく、**既存のチェック項目で実質的にカバーされている**という
判断によるものです。

```
CL（Beacon）→ 外部Alchemy → SSVノード独自の依存先
            → 既存の health check には存在しない依存関係
            → 個別の確認項目が必要だった

EL（Geth）  → ローカルGeth（ws://127.0.0.1:8546）
            → [1] System Services Status の geth: active で
              すでに「サービスとして起動しているか」は確認済み
            → [12]の Sync Slot が更新され続けていること自体が、
              SSVノードがEL（registry events等）を正しく受信できて
              いる証拠にもなっている
```

> 💡 **「サービスが起動しているか」と「SSVノードがそのサービスに正しく
> 接続できているか」は、理論上は別の話です。** 例えばGethは起動していても、
> 何らかの理由で`--ws`オプションが外れていたり、ポート8546だけ別の問題で
> 塞がっていれば、SSVノード側はEL接続エラーを起こす可能性があります。
> しかし、その場合は[12]の`Sync Slot`が更新されなくなる（停止する）ため、
> 結果的に異常が検知できます。CLのように「個別の依存先を明示しないと
> 気づけない」ものと、ELのように「既存項目の組み合わせで間接的に
> カバーできる」ものを区別し、後者には項目を増やさない、という判断です。
>
> 死活監視の項目を増やすこと自体が目的ではなく、**「何を見れば十分か」を
> 見極めて、必要最小限の項目に絞る**ことも、運用設計の一部だと考えています。

---

## 今後の課題

```
[ ] 1〜2オペレーターを意図的に停止し、閾値（3-of-4等）でも
    署名が継続するか実験（DVTの真価の検証）
[ ] 次の検証候補：Lido CSM（ボンド）+ SSV DKGの組み合わせ
```
