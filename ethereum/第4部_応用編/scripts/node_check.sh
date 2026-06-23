#!/bin/bash

# 色の定義
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}   Ethereum Node Health Check (Hoodi Bare-metal)    ${NC}"
echo -e "${CYAN}   Lido CSM Operator #<CSM_ID> | SSV Operator #<SSV_ID>       ${NC}"
echo -e "${CYAN}====================================================${NC}"
TZ="Asia/Tokyo" date "+%Y-%m-%d %H:%M:%S (JST)"

# 1. サービスの稼働状況 (systemctl is-active は sudo 不要)
echo -e "\n${YELLOW}[1] System Services Status${NC}"
for svc in geth lighthouse mev-boost lighthouse-vc; do
    STATUS=$(systemctl is-active $svc)
    if [ "$STATUS" = "active" ]; then
        echo -e " - $svc: ${GREEN}$STATUS${NC}"
    else
        echo -e " - $svc: ${RED}$STATUS${NC}"
    fi
done

# 2. リソース
echo -e "\n${YELLOW}[2] Resource Usage${NC}"
df -h / | awk 'NR==1 || NR==2'
echo ""
free -h

# 3. 同期ステータス
echo -e "\n${YELLOW}[3] Sync Status${NC}"
SYNC_INFO=$(curl -m 5 -s http://127.0.0.1:5052/eth/v1/node/syncing 2>/dev/null)
if [ -n "$SYNC_INFO" ]; then
    IS_SYNCING=$(echo $SYNC_INFO | jq -r '.data.is_syncing')
    SYNC_DISTANCE=$(echo $SYNC_INFO | jq -r '.data.sync_distance')
    [ "$IS_SYNCING" = "false" ] && SYNC_STATUS="${GREEN}$IS_SYNCING${NC}" || SYNC_STATUS="${RED}$IS_SYNCING${NC}"
    echo -e " - is_syncing:    $SYNC_STATUS"
    echo " - sync_distance: $SYNC_DISTANCE"
else
    echo -e "${RED}Error: Cannot connect to BN API.${NC}"
fi

# 4. ピア数
echo -e "\n${YELLOW}[4] Peer Count${NC}"
LH_PEERS=$(curl -m 5 -s http://127.0.0.1:5052/eth/v1/node/peer_count | jq -r '.data.connected' 2>/dev/null)
GETH_HEX=$(curl -m 5 -s -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result' 2>/dev/null)
if [[ "$GETH_HEX" == 0x* ]]; then GETH_PEERS=$(printf "%d" "$GETH_HEX" 2>/dev/null); else GETH_PEERS="Error"; fi
echo " - Lighthouse Peers: ${LH_PEERS:-Error}"
echo " - Geth Peers:       ${GETH_PEERS:-Error}"

# 5. 直近の署名活動 (一般権限で読める範囲を表示)
echo -e "\n${YELLOW}[5] Recent Attestations (Last 3)${NC}"
journalctl -u lighthouse-vc --no-pager -n 100 | grep "Successfully published attestations" | tail -n 3

# 6. MEV-Boost
echo -e "\n${YELLOW}[6] MEV-Boost Status${NC}"
MEV_STATUS=$(curl -m 5 -s http://127.0.0.1:18550/eth/v1/builder/status)
if [ "$MEV_STATUS" = "{}" ] || [ -n "$MEV_STATUS" ]; then
    echo -e " - Builder API: ${GREEN}Online${NC}"
else
    echo -e " - Builder API: ${RED}Offline${NC}"
fi
# 7. Validator Status & Balance (ディレクトリ動的取得)
echo -e "\n${YELLOW}[7] Validator Status & Balance${NC}"

# ACLで権限付与済みのため、sudoなしでディレクトリ名を読み取れる
PUBKEYS=$(ls -1 /var/lib/lido-csm/validators/ 2>/dev/null | grep "^0x" | paste -sd "," -)

if [ -z "$PUBKEYS" ]; then
    echo -e "${RED}Error: Cannot read validator directories in /var/lib/lido-csm/validators/${NC}"
else
    # 取得した全公開鍵を使って、Beacon Node API にステータスを問い合わせる
    BN_DATA=$(curl -m 5 -s "http://127.0.0.1:5052/eth/v1/beacon/states/head/validators?id=$PUBKEYS")

    if [ -n "$BN_DATA" ] && [ "$(echo "$BN_DATA" | jq -e '.data' 2>/dev/null)" != "null" ]; then
        echo "PUBKEY (SHORT) | STATUS         | BALANCE    | PERFORMANCE (Real-time)"
        echo "---------------------------------------------------------------------------"
        echo "$BN_DATA" | jq -r '.data[] | "\(.validator.pubkey[0:10]) \(.status) \((.balance | tonumber) / 1000000000)"' | while read pk st bal; do
            # ステータスによって色を変える
            if [[ "$st" == *"active"* ]]; then
                printf "${CYAN}%-14s${NC} | ${GREEN}%-14s${NC} | %.4f ETH | See Grafana Dashboard\n" "${pk}..." "$st" "$bal"
            elif [[ "$st" == *"pending"* ]]; then
                printf "${CYAN}%-14s${NC} | ${YELLOW}%-14s${NC} | %.4f ETH | See Grafana Dashboard\n" "${pk}..." "$st" "$bal"
            else
                printf "${CYAN}%-14s${NC} | %-14s | %.4f ETH | See Grafana Dashboard\n" "${pk}..." "$st" "$bal"
            fi
        done
    else
        echo -e "${RED}Error: Cannot fetch data from Beacon Node.${NC}"
    fi
fi
# 8. Time Synchronization Status (Detailed)
echo -e "\n${YELLOW}[8] Time Synchronization Status${NC}"
# chronyc tracking から情報を抽出
CHRONY_TRACKING=$(chronyc tracking)
OFFSET=$(echo "$CHRONY_TRACKING" | grep "Last offset" | awk '{printf "%.6f", $4}')
REF_ID=$(echo "$CHRONY_TRACKING" | grep "Reference ID" | awk '{print $4 " (" $5 ")"}')

# ズレが 0.01秒 (10ms) 以内ならグリーン、それ以上はレッド
IS_OK=$(echo "$OFFSET" | awk '{if ($1 < 0.01 && $1 > -0.01) print "true"; else print "false"}')

if [ "$IS_OK" = "true" ]; then
    echo -e " - Status      : ${GREEN}Synchronized${NC}"
    echo -e " - Last Offset : ${GREEN}${OFFSET}s${NC} (Ideal: < 0.01s)"
else
    echo -e " - Status      : ${RED}Large Offset Warning!${NC}"
    echo -e " - Last Offset : ${RED}${OFFSET}s${NC}"
fi
echo -e " - Reference ID: $REF_ID"
# 9. Security
echo -e "\n${YELLOW}[9] Security & Remote Access${NC}"
# fail2ban だけは sudo が必要（visudo で NOPASSWD 設定済み前提）
F2B=$(sudo fail2ban-client status sshd | grep "Currently banned" | awk '{print $4}')
echo -e " - fail2ban: ${GREEN}active${NC} (Banned: ${F2B:-0})"
echo -e " - Tailscale: ${GREEN}online${NC}"
# 10. Network Usage (昨日と本日の通信量)
echo -e "\n${YELLOW}[10] Network Usage (rx:Down / tx:Up / total)${NC}"

if command -v vnstat >/dev/null 2>&1; then
    IFACE="enp1s0"
    # 昨日の確定値
    vnstat -i $IFACE | grep "yesterday" | awk '{
        printf " - Yesterday : ↓ %-8s | ↑ %-8s | Total: %-8s\n", $2" "$3, $5" "$6, $8" "$9
    }'

    # 今日の実測値
    T_DATA=$(vnstat -i $IFACE | grep "today")
    T_RX=$(echo "$T_DATA" | awk '{print $2" "$3}')
    T_TX=$(echo "$T_DATA" | awk '{print $5" "$6}')
    T_TOT=$(echo "$T_DATA" | awk '{print $8" "$9}')

    # 今日の予測値 (vnstat -d から確実に「今日の予測」だけを1行抽出)
    T_EST=$(vnstat -i $IFACE -d | grep "estimated" | awk '{print $8" "$9}')

    printf " - Today     : ↓ %-8s | ↑ %-8s | Total: %-8s (Est: %-8s)\n" "$T_RX" "$T_TX" "$T_TOT" "$T_EST"
else
    echo -e "${RED} - vnstat is not installed.${NC}"
fi
# ==========================================
# [11] OS Update & Restart Status
# ==========================================
echo -e "\n${YELLOW}[11] OS Update & Restart Status${NC}"

# 再起動が必要かどうかをファイル（/var/run/reboot-required）の存在で判定
if [ -f /var/run/reboot-required ]; then
    echo -e " - Restart Required : ${RED}YES (*** System restart required ***)${NC}"
    echo -e "                      Please run './node_safe_stop.sh' and 'sudo reboot' when possible."
else
    echo -e " - Restart Required : ${GREEN}NO${NC}"
fi

# 適用可能なアップデートの数を確認
# apt-checkコマンドを利用（標準出力と標準エラー出力を合成して取得）
UPDATE_INFO=$(/usr/lib/update-notifier/apt-check --human-readable 2>&1)
if echo "$UPDATE_INFO" | grep -q "0 packages can be updated"; then
    echo -e " - Pending Updates  : ${GREEN}0 updates${NC}"
else
    # アップデートがある場合は黄色で警告
    echo -e " - Pending Updates  : ${YELLOW}Updates Available!${NC}"
    echo "$UPDATE_INFO" | sed 's/^/    /'
fi
# ==========================================
# [12] SSV Node (DVT) Status
# ==========================================
echo -e "\n${YELLOW}[12] SSV Node (DVT) Status${NC}"

# Dockerがインストールされており、ssv-nodeという名前のコンテナが存在するか確認
if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -q "^ssv-node$"; then
    # 1. コンテナの稼働ステータス
    SSV_STATUS=$(docker inspect -f '{{.State.Status}}' ssv-node 2>/dev/null)
    if [ "$SSV_STATUS" == "running" ]; then
        echo -e " - Container : ${GREEN}active (running)${NC}"

        # 2. P2Pピア数の取得 (Metrics APIから抽出)
        SSV_PEERS=$(curl -m 3 -s http://127.0.0.1:15000/metrics | grep '^ssv_p2p_peers_connected' | awk '{print $2}')
        if [ -n "$SSV_PEERS" ]; then
            echo -e " - P2P Peers : ${CYAN}${SSV_PEERS}${NC}"
        else
            echo -e " - P2P Peers : ${RED}Error fetching metrics${NC}"
        fi

        # 3. 最新の同期ログ抽出 (DutyScheduler のスロット処理を監視)
        SSV_LATEST_SLOT=$(docker logs ssv-node --tail 100 2>&1 | grep "DutyScheduler" | grep "received head event" | tail -n 1 | awk -F'"slot": ' '{print $2}' | awk -F',' '{print $1}')
        if [ -n "$SSV_LATEST_SLOT" ]; then
            echo -e " - Sync Slot : ${GREEN}${SSV_LATEST_SLOT}${NC} (Following Chain Head)"
        else
            echo -e " - Sync Slot : ${YELLOW}Waiting for chain events...${NC}"
        fi

        # 4. CL接続先の表示（片肺運転の可視化）
        # 【Why】SSVノードのCL（Beacon）接続は外部RPC（Alchemy等）に依存する
        # ハイブリッド構成のため、無料枠の枯渇や接続障害に気づけるよう
        # 「今どこに繋がっているか」を毎回明示する。
        SSV_BEACON_ADDR=$(docker inspect ssv-node --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^BEACON_NODE_ADDR=' | cut -d'=' -f2-)
        if [ -n "$SSV_BEACON_ADDR" ]; then
            if [[ "$SSV_BEACON_ADDR" == *"127.0.0.1"* ]]; then
                echo -e " - CL Source : ${GREEN}Local${NC} (${SSV_BEACON_ADDR})"
            else
                # ホスト名だけを抜き出して表示（APIキー等の漏洩を防ぐ）
                SSV_BEACON_HOST=$(echo "$SSV_BEACON_ADDR" | awk -F/ '{print $3}')
                echo -e " - CL Source : ${YELLOW}External (${SSV_BEACON_HOST})${NC} (Single point of dependency)"
            fi
        else
            echo -e " - CL Source : ${RED}Error fetching config${NC}"
        fi

        # 5. Metrics APIから各種公式メトリクスを一括取得
        # 【Why】以前はログ全文をgrepして集計していたが、SSVノードは
        # Prometheus形式で必要な数値（CL/EL健全性・duty成功率・
        # バリデータ状態）を公式に提供している。docker logsの読み出し
        # コスト（コンテナの累積ログ量に依存し時間がかかる）を避けられる。
        SSV_METRICS=$(curl -m 3 -s http://127.0.0.1:15000/metrics)

        # 5-1. CL（Beacon）の健全性：接続先がsyncedか
        SSV_CL_SYNCED=$(echo "$SSV_METRICS" | grep '^ssv_cl_sync_status{.*ssv_cl_sync_status="synced"' | awk '{print $2}')
        if [ "$SSV_CL_SYNCED" == "1" ]; then
            echo -e " - CL Status : ${GREEN}synced${NC}"
        else
            echo -e " - CL Status : ${RED}not synced (check CL Source!)${NC}"
        fi

        # 5-2. EL（ローカルGeth）の健全性：SSVノードから見て ready か
        SSV_EL_READY=$(echo "$SSV_METRICS" | grep '^ssv_el_sync_status{.*ssv_el_status="ready"' | awk '{print $2}')
        if [ "$SSV_EL_READY" == "1" ]; then
            echo -e " - EL Status : ${GREEN}ready${NC}"
        else
            echo -e " - EL Status : ${RED}not ready (check Geth/--ws!)${NC}"
        fi

        # 5-3. バリデータの実働状態（active/attesting/participating）
        SSV_VAL_ATTESTING=$(echo "$SSV_METRICS" | grep '^ssv_validator_validators_per_status{.*status="attesting"' | awk '{print $2}')
        if [ "$SSV_VAL_ATTESTING" == "1" ]; then
            echo -e " - Validator : ${GREEN}attesting${NC}"
        else
            echo -e " - Validator : ${YELLOW}not attesting${NC}"
        fi

        # 【Note】Duty失敗回数・Round Change回数の表示は、ここから削除した。
        # これらは ssv_runner_submissions_failed_total ・
        # ssv_validator_duty_rounds_changed_total という累積カウンター
        # （counter型）であり、単発のcurlでは「コンテナ起動からの
        # 累積値」しか取得できず、「いつ起きたか」が分からない。
        # 正しく期間を絞って見るには increase(...[1h]) のような
        # PromQL関数が必要だが、これはPrometheusサーバーが過去の値を
        # 記録していないと計算できず、シェルスクリプト単体では実現
        # できない。そのためGrafanaダッシュボード（SSV Duty Failures /
        # SSV Round Changesパネル）に役割を移管した。
        # 詳細は第8章参照。
    else
        echo -e " - Container : ${RED}${SSV_STATUS}${NC}"
    fi
else
    echo -e " - Container : ${YELLOW}Not installed or not running${NC}"
fi
echo -e "\n${CYAN}====================================================${NC}"