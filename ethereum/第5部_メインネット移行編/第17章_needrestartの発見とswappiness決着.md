# 第5部・メインネット移行編 第17章 見えない自動再起動 — swappinessの決着とneedrestartの発見

> **「手動で管理しているつもり」の裏側で、OSは勝手に動いていた**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第15章のswappiness観察の最終決着と、その観察期間中に偶然発見した、OSレベルの自動再起動の仕組み（needrestart）への対応記録 |
| 実施日 | 2026年9月10日〜9月12日 |
| 対象 | vm.swappiness最終判断、needrestartの設定変更 |
| 前提 | 第15章（swappiness積み残しTODO、Doppelganger Protection導入） |

> ⚠️ 本章は機密情報を一切含みません。

---

## 1. swappinessの決着（9月10日）

第15章で「`1`のまま様子を見る」とした観察が、4日目を迎えた。

```
9/7（変更直後）：Swap 2.2Gi
9/8            ：Swap 3.4〜3.5Gi
9/9            ：Swap 2.9Gi
9/10           ：Swap 3.6Gi
```

明確な減少トレンドこそ見えなかったが、`available`（すぐに使える空きメモリの実質値）は常に10〜11Gi以上を維持しており、Swapの増減に伴う実害（OOM、レスポンス低下等）は一度も観測されなかった。

第11章（テストネット期）が`10`を選定した根拠は「32GB・SSVを含む重量級プロセス同時稼働・高速NVMe」という条件だったが、現在のメインネット環境はSSV非稼働で、そもそも前提条件が変わっている。メモリに実際の余裕がある以上、外部ガイド推奨の`1`（先回りの退避を抑え、物理RAMを使い切る方向）のまま運用を継続する判断とした。

```
[x] vm.swappiness=1 での観察 → 完了。available常に十分、実害なしと確認
[x] 観察結果を踏まえた最終判断 → 1のまま継続に決定（2026年9月10日）
```

---

## 2. 気になる変化 — Peer数急減とメモリの急変（9月11日）

swappinessの決着から間もない9月11日、node_check実行時に複数の異常な変化が同時に現れた。

```
Lighthouse Peers: 183 → 89（約半減）
Swap used        : 3.6Gi → 67Mi（ほぼゼロに）
buff/cache        : 10Gi → 16Gi（急増）
[11] Restart Required: NO → YES（7 updates pending）
```

Peer数の急減、Swapのリセット、buff/cacheの急増——これらを組み合わせると「Lighthouseが何らかの理由で再起動した」という仮説が浮かぶ。同時に現れた「Restart Required」「7 updates」という表示から、何らかのアップデート処理との関連も疑われた。

### 2-1. ログによる裏付け

```bash
sudo journalctl -u lighthouse --since "2026-09-10 07:40" | grep -iE "start|stop|restart"
sudo journalctl -u geth --since "2026-09-10 07:40" | grep -iE "start|stop|restart"
```

結果、geth・lighthouseとも、9月11日06:20頃に**停止→即座に再起動**していたことが確認できた。手動で操作した記憶はなく、`node_safe_stop.sh`を経由した形跡もない。

### 2-2. 原因の特定：dpkgログとの時刻照合

```bash
grep "2026-09-11 06:2" /var/log/dpkg.log
```

このログから、以下の時系列が浮かび上がった。

```
06:20:15〜06:20:16 UTC  libc6（Ubuntuの基幹共有ライブラリ）がアップデート
06:20:20 UTC            geth.service 停止開始
06:20:21 UTC            lighthouse.service 停止開始
```

libc6の更新完了から、わずか4〜5秒後にgeth・lighthouseが停止していた。この時間差の近さから、両者に直接の因果関係があると判断した。

### 2-3. 犯人はneedrestart

```bash
dpkg -l | grep needrestart
```

`needrestart`（Ubuntu標準搭載、v3.6-7ubuntu4.5）がインストール済みであることを確認した。これは、共有ライブラリの更新を検知し、そのライブラリをリンクしたまま稼働し続けているプロセスを自動的に再起動する仕組みである。

```
① 06:20:05 UTC apt-daily-upgrade.service が起動
② unattended-upgrade により libc6 が自動更新される
③ needrestart が「geth・lighthouseは古いlibc6をリンクしたまま」と検知
④ 両サービスを自動的に再起動
```

`Unattended-Upgrade::Automatic-Reboot`（OS全体の自動reboot）は`false`に設定されており、OS再起動そのものは正しく無効化されていた。今回発生したのは、それとは別レイヤーの、**needrestartによる個別サービスの自動再起動**だった。

> 💡 **これまで気づかなかった理由。** 毎週月曜に「node_safe_stop→apt upgrade→reboot」という手動メンテナンスを行っており、感覚としては「アップデートは手動で制御している」つもりだった。しかし実際には、日々の自動セキュリティ更新（unattended-upgrades）が裏側で別途動作しており、そちらは手動運用の管理下になかった。テストネット期にはこの事象が一度も確認されておらず、単に基幹ライブラリが更新される頻度が低く、これまで遭遇していなかっただけだった可能性が高い。

---

## 3. 対応：needrestartを「一覧表示のみ」モードに変更

### 3-1. Ubuntu 24.04特有の落とし穴

