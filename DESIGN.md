# 番頭（`agy-delegation-watchdog`）— 設計・契約の正本

## 1. 概要と正本の分担
LLM を使わない共通番犬フック **`agy-delegation-watchdog`**（5分ポーリング）が、`~/bantou/run/targets/*.json` の全委任を **stat と先頭行読み取りだけ**で見張る。回復可能な停滞では回復役エージェントを `wake` して無言で復旧させ、回復のはしごが尽きたとき（または認証・クォータ・課題ルール起因の停止時）のみ1回だけメインへ報告する。番犬スクリプトに通知コードは一切持たない。

| 文書・部品 | パス | 役割（正本の分担） |
|---|---|---|
| 作法・起動ゲートの正本 | `~/bantou/skill/SKILL.md` | いつ番頭を張るか・会話継続・Colab アダプタ（契約は本書 §5 を参照） |
| 番犬設計・契約の正本 | `~/bantou/DESIGN.md`（本書） | 検出条件・回復のはしご・対象設定スキーマ・状態／起動／ドライバ共通契約 |
| 番犬スクリプト（稼働中） | `~/hooks/scripts/agy-delegation-watchdog.sh` | LLMなし判定本体（毎回 `watchdog_heartbeat` を原子的更新） |
| フック定義控え | `~/bantou/hook_definition.json` | 回復役プロンプトとポーリング定義 |
| ドライバ規約の見本 | `~/bantou/driver_body.md` | 個別案件ドライバ本文の汎用テンプレート（§5 準拠） |
| 作業者起動窓口 | `~/bantou/launch_worker.sh` | `bantou-<id>.service` 分離起動と `.exit.json` 記録 |
| 自動テスト | `~/bantou/tests/run_tests.sh` | 砂場での全境界テスト |

## 2. 役割分担と相互監視

```
            ┌── 10分ごと ──┐                 ┌── 5分ごと（LLMなし）──┐
 ワーカー   ←─ 再起動 ── ドライバ cron ──心拍→ 状態ファイル ←─stat── 番犬フック
  │ 成果物・ログ                │ ←──stat── watchdog_heartbeat ←─書く──┘
  └────────────── stat ─────────┴──────────────────────────────────────┘
                                         番犬が異常を見たら wake → 回復役エージェント
```

- **ワーカーの起動・ハング検出・再起動** → ドライバ cron（10分周期）が生存と進捗（30分）を確認し、§5 の手順で停止・再起動する。
- **ドライバや状態の異常** → 番犬が回復役を `wake` し、状態再構成・cron 再有効化／再登録・ドライバ手順1回代行を行う。
- **ドライバ生存中の作業停滞（45分）** → ドライバの再起動が空回りしているため、回復役が停止・再起動を代行する（`attempts` は共有）。
- **番犬の停止** → ドライバが `watchdog_heartbeat`（20分超）で気づき、フック有効化を1回試みて `watchdog_issue` に無言記録する。

## 3. 検出条件（優先順）

| kind | 判定条件 | 既定値 | 備考 |
|---|---|---|---|
| `state_broken` | 対象設定 JSON 破損／必須キー欠落、状態ファイル不在・破損、`phase` が空／非文字列／未定義、または監視パスが空 | — | 正本・設定の不整合を最優先で復旧 |
| `driver_missing` | `driver_def` が存在しない（非終端時） | — | cron 定義消失 |
| `driver_disabled` | `driver_def` の YAML フロントマター最上位が `enabled: false`（非終端時） | — | 誤った自己無効化・手動停止 |
| `driver_stale` | `driver_heartbeat_epoch` が古い（未記入かつ `rescue_epoch` 不在時のみ状態 mtime 代替。文字列秒・ミリ秒は正規化、未来時刻は無効化） | 25分 | 10分周期の2.5倍（1回遅延は許容） |
| `work_stale` | 現 `phase` の `progress_paths`（単体ファイル優先→フォルダ配下）の最新 mtime が古い（全パス未作成時は `last_restart_epoch` 起点で猶予） | 45分 | ドライバの30分再起動が効いていない |

- **終端フェーズ**（既定 `done` / `failed`）は `driver_def` や成果物走査を省いて即 `silent` とし、事象も消去する。
- **高速・公平な成果物走査**：単体ファイル（ログ等）が新しければ即終了。フォルダ走査時は `os.scandir` の幅優先ラウンドロビン（1フォルダ256件単位で巡回、子フォルダは mtime 降順）で最大 10,000 件まで検査する。ディレクトリ自身の mtime・ディレクトリ symlink・`node_modules`／`.git`／`.venv` 等のキャッシュは除外する。

