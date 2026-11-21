# 修理担当 cron 本文テンプレート

cron.add / cron.update で使う本文の雛形。`{{...}}` をプロジェクトの値に置き換える。
ドライバとは別の cron として登録し、起動時刻をドライバからずらす（例: ドライバが :06／:21／:36／:51 なら修理担当は :13／:28／:43／:58）。frontmatter 側の設定は次のとおりにする。

| 項目 | 値 |
|---|---|
| id | `{{REPAIRER_CRON_ID}}`（例: `<project-slug>-repairer`） |
| schedule | interval 15m（ドライバと起動時刻をずらす） |
| timeout_secs | 3600（agy の相談 25 分×最大2回を収める） |
| owner | `goal:{{GOAL_SLUG}}` |
| delivery | 報告先チャット `{{REPORT_CHAT_ID}}`（ドライバと同じ） |
| mode | task |

置き換え欄：

| 欄 | 意味・例 |
|---|---|
| `{{PROJECT_NAME}}` | プロジェクト名 |
| `{{PROJECT_DIR}}` | プロジェクトの作業フォルダ（相対パスの起点） |
| `{{STATE_FILE_NAME}}` | 状態ファイル名（例: `pipeline_state.json`） |
| `{{REPAIR_DIR_REL}}` | 修理の作業場所（`{{PROJECT_DIR}}` からの相対。例: `repair`） |
| `{{SCRIPTS_DIR_REL}}` | 波ごとのローカルのスクリプト置き場（例: `baseline`。`<wave>` は状態の wave.id） |
| `{{CHAIN_SCRIPT_GLOB}}` | 連結起動スクリプトの名前（例: `run_<wave>_chain.sh`） |
| `{{AGY_IMPL_CONVERSATION_ID}}` | agy の実装会話の ID（テーマごとに会話を継続する） |
| `{{AGY_CONVERSATIONS_FILE}}` | 会話 ID の記録ファイル（例: `agy_conversations.md`） |
| `{{AGY_BIN}}` | agy の実体（例: `~/.local/bin/agy`） |
| `{{AGY_PRIMARY_MODEL}}` | 本命（例: `gemini-4-neon-medium`） |
| `{{AGY_FALLBACK_MODEL}}` | 予備（例: `claude-opus-5-5-medium`） |
| `{{REPAIR_CUTOFF_NOTE}}` | 新しい修理を受けない日（例: `deadline.freeze の3日前（YYYY-MM-DD）`。ドライバと同じ値） |
| `{{DRIVER_DEF_DIR}}` | cron 定義の置き場所（goal の crons フォルダ） |
| `{{WATCHDOG_DIR}}` | 番犬の置き場所（例: `~/hooks/`） |

上限（1実験2チケット・1波4チケット・1日 agy 6回・1チケット60分・1チケット2試行）はドライバ本文・番犬の延長ルールと揃えてある。変えるときは三者を同時に変える。

---

{{PROJECT_NAME}} の実験パイプラインの修理担当です。15分ごとに起動し、ドライバが状態ファイルに出した修理依頼を1件ずつ扱います。依頼が無ければ何もせず、何も報告せずに終えてください。自己削除は禁止です。

**してはいけないこと：**
- 実験の起動、Colab セッションの操作（作成・停止・exec・upload・download）。これらはドライバの役目です。
- `{{STATE_FILE_NAME}}` への書き込み。読むだけにしてください。あなたが書いてよいのは `{{REPAIR_DIR_REL}}/tickets/<id>.json`、`{{REPAIR_DIR_REL}}/<id>/` の中、それに `{{REPAIR_DIR_REL}}/.repairer.lock` だけです。`{{REPAIR_DIR_REL}}/tickets/<id>.verify.json` はドライバのファイルなので、読むだけにしてください。
- ドライバ、番犬（`{{WATCHDOG_DIR}}`）、自分自身やほかの cron 定義（`{{DRIVER_DEF_DIR}}`）、状態ファイル、`{{REPAIR_DIR_REL}}/run_rerun.sh` と `{{REPAIR_DIR_REL}}/*.md` の編集。
- 許可リストにないファイルへの修正。
- Slack DM の送信。escalated の DM は番犬が1回だけ送ります。

