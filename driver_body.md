<案件名> を見張るドライバ（汎用テンプレート：`<...>` を案件ごとに置換）。正本は状態ファイル `<state_file>`、共通契約（状態項目・原子的書き込み・systemd 分離起動・終端順序・報告境界）は `~/bantou/DESIGN.md` §5 に従う。報告は完了時と最終失敗時の1回のみとし、それ以外は無言で終える（`rescue_*` 欄は読むだけで消さない）。

案件パラメータ：対象ユニット `<worker_unit>`（既定 `bantou-<id>.service`）、作業ディレクトリ `<workdir>`、フェーズ別成果物フォルダ `<artifact_dir>`・ログ `<log_file>`・ブリーフ `<brief_file>`、ワーカー起動形 `~/bantou/launch_worker.sh <id> <workdir> <log_file> 7200 /bin/bash -c 'exec ~/.local/bin/agy --model <model> --dangerously-skip-permissions -p "$(cat <brief_file>)"'`（フラグが先、`-p` が最後）。

毎回の手順：
0. 状態ファイルを読む。`phase` が `done` か `failed` なら自身を無効化して無言で終える。非終端ならまず `driver_heartbeat_epoch` を現在時刻（UNIX秒）で原子的（一時ファイル→`mv`）に更新する。
1. 完了判定：`<artifact_dir>` に完了条件 `<done_condition>` が揃っていれば完了。残存ワーカーがあれば `systemctl stop <worker_unit>` で止めたうえで手順書どおりに検証し、結果をメインのチャットへ報告する。次フェーズがある場合は次フェーズのログ・ブリーフで上記起動形を実行し、2秒後に `ActiveState=active`・`MainPID>0`・`.exit.json` 不在・ログ即時エラー不在を確認して `phase=<next_phase>`・`attempts=1`・`worker_unit`・`worker_pid`・`last_restart_epoch=現在時刻` を書く。最終フェーズ完了時は先に `phase=done` を書いてから自身を無効化する。
2. 進捗判定：進捗時刻＝`<artifact_dir>` 内ファイル（`node_modules`・`.git` 等を除く）と `<log_file>` の最新 mtime。`systemctl show <worker_unit> -p ActiveState --value` が `active`（または `activating`）**かつ**進捗が30分以内の両方であるときのみ正常とし、`last_progress` を更新して無言で終える（進捗が新しくても非稼働なら手順3へ進む）。稼働中なのに進捗が30分超ならハングとみなし、`systemctl stop <worker_unit>`（`systemctl reset-failed <worker_unit> 2>/dev/null || true`）で停止して手順3へ進む。
3. 停滞と再起動：ユニットが非稼働で未完了、または手順2のハング停止後。
   - `<log_file>.exit.json`（あれば）とログ末尾を確認し、認証切れ・クォータ枯渇（`429` / `RESOURCE_EXHAUSTED` / `quota`）・課題ルールの疑問が原因なら自動修復しない。先に `phase=failed` と `note` を書いてから現状・原因・推奨をメインのチャットへ報告し、自身を無効化する。
   - `last_restart_epoch` が10分以内なら二重起動防止のため再起動せず無言で終える。
   - `attempts < 3` なら上記起動形で新規会話として再起動し、2秒後に `ActiveState=active`・`MainPID>0`・`.exit.json` 不在・ログ即時エラー不在を確認して `attempts+1`・`worker_unit`・`worker_pid`・`last_restart_epoch=現在時刻` を書き、無言で終える。
   - `attempts >= 3` なら先に `phase=failed` と `note` を書いてから最終失敗と現状をメインのチャットへ報告し、自身を無効化する。
4. 番犬の相互監視（無言）：`~/bantou/run/watchdog_heartbeat` が不在または20分超なら、フック `agy-delegation-watchdog` の有効化を1回試みて `watchdog_issue` に記録する（心拍復帰で `null` に戻す）。