## 4. 回復のはしご（レート制限）
対象（`id`）ごとの継続事象を `hook_state` の `agy_watchdog_incidents` に保持する（対象削除・無効化時は自動消去）。

1. 初回検出で `wake`（`wake_no=1`）。以後 `wake_cooldown_min`（既定20分＝ドライバ2周期分）を空けて `wake_no=2`、`3`（`max_revives`）。
2. 異常未解消のまま `kind` が変化しても**クールダウンと `wakes` を引き継ぐ**。また回復実行が遅延して `rescue_epoch > last_wake` となった場合、`driver_stale` には `rescue_epoch` から最大15分（再登録 cron の初回周期＋余裕）の猶予を与え、早すぎる `wake_no=2` 再作成を防ぐ。
3. `max_revives` 回で解消しなければ次回 **`final=true` の `wake` を1回**出し、以後は解消まで無言（`gave_up`）。
4. 全異常解消（`kinds == []` または終端 `phase`）で事象を消去し、はしごを初期化する。
5. 1回のポーリングで出す `wake` は最優先の1件のみ（他対象は次回へ繰り越し）。`wake` 失敗時は `hook_state` を即座に巻き戻す。

## 5. ドライバ・回復役・起動の共通契約（唯一の正本）
新規委任は番犬スクリプトを増やさず `~/bantou/run/targets/<id>.json` を追加し、以下を守る：

```json
{
  "id": "<短い名前>", "enabled": true,
  "state_file": "<状態 JSON>", "driver_def": "<ドライバ cron 定義 .md>",
  "driver_cron_id": "<cron id>", "driver_body_file": "<ドライバ本文の控え>",
  "recovery_doc": "~/bantou/DESIGN.md",
  "terminal_phases": ["done", "failed"],
  "driver_stale_min": 25, "work_stale_min": 45, "wake_cooldown_min": 20, "max_revives": 3,
  "phases": { "<phase名>": { "progress_paths": ["<ログファイルまたは glob>", "<成果物フォルダ>"] } }
}
```

1. **心拍と回復印**：非終端ドライバは毎回必ず `driver_heartbeat_epoch`（UNIX秒）を更新する。**回復役は `driver_heartbeat_epoch` を決して書かず**、`rescue_epoch` / `rescue_note` を書く（`rescue_epoch` 存在時は mtime 代替しない）。
2. **終端順序**：完了・最終失敗時は、必ず先に `phase` を `done` または `failed` に書いてからドライバ自身を無効化する。
3. **原子的更新・systemd 分離起動・二重起動防止**：状態ファイル（必須：`phase`, `attempts`, `worker_unit`, `worker_pid`, `driver_heartbeat_epoch`, `last_restart_epoch`, `note`, `watchdog_issue`）は一時ファイル→`mv` で書く。ワーカー起動・再起動はすべて `~/bantou/launch_worker.sh`（`bantou-<id>.service`、環境引き継ぎ・`<log>.exit.json` 記録）経由とし、`nohup` / `setsid` 直起動は禁止。生存確認は `systemctl show <worker_unit> -p ActiveState --value`、停止は `systemctl stop <worker_unit>`（`pgrep` / `kill` 禁止）で行い、`last_restart_epoch` が10分以内なら再起動しない。
4. **相互監視**：`~/bantou/run/watchdog_heartbeat` が不在または20分超ならフック有効化を1回試み、`watchdog_issue` に記録する（復帰で `null`）。
5. **エスカレーション境界**：認証切れ・クォータ枯渇（個別切替指示を除く）・課題ルールの疑問は自動修復せず、`phase=failed` と `note` を書いて1回だけ報告する。

## 6. 保守ルール（稼働中スクリプトの更新手順）
`~/hooks/scripts/agy-delegation-watchdog.sh` への直接上書きは厳禁。必ず同一ディレクトリの一時ファイルで検証してから `mv` で差し替える：

```bash
bash -n ~/hooks/scripts/.agy-delegation-watchdog.sh.tmp \
  && bash ~/bantou/tests/run_tests.sh ~/hooks/scripts/.agy-delegation-watchdog.sh.tmp \
  && chmod 755 ~/hooks/scripts/.agy-delegation-watchdog.sh.tmp \
  && mv -f ~/hooks/scripts/.agy-delegation-watchdog.sh.tmp ~/hooks/scripts/agy-delegation-watchdog.sh
```