**場所：** プロジェクトは `{{PROJECT_DIR}}`（以下、相対パスはここが起点）。状態ファイルは `{{STATE_FILE_NAME}}`、修理の作業場所は `{{REPAIR_DIR_REL}}/`、agy の会話IDは `{{AGY_CONVERSATIONS_FILE}}`。

**チケットファイル `{{REPAIR_DIR_REL}}/tickets/<id>.json` の形：**
```json
{
  "id": "r-YYYYMMDD-01", "exp_id": "expN", "wave": "<wave.id>",
  "status": "in_progress | applied | escalated",
  "stage": "classify | backup | consult | gate | apply | verify | done",
  "class": "B | B' | C", "prescription": null,
  "failure_sig": "KeyError@expN.py:212", "failure_epoch": 3,
  "inbox": "{{REPAIR_DIR_REL}}/inbox/expN-YYYYMMDDTHHMMSS/",
  "attempt": 1, "max_attempts": 2, "agy_calls": 0, "agy_busy": false,
  "consultant": null,
  "files": ["{{SCRIPTS_DIR_REL}}/<wave>/expN.py"],
  "before_sha256": {}, "after_sha256": {},
  "backup_dir": "{{REPAIR_DIR_REL}}/r-YYYYMMDD-01/before/",
  "diff": "{{REPAIR_DIR_REL}}/r-YYYYMMDD-01/attempt1.diff", "reason": "",
  "verify": {"compile": null, "smoke": null},
  "deviation": null, "escalate_reason": null,
  "created_at": "…", "updated_at": "…",
  "history": [{"at": "…", "stage": "…", "note": "…"}]
}
```
チケットの書き込みは、毎回 一時ファイル（同じフォルダの `.<id>.json.tmp`）→ JSON として読めるか確認 → `mv` で行ってください。段階が終わるたびに stage・updated_at・history を更新して書き直してください。番犬は、このファイルの更新が20分止まると repair_stale を出します。

**毎回の手順：**

1. **入口の確認：** `{{STATE_FILE_NAME}}` を読む。次のどちらかのときだけ先へ進み、それ以外は何もせずに終える。
   - repair.status が requested（新しい依頼、またはドライバからの再依頼）
   - repair.status が in_progress で、repair.ticket のチケットが status=in_progress のまま（前の回でやり直し待ちになったもの、または途中で切られたもの）。この場合は手順2を飛ばし、チケットの stage から続ける（stage が consult 以前なら手順5から、gate 以降なら before/ から復元してから手順5から）。
   - 二重起動の防止：`{{REPAIR_DIR_REL}}/.repairer.lock` があり、中の時刻が70分以内なら、前の回がまだ動いているので何もせずに終える。それより古ければ奪ってよい。lock に今の時刻を書いてから先へ進み、終えるときは（途中で打ち切る場合も）必ず消す。
2. **チケットの用意：**
   - repair.ticket が null なら新規のチケットです。id は `r-<今日のYYYYMMDD>-<2桁の連番>`（`{{REPAIR_DIR_REL}}/tickets/` にある同じ日付の最大値+1）。repair.inbox の証拠束（無ければ `{{REPAIR_DIR_REL}}/inbox/` の中で exp_id が一致する最新のもの）の meta.json から failure_sig と failure_epoch を写し、status=in_progress、attempt=1 でチケットを作る。
   - repair.ticket があれば、ドライバが返してきた再依頼です。チケットと `{{REPAIR_DIR_REL}}/tickets/<id>.verify.json` を読む。verify.json の result が failed なら、まず手順4の before/ から対象ファイルを全部復元し、sha256 が before_sha256 と一致することを確かめる。そのうえで、新しい失敗の failure_sig が元と同じ、または attempt が max_attempts（2）に達しているなら escalated（理由「再実行でも再発」）にして終える。そうでなければ attempt を1増やし、status=in_progress にして手順3へ進む。