対応にあたり、Ubuntu 24.04（Noble）環境特有の注意点が事前調査で見つかった。Ubuntu 24.04には「Ubuntu mode」という独自の挙動があり、`/etc/needrestart/needrestart.conf`本体を直接編集して`$nrconf{restart}`を設定しても、その設定が無視されてサービスが自動再起動されてしまう不具合が報告されている（Launchpad bug #2068543）。この不具合の再現条件は「`$nrconf{restart} = 'l'`と設定した状態でlibc6等をapt再インストールする」というもので、今回の状況とほぼ一致していた。

報告されている正しい対処法は、本体ファイルではなく**`/etc/needrestart/conf.d/`配下にドロップインファイルを追加する方式**である。

### 3-2. 設定変更

```bash
sudo nano /etc/needrestart/conf.d/no-auto-restart.conf
```

```perl
# バリデータサービス（geth/lighthouse/mev-boost）が
# 基幹ライブラリ更新時に予告なく自動再起動されるのを防ぐため、
# 自動再起動ではなく一覧表示のみに変更する
$nrconf{restart} = 'l';
```

### 3-3. 動作確認テスト

作業前に、現状クリーンな状態であることを確認した。

```bash
sudo needrestart -r l
# → No services need to be restarted.
```

続いて、9/11に実際に起きた状況（libc6の更新）を意図的に再現するテストを行った。

```bash
sudo apt reinstall libc6
```

出力に、決定的な一文が現れた。

```
Disabling Ubuntu mode, explicit restart mode configured

Services to be restarted:
 ...
 systemctl restart geth.service
 systemctl restart lighthouse-vc.service
 systemctl restart lighthouse.service
 ...
```

needrestart自身が「明示的な再起動モードの設定を検知したため、Ubuntu modeを無効化する」と宣言しており、ドロップインファイルによる設定が正しく認識されたことが確認できた。geth・lighthouse・lighthouse-vcは「再起動が必要」と正しく判定されているが、**一覧に載るのみで、実際には再起動されない**という、狙い通りの挙動になっている。

### 3-4. 実ログでの最終確認

テスト直後、geth・lighthouseのプロセスID（それぞれ1019、1021）を確認したところ、9/11の事象時と異なり、**再起動の形跡は一切なく**、通常の同期処理（`Imported new potential chain segment`、`New block received`等）が継続していることを確認した。

```
✅ needrestart -r l で「再起動不要」と正しく判定
✅ apt reinstall libc6 実行後も、geth/lighthouseのPIDは変わらず
✅ 通常のログ（ブロック同期処理）が途切れることなく継続
```

---

## 4. 副次的な発見：影響範囲は想像以上に広かった

今回のテストで表示された「Services to be restarted」の一覧には、geth・lighthouse以外にも、以下のような多数のシステムサービスが含まれていた。

```
chrony、cron、fail2ban、rsyslog、ssh、vnstat、
systemd-networkd、systemd-resolved 等、20近いサービス
```

つまり、libc6のような基幹ライブラリの更新は、バリデータ本体だけでなく、**時刻同期・セキュリティ・監視系サービスまで含めた、システム全体に影響する規模の再起動**を引き起こしていたことになる。これまで気づかずに、これだけ広範囲のサービスが日々自動再起動され続けていた可能性がある、という事実が今回初めて可視化された。

---

## 5. まとめ

```
① swappiningは第15章からの継続観察の末、`1`のまま運用継続を
   正式決定した（2026年9月10日）。第11章の根拠（SSV稼働前提）が
   もはや現状と合わないため、条件変化を踏まえた再選定だった
② その直後、node_checkの異常な数値変化から、geth/lighthouseが
   予告なく自動再起動されていた事実を発見した
③ 原因は、unattended-upgradesによるlibc6の自動更新と、
   それを検知したneedrestartによる自動再起動の組み合わせだった
④ Ubuntu 24.04特有の「Ubuntu mode」の罠を踏まえ、
   /etc/needrestart/conf.d/へのドロップインファイル方式で対応した
⑤ apt reinstallによる意図的な再現テストで、修正が正しく
   機能していることを実ログ・実出力の両面から確認した
⑥ 副次的に、影響範囲がバリデータ本体だけでなく、
   システム全体の20近いサービスに及んでいたことが判明した
```

「毎週手動でメンテナンスしているから、アップデートは制御できている」という認識が、実際には裏側で動く自動更新の仕組みによって、静かに崩れていた——というのが今回の一件の本質だった。9/28のActivationを前に、この盲点を実害なく発見・是正できたことは、地味だが重要な備えになったと考えている。

---

## 今後の課題

```
[x] vm.swappiness=1 での観察・最終判断（本章3節にて完了）
[x] needrestartの自動再起動設定を'l'（list only）に変更、動作確認完了
[ ] node_check_mainnet.sh に、再起動待ちプロセスの一覧表示を追加検討
    （候補コマンド：sudo needrestart -b）
[ ] 'l'設定後は、基幹ライブラリ更新が「セキュリティパッチとしては
    適用済みだが、実行中プロセスには未反映」という状態を生み出すため、
    毎週月曜の定期メンテナンス（node_safe_stop→apt upgrade→reboot）で
    確実に解消されているか、継続して確認する
```
