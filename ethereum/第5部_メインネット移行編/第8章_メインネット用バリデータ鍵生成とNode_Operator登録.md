# 第5部・メインネット移行編 第8章 メインネット用バリデータ鍵生成とNode Operator登録 — 手順は同じ、重みが違う

> **テストネットと手順はほぼ同じ。しかし、実際の資産が動くという事実が、随所で確認の手を止めさせた**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第5部第1章のロードマップ「⑥メインネット用の新規鍵生成・1鍵運用開始」の実施記録 |
| 実施日 | 2026年8月20日 |
| 対象 | メインネット用バリデータ鍵の生成、Lido CSM Node Operatorとしての登録、監視体制の整備 |
| 前提 | 第1部（鍵生成の基本手順）、第5部第7章（メインネットサーバー構築） |

> ⚠️ 本章は機密情報を一切含みません。

---

## 1. ツールの更新確認

第1部で使用した`ethstaker_deposit-cli`は、半年の間にバージョンが上がっていた。単純に同じバージョンを使うのではなく、最新版の変更点を確認してから採用した。

### セキュリティ監査の反映

最新の正式版（v1.3.0）は、Trail of Bitsによるセキュリティ監査を反映したものだった。過去のバージョンでは、1回の実行で複数のkeystoreファイルを同時生成すると、秘密鍵が漏洩しやすくなるという脆弱性が指摘されていたが、今回は1本のみの生成のため、この影響は受けない。

### オプション名の変更

v1.3.0では、`--eth1_withdrawal_address`が非推奨化され、`--execution_address`に整理されていた。機能自体は同じだが、公式ドキュメントに沿って新しい名称を採用した。

```bash
./deposit new-mnemonic \
  --num_validators 1 \
  --chain mainnet \
  --execution_address 0xB9D7934878B5FB9610B3fE8A5e441e8fad7E293f
```

ダウンロードしたファイルは、公式記載のSHA256チェックサムと照合し、改ざん・破損がないことを確認してから実行した。

## 2. 鍵生成時の確認事項——テストネットと同じ、だが重みが違う

生成コマンド自体、聞かれる質問の内容も、第1部の記録とほぼ同一だった。ただし、確認する際の慎重さは明確に違った。

### withdrawal addressの確認

```
Repeat your withdrawal address for confirmation.:
0xB9D7934878B5FB9610B3fE8A5e441e8fad7E293f
```

これはMainnet用のLido Withdrawal Vaultアドレスであり、Hoodi用とは異なる値である。1文字の間違いが、後から修正不可能な資産の逸失につながるため、公式資料の値と1文字ずつ照合した。

### Compounding validatorsの確認

```
Please enter yes if you want to generate compounding validators with 0x02 withdrawal credentials...
Please type no or nothing if you want regular validators with 0x01 withdrawal credentials...  [no]:
```

第1部で確立した通り、Lido CSMのWithdrawal Vaultは0x02タイプと非互換であるため、必ず`no`（Enterのみ）を選択する。この判断基準自体はテストネットと変わらないが、間違えた場合の影響がテストネットより大きいことを意識しながら進めた。

### 生成後の検証

```bash
cat validator_keys/deposit_data-*.json | jq '.[] | {network_name, withdrawal_credentials}'
```

```json
{
  "network_name": "mainnet",
  "withdrawal_credentials": "010000000000000000000000b9d7934878b5fb9610b3fe8a5e441e8fad7e293f"
}
```

`network_name`が`mainnet`であること、`withdrawal_credentials`が`01`で始まり、続くアドレス部分がLido Withdrawal Vaultと完全一致することを確認した。

## 3. keystoreインポート時のパスワード管理トラブル

`lighthouse account validator import`コマンドでkeystoreをインポートする際、パスワードの扱いで2段階のつまずきがあった。

### 1段階目：平文パスワードの混入

```bash
sudo -u ethereum /usr/local/bin/lighthouse account validator import \
  --network mainnet \
  --datadir /var/lib/lido-csm \
  --directory /tmp/keys_import/validator_keys \
  --reuse-password
```

実行時、「パスワードを入力するか、Enterで省略するか」を問われる場面で入力したため、`validator_definitions.yml`に**平文でパスワードが記載された**状態になった。これはテストネットの記録にもあった通り、本来避けるべき状態である。

```bash
sudo -u ethereum sed -i '/voting_keystore_password/d' \
  /var/lib/lido-csm/validators/validator_definitions.yml
```

