# 第4部・応用編 第10章 SSV片肺運転の解消 — 複数Beacon Node構成で単一障害点を断つ

> **第3部・第6章・第7章・第8章で繰り返し指摘してきた「片肺運転」の課題に、ついに対策を実装する**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | 第4部・応用編の第10章。SSVノードのCL（Beacon Node）が外部RPC（Alchemy）単独に依存していた単一障害点を、複数エンドポイント構成で解消する |
| 前提 | 第3部（SSV構築）、第6章（SSV DVTクラスター実践検証）、第8章（死活監視の設計思想）が完了していること |
| 検証日 | 2026年6月26〜27日（Hoodi Testnet） |

> ⚠️ **本書は機密情報を一切含みません。** アドレス類・APIキーは `<...>` のプレースホルダです。

---

## 1. これまでの経緯（振り返り）

第3部でSSVノードを構築した際、ローカルのLighthouseに接続しようとすると
`nil pointer dereference`でクラッシュする問題に遭遇し、CL（Beacon Node）
の接続先を外部RPC（Alchemy）に退避させるハイブリッド構成を採用しました。

```
EL（Geth）  : ローカル（ws://127.0.0.1:8546）
CL（Beacon）: 外部Alchemy単独
              → これが「単一障害点（片肺運転）」として、
                第6章・第7章・第8章で繰り返し課題として
                記録されてきました
```

第8章では、この課題に対する対策候補として「v2.5.x登場後のローカル
Lighthouse接続再検証」「複数Beacon Nodeエンドポイントの併記」「Alchemy
以外の代替RPCプロバイダーの比較検討」を挙げていました。本章では、
これらを実際に検証し、単一障害点の解消を実装します。

---

## 2. 調査：v2.4.2は本当に古いバージョンなのか

まず、当時の問題（hoodi名でのクラッシュ）が、最新バージョンでは解消
されているかを確認しました。

```bash
curl -s http://127.0.0.1:15000/metrics | grep "target_info"
```

```
target_info{..., service_version="v2.4.2-9117de68763017de6711515fb6e9dcad44bcc0e1", ...} 1
```

SSV公式のGitHubリリースページを確認したところ、**v2.4.2が現時点での
最新版**であることが分かりました。つまり、アップデートによる解決は
期待できません。

### 2-1. hoodi名問題の正確な原因（再確認）

過去の調査記録を確認すると、当時の問題は「hoodi」という名前そのもの
が原因ではなく、より具体的な原因であることが分かりました。

```
症状：SSVノードがローカルLighthouseに接続すると
      nil pointer dereference でクラッシュ

根本原因：/eth/v1/config/spec エンドポイントのレスポンス形式の違い

  外部RPC（Alchemy）  : {"data": {...}}     ← dataラッパー「あり」
  ローカルLighthouse   : {...}              ← dataラッパー「なし」

  → SSV v2.4.2は「dataラッパーが必ずある」前提でコードが書かれており、
    ラッパーがないレスポンスを受け取るとクラッシュする
```

これは「設定ミス」ではなく、**SSVノード側の実装上の制約**です。
ローカルLighthouseの仕様自体は正しく、SSV側がその差異を想定していな
かったことが原因でした。SSV運営への問い合わせも過去に行いましたが、
v2.4.2が最新版である現時点では、この制約は解消されていません。

> 💡 **v2.5.x登場・もしくはSSV専用CLクライアント「Anchor」の動向は、
> 今後も注視する価値があります。** Lighthouse開発元のSigma Primeが
> 開発しているAnchorは、SSV専用設計のCLクライアントであり、この種の
> 互換性問題自体を解消する可能性があります。

---

## 3. 解決策：複数Beacon Nodeエンドポイント構成

ローカル接続が当面実現できない以上、**「外部RPCを1本から2本に増やす」**
という、現実的な対策を実装しました。

### 3-1. SSV公式のフェイルオーバー機能

SSV公式ドキュメントによると、`BeaconNodeAddr`にセミコロン区切りで複数
のエンドポイントを設定すると、最初のノードがオフラインになるか同期
から外れた場合、SSVは次のエンドポイントに切り替える仕組みが標準で
備わっています。エンドポイントは使いたい順序で設定し、最初のものが
プライマリになります。

```
BeaconNodeAddr: http://example.url:5052;http://example.url:5053
```

これは特別な実装をする必要がなく、**環境変数の設定を変更するだけ**で
利用できる、SSVノードの標準機能です。

### 3-2. 第二のRPCプロバイダーの選定

代替プロバイダーとして、以下を比較検討しました。

| プロバイダー | 無料枠 | サインアップ |
|---|---|---|
| PublicNode | 不明（要サインアップなしで試行したが、正しいBeacon APIのURL構造が確認できず断念） | 不要 |
| Chainstack | 月間300万リクエスト、25 RPS | 必要 |
| Ankr | Hoodi対応の専用ページあり | 必要 |

