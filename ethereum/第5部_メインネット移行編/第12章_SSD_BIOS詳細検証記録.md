# 第5部・メインネット移行編 第12章 SSD/BIOS詳細検証記録 — 見ていた指標が違っていた

> **温度では効果が見えなかった対策が、実はレイテンシの安定化という別の形で効いていた**

---

| 項目 | 内容 |
|---|---|
| 位置づけ | コミュニティでのSSD議論をきっかけに、ハードウェア面の健全性を深掘り検証する |
| 実施日 | 2026年8月25日〜27日 |
| 対象 | SSD健康診断、BIOS電源管理設定、Grafanaの温度パネル是正 |
| 前提 | 第9章（ディスク逼迫とプルーニング実践記録）、第11章（監視基盤の拡張） |

> ⚠️ 本章は機密情報を一切含みません。コミュニティで得た助言は、発言者を特定せず内容のみを記録しています。

---

## 1. きっかけ：コミュニティでのSSD議論

第9章で記録した`prune-history`の実践結果を、運用者コミュニティのディスコードチャンネルに共有したところ、同様の構成（bare-metal Ubuntu、単一2TB NVMe）で運用する他の参加者から、ほぼ同一の実測値（8日で使用率93%、プルーニングで半秒程度・約300GB解放）が報告された。この一致は、`prune-history`というコマンドの挙動が、環境を問わず高い再現性を持つことの裏付けとなった。

同じやり取りの中で、SSD選定基準（TLC・DRAM・NVMeというフィルタ）や、単一ドライブとLVMプール化のトレードオフについても議論があり、自分自身が「予算の都合で2TBのまま1枚増設し、LVMでプールする」という、拡張性を優先し冗長性は定期バックアップで別途担保する方針であることを、あらためて言語化する機会になった。

## 2. SSD健康診断：まず基礎から確認する

議論の中で紹介された、コミュニティで広く参照されているSSD選定リスト（TLC・DRAM搭載・NVMeという基準でGood/Bad/Uglyに分類されたガイド）を確認したところ、使用中のSamsung 990 Proについて、以下2点の言及があった。

- Performanceモードでのみ安定動作するとの報告があり、Grub調整（`nvme_core.default_ps_max_latency_us=0 pcie_aspm=off`）が必要
- 990 Proの健康度が急速に低下するという報告があり、これを止めるファームウェアアップデート（1B2QJXD7）が存在する

まず、現状のSMART情報を確認した。

```bash
sudo apt install -y smartmontools
sudo smartctl -x /dev/nvme0n1
```

```
Firmware Version:      5B2QJXD7
Critical Warning:      0x00
Temperature:           44 Celsius
Available Spare:       100%
Percentage Used:       4%
Media and Data Integrity Errors: 0
Error Information Log Entries:   0
SMART overall-health self-assessment test result: PASSED
Unsafe Shutdowns:      1
```

ファームウェア（5B2QJXD7）は、劣化バグが修正された1B2QJXD7よりさらに新しいバージョンであり、該当しないことを確認した。摩耗率4%、エラー0件と、健康状態は良好だった。

唯一気になった`Unsafe Shutdowns: 1`は、過去に自宅のエアコン設置工事でブレーカーが落ちた際の記録であると特定できた。Media and Data Integrity Errorsが0であることから、実害はなかったと判断した。

## 3. Grubパラメータの追加（1回目）

```bash
sudo cp /etc/default/grub /etc/default/grub.bak
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.default_ps_max_latency_us=0 pcie_aspm=off"/' /etc/default/grub
sudo update-grub
```

`node_stop`で安全停止したのち再起動し、反映を確認した。

```bash
cat /proc/cmdline
# nvme_core.default_ps_max_latency_us=0 pcie_aspm=off
```

## 4. ioping実測：予想外の結果

効果測定として、レイテンシを実測した。

```bash
sudo apt install -y ioping
sudo ioping -D -c 30 /dev/nvme0n1
```

**稼働中（geth稼働中）の実測**
```
min/avg/max/mdev = 33.3 us / 312.6 us / 785.9 us / 297.8 us
```

続けて、より正確なベースラインを取るため、`node_stop`で全サービスを完全停止した状態でも計測した。

**完全停止中の実測**
```
min/avg/max/mdev = 70.3 us / 1.27 ms / 1.51 ms / 347.8 us
```

予想に反し、**無負荷であるはずの完全停止中の方が、稼働中よりもレイテンシが大きく、不安定だった。**「本来はサービスを止めて計測すべきではないか」「計測自体が再起動直後の一時的な負荷と重なっていたのではないか」という指摘を受け、この結果自体の解釈を保留にしたまま、原因調査に進んだ。

> 💡 **教訓：直感に反する実測値は、すぐに結論を出さず、条件を疑う。** 「無負荷の方が遅い」という結果は、通常の直感とは逆である。この違和感こそが、次の深掘り調査（パワーステート、ASPM）につながる出発点になった。

## 5. 深掘り調査：パワーステートとASPM

