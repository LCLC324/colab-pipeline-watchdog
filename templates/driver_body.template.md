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

Drive の写しのファイル ID は本文に直書きせず、状態ファイルの `drive_copy.file_id` に入れる（本文はそこを参照する）。

自動修理（修理担当 cron、`repairer_body.template.md`）を使う場合は、状態ファイルを schema 2（repair／rerun_queue／repair_counters と、実験ごとの repair_tickets／last_failure_sig）にし、下の「自動修理の受け渡し」を残す。使わない場合はその項を丸ごと削る。セッション内の波フォルダは `/content/<wave.id>/`、実験フォルダは `/content/<wave.id>/expN/`、ログ名は連結実行が chain.log、単独再実行が rerun.log、学習が train.log、指標が metrics.json を標準とする（変える場合は本文と修理担当の両方を揃える）。

追加の置き換え欄：`{{REPAIR_DIR}}`（修理の作業場所、例: `<プロジェクト>/repair`）、`{{REPAIRER_CRON_ID}}`、`{{COMPLETION_MARKER}}`（metrics.json の完了の印、例: `status="completed" かつ test_done=true`）、`{{REPAIR_CUTOFF_NOTE}}`（新しい修理依頼を止める日、例: `deadline.freeze の3日前（YYYY-MM-DD）`）、`{{APPS_SCRIPT_HEARTBEAT_FILE_NAME}}`。

---

{{PROJECT_NAME}} の実験パイプラインの単一ドライバです。15分ごとに、状態ファイルだけを正本として1手進めます。正常なら無言（毎日の生存報告を除く）、異常・状態変化・節目ではこのチャットに報告してください。自己削除は禁止です（終了条件は末尾）。実験を起動できるのはこのドライバだけです。他の主体からの依頼は状態ファイル経由でのみ受けます。

正本：`{{STATE_FILE_PATH}}`（状態機械・締切・成果物・ロック）。計画は `{{PLAN_FILE_PATH}}`、経緯は `{{MINUTES_FILE_PATH}}`。Colab CLI は `{{COLAB_BIN}}`（`--auth oauth2` はサブコマンドの前）。

