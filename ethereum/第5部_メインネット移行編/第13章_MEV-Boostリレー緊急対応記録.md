# 第5部・メインネット移行編 第13章 MEV-Boostリレー緊急対応記録 — 2日前の告知に、確実な情報で応える

> **リレー終了の告知を受けて、確実な情報源だけを根拠に、設定ファイルを書き換えた**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 運用者コミュニティでのリレー終了告知を受けた、MEV-Boost設定の緊急対応記録 |
| 実施日 | 2026年8月25日 |
| 対象 | mev-boost.serviceのリレー構成変更 |
| 前提 | 第5部第7章（メインネットサーバー構築、5リレー構成の選定経緯） |

> ⚠️ 本章は機密情報を一切含みません。コミュニティで得た告知は、発言者を特定せず内容のみを記録しています。

---

## 1. 告知：bloXroute Max-Profitリレーの終了

運用者コミュニティのディスコードチャンネルに、Lidoの公式アナウンスとして、以下の告知が投稿された。

> bloXrouteが、Max-Profitリレーを2日後（8月26日）にサービス終了する。使用している場合は、期限前に設定から削除すること。代替として、同社のRegulatedリレーを利用できる。

第7章で構築したメインネットのMEV-Boostは、5リレー構成のうちの1つとして、まさにこのbloxroute.max-profit.blxrbdn.comを使用していた。

```bash
systemctl cat mev-boost | grep -i relay
```

```
-relays https://...@aestus.live,https://...@agnostic-relay.net,
        https://0x8b5d2e73...@bloxroute.max-profit.blxrbdn.com,
        https://...@boost-relay.flashbots.net,
        https://...@relay.ultrasound.money
```

該当を確認し、期限までに対応することにした。

## 2. 代替リレーの確実な確認

Pubkeyを含むURLを扱うため、記憶や推測に頼らず、公式ドキュメント・複数の独立した情報源で裏付けを取った。

```bash
# Webで検索し、bloXroute公式ドキュメント、コミュニティガイド、
# 第三者ステーキングガイドの3系統で、同一のPubkeyが
# 一致することを確認した
```

確認できたRegulated Relayのエンドポイントは以下の通りだった。

```
https://0xb0b07cd0abef743db4260b0ed50619cf6ad4d82064cb4fbec9d3ec530f7c5e6793d9f286c4e082c0244ffb9f2658fe88@bloxroute.regulated.blxrbdn.com
```

第7章で確立していたリレー選定方針——no filtering（Aestus、Agnostic、Ultra Sound Relay）とOFAC filtering（bloXroute、Flashbots）のバランスを取る——を踏まえると、Max-Profitも「OFAC filtering」側の一角だったため、単純に削除するのではなく、同じfiltering属性を持つRegulatedリレーへ置き換えることで、5リレー構成とfiltering/no-filteringのバランス（2:3）を維持することにした。

## 3. 設定の書き換えと反映

```bash
sudo cp /etc/systemd/system/mev-boost.service /etc/systemd/system/mev-boost.service.bak
sudo sed -i 's|https://0x8b5d2e73e2a3a55c6c87b8b6eb92e0149a125c852751db1422fa951e42a09b82c142c3ea98d0d9930b056a3bc9896b8f@bloxroute.max-profit.blxrbdn.com|https://0xb0b07cd0abef743db4260b0ed50619cf6ad4d82064cb4fbec9d3ec530f7c5e6793d9f286c4e082c0244ffb9f2658fe88@bloxroute.regulated.blxrbdn.com|' /etc/systemd/system/mev-boost.service
sudo systemctl daemon-reload
sudo systemctl restart mev-boost
```

再起動後、ログで5リレーすべてが正しくロードされていることを確認した。

```
using 5 relays
relay #1: https://0xa15b525...
relay #2: https://0xa7ab7a9...
relay #3: https://0xb0b07cd...   ← Regulated Relayに置き換わった
relay #4: https://0xac6e77d...
relay #5: https://0xa1559ac...
listening on 127.0.0.1:18550
```

`systemctl cat mev-boost`で設定ファイル本体も確認し、Max-Profitの痕跡が残っていないことを、複数の角度（サービスログ・設定ファイル）から確認した。

---

## 5. まとめ

```
① コミュニティ経由の告知から、2日という短い期限内に
   確実な情報源のみを根拠として対応した
② Pubkeyを含む設定変更は、記憶や推測に頼らず、
   複数の独立した情報源で一致を確認してから実施した
③ 単純な削除ではなく、第7章で確立していたfiltering/
   no-filteringのバランス方針を踏まえ、同じ属性を持つ
   代替リレーへの置き換えを選んだ
④ 設定変更後、サービスログと設定ファイル本体の両方から、
   反映を確認した
```

## 6. 今後の課題・次のステップ

```
[ ] Lido公式のリレーAllowlist側の更新状況を、
    引き続き確認する（ガバナンスプロセス経由のため、
    反映には時間がかかる見込み）
[ ] 他のリレーについても、定期的な生存確認・
    アナウンスのウォッチを継続する
```