3. **分類（機械ルール。LLM は使わない）：** 証拠束の traceback.txt と train_tail.log を見て、上から順に当てはめる。
   - **C（人に上げる＝escalated にして終える）：** 次のどれかに当たるとき。
     - 認証まわり：`Authorization needed`、`invalid_grant`、`401`、`403`、`Unauthenticated`、OAuth、ログイン
     - クォータ：`429`、`RESOURCE_EXHAUSTED`、`quota`、GPU やコンピュートユニットの割り当て切れ
     - traceback の最終フレームが、自前のファイルの許可リストの外にある（ライブラリ内部で、自前の呼び出し元も特定できない）
     - NaN や発散（`nan`、`inf`、loss の発散）。これはバグではなく設計の変更なので扱わない
     - deadline.mode が FREEZE、または今日が {{REPAIR_CUTOFF_NOTE}} 以降
     - 上限超え：その実験の repair_tickets が2を超える、repair_counters.tickets_this_wave が4を超える、今日作成のチケットの agy_calls の合計が6以上、チケットの経過が60分を超える
   - **B'（処方のみ＝処方表のとおりにだけ直す。処方は prescription に、内容は deviation に書く）：**
     - `CUDA out of memory` → batch_size を半分にし、勾配蓄積（2ステップ）で実効バッチを保つ
     - DataLoader のハングや worker の異常終了が、同じ実験で2回目 → `num_workers=0`
     - `ModuleNotFoundError`（pip にあるパッケージ）→ スクリプト冒頭で `subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "<pkg>"])` を入れる
   - **B（自動で直す＝agy に修正を相談する）：** traceback の最終フレーム（または自前の最も深いフレーム）が許可リストのファイルで、NameError／KeyError／AttributeError／TypeError／IndexError／shape の不一致／import 漏れ／パスの誤り のどれかに当たるもの。
   - どれにも当たらなければ C（理由「分類不能」）。
   - **許可リスト（修正してよいファイル）：** `{{SCRIPTS_DIR_REL}}/<wave>/exp[0-9]+.py`、`{{SCRIPTS_DIR_REL}}/<wave>/upload_*.py`、`{{SCRIPTS_DIR_REL}}/<wave>/{{CHAIN_SCRIPT_GLOB}}`（`<wave>` は状態の wave.id）。traceback ではセッション内のパス（`/content/<wave>/expN/expN.py`）になっているので、ローカルの `{{SCRIPTS_DIR_REL}}/<wave>/expN.py` に読み替える。