```bash
sudo nvme get-feature /dev/nvme0n1 -f 0x02 -H
# Power State (PS): 0

sudo nvme get-feature /dev/nvme0n1 -f 0x0c -H
# Autonomous Power State Transition Enable (APSTE): Disabled

cat /sys/module/pcie_aspm/parameters/policy
# [default] performance powersave powersupersave

sudo lspci -d 144d: -vv | grep "LnkCtl:"
# LnkCtl: ASPM L1 Enabled; RCB 64 bytes, Disabled- CommClk+
```

パワーステートは0（最高性能）、APST（自動遷移）も無効化されていたにもかかわらず、**ASPM L1自体はEnabledのままだった。** `pcie_aspm=off`のカーネルパラメータは正しく渡っているにもかかわらず、実際のリンク状態には反映されていなかった。

## 6. BIOS確認：物理アクセスでの検証

BIOS画面へのアクセス自体に手間取った。Del/F2/F7を順に試したが、電源投入直後にキーを押しても間に合わず、最終的に**「電源ボタンを押す前からDeleteキーを押しっぱなしにしておく」**という手順で入ることができた。

BIOS内を探索し、以下の項目を発見・変更した。

```
Advanced → CPU Configuration → CPU Common Options
  Global C-state Control: Auto → Disabled
  （CPUのディープスリープがレイテンシ増加につながるため、
    第2部の設計方針として意図されていたが、実際の構築ログには
    含まれておらず、未実施のまま残っていた項目）

Power Limit Setting: Balance Mode → Performance Mode
```

一方、PCI-E Port配下を探索したが、ASPMを明示的に制御する項目自体が見当たらなかった。

## 7. BIOS誤操作と、保存前の発見

Onboard Devices Setting配下の「PCI-E Port」を探索する過程で、`SSD0`・`SSD1`・`LAN`・`WLAN`という項目を見つけた。ヘルプテキストが「Enable/Disable/Auto、Auto used board default setting」となっていたため、これがASPM相当の設定だと誤認し、**すべて`Disabled`に変更してしまった。**

保存前に内容を再確認したところ、これはASPMではなく**PCIeポート自体の有効/無効を切り替える設定**であり、`SSD0`（起動ドライブ）や`LAN`（リモートアクセス経路）を無効化すれば、次回起動時にシステムが起動不能になる、あるいはリモートから復旧不能になるおそれがあることに気づいた。保存前の時点で全項目を`Auto`に戻し、事なきを得た。

> ⚠️ **教訓：ヘルプテキストの文言だけで判断せず、項目の実際の効果を疑うこと。** 「Enable/Disable/Auto」という表記は、電源管理設定にもポート有効化設定にも共通して使われる。保存前の確認を徹底する運用が、今回は実際にシステム起動不能という事態を防いだ。

## 8. 結論①：ASPMはこのBIOSでは制御不可能

PCI-E Port配下を含め、探索できる範囲のBIOS設定をすべて確認したが、ASPMを直接無効化する項目は、このBIOS（Minisforum AI X1、American Megatrends製、Version 02.22.0058）には存在しなかった。カーネル側の`pcie_aspm=off`パラメータも、単体では実際のリンク状態を変えられなかった。

Global C-state ControlとPower Limit Settingの変更は完了し、保存・再起動した。BIOS変更後の再起動では、`is_optimistic`がなかなか`false`に切り替わらない状態が続いたが、`geth`のログにはエラーがなく、「chain gapped」「reorging」という、短時間に複数回再起動を繰り返したことによる正常な追いつき処理であることを確認した。約1時間の放置で解消した。

## 9. CPU温度パネルの誤表示発見

BIOS変更後、node_checkの温度表示（当時は既存のGrafanaパネル「CPU Temperature」を参照していた）が52.9°Cと、通常より高く見えたことをきっかけに、`lm-sensors`を導入して実際のセンサー構成を確認した。

```bash
sudo apt install -y lm-sensors
sensors
```

```
k10temp-pci-00c3
  Tctl:         +46.9°C    ← 本当のCPUコア温度
acpitz-acpi-0
  temp1:        +46.0°C
amdgpu-pci-c400
  edge:         +43.0°C
nvme-pci-0300
  Sensor 1:     +44.9°C
  Sensor 2:     +52.9°C    ← これまで「CPU Temperature」として
                              表示していた値
```

Grafanaの「CPU Temperature」パネルは`max(node_hwmon_temp_celsius)`という、全センサーの最大値を機械的に取るクエリになっており、意図せずSSDのSensor 2を表示していたことが判明した。前日までCPU温度上昇として懸念していた数値は、実際にはSSDの温度だった。

## 10. コミュニティからの追加助言：pcie_port_pm=off

コミュニティで一連の対応を共有したところ、別の参加者から次の助言があった。

> 「`pcie_port_pm=off`と`pcie_aspm=off`を併用したところ、温度グラフがフラット化し、常時発生していた60°C台のピークが出なくなった」
>
> 「PL1/PL2（電力上限）のBIOS設定も調整した」