**Chainstack**を選定しました。理由は、無料枠が大きく、ダッシュボード
上で正確なエンドポイントURLが明示的に発行されるため、推測でURLを
構築する必要がないことです。

> 💡 **PublicNodeでの試行錯誤：** `ethereum-hoodi-beacon.publicnode.com`
> や`ethereum-hoodi-beacon-rpc.publicnode.com`等、複数のURL構造を
> 推測して試しましたが、いずれも404または無応答でした。Execution
> Layer（JSON-RPC）とConsensus Layer（Beacon API）でドメイン構造が
> 異なる可能性があり、正確なURLを公開ページから読み取れなかったため、
> 確実な方法（プロバイダーのダッシュボードで発行されたURLを使う）に
> 切り替えました。

### 3-3. Chainstackのセットアップ

```
1. Chainstackでアカウント作成（Developerプラン・無料）
2. プロジェクト作成 → Ethereum → Hoodi Testnetを選択してノードを作成
3. ダッシュボードの「Consensus client HTTPS endpoint」を確認
   （Execution client HTTPS endpointとは別の項目なので注意）
4. 動作確認
```

```bash
curl -s "<ChainstackのConsensus client endpoint>/eth/v1/node/syncing"
```

```json
{"data":{"is_syncing":false,"is_optimistic":false,"el_offline":false,"head_slot":"3356094","sync_distance":"0"}}
```

> ✅ **レスポンスが`{"data": {...}}`という、dataラッパー付きの形式で
> 返ってきていることを確認しました。** これはAlchemyと同じ形式であり、
> SSV v2.4.2がクラッシュする原因（ラッパーなしのレスポンス）には
> 該当しません。安全に併記できることが、ここで裏付けられました。

### 3-4. docker-compose.yamlの変更

```yaml
# Beacon APIは実績のあるAlchemy + Chainstackの2本構成（片肺解消）
- BEACON_NODE_ADDR=https://eth-hoodibeacon.g.alchemy.com/v2/<Alchemy_API_KEY>;<Chainstackのconsensus_endpoint>
```

```bash
cd /opt/ssv
docker compose up -d
```

`restart: always`の設定により、`docker compose up -d`でコンテナが
再作成され、新しい環境変数が反映されました。

---

## 4. 実機検証

### 4-1. メトリクスでの確認

```bash
curl -s http://127.0.0.1:15000/metrics | grep "ssv_cl_sync_status"
```

```
ssv_cl_sync_status{server_address="https://eth-hoodibeacon.g.alchemy.com/xxxxx", ssv_cl_sync_status="synced"} 1
ssv_cl_sync_status{server_address="https://ethereum-hoodi.core.chainstack.com/xxxxx", ssv_cl_sync_status="synced"} 1
```

**AlchemyとChainstack、両方が`synced=1`として個別に記録されている**
ことを確認しました。これは、SSVノードが本当に2つのエンドポイントを
並行して認識していることの直接的な証拠です。

### 4-2. 【発見】node_check.shが複数エンドポイントに対応していなかった

構成変更後、`node_check.sh`を実行したところ、`CL Status : not synced
(check CL Source!)`という、実態と矛盾する表示が出ました。`Sync Slot`
は正常に更新されていたため、これはSSVノード側の異常ではなく、
**スクリプト側の表示ロジックの問題**だと判断しました。

```bash
# 旧ロジック（単一エンドポイント前提）
SSV_CL_SYNCED=$(echo "$SSV_METRICS" | grep '^ssv_cl_sync_status{.*ssv_cl_sync_status="synced"' | awk '{print $2}')
if [ "$SSV_CL_SYNCED" == "1" ]; then ...
```

このロジックは、`grep`が複数行（Alchemy分・Chainstack分）にマッチして
しまい、`awk '{print $2}'`が複数行の値を想定していなかったため、
正しい判定ができていませんでした。

> 💡 **インフラの改善には、監視の仕組みの追従が必要です。** 単一
> 障害点を解消したことで、これまで「1つしかなかった」ものが「複数」
> になり、それに気づかず古い前提のまま監視スクリプトを使い続けると、
> 実態と異なる誤った表示をしてしまいます。インフラ変更時には、関連
> する監視スクリプトも合わせて見直す必要があるという、第8章の教訓が
> ここでも再確認されました。

### 4-3. node_check.shの修正

CL Sourceの表示を、セミコロン区切りで複数件あることを前提に、
Primary/Secondaryとして列挙する形に変更しました。

```bash
SSV_BEACON_ADDR=$(docker inspect ssv-node --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^BEACON_NODE_ADDR=' | cut -d'=' -f2-)
if [ -n "$SSV_BEACON_ADDR" ]; then
    SSV_ENDPOINT_COUNT=$(echo "$SSV_BEACON_ADDR" | awk -F';' '{print NF}')
    SSV_ENDPOINT_INDEX=0
    IFS=';' read -ra SSV_ENDPOINTS <<< "$SSV_BEACON_ADDR"
    for SSV_EP in "${SSV_ENDPOINTS[@]}"; do
        SSV_ENDPOINT_INDEX=$((SSV_ENDPOINT_INDEX + 1))
        if [ "$SSV_ENDPOINT_INDEX" -eq 1 ]; then
            SSV_EP_LABEL="Primary"
        else
            SSV_EP_LABEL="Secondary"
        fi
        SSV_EP_HOST=$(echo "$SSV_EP" | awk -F/ '{print $3}')
        echo " - CL Source : ${SSV_EP_LABEL}: External (${SSV_EP_HOST})"
    done
fi
```

