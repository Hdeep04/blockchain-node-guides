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

## 第1部（検証編）固有の執筆ルール

### SSHセクションの順序
必ず以下の順番で記載すること：
1. 127.0.0.1・ポートフォワーディングの概念解説（先に理解させる）
2. 公開鍵の生成（ssh-keygen）
3. 各オプションの解説（-t / -C）
4. 実行の流れ（対話形式で全体を見せる）
5. パスフレーズの説明
6. 生成ファイルの確認
7. 公開鍵をVMに登録
8. SSH接続の実行
9. フィンガープリントの説明（接続時に遭遇するから最後）

### Gethセクションの順序
必ず以下の順番で記載すること：
1. インストールコマンド（PPAの追加・apt install・バージョン確認）
2. Systemdサービスの作成
3. 起動・ログ確認
4. 同期完了の確認（false になるまで待つ）

### チェックポイント同期サイトの解説
--checkpoint-sync-url の説明には以下を必ず含めること：
- ethpandaops は Ethereum Foundation 公式チームが運営していること
- サイト（https://checkpoint-sync.hoodi.ethpandaops.io）で何が確認できるか
  - Latest Finalized Epoch（確定済み最新ブロック）
  - Latest Justified Epoch（承認待ち最新ブロック）
  - Block Root（ブロックの識別ハッシュ）
- Lighthouseがこのサイトを「出発点」として使う仕組み
- 初回構築・再構築時にのみ参照する（通常稼働中は不要）

### beaconcha.in の解説
Step 6（動作確認）のbeaconcha.inセクションには
以下を必ず含めること：

#### アクセス方法
- URL: https://hoodi.beaconcha.in/
- 検索方法: バリデータの公開鍵（0x始まり）で検索
- Lido CSMウィジェットの「Monitoring」リンクからも直接アクセス可能

#### ダッシュボード各項目の読み方（表形式）
| 項目 | 意味 | 正常値 |
|---|---|---|
| Validators Live | アクティブなバリデータ数 | 登録数と一致 |
| BeaconScore | バリデータ総合スコア | 95%以上 |
| Attestations | 署名成功数 / 失敗数 | 失敗0が理想 |
| Att. Efficiency | アテステーション効率 | 95%以上 |
| Slashings | スラッシング発生数 | 必ず0 |
| APR | 年利回り | ネットワーク平均前後 |
| Sync Efficiency | 同期効率 | 100% |
| Source / Target / Head | アテステーションの種類別成功数 | 全て緑 |
| Avg. Incl. Distance | 署名がブロックに含まれるまでの平均距離 | 1.0〜1.5が理想 |

#### スロットマップの色の意味
| 色 | 意味 |
|---|---|
| 緑（塗りつぶし） | 署名成功 ✅ |
| 緑（枠のみ） | 同期委員会参加 |
| 赤枠 | その瞬間だけ遅延（軽微・問題なし） |
| グレー | 未来のスロット（未確定） |

#### 参考実測値（Hoodi Testnet / 10バリデータ運用時）
- BeaconScore: 97.39%
- Attestations: 2,250 / 0（失敗ゼロ）
- Slashings: 0 / 0
- Att. Efficiency: 97.39%
- APR: 1.8%

#### 補足説明
- ほぼ全部緑であれば正常稼働中
- 数個の赤枠はネットワークの一時的な遅延で発生するため連続しない限り問題なし
- BeaconScoreが90%を下回る場合はノードの状態を確認する

### Systemdサービスの共通解説ルール
各サービスの設定ファイルには以下の項目を必ず解説すること：
- User/Group: なぜethereum専用ユーザーを使うのか
- Restart=always: プロセスが落ちたら自動再起動する意味
- RestartSec=5: 5秒待ってから再起動する理由
- LimitNOFILE: ファイルディスクリプタの上限（必要な場合）

### 初心者向け解説の基準
以下の場面では必ず「なぜか」の説明を加えること：
- sudo を使う理由
- chmod / chown のパーミッション数値の意味
- ファイルパス（/var/lib/等）の意味
- curl コマンドの各オプション
- jq コマンドの役割
