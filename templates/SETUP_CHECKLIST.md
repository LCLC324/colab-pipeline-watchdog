# 立ち上げチェックリスト

Colab パイプライン監視一式を新しいプロジェクトに立ち上げる順番表。
上から順に行い、各段の「完了条件」を満たしてから次へ進む。
所要の目安は全体で30分程度（通知訓練の確認待ちを含む）。

前提：プロジェクトの置き場所 `{{PROJECT_DIR}}`、報告先チャット、締切日が決まっていること。

## 1. 状態ファイル作成

- [ ] `templates/pipeline_state.template.json` を `{{PROJECT_DIR}}/pipeline_state.json` にコピーし、`{{...}}` をすべて実値に置き換える
- [ ] 締切の節目（final / point_of_no_return / freeze / submit_target / rehearsal）を固定日付で入れる。deadline.mode は NORMAL で始める（以後はドライバが書き換える）
- [ ] wave.phase_since に作成時刻を入れる（空のままだと番犬が phase_since_missing を出す）。wave.setup_failures は 0
- [ ] experiments に最初の波の実験を登録する（想定時間が分かるものは expected_minutes も足す。番犬の RUNNING 滞在上限の見積りに使う）
- [ ] session.started_at は null のままでよい（ドライバがセッション作成時に記録する）
- [ ] drive_copy.file_id は 5. で Drive ファイルを作ってから入れる（それまでは写しのアップロードが失敗し、consecutive_failures が増える）
- [ ] lock は null、retired は false で始める

完了条件：`python3 -m json.tool {{PROJECT_DIR}}/pipeline_state.json` が通り、phase=SETUP・wave と session が実物と一致し、`{{` が1つも残っていない。

## 2. ドライバ登録

- [ ] `templates/driver_body.template.md` のプレースホルダを埋め、cron.add で interval 15m・owner=goal:{{GOAL_SLUG}}・delivery=報告先チャットとして登録する
- [ ] ドライバの初回実行を待つ（または run-now する）

完了条件：状態ファイルの driver_last_run_at と updated_at が初回実行時刻で更新され、lock が null に戻っており、wave.phase_since が（phase を変えていない限り）作成時の値のままで、報告先チャットに当日の生存報告（1行）が届いている。

## 3. 番犬の有効化

- [ ] `templates/watchdog.template.sh` の設定欄を埋め、`~/hooks/scripts/{{WATCHDOG_HOOK_ID}}.sh` に置く（編集は同じフォルダの一時ファイル→bash -n→mv。稼働中ファイルへの直接上書き禁止。シンボリックリンクは不可）
  - LEGIT_STOP_OK_REASONS_JSON には SUBMITTED と、ドライバ本文で使う停止理由コード（{{LEGIT_STOP_REASON_CODES}}）をすべて JSON 配列で入れる。未記入のままだと判定処理が落ち、watchdog_self_error が毎回出る
  - 閾値の既定値：driver_stale 60分、progress_stale 45分、session_age 3時間、legit_stop_long 48時間、lock_stuck 30分。滞留許容（STALL_ALLOWANCES_JSON）と滞在上限（DWELL_LIMITS_JSON）は変えずに始める
- [ ] `templates/watchdog_definition.template.json` を埋めて hooks.add で登録する
- [ ] hooks.dry_run で silent（異常なし）になることを確認する

完了条件：フックが enabled で、hook_state の `{{PROJECT_SLUG}}_watchdog_heartbeat` がポーリングごとに更新されている（heartbeat は各回の最後に書かれるので、更新されていれば判定と通知の試行まで完走している）。

## 4. 通知訓練（到達確認）

- [ ] 状態ファイルの driver_last_run_at の元の値を控える
- [ ] driver_last_run_at を2時間前の値に書き換え、あわせて `"watchdog_drill": true` を状態ファイルに足す（書き込みは一時ファイル→mv。ドライバの実行と重ならないよう、lock が null のときに行う）
- [ ] 番犬の次回ポーリング（または hooks.run）で、通知先に先頭が「【訓練】」の異常 DM（driver_stale）が実際に届くことを、受け手側（Slack の読み戻し等）で確認する
- [ ] driver_last_run_at を元の値に戻し、watchdog_drill を除去する

完了条件：「【訓練】」印つきの DM の到達を、送信ログではなく受け手側で確認できている。
注意：訓練で使った異常種別（driver_stale）はレート制限（2時間）の枠を消費する。その間、同種の本物の異常 DM は枠明けまで遅れる。検知自体は継続する。

## 5. Apps Script の外部の目

- [ ] 状態ファイルの写しを置く Drive ファイルを作成し、そのファイル ID を状態ファイルの drive_copy.file_id に入れる（Apps Script の STATE_FILE_ID と同じ値）
- [ ] ドライバが毎回、写しを Drive へ上書きアップロードし、drive_copy.consecutive_failures が 0 のままであることを確認する
- [ ] script.google.com で新規プロジェクトを作り、`templates/apps_script_code.gs.template` の STATE_FILE_ID と ALERT_TO を差し替えて貼る
- [ ] 時間主導型トリガー（checkPipelineState、例：1時間おき）を設定し、初回実行で Drive 読み取りとメール送信の権限を承認する

完了条件：Drive 上の写しの更新時刻がドライバの実行に追随して進んでおり、Apps Script の実行ログにエラーが無い。可能なら、写しの更新を止めて異常メールが届くことまで確認する。

## 6. 生存報告の開始確認

- [ ] ドライバの生存報告（1日1回・報告先チャット）が届く
- [ ] 番犬の生存 DM（1日1回・通知先）が届く

完了条件：両方が1回ずつ到達している。以後は「どちらかが来ない」こと自体が異常の合図になる。

## 終了手順（プロジェクト完了時）

- [ ] 最終提出が済み、台帳に記録されたら、ドライバが LEGIT_STOP＋SUBMITTED を確認し、状態の retired を true にしてから自分を cron.remove で削除する（この順番。手動で消さない）
- [ ] 番犬は retired=true かつ LEGIT_STOP＋SUBMITTED の状態を見て、ドライバ定義の消失も含めて全判定を止める（retired が他の状態と矛盾していれば retired_inconsistent を出す）。無言になったことを確認してから番犬フックを無効化する
- [ ] Apps Script のトリガーを削除する
- [ ] 状態ファイルと結果一式はプロジェクトフォルダに残す（記録として保持）
