# bitcoin

## このディレクトリについて
Bitcoinフルノード構築手順書

## ファイル構成（予定）
- フルノード構築手順書.md : VirtualBox + Ubuntu 24.04でのフルノード構築

## Bitcoin固有の注意事項
- IBD（初期同期）にはdbcache=4000以上を推奨
- ストレージは最低1.2TB、推奨2TB以上
- txindex=1 で全トランザクション検索が可能になる
