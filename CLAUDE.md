# blockchain-node-guides

## プロジェクト概要
50代キャリアチェンジ・ブロックチェーンノード運用ガイド（公開版）
27年間の会社員キャリアを経て、ゼロからブロックチェーンインフラエンジニアへ挑戦した実録。

## 対象読者
ITの基礎はあるが、ブロックチェーンは初めての方

## 構成
- ethereum/ : Ethereumバリデータ構築 3部作
- cardano/  : Cardano SPO構築（追加予定）
- bitcoin/  : Bitcoinフルノード構築（追加予定）

## 鉄則（必ず守ること）
- 機密情報（ユーザー名・秘密鍵・ニーモニック・パスワード・IPアドレス）は絶対に含めない
- ユーザー名は <your_user>、アドレス類は <...> のプレースホルダを使う
- アドレスは「明示 → 参照リンク → 解説」の3点セットで記載する
- コマンドには「なぜこのコマンドを打つのか」を必ず添える
- 失敗した経験・トラブルシューティングも学びとして記録する

## アドレス記載ルール
公式アドレスは以下の形式で記載する：

> ⚠️ アドレスは明示・リンク・解説の3点セット
> - アドレスを明示（proxy/implなど種別も明記）
> - 公式確認リンクを添える
> - 迷いやすい点を解説する

## コミットメッセージ
英語で記載する（例: Add reference links, Fix fee-recipient address）

## 重要なアドレス一覧（Hoodi Testnet）
- Lido Withdrawal Vault (proxy): 0x4473dCDDbf77679A643BdB654dbd86D67F8d32f2
- Lido EL Rewards Vault (fee-recipient): 0x9b108015fe433F173696Af3Aa0CF7CDb3E104258
- Lido CSM Widget: https://csm.testnet.fi/
- Checkpoint Sync URL: https://checkpoint-sync.hoodi.ethpandaops.io

## 重要なアドレス一覧（Mainnet）
- Lido Withdrawal Vault (proxy): 0xB9D7934878B5FB9610B3fE8A5e441e8fad7E293f
- Lido EL Rewards Vault (fee-recipient): 0x388C818CA8B9251b393131C08a736A67ccB19297