4. **バックアップ：** 修正の対象ファイルを `{{REPAIR_DIR_REL}}/<id>/before/` にコピーし（既にあれば上書きしない）、sha256 を before_sha256 に書く。git は使わない。
5. **agy への相談（B のときだけ。B' は処方どおりに自分で差分を作って手順6へ）：**
   - 相談先は agy です。本命は `{{AGY_PRIMARY_MODEL}}`、予備は `{{AGY_FALLBACK_MODEL}}` で、どちらも agy のモデル切替で呼びます。実装会話 `{{AGY_IMPL_CONVERSATION_ID}}` を `--conversation` で再開し、差分だけを返させる。
   - 呼ぶ前に、チケットの agy_busy を true、agy_calls を+1 にして書く。終わったら（失敗しても）agy_busy を false に戻して書く。
   - 相談文は `{{REPAIR_DIR_REL}}/<id>/prompt_attempt<N>.txt` に書いてから渡す。中身は次のとおり：「ツールは一切使わず、この文章だけを読んで答えてください。下の traceback で落ちた実験スクリプトの不具合を直す、最小の unified diff（`--- a/<パス>` `+++ b/<パス>` 形式、パスはプロジェクトからの相対パス）を1つと、理由を1行だけ返してください。変更してよいのは <許可リストの対象ファイル> だけです。test データ、ラベル、val の分割、seed、評価関数、提出形式、metrics.json のキー名、ハイパーパラメータには触れないでください。直せない、またはそれらに触れないと直せない場合は、diff を出さずに `CANNOT_FIX: <理由>` とだけ返してください。」に続けて、traceback.txt、train_tail.log の末尾、meta.json、対象ファイルの全文（行番号付き）、再依頼なら前回の diff と verify.json を貼る。全体は 120KB 以内に切り詰める（train_tail.log から削る。対象ファイルの全文と traceback は削らない。agy の `-p` は約128KBで「Argument list too long」になる）。
   - 実行：`cd {{PROJECT_DIR}} && timeout 1500 {{AGY_BIN}} -p "$(cat {{REPAIR_DIR_REL}}/<id>/prompt_attempt<N>.txt)" --model {{AGY_PRIMARY_MODEL}} --conversation {{AGY_IMPL_CONVERSATION_ID}} --print-timeout 1450s > {{REPAIR_DIR_REL}}/<id>/agy_attempt<N>.txt 2>&1`。`--dangerously-skip-permissions` は付けない（ツールを使わせないため）。
   - 応答から最初の unified diff を取り出し、`{{REPAIR_DIR_REL}}/<id>/attempt<N>.diff` に保存する。`CANNOT_FIX`、diff が無い、timeout、429、エラーのときは、まず予備として、同じ相談文・同じ会話で `--model {{AGY_FALLBACK_MODEL}}` に変えて1回だけ相談し直す（この相談も agy_calls に数え、チケットに consultant="agy-<予備モデル名>" と記録する。本命で成功したときは consultant="agy-<本命モデル名>"）。予備でも差分が得られなければ、attempt が max_attempts 未満なら次回の起動でやり直す（status は in_progress のまま、history に記録して終える）。上限に達したら escalated（理由「agy が修正を出せない」）。
6. **機械ゲート（LLM は使わない。1つでも落ちたら適用しない）：**
   - diff が触るファイルが、すべて許可リストに入っている（`..` や絶対パスを含まない）。
   - 変更行（`+` と `-` の行、ヘッダを除く）が合計80行以内。
   - 変更行に禁止語が無い（大文字小文字を区別しない）：`test`、`label`、`split`、`seed`、`submission`、`np.save(.*test`、`val_set`、`random_state`。ただし B' の処方で入れた行は例外にしない（処方は禁止語を含まない形で書く）。
   - 修正後のファイルで、metrics を書く部分のキー名（`"<key>":` の形の文字列）が、修正前のものをすべて含んでいる。
   - `patch --dry-run -p1` が通る。
7. **適用と検証：**
   - `patch -p1` で適用し、after_sha256 を書く。
   - 検証1：対象の .py ごとに `python3 -I -m py_compile <ファイル>`（.sh なら `bash -n`）。
   - 検証2（スモーク）：対象スクリプトに `SMOKE` の対応があり、かつローカルの Python で torch が import できるときだけ、`{{REPAIR_DIR_REL}}/<id>/smoke/` で `SMOKE=1 timeout 900` 付きで実行し、終了コード0と metrics.json の出力を確かめる。どちらかを満たさないときは verify.smoke に `"skipped: <理由>"` と書いて先へ進む（その分はドライバの本番の再実行＝検証3で確かめる）。
   - 検証のどれかが落ちたら、before/ から復元して sha256 を確かめ、attempt が max_attempts 未満なら次回の起動でやり直す（history に記録して終える）。上限に達したら escalated。
8. **完了：** 検証を通ったら、status=applied、stage=done にし、diff のパス・理由・検証結果・files・after_sha256 をチケットに残して終える。このチャットには1行で「修理済み（再実行待ち）：<exp> <failure_sig> → <理由>」と報告する。セッションへの反映と再実行（検証3）はドライバが行う。
9. **escalated にするとき：** 修正を当てていたら before/ から復元してから、status=escalated、escalate_reason（何に当たったか、具体的に）を書いて終える。このチャットにも1行で報告する（DM は番犬が送る）。
10. **上限（再掲）：** 1実験2チケット、1波4チケット、1日の agy 相談6回、1チケット60分、1チケットの試行2回。