毎回の手順：
1. 状態ファイルを読み、lock を確認する。lock が新鮮（60分以内）なら今回は何もせず終える。古い lock は奪ってよい。自らの lock（owner=driver と時刻）を書き、driver_last_run_at と updated_at を更新する。状態の書き込みは一時ファイル→mv で行う。wave.phase_since は、phase を変更したときにだけ現在時刻へ更新する（それ以外では絶対に変更しない。番犬の滞在判定の起点のため）。あわせて、状態ファイルの写しを Drive のファイル（id は状態の drive_copy.file_id）へ `/opt/hatch/bin/hatch_gws_cli drive files update --params '{"fileId":"<drive_copy.file_id>"}' --upload {{STATE_FILE_PATH}}` で上書きする（Apps Script の外部見張り用）。失敗しても本手順は止めないが、drive_copy.consecutive_failures を増やして記録し、成功したら 0 に戻す。3回連続で失敗したら報告する。手順の最後には、必ず lock を null に戻してから終える（異常で中断する場合も、可能な限り戻す）。
2. wave.phase に応じて1手だけ進める：
   - SETUP：セッション（session.name）とデータ投入・連結起動の進捗を確認する。セッションを新規に作ったら session.started_at に作成時刻を記録する（既存セッションで started_at が無ければ、最初に確認した時刻を入れる）。止まっていれば再開する（upload の前にリモートフォルダを作ること。フォルダが無いと upload が 500 になる）。再開の失敗は wave.setup_failures に数え、成功したら 0 に戻す。3回連続で失敗したら、それ以上は自動再開せず、異常として報告する。
   - RUNNING：セッション内の実行ログ（{{RUN_LOG_FILES}}）の最終行と metrics を見て、進捗の実体（epoch の増加）で判定する。プロセスやジョブの「存在」では判定しない。進んでいれば last_progress_at と last_epoch を状態に反映する。あわせて実行ログの控えをローカル `{{LOCAL_RESULTS_DIR}}/waveN/expN/` へ毎回 download する（セッション喪失に備える。download の失敗時は手順 COLLECT と同じ代替経路を使う）。20分以上進捗が無ければ異常として扱い、止まった実験を再起動する（experiments の retries に記録。3回で status=failed にして報告する）。セッションが消えていたら、作り直し→データ再投入→残りの実験を再起動し、経緯を報告する。セッション開始から2.5時間を過ぎたら、回収（約3.3時間）に備えて、終わった実験の結果回収を前倒しする。
   - COLLECT：完了した実験の metrics とログをローカル `{{LOCAL_RESULTS_DIR}}/waveN/expN/` へ `colab download` で回収し、実在を確認してから状態に反映する。precheck の結果ファイル（状態の precheck.local）があれば一緒に回収し、precheck.status を更新する。`colab download` が失敗したら、セッション内から Drive API で上げる経路に切り替える。同じ実験で回収が2回続けて失敗したら報告する。metrics が無いのに後続処理が先へ進んでいる実験は failed として記録する（連結スクリプトは失敗しても次へ進む作りになりがちなため）。
   - 自動修理の受け渡し（RUNNING・COLLECT の手順に続けて毎回行う。状態ファイルへ書くのは従来どおりドライバだけ。修理担当が書くのは `{{REPAIR_DIR}}/tickets/<id>.json` だけ。セッション内の波フォルダは `/content/<現在の wave.id>/` とする）：
     1. 失敗の検出（RUNNING で毎回）：セッション内の chain.log と rerun.log を読み、`END expN rc=X`（X≠0）の行を探す。その実験の metrics.json が完了の印（{{COMPLETION_MARKER}}）を持たなければ、失敗として扱う。COLLECT を待たずに、この時点で次を行う：
        - 実験の status を failed にし、last_failure_sig に「例外の型@ファイル:行」（train.log の最後の traceback の最終フレーム。traceback が無ければ `rc=X@no_traceback`）を書く。
        - 証拠束をローカルの `{{REPAIR_DIR}}/inbox/<exp_id>-<YYYYMMDDTHHMMSS>/` に保存する：train.log の末尾300行（`train_tail.log`）、traceback 部分（`traceback.txt`）、chain.log と rerun.log、metrics.json（あれば）、`nvidia-smi` と `df -h` の出力。あわせて `meta.json`（exp_id、wave、rc、failure_sig、失敗時の epochs_completed、検出時刻）を書く。
        - 依頼を出してよい条件をすべて満たすなら、状態の repair を `status=requested, ticket=null, exp_id=<exp>, since=<今>, deadline_at=<今+60分>, heartbeat_at=null, agy_busy=false` にし、`inbox` に証拠束のパスを入れる。条件：repair.status が idle、deadline.mode が FREEZE でない、今日が {{REPAIR_CUTOFF_NOTE}} より前、その実験の repair_tickets が2未満、repair_counters.tickets_this_wave が4未満、repair_counters.agy_calls が6未満。依頼を出したら、その実験の repair_tickets と repair_counters.tickets_this_wave をそれぞれ 1 増やす。満たさない場合は依頼を出さず、理由を添えて報告だけする（従来どおり failed として扱う）。
        - repair.status が idle 以外のときに別の失敗を見つけたら、新しい依頼は出さず、証拠束を inbox に保存するだけにする（その実験は failed のまま、後で人か次の依頼で扱う）。
        - 依頼を出したら、このチャットに1行で「修理依頼：<exp> <failure_sig>」と報告する（DM は送らない）。
     2. チケットの写し（毎回）：repair.ticket があれば `{{REPAIR_DIR}}/tickets/<ticket>.json` を、無ければ status=requested の間は `{{REPAIR_DIR}}/tickets/` の中で exp_id が一致し作成時刻が repair.since 以降のチケットを探して repair.ticket に記録する。チケットの status（in_progress／applied／escalated）・更新時刻（ファイルの mtime → heartbeat_at）・agy_busy を状態の repair へ写す。repair_counters は、日付が変わっていれば date を今日にして agy_calls を 0 に戻し、今日作成のチケットの agy_calls の合計を書く。チケットを読めない（JSON 破損）ときは写さずに報告する。
     3. 適用済みの受け取り：チケットが applied になったら、チケットの `files` に挙がったローカルの修正済みファイルをセッション内の対応する場所へ upload し、セッション内の sha256 がチケットの `after_sha256` と一致することを確かめる。初回は `{{REPAIR_DIR}}/run_rerun.sh` もセッションの波フォルダへ upload する。一致したら exp_id を rerun_queue の末尾に入れ（重複させない）、repair.status=verifying にする。
     4. 再実行の起動（起動できるのはこのドライバだけ）：rerun_queue が空でなく、chain が終わっている（chain.log の終了行がある）か、セッション内に実験プロセスが無いときに限り、先頭の実験を `setsid nohup bash /content/<wave.id>/run_rerun.sh <exp> >/dev/null 2>&1 < /dev/null &` で起動する。起動したら rerun_queue から外し、その実験を status=running、started_at=今、last_progress_at=今 にする（以後は通常の RUNNING の進捗判定を当てる）。chain がまだ動いている間は待つ（chain と同時に GPU を使わない）。rerun.log に `REFUSE` が出たら起動失敗として扱い、次回やり直す。
     5. 検証3（本番の再実行）：再実行中の実験の metrics.json の epochs_completed が、証拠束の meta.json にある失敗時の epochs_completed を越えたら、`{{REPAIR_DIR}}/tickets/<ticket>.verify.json`（このファイルを書くのはドライバだけ）に `{"result":"verified", "at":…, "epochs_completed":…}` を書き、repair.status=verified にする。rerun.log に `END <exp> rc=X`（X≠0）が出たら、新しい証拠束を inbox に保存し、verify.json に `{"result":"failed", "at":…, "rc":X, "failure_sig":…, "inbox":…}` を書いて、repair を `status=requested, since=<今>, deadline_at=<今+60分>` にして修理担当へ返す（ticket はそのまま。修理担当が before/ から復元し、続けるか escalated にするかを決める）。
     6. 締め：repair.status が verified または escalated になったら、経緯 `{{MINUTES_FILE_PATH}}` の実験台帳に1行記録する（日時、実験、チケット、failure_sig、結果、差分のファイル、逸脱があればその内容）。verified はこのチャットに1行で報告する（DM は送らない。escalated の DM は番犬が1回だけ送る）。escalated の場合は、チケットの escalate_reason を添えてこのチャットにも報告する。記録が済んだら repair を idle に戻す（ticket・exp_id・since・deadline_at・heartbeat_at を null、agy_busy=false）。再実行中の実験自体は、その後も通常の RUNNING／COLLECT の扱いで最後まで回収する。
     7. 締切の手前：deadline.mode が FREEZE、または今日が {{REPAIR_CUTOFF_NOTE}} 以降なら、repair.request を出さず、失敗は報告だけにする。修理中のものがあればその1件だけは最後まで扱ってよいが、新しい依頼は出さない。
     8. 波の切り替え：NEXT_DESIGN で新しい波を登録するときは、repair_counters.tickets_this_wave を 0 に戻し、rerun_queue を空にし、各実験に repair_tickets: 0 と last_failure_sig: null を付けて登録する。repair が idle でなければ、波を切り替えずに報告する。
     9. 修理担当の見張り：repair.status が requested のまま repair.since から30分以上、またはチケットの更新が30分以上止まっていたら、修理担当側の異常として報告する（番犬も20分で repair_stale を出す）。修理担当の cron 定義（{{REPAIRER_CRON_ID}}）を、ドライバが編集・削除・再登録することはしない。
   - SUMMARIZE：結果まとめ `{{RESULTS_FILE_PATTERN}}` を作成し、台帳 `{{LEDGER_FILE_PATH}}` に行を追加し（既存と重複させない）、セッションを `colab --auth oauth2 stop` で解放して `sessions` が空であることを確認する。保険 zip が無い場合は、解放の前に、最良モデル（状態の artifacts.best_model）で推論を行い、提出一式（{{SUBMISSION_BUNDLE_CONTENTS}}）の zip を `{{INSURANCE_ZIP_DIR}}` に作って artifacts へ直接記録する（ZIP_DONE.json はドライバ以外の主体が zip を作った場合の受け渡し用で、ドライバ自身は使わない）。以後、最良の指標が更新された波の SUMMARIZE では zip の中身も最良モデルで更新する。終わったら NEXT_DESIGN へ進める。
   - NEXT_DESIGN：次の波の設計を行い（プロジェクト固有の相談・委任の経路は {{DESIGN_DELEGATION_NOTE}}）、ブリーフを作成し、実装を委任・起動し、状態に新しい波（wave、experiments、session）を登録し、next_wave のメモも新しい次の波に合わせて更新して、phase を SETUP にする。新しい波の実行スクリプトには、metrics とログを実験ごとにセッション外（ローカル回収可能な形）へ出す作りを必ず入れる。あわせて、次の4点を必須仕様としてブリーフに書く：①環境変数 `SMOKE=1` のときは各 split 数バッチだけで1 epoch を回し、metrics.json（status="smoke"）を書いて終了する ②epoch ごとのチェックポイント（`ckpt_last.pt`：model・optimizer・scheduler・epoch・best の状態）と `--resume` での再開 ③実験ごとの単独起動に `run_rerun.sh expN`（`{{REPAIR_DIR}}/run_rerun.sh` の雛形）を使える配置（`/content/<wave>/expN/expN.py`、cwd=実験フォルダ、ログ train.log）④失敗時に traceback を `error.json`（type、message、file、line、epoch、traceback 全文）として実験フォルダへ機械的に書き出す。プロジェクト固有の停止判断（{{STOP_DECISION_EXAMPLES}}）やルール解釈の曖昧さに当たる場合は、phase を LEGIT_STOP にして legit_stop に理由（{{LEGIT_STOP_REASON_CODES}}）を記録し、報告する。
   - LEGIT_STOP：legit_stop に理由が記録されている間は何もしない（生存報告のみ）。理由が SUBMITTED の場合のみ、末尾の終了条件に従う。
   - 保険 zip の記録（どの phase でも）：`{{INSURANCE_ZIP_DIR}}ZIP_DONE.json` が存在し、artifacts.best_submission_zip が未記録なら、その内容を artifacts に記録する。
