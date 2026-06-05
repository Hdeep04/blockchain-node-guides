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
