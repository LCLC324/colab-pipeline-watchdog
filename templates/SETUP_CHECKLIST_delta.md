# `SETUP_CHECKLIST.md` 差分（番頭方式への載せ替え）

対象：`~/bantou/skill/templates/SETUP_CHECKLIST.md`  
方針：チェックリスト本体は書き換えず、番頭（単一ドライバ＋状態ファイル＋共有番犬 `agy-delegation-watchdog`）へ移行する際に置換・削除・変更する箇所を節ごとに列挙する。

---

## §1. 状態ファイル作成

| 旧チェックリスト項目 | 番頭方式での置換・変更 |
|---|---|
| `templates/pipeline_state.template.json` を `pipeline_state.json` にコピー | `colab_state.template.json` を `<state_file>`（例：`state.json`）にコピーし、`<...>` を実値に置換する |
| `wave.phase_since` / `wave.setup_failures` / `retired: false` / `schema: 2`・`repair` 一式を設定 | 番頭 §5 必須のトップレベルキー（`phase="setup"`, `attempts=0`, `worker_unit`, `worker_pid=null`, `driver_heartbeat_epoch=null`, `last_restart_epoch=null`, `note=null`, `watchdog_issue=null`）と `colab.*`（`wave_id`, `phase_since`, `session_name`, `session_started_at=null`, `drive_evac_verified=false`, `deadline.*`）を設定する。`retired` および既定の `repair` 項目は削除する |
| `drive_copy.file_id` を §5 後に状態ファイルへ直接記入 | 状態ファイルに Drive ファイル ID を直書きしない。Apps Script を使う場合のみ `colab.drive_copy.enabled=true` とし、ID・認証情報は環境変数で渡す |
| （新規追加）実験開始前の Drive 退避確認 | 立ち上げ完了条件に「`colab.drive_evac_verified` をドライバ初回 `setup` で `true` にする（セッション内から Drive API への直接アップロード疎通確認）」を追加する |

## §2. ドライバ登録

| 旧チェックリスト項目 | 番頭方式での置換・変更 |
|---|---|
| `templates/driver_body.template.md` を埋めて **interval 15m** で登録 | `colab_driver_body.template.md` を埋めて **interval 10m**（共有番犬 `driver_stale_min: 25` と整合）で登録する |
| 完了条件：`driver_last_run_at` と `updated_at` 更新＋当日の生存報告1行到達 | 完了条件：`driver_heartbeat_epoch`（UNIX秒）と `updated_at` が更新され、`lock=null` に戻っていること（番頭標準では正常時無言のため生存報告必須チェックは外す） |

## §3. 番犬の有効化（大幅簡素化・置換）

| 旧チェックリスト項目 | 番頭方式での置換・変更 |
|---|---|
| `templates/watchdog.template.sh` を埋めて `~/hooks/scripts/<id>.sh` に配置 | **廃止**。案件別番犬スクリプトは作らない |
| `LEGIT_STOP_OK_REASONS_JSON` / `REPAIR_DIR` / `REPAIRER_DEF_REL` / 各種閾値の設定 | **廃止**。セッション経過時間・epoch 停滞・締切逆算などの Colab 固有判定はドライバ本文へ移管済み |
| `templates/watchdog_definition.template.json` を `hooks.add` で登録 | **廃止**。既稼働の共有番犬 `agy-delegation-watchdog` をそのまま使う |
| （置換）対象登録 | `bantou-colab-target.example.json` を参考に `~/bantou/run/targets/<id>.json` を1ファイル追加する（`phases.<phase>.progress_paths` にローカルの成果物・ログ控えを含める） |
| 完了条件：`<slug>_watchdog_heartbeat` の更新 | 完了条件：`~/bantou/run/watchdog_heartbeat` が5分以内に更新されており、`hooks.dry_run`（`agy-delegation-watchdog`）で追加対象が `silent` として正常評価されること |

## §4. 通知訓練（到達確認）

| 旧チェックリスト項目 | 番頭方式での置換・変更 |
|---|---|
| `driver_last_run_at` を2時間前に改ざん＋`watchdog_drill: true` で実 DM 到達確認 | **廃止**。共有番犬は通知コードを持たず（回復役 `wake` 方式）、基盤自体は稼働検証済みのため案件ごとの実 DM 訓練は不要 |
| （置換）設定疎通確認 | `targets/<id>.json` 追加後に `agy-delegation-watchdog` の `dry_run` を1回実行し、対象 JSON の構文エラー・必須キー欠落（`state_broken`）が無いことだけ確認する |

## §5. Apps Script の外部の目（任意追加へ変更）

| 旧チェックリスト項目 | 番頭方式での置換・変更 |
|---|---|
| 標準構成の一部として導入 | **VM 丸ごと停止の検出専用・任意追加**として位置づける（回復や操作は行わない） |
| `apps_script_code.gs.template` の参照キー（`driver_last_run_at`, `wave.phase`, `retired`, `legit_stop`） | 番頭状態ファイルに合わせて読み替える：`driver_last_run_at` → `driver_heartbeat_epoch`（UNIX秒→Date 変換）、`wave.phase` → `phase`、`retired` → `phase === 'done' \|\| phase === 'failed'`、`deadline` → `colab.deadline` |
| `drive_copy.file_id` を状態ファイルへ記入 | `colab.drive_copy.enabled: true` のみ状態に置き、対象ファイル ID や認証情報は環境変数側で管理する |

## §6. 自動修理（任意）

| 旧チェックリスト項目 | 番頭方式での置換・変更 |
|---|---|
| 番犬の `REPAIR_DIR` / `REPAIRER_DEF_REL` 設定と延長ルール整合確認 | **削除**。共有番犬には修理専用判定を持たせない。必要な長期案件のみ、ドライバ＋独立した修理担当 cron として任意に後付けする |

## §7. 生存報告の開始確認

| 旧チェックリスト項目 | 番頭方式での置換・変更 |
|---|---|
| ドライバの日次生存報告＋番犬の日次生存 DM の両方を確認 | **番犬の日次生存 DM は廃止**（共有番犬は正常時完全無言）。ドライバの相互監視で `watchdog_heartbeat` が20分以内であり、`watchdog_issue` が `null` のままであることを確認する |

## 終了手順（プロジェクト完了時）

| 旧チェックリスト項目 | 番頭方式での置換・変更 |
|---|---|
| `LEGIT_STOP` + `SUBMITTED` → `retired: true` → ドライバを `cron.remove` | `DESIGN.md` §5.2 に統一：**先に `phase="done"`（最終失敗時は `"failed"`）を書いてから**ドライバ cron を無効化する（順序厳守） |
| 番犬が無言になったことを確認してから番犬フックを無効化 | **共有番犬フックは絶対に無効化しない**（他案件も監視しているため）。`phase` が終端に入ると共有番犬は自動で `silent` 化し事象を消去する。片付けとして `~/bantou/run/targets/<id>.json` を削除するか `enabled: false` にする |
| Apps Script の2本のトリガー削除 | 任意で導入していた場合のみ同様に削除する |