自分の環境（AMD Ryzen）ではPL1/PL2という用語自体は該当しないが、既に実施していたPower Limit Setting（Performance Mode）が、この助言と同じ方向性の対応だったと確認できた。あわせて`mitigations=off`（CPU脆弱性緩和策の無効化）も提案されたが、助言者の環境はIntelであり、AMD環境での妥当性が不確実であること、また鍵を扱うバリデータサーバーでセキュリティ緩和策を安易に切ることへの懸念から、この提案は見送った。

## 11. Grubパラメータの追加（2回目）

```bash
sudo cp /etc/default/grub /etc/default/grub.bak2
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.default_ps_max_latency_us=0 pcie_aspm=off"/GRUB_CMDLINE_LINUX_DEFAULT="nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off"/' /etc/default/grub
sudo update-grub
```

`node_stop`→OSアップデート→再起動の順で反映した。今回は`is_optimistic`も速やかに`false`へ切り替わり、前回のBIOS再起動時のような長い待ち時間は発生しなかった。

## 12. Grafanaパネルの是正

「CPU Temperature」パネルのクエリを、SSDの誤表示を避けるため修正した。

```promql
# 修正前
max(node_hwmon_temp_celsius)

# 修正後
node_hwmon_temp_celsius{chip="thermal_thermal_zone0", sensor="temp1"}
```

k10temp（AMD公式のCPUダイ内部温度）は、Node Exporter側では検出されておらず（原因未特定、今後の課題）、次善として`thermal_thermal_zone0`（ACPIサーマルゾーン、CPU周辺の近似値）を採用した。あわせて、SSD温度を正しく追跡するための専用パネルを新設した。

```promql
node_hwmon_temp_celsius{chip="nvme_nvme0", sensor="temp3"}
```

パネル名は「SSD Temperature (NVMe Sensor 2)」とし、凡例も`SSD Sensor 2`に整理した。

## 13. 効果測定：温度では見えなかった、レイテンシでの効果

2日分のデータで、SSD温度（Sensor 2）の推移を確認した。設定前は60°C近い急上昇があったが、`pcie_port_pm=off`適用後は、そうした極端なピークは見られなくなったものの、47〜56°C台の変動自体は継続しており、コミュニティで報告されていたような「完全なフラット化」は確認できなかった。

温度だけでは効果が判然としなかったため、`ioping`による再検証を行った。

| 条件 | 設定前（8/22、aspm=offのみ） | 設定後（8/27、port_pm=off追加後） |
|---|---|---|
| 稼働中 min/avg/max | 33.3 / 312.6 / 785.9 μs | 26.1 / 397.4 / 740.6 μs |
| 完全停止中 min/avg/max | 70.3 / 1270 / 1510 μs | 97.9 / 700.9 / 761.9 μs |

**完全停止中のレイテンシが、大幅に改善・安定化していた。** 設定前は「稼働中は速いが、完全停止すると急激に遅くなる（avg 1.27ms）」という、負荷状態によって性能が大きくぶれる挙動だったが、設定後は稼働中・完全停止中とも、ほぼ同じ水準（700〜760μs台）に収束していた。

> 💡 **見ていた指標が違っていた。** 当初「温度がフラットになるか」だけを効果測定の基準にしていたが、実際に`pcie_port_pm=off`がもたらした効果は、「負荷状態によらず、常に一定の応答速度を保つ」というレイテンシの一貫性だった。温度という単一の指標だけで「効果なし」と判断していたら、この発見は見逃していた。

---

## 14. まとめ

```
① コミュニティでのSSD議論がきっかけとなり、SMART健康診断・
   Grub調整・BIOS調査という、一連のハードウェア検証を実施した
② SSDの健康状態自体は良好（摩耗率4%、エラー0件）で、
   ファームウェアも劣化バグ修正済みだった
③ ioping実測で「完全停止中の方が稼働中より遅い」という、
   直感に反する結果に遭遇し、これが深掘り調査の出発点になった
④ pcie_aspm=off単体では、実際のASPM L1状態を変えられなかった
⑤ BIOS調査で、第2部で意図されていたが未実施だった
   Global C-state Controlを発見・是正した
⑥ 誤ってSSD0/LAN等を無効化する操作をしてしまったが、
   保存前の確認で発見・訂正できた
⑦ このBIOSには、ASPMを直接制御する項目自体が存在しない
   ことが判明した
⑧ 既存の「CPU Temperature」パネルが、実際にはSSDの
   センサーを表示していたという誤りを発見・是正した
⑨ コミュニティからの追加助言（pcie_port_pm=off）を実施したが、
   温度面での劇的な改善（フラット化）は確認できなかった
⑩ 温度ではなくレイテンシの一貫性という観点で再検証したところ、
   完全停止中のレイテンシが大幅に安定化していることが判明した。
   単一の指標だけで効果の有無を判断しないという教訓を得た
```

## 15. 今後の課題・次のステップ

```
[ ] k10temp（正確なCPUコア温度）がNode Exporterで検出されない
    原因の調査（優先度低、現状thermal_thermal_zone0で代替中）
[ ] mitigations=off の、AMD環境での妥当性の継続検討
    （現時点ではセキュリティを優先し見送り）
[ ] SSD増設・LVMプール化の実施
[ ] geth snapshot prune-stateの検証（未着手）
```
