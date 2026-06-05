# ethereum

## このディレクトリについて
Ethereum Lido CSMバリデータ構築 3部作

## ファイル構成
- 第1部_検証編.md      : VirtualBox VMでの検証
- 第2部_ベアメタル編.md : 物理PCへの移行・10鍵増設・長期安定運用
- 第3部_分散化SSV編.md  : SSVノード兼業（二毛作）

## 重要アドレス（Hoodi Testnet）
- Lido Withdrawal Vault (proxy): 0x4473dCDDbf77679A643BdB654dbd86D67F8d32f2
  ※ proxyを使用。implは内部処理用のため使用しない
  📎 https://docs.lido.fi/deployed-contracts/hoodi

- Lido EL Rewards Vault (fee-recipient): 0x9b108015fe433F173696Af3Aa0CF7CDb3E104258
  📎 https://docs.lido.fi/run-on-lido/csm/troubleshooting/setting-the-fee-recipient-for-csm-validators/

## 重要アドレス（Mainnet）
- Lido Withdrawal Vault (proxy): 0xB9D7934878B5FB9610B3fE8A5e441e8fad7E293f
- Lido EL Rewards Vault (fee-recipient): 0x388C818CA8B9251b393131C08a736A67ccB19297

## 重要URL
- Lido CSM Widget (Hoodi): https://csm.testnet.fi/
- Checkpoint Sync (Hoodi): https://checkpoint-sync.hoodi.ethpandaops.io
- SSV Network WebApp: https://app.ssv.network/
- ethstaker-deposit-cli: https://github.com/eth-educators/ethstaker-deposit-cli/releases

## Ethereum固有の注意事項
- fee-recipientは自分のアドレスを絶対に使わない（MEV stealing判定でペナルティ）
- スラッシング保護データは移行時に必ずエクスポート・インポートする
- SSV v2.4.2はHoodiネットワーク名に非対応（CLはAlchemy経由のハイブリッド構成で回避）
- Withdrawal Vaultアドレスのproxy/implを混同しない

## SSV Network（DVT）固有の情報

### バージョン情報
- 動作確認済みバージョン: v2.4.2-9117de68763017de6711515fb6e9dcad44bcc0e1
- 現時点（2025年6月）の最新安定版: v2.4.2 = latest（同一イメージ）

### 既知の問題（重要）
SSV v2.4.2 + ローカルLighthouse(Hoodi) での接続パニック問題

- 症状: 起動直後に nil pointer dereference パニック → Restartingループ
- 原因: SSV v2.4.2 は "holesky" を期待するが、
        ローカルLighthouseは "hoodi" と返答するため
        ネットワーク名のアイデンティティ不一致でパニック
- 解決策: ハイブリッド構成（下記参照）

### 現在の安定構成（ハイブリッド）
- EL（Geth）   : ローカル ws://127.0.0.1:8546
- CL（Beacon）: 外部Alchemy Hoodi Beacon API

理由：
- EL側はネットワーク名を検証しないためローカル接続可能
- CL側はネットワーク名を厳格に検証するため外部RPCで回避
- ELトラフィックをローカルで吸収することでAlchemyのCU消費を最小化

### SSV重要ポート
- 12001/UDP : P2Pピア探索（discv5）
- 13001/TCP : P2Pピア接続維持
- 15000/TCP : Metrics API（監視用）

### SSV重要ファイル
- /opt/ssv/data/encrypted_private_key.json : オペレーター鍵（要バックアップ）
- /opt/ssv/data/password.txt               : 復号用パスワード（要バックアップ）
- /opt/ssv/data/db/                        : スラッシング防止DB（要バックアップ）

### fee-recipient（SSV経由の場合も同じ）
SSV Network経由でも fee-recipient は
Lido EL Rewards Vault アドレスを必ず指定すること。
設定場所: SSV dApp → 右上「Fee Address」
※ Fee RecipientはウォレットAアドレス単位で設定される

### v2.5.x リリース時の確認事項
以下のコマンドでローカルLighthouseへの接続を再検証すること：
docker compose down
image タグを v2.5.x に変更
docker compose up -d
docker compose logs -f --tail 30
→ received head event が出ればローカル接続成功
