<project_name> の Colab 実験パイプラインを見張る単一ドライバ（番頭 Colab アダプタ用テンプレート：`<...>` を案件ごとに置換）。正本は状態ファイル `<state_file>`、共通契約（状態項目・原子的書き込み・systemd 分離起動・終端順序・報告境界）は `~/bantou/DESIGN.md` §5 に従う。Colab セッションを操作できるのはこのドライバ（またはドライバが起動したワーカー）だけとする。報告は完了時・最終失敗時・締切節目未達時のみとし、通常時は無言で終える（`rescue_*` 欄は読むだけで消さない）。

案件パラメータ：
- 案件 ID `<id>`、対象ユニット `<worker_unit>`（既定 `bantou-<id>.service`、ローカル補助ワーカーを使う場合）、作業ディレクトリ `<workdir>`
- ローカル成果物フォルダ `<artifact_dir>`、ドライバ／ワーカーログ `<log_file>`、ブリーフ `<brief_file>`、実験台帳 `<ledger_file>`、保険成果物フォルダ `<insurance_dir>`
- Colab CLI `<colab_bin>`（`--auth oauth2` は常にサブコマンドの前に置く）、セッション名 `<colab_session>`、セッション内波フォルダ `<remote_wave_dir>`
- Drive 退避用の認証環境変数 `<drive_evac_env>`（トークン・URL・ファイル ID 等の秘密は本文や状態に直書きせず、環境変数の有無だけを確認する）
- 完了条件 `<done_condition>`（例：`metrics.json` が完了印を持ち、提出物・ログが非ゼロでローカル検証済み）
- ローカル補助ワーカー起動形（実装・設計を委任する場合）：`~/bantou/launch_worker.sh <id> <workdir> <log_file> 7200 /bin/bash -c 'exec ~/.local/bin/agy --model <model> --dangerously-skip-permissions -p "$(cat <brief_file>)"'`（フラグが先、`-p` が最後）

毎回の手順（10分周期）：

0. **状態読み込み・心拍・簡易ロック**：
   - `<state_file>` を読む。`phase` が `done` か `failed` なら自身を無効化して無言で終える。
   - `lock` が新鮮（60分以内）なら二重実行を避けて無言で終える。60分超の古い `lock` は回収してよい。
   - 非終端ならまず `driver_heartbeat_epoch`（現在 UNIX 秒）・`updated_at`（ISO8601）・`lock`（owner=`driver`, 時刻）を原子的（一時ファイル→`mv`）に書く。以降の処理終了時（異常中断時も含む）に必ず `lock` を `null` へ戻す。

1. **Colab 共通ガード（`setup` / `running` / `collect` で毎回）**：
   - **認証環境の確認**：`<drive_evac_env>` 等の必須環境変数が未設定、または Colab / Drive の認証切れ・クォータ枯渇（`429` / `RESOURCE_EXHAUSTED` / `quota`）を検出したら自動修復しない。先に `phase="failed"` と `note` を書いてから現状・原因・推奨をメインのチャットへ1回だけ報告し、自身を無効化する。
   - **セッション残り時間（約3.3時間回収対策）**：`colab.session_started_at` からの経過時間を計算する。
     - **2.5時間超**：完了済み実験の成果物・ログを前倒しで Drive 退避およびローカル `<artifact_dir>` へ回収する。
     - **3.0時間超（`colab.session_max_age_h`）**：回収間近とみなし、そのセッションで新規実験を起動しない。実行中実験の最新チェックポイントとログを退避し、セッション切替（再作成→`--resume` 再開）へ備える。
   - **セッション生存確認**：`setup` / `running` 中に `<colab_session>` が消失していたら、退避済み成果物とローカル控えを確認し、セッション再作成→`colab exec` で `mkdir -p`→データ再投入→未完実験を `--resume` で再起動する（再起動時は手順2の二重起動防止・`attempts` 上限3に従う）。