平文パスワードの行を削除し、代わりにパスワードファイル方式（`secrets/`ディレクトリ内に、公開鍵と同名のファイルとしてパスワードを保管）に切り替えた。

```bash
echo "パスワード" | sudo -u ethereum tee /var/lib/lido-csm/secrets/<公開鍵> > /dev/null
sudo chmod 600 /var/lib/lido-csm/secrets/<公開鍵>
```

### 2段階目：参照先の指定漏れ

このままLighthouse VCを起動したところ、以下のエラーで起動に失敗した。

```
The validator_definitions.yml file does not contain either of the following fields:
 - voting_keystore_password
 - voting_keystore_password_path
```

平文パスワードの行を削除した際、その代わりに指定すべき`voting_keystore_password_path`（パスワードファイルへの参照）を追記し忘れていたことが原因だった。

```bash
sudo -u ethereum sed -i "/voting_keystore_path/a\\  voting_keystore_password_path: /var/lib/lido-csm/secrets/<公開鍵>" \
  /var/lib/lido-csm/validators/validator_definitions.yml
```

この行を追記し、サービスを再起動したところ、正常に起動した。

```
Enabled validator          voting_pubkey: "0x8181..."
Initialized validators     disabled: 0, enabled: 1
Loaded validator keypair store   voting_validators: 1
```

> 💡 **教訓：「平文パスワードを消す」と「参照先を追加する」は、必ずセットで行う。** 片方だけでは、Lighthouse VCがパスワードの取得方法自体を失い、起動できなくなる。

### アクセス権限の壁

作業の過程で、`<your_user>`ユーザーが`/var/lib/lido-csm/`配下のディレクトリを直接読めない（`Permission denied`）場面が複数回発生した。これは`ethereum`専用ユーザーによる厳格な権限分離が正しく機能している証であり、想定通りの挙動である。確認が必要な場面では、都度`sudo`を用いるか、`setfacl`によるACL（アクセス制御リスト）を用いて、必要最小限の読み取り権限（`rX`）のみを付与した。

```bash
sudo apt install -y acl
sudo setfacl -m u:<your_user>:x /var/lib/lido-csm
sudo setfacl -R -m u:<your_user>:rX /var/lib/lido-csm/validators/
sudo setfacl -R -d -m u:<your_user>:rX /var/lib/lido-csm/validators/
```

親ディレクトリ自体にも、通過用の実行権限（`x`）を個別に付与する必要があった点は、今回新たに得た知見である。

## 4. Lido CSM Node Operatorとしての登録

ICS認証済みウォレットで`csm.lido.fi`（メインネット、`csm.testnet.fi`とは別サイト）に接続し、Node Operatorとして新規登録した。

### deposit dataの投入

生成した`deposit_data-*.json`の中身は、秘密鍵を含まない公開情報のみで構成されているため、CSM UIへの貼り付け自体に問題はない。UI上の「Parsed」表示で、公開鍵がサーバー側で確認した値と1文字も違わず一致していることを、貼り付け後にもう一度確認した。

### Bond拠出

```
Number of keys: 1
ETH amount: 1.5
```

MetaMaskでの署名により、1.5 ETH相当のBondを拠出した。トランザクションは、Owner → CS VettedGate → Community Staking Module → CS Accounting → stETH Tokenという経路を通り、Etherscan上でStatus: Successを確認した。

```
Node Operator #<your_operator_id>（メインネット、ICS）
Keys: Depositable 1 / Pending activation 0 / Active 0 / Withdrawn 0
Bond balance: 1.4999 stETH
```

これで、第5部第1章のロードマップに掲げていた「メインネット用の新規鍵生成・1鍵運用開始」が、Activation待ちの状態まで到達した。

### 余剰Bondの追加拠出

その後、ウォレットに残っていた0.5 ETHを、追加でBondに拠出した。ウォレットに置いたままでは資産が増えないのに対し、CSM Bondとして拠出しておけば、stETH建てで保有される限りリベース（複利的な増加）の恩恵を受けられる。この判断は、第5部第1章で確立した「報酬はBondへ再投資し、stETH建てのまま保有し続ける」という方針の延長線上にある。

```
Bond balance: 1.9999 stETH
Available to claim: 0.4999 stETH
```