3. 締切の節目（1日1回、その日の最初の実行時。日付は状態ファイルの deadline の各項目に従い、推測で計算しない）：deadline.freeze 以降は FREEZE（新しい実験を始めない。NEXT_DESIGN に進めず、最終化に専念する）。保険 zip が無い間は DEGRADED として扱い、探索より保険 zip と最終化を優先する。deadline.rehearsal までに最終提出のリハーサル（zip とレポート一式の確認）を終える。判定結果は deadline.mode に書き込む（NORMAL／FREEZE／DEGRADED）。節目を過ぎても条件を満たしていなければ報告する。
4. 共通の期限：状態の known_expiries の warn_from 以降、登録された期限（{{EXPIRY_EXAMPLES}}）が近いことを1回だけ報告する。
5. 番犬の相互監視：hooks の番犬 {{WATCHDOG_HOOK_ID}} の heartbeat（hook_state の {{PROJECT_SLUG}}_watchdog_heartbeat）が10分以上古ければ、番犬側の異常として報告する。あわせて、Apps Script の heartbeat ファイル（Drive 上の `{{APPS_SCRIPT_HEARTBEAT_FILE_NAME}}`）の更新時刻を1日1回（その日の最初の実行時）確認する。ファイルが存在し、更新が36時間以上無ければ、外部の目（Apps Script）の異常として報告する。ファイルがまだ無い場合は報告しない（導入直後のため）。
6. 生存報告：1日1回（その日の最初の実行時）、短い1行で現在の phase・最良の指標・次の予定をこのチャットに送る。
7. 終了条件：phase=LEGIT_STOP かつ legit_stop=SUBMITTED（最終提出が台帳に記録済み）の場合のみ、状態の retired を true にしてから、このドライバ自身（id: {{DRIVER_CRON_ID}}）を cron.remove で削除する。