2. **フェーズ別の1手進行（`phase` に応じて1ステップだけ進める）**：
   - **`setup`**：
     - **実験開始前の Drive 退避疎通検証**：`colab.drive_evac_verified` が `false` のまま実験を開始しない。セッション内から Drive API へ小さなテストファイルを直接アップロードし、ローカル側から読み戻して一致を確認したら `colab.drive_evac_verified=true` を記録する（Drive API 資格情報が使えない他環境では、VM 側からの定期 `colab download` を代替経路として疎通確認する）。
     - セッション新規作成時は `colab.session_started_at` に現在時刻を記録する。
     - **`colab upload` 前の `mkdir -p`**：アップロード先のリモートフォルダを必ず事前に `colab exec` で `mkdir -p` してから `colab upload` する（親フォルダ不在だと HTTP 500 になる）。
     - データ投入とスモーク確認が済んだら実験を起動し、`phase="running"`・`attempts=0`・`colab.phase_since=現在時刻`・`last_restart_epoch=現在時刻` を書いて無言で終える。
     - セットアップが失敗したら `attempts+1`。`last_restart_epoch` が10分以内なら再試行を待つ。`attempts >= 3` なら先に `phase="failed"` と `note` を書いて1回報告し、自身を無効化する。
   - **`running`**：
     - **進捗の実体判定（epoch 増加）**：セッション内の実行ログ末尾と `metrics.json` を確認し、プロセス存在ではなく **epoch の増加**（または明確なステージ進行）で進捗を判定する。
     - 進んでいれば `colab.last_epoch` と `colab.last_progress_epoch` を更新し、ローカル `<artifact_dir>` へ最新ログ・指標の控えを反映する（共有番犬 `agy-delegation-watchdog` の `work_stale` 判定がローカル更新時刻を見るため必須）。
     - **Drive 退避（主経路）**：`colab download` は HTTP 500 が多発するため依存しない。チェックポイントや完了実験の成果物はセッション内から Drive API へ直接アップロードし、成功したら `colab.last_evac_epoch` を更新する。
     - **停滞・ハング判定（30分）**：epoch が30分以上進んでいない、または実験プロセスが異常終了していれば停滞とみなす。ログ末尾で認証切れ・クォータ枯渇・課題ルールの疑問を確認し、該当すれば即 `phase="failed"` 報告。そうでなければ `last_restart_epoch` が10分以内は再起動をスキップし、`attempts < 3` なら `--resume` で再起動して `attempts+1`・`last_restart_epoch=現在時刻` を記録する。`attempts >= 3` なら `phase="failed"` と `note` を書いて1回報告し、自身を無効化する。
     - 全実験が完了条件を満たしたら `phase="collect"`・`attempts=0`・`colab.phase_since=現在時刻` へ進める。
   - **`collect`**：
     - 完了した実験の `metrics.json`・ログ・モデルを Drive 退避先からローカル `<artifact_dir>` へ回収する（Drive 経由が使えない場合のみ `colab download` をフォールバック使用）。
     - `<done_condition>`（完了印・非ゼロサイズ・期待形状）をローカル実ファイルで検証する。`metrics.json` 不在のまま後続へ進んだ実験は失敗として記録する。
     - 同一実験で回収が2回連続失敗したら `note` に記録して報告する。全件の回収・検証が済んだら `phase="summarize"`・`attempts=0`・`colab.phase_since=現在時刻` へ進める。
   - **`summarize`**：
     - 結果まとめを作成し、台帳 `<ledger_file>` へ重複なく追記する。
     - 保険成果物（提出可能一式）が未作成、または最良指標が更新された場合は `<insurance_dir>` を更新し、`colab.artifacts` に記録する。
     - `<colab_bin> --auth oauth2 stop` 等でセッションを解放し、残存セッションが無いことを確認する（`colab.session_started_at=null`）。
     - 最終目標達成または `colab.deadline.mode == "FREEZE"` での最終提出完了（台帳記録済み）なら、先に `phase="done"` を書いてから結果をメインのチャットへ1回報告し、自身を無効化する。それ以外は `phase="next_design"`・`attempts=0`・`colab.phase_since=現在時刻` へ進める。
   - **`next_design`**：
     - `colab.deadline.mode == "FREEZE"` なら新規実験を起こさず最終化・提出準備へ切り替える。
     - 次波の設計・ブリーフ作成を行う。ローカル補助ワーカー（`agy` 等）を使う場合は必ず `launch_worker.sh` で分離起動し、2秒後に `systemctl show <worker_unit> -p ActiveState -p MainPID --value` が `active` かつ `MainPID > 0`、`<log_file>.exit.json` 不在・ログ即時エラー不在を確認して `worker_unit`・`worker_pid`・`last_restart_epoch` を記録する。稼働確認・停止は `systemctl show/stop <worker_unit>` のみ（`pgrep`/`kill`/`nohup` 禁止）。
     - 次波の実験リストを状態へ登録したら `phase="setup"`・`attempts=0`・`colab.phase_since=現在時刻` へ戻す。
     - 課題ルールの疑問や人の方針判断が必須な止め点に当たった場合は自動修復せず、`colab.stop_reason` と `note` に理由を書き、先に `phase="failed"` にしてからメインのチャットへ1回だけ報告し、自身を無効化する（人の判断後に `phase` を戻してドライバを再有効化する）。

3. **締切の逆算・任意の外部の目連携（1日1回、その日の初回実行時のみ）**：
   - `colab.daily_check_date` が今日と異なれば以下を実行し、完了後に今日の日付を書き込む。
   - **締切モード更新**：`colab.deadline`（`final` / `freeze` / `rehearsal`）を正本として `colab.deadline.mode` を更新する（推測計算しない）。`freeze` 以降なら `FREEZE`、保険成果物未作成なら `DEGRADED`、それ以外は `NORMAL`。`rehearsal` 等の節目を過ぎても未達ならメインのチャットへ報告する。
   - **外部の目（Apps Script・任意追加・検出専用）**：`colab.drive_copy.enabled` が `true` の場合のみ、環境変数で指定された Drive 先へ状態ファイルの写しを更新し（3回連続失敗で報告）、Apps Script の heartbeat ファイルが36時間以上古ければ報告する（未作成直後は無視）。

4. **番犬の相互監視（毎回・無言）**：
   - `~/bantou/run/watchdog_heartbeat` が不在または20分超なら、フック `agy-delegation-watchdog` の有効化を1回試みて `watchdog_issue` に記録する（心拍復帰で `null` に戻す）。
   - 最後に `lock` を `null` に戻して原子的書き込みで終える。