ただし、Bondは通常のウォレットとは異なり、必要最低限の担保分は引き出せないこと、MEV窃取や重大な未稼働ペナルティが発生した場合はここから差し引かれることを踏まえ、「完全に自由な資産」ではなく「運用のバッファーを兼ねた置き場所」として位置づけている。

## 5. Gethのメモリ管理——過去の教訓を新環境に反映する

Node Operator登録後、`node_check`でリソース状況を確認したところ、Swap使用量が1.4GBで高止まりしていることに気づいた。

```bash
sudo systemctl status geth | grep Memory
```

```
Memory: 14.5G (peak: 22.0G swap: 100.4M swap peak: 335.7M)
```

Gethが、単独でサーバー全体（29GB）の約半分を消費していた。

### 過去の教訓との接続

VM環境での運用初期、Gethのメモリ使用量に上限を設けなかった結果、OOM Killer（メモリ不足によるプロセス強制終了）が発生した経験があった。その対策として`--cache`オプションでキャッシュ量を制限する方針を確立していたが、今回のメインネット新規構築時、`geth.service`のテンプレートにこの制限が反映されていなかった。

### 対処

```diff
ExecStart=/usr/bin/geth --mainnet --datadir /var/lib/ethereum/geth ... --metrics.addr 127.0.0.1
+ --cache 8192
```

サーバー全体のメモリ（29GB）に対し、Geth用に8GBを割り当てる設定に変更した。Activation前（バリデータがまだ署名業務を行っていない）という、影響の少ないタイミングを選び、あわせてOSアップデート（AppArmorの更新を含む）も適用したうえで、計画的に全サービスを停止し、再起動した。

```bash
sudo systemctl stop lighthouse-vc lighthouse mev-boost geth
sudo apt-get update && sudo apt-get upgrade -y
sudo reboot
```

### 結果

| | 対応前 | 対応後 |
|---|---|---|
| Gethメモリ使用量 | 14.5G（peak 22.0G） | 6.3G（peak 6.3G） |
| Swap使用量 | 1.4GB | 0B |

Gethのメモリ使用量は半分以下に抑えられ、Swapへの依存も解消した。半年前にVM環境で得た教訓が、規模の異なるメインネット環境でも、そのまま有効な対策として機能した。

## 6. CSM Sentinelの再登録

テストネット時代に利用していたTelegram通知Bot（CSM Sentinel）は、Ethereum用とHoodi用で別々のBotとして提供されている。メインネット用の`@CSMSentinel_bot`に対し、あらためて`/start`し、Node Operator #<your_operator_id>をフォロー登録した。

```
You are now following Node Operator #<your_operator_id>
```

これにより、Activation等の重要イベントを、能動的に確認しなくても通知で把握できる体制が整った。CSM Sentinelは開発者コミュニティによる非公式ツールであり、可用性の保証がない点は留意しつつ、Lido公式のOperator Portalでも紹介されている実質的な定番ツールとして採用した。

---

## 7. まとめ

```
① ethstaker_deposit-cliは、セキュリティ監査を反映した最新版
   （v1.3.0）を採用した。オプション名の変更（--execution_address）にも対応した
② 鍵生成の手順自体はテストネットとほぼ同一だが、
   間違えた場合の影響の大きさから、確認の重みが異なった
③ keystoreインポート時のパスワード管理は、「平文削除」と
   「参照先追加」を必ずセットで行う必要がある
④ ethereum専用ユーザーによる権限分離は、親ディレクトリの
   通過権限も含めてACLで最小限の付与が必要になる
⑤ Node Operator登録・Bond拠出は、公開情報のみで構成される
   deposit_dataの特性を理解した上で、確認を徹底して進めた
⑥ 余剰資金は、ウォレットに置くより、CSM Bondに拠出する方が
   stETHのリベースを活かせる。ただし完全に自由な資産ではない
⑦ Gethのメモリ管理は、過去（VM環境）の教訓が、規模の異なる
   メインネット環境でもそのまま有効だった
⑧ CSM Sentinelは、テストネットとメインネットで別のBotとして
   提供されており、あらためての登録が必要
```

---

## 8. 今後の課題・次のステップ

```
[ ] バリデータのActivation待ち（デポジットキュー通過）
[ ] Activation後、ブロック提案予定を考慮した安全な運用サイクルの確立
[ ] node_safe_stop.shのメインネット向け書き換え
    （バリデータインデックスの動的取得への変更）
[ ] Grafana/Prometheusによる監視体制の再構築
```