CL Statusの判定も、「synced=1の件数 / 全エンドポイント数」という
集計方式に変更しました。

```bash
SSV_CL_SYNCED_COUNT=$(echo "$SSV_METRICS" | grep '^ssv_cl_sync_status{.*ssv_cl_sync_status="synced"' | awk '{sum+=$2} END{print sum+0}')
SSV_CL_TOTAL_COUNT=$(echo "$SSV_METRICS" | grep '^ssv_cl_sync_status{.*ssv_cl_sync_status="synced"' | wc -l)
if [ "$SSV_CL_TOTAL_COUNT" -gt 0 ] && [ "$SSV_CL_SYNCED_COUNT" -eq "$SSV_CL_TOTAL_COUNT" ]; then
    echo " - CL Status : ${SSV_CL_SYNCED_COUNT}/${SSV_CL_TOTAL_COUNT} synced"
elif [ "$SSV_CL_SYNCED_COUNT" -gt 0 ]; then
    echo " - CL Status : ${SSV_CL_SYNCED_COUNT}/${SSV_CL_TOTAL_COUNT} synced (degraded, check CL Source!)"
else
    echo " - CL Status : ${SSV_CL_SYNCED_COUNT}/${SSV_CL_TOTAL_COUNT} synced (check CL Source!)"
fi
```

> 💡 **「degraded（一部だけsynced）」という中間状態を表現できるように
> したのがポイントです。** 「全部synced（緑）」「全部not synced（赤）」
> の2値だけでなく、「2本のうち1本だけ落ちている」という、まさに
> フェイルオーバーが発生している最中の状態を、黄色で区別できるように
> しました。

### 4-4. 修正後の実機確認

```
[12] SSV Node (DVT) Status
 - Container : active (running)
 - P2P Peers : 5
 - Sync Slot : 3356209 (Following Chain Head)
 - CL Source : Primary: External (eth-hoodibeacon.g.alchemy.com)
 - CL Source : Secondary: External (ethereum-hoodi.core.chainstack.com)
 - CL Status : 2/2 synced
 - EL Status : ready
 - Validator : attesting
```

Grafanaダッシュボードでも、SSV CL Status (Beacon)パネルが正しく
「Synced」（緑）と表示され、Attestation Success Rate・SSV Validator
Attesting・SSV EL Statusもすべて健全であることを確認しました。

---

## 5. Chainstack無料枠についての確認

```
Developerプラン（無料）：
  月間 3,000,000 リクエスト単位
  25 RPS（1秒あたり25リクエストまで）
```

今回の構成では、Chainstackは「セカンダリ（フェイルオーバー用の予備）」
としての位置づけのため、Alchemyが正常に動いている限りはほとんど
使われません。第6章での実測（COMMITTEE duty 1回あたり数件のAPIコール
程度）を踏まえると、フェイルオーバー用途においては、この無料枠で
十分すぎる余裕があると判断しています。

---

## 6. まとめ

| 知見 | 内容 |
|---|---|
| v2.4.2は最新版だった | アップデートによる解決は期待できない。hoodi名問題は今のバージョンでも残存している |
| hoodi名問題の正確な原因 | 「hoodi」という名前自体ではなく、`/eth/v1/config/spec`のレスポンスにdataラッパーがあるかどうかの違い |
| 複数Beacon Node構成は標準機能 | `BeaconNodeAddr`をセミコロン区切りにするだけで、SSV公式のフェイルオーバー機能が有効になる |
| プロバイダー選定の実務 | URLを推測するより、ダッシュボードで発行された正確なエンドポイントを使う方が確実（PublicNodeでの試行錯誤から得た教訓） |
| インフラ変更は監視の見直しを伴う | 単一エンドポイント前提で書かれたスクリプトは、複数エンドポイント化すると誤った判定をする。インフラ変更時は監視ロジックも合わせて見直す必要がある |
| 中間状態の表現 | 「全部synced」「全部not synced」の2値だけでなく、「degraded（一部のみsynced）」という中間状態を用意することで、フェイルオーバー発生中の状態を区別できる |

---

## 今後の課題

```
[ ] Chainstackが実際にフェイルオーバーとして機能するか、
    意図的にAlchemy側を一時的に無効化して実機検証する
[ ] SSV専用CLクライアント「Anchor」の動向を継続的に確認
[ ] v2.5.x登場時に、ローカルLighthouse接続が可能になっているか再検証
[ ] クラスター相手3社（Operator A・B・C）の定期確認ルーチンの確立
```
