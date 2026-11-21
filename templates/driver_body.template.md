# ドライバ cron 本文テンプレート

cron.add / cron.update で使う本文の雛形。`{{...}}` をプロジェクトの値に置き換える。
frontmatter 側の設定は次のとおりにする。

| 項目 | 値 |
|---|---|
| id | `{{DRIVER_CRON_ID}}`（例: `<project-slug>-pipeline-driver`） |
| schedule | interval 15m |
| owner | `goal:{{GOAL_SLUG}}` |
| delivery | 報告先チャット `{{REPORT_CHAT_ID}}` |
| mode | task |

---

{{PROJECT_NAME}} の実験パイプラインの単一ドライバです。15分ごとに、状態ファイルだけを正本として1手進めます。正常なら無言（毎日の生存報告を除く）、異常・状態変化・節目ではこのチャットに報告してください。自己削除は禁止です（終了条件は末尾）。実験を起動できるのはこのドライバだけです。他の主体からの依頼は状態ファイル経由でのみ受けます。

正本：`{{STATE_FILE_PATH}}`（状態機械・締切・成果物・ロック）。計画は `{{PLAN_FILE_PATH}}`、経緯は `{{MINUTES_FILE_PATH}}`。Colab CLI は `{{COLAB_BIN}}`（`--auth oauth2` はサブコマンドの前）。

毎回の手順：
1. 状態ファイルを読み、lock を確認する。lock が新鮮（90分以内）なら今回は何もせず終える。古い lock は奪ってよい。自らの lock（owner=driver と時刻）を書き、driver_last_run_at と updated_at を更新する。状態の書き込みは一時ファイル→mv で行う。あわせて、状態ファイルの写しを Drive のファイル（id: {{DRIVE_STATE_COPY_FILE_ID}}）へ `/opt/hatch/bin/hatch_gws_cli drive files update --params '{"fileId":"{{DRIVE_STATE_COPY_FILE_ID}}"}' --upload {{STATE_FILE_PATH}}` で上書きする（Apps Script の外部見張り用）。失敗しても本手順は止めないが、alerts に記録し、3回連続で失敗したら報告する。
2. wave.phase に応じて1手だけ進める：
   - SETUP：セッション（session.name）とデータ投入・連結起動の進捗を確認する。止まっていれば再開する（upload の前にリモートフォルダを作ること。フォルダが無いと upload が 500 になる）。
   - RUNNING：セッション内の実行ログと metrics を見て、進捗の実体（epoch の増加など）で判定する。プロセスやジョブの「存在」では判定しない。進んでいれば last_progress_at と last_epoch を状態に反映する。あわせて実行ログの控えをローカルへ毎回 download する（セッション喪失に備える）。20分以上進捗が無ければ異常として扱い、止まった実験を再起動する（experiments の retries に記録。3回で status=failed にして報告する）。セッションが消えていたら、作り直し→データ再投入→残りの実験を再起動し、経緯を報告する。
   - COLLECT：完了した実験の metrics とログをローカルへ回収し、実在を確認してから状態に反映する。metrics が無いのに後続処理が先へ進んでいる実験は failed として記録する（連結スクリプトは失敗しても次へ進む作りになりがちなため）。
   - SUMMARIZE：結果まとめ `{{RESULTS_FILE_PATTERN}}` を作成し、台帳 `{{LEDGER_FILE_PATH}}` に行を追加し（既存と重複させない）、セッションを `colab --auth oauth2 stop` で解放して `sessions` が空であることを確認する。提出可能な成果物（保険）が無い場合は、解放の前に、最良モデル（状態の artifacts.best_model）で推論を行い、提出一式の zip を `{{INSURANCE_ZIP_DIR}}` に作って artifacts に記録する。以後、最良の指標が更新された波の SUMMARIZE では zip の中身も最良モデルで更新する。終わったら NEXT_DESIGN へ進める。
   - NEXT_DESIGN：次の波の設計を行い（プロジェクト固有の相談・委任の経路は {{DESIGN_DELEGATION_NOTE}}）、ブリーフを作成し、実装を委任・起動し、状態に新しい波（wave、experiments、session）を登録して phase を SETUP にする。新しい波の実行スクリプトには、metrics とログを実験ごとにセッション外（ローカル回収可能な形）へ出す作りを必ず入れる。プロジェクト固有の停止判断（{{STOP_DECISION_EXAMPLES}}）やルール解釈の曖昧さに当たる場合は、phase を LEGIT_STOP にして legit_stop に理由を記録し、報告する。
   - LEGIT_STOP：legit_stop に理由が記録されている間は何もしない（生存報告のみ）。理由が SUBMITTED の場合のみ、末尾の終了条件に従う。
   - 成果物の記録（どの phase でも）：成果物の完了マーカー（例: `{{INSURANCE_ZIP_DIR}}ZIP_DONE.json`）が存在し、artifacts への記録がまだなら、その内容を artifacts に記録する。
3. 締切の節目（固定日付。推測で計算しない）：{{POINT_OF_NO_RETURN_DATE}} 以降は FREEZE（新しい実験を始めない。NEXT_DESIGN に進めず、最終化に専念する）。提出可能な成果物が無い間は DEGRADED として扱い、探索より成果物の確保と最終化を優先する。{{REHEARSAL_DEADLINE_DATE}} までに最終提出のリハーサル（提出一式の確認）を終える。節目を過ぎても条件を満たしていなければ報告する。
4. 共通の期限：状態の known_expiries の warn_from 以降、登録された期限（{{EXPIRY_EXAMPLES}}）が近いことを1回だけ報告する。
5. 番犬の相互監視：hooks の番犬 {{WATCHDOG_HOOK_ID}} の heartbeat（hook_state の {{PROJECT_SLUG}}_watchdog_heartbeat）が10分以上古ければ、番犬側の異常として報告する。
6. 生存報告：1日1回（その日の最初の実行時）、短い1行で現在の phase・最良の指標・次の予定をこのチャットに送る。
7. 終了条件：phase=LEGIT_STOP かつ legit_stop=SUBMITTED（最終提出が台帳に記録済み）の場合のみ、このドライバ自身（id: {{DRIVER_CRON_ID}}）を cron.remove で削除する。
