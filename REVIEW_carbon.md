# 番頭（`agy-delegation-watchdog`）点検・洗練レポート（Carbon）

## 1. 判定

**課題あり（重大な見逃し・誤検出の境界欠陥および文書間の三重重複を特定し、互換性を完全維持したままその場で修正・洗練済み）。**

---

## 2. 見つけた課題の一覧

※行番号はすべて点検開始時点（修正前）の各ファイルに基づく。なお点検対象4番の 対象設定の1件は案件完了に伴い既に撤去済みであったため、現行稼働中の `~/bantou/run/targets/*.json` 4件および旧ドライバのアーカイブを実例として照合した。

| # | 観点 | 重大さ | 根拠（ファイル・行・該当記述） | 対応（直したか／理由） |
|---|---|---|---|---|
| 1 | 精度（見逃し） | **高** | `agy-delegation-watchdog.sh` L133–L137: `if not os.path.exists(state_path): ... if driver_enabled(driver_def): kinds.append("state_broken")`<br>`enabled: true` の監視対象で状態ファイルと `driver_def` が同時に消えた場合、またはドライバが `enabled: false` の状態で状態ファイルが欠損した場合に、`state_broken` も `driver_missing`/`driver_disabled` も立たず `kinds == []`（正常）となり、既存インシデントまで `incidents.pop` で消去される完全無音の死角があった（単一案件用の旧番犬スクリプトの条件の名残）。 | **修正済**。有効な対象設定で `state_file` が不在なら `driver_def` の有無・有効状態に依らず必ず `state_broken` を立て、あわせて `driver_missing`/`driver_disabled` も `kinds` に併記するよう統一（テスト19a/19b追加）。 |
| 2 | 精度（誤検出）・速さ | **高** | `agy-delegation-watchdog.sh` L65–L78: `for root, subdirs, fnames in os.walk(d): ... if seen >= WALK_CAP: break`<br>① Linux では深い階層（例：`src/deep/main.py`）の既存ファイル更新やファイル作成では親ディレクトリ `src/` の mtime が更新されない。そのためデータ展開等で後から作られた兄弟フォルダ（例：`old_bulk/`、3,000ファイル超）のディレクトリ mtime の方が新しいと、深さ優先の `os.walk` が `old_bulk/` だけで `WALK_CAP=3000` を使い切って break し、更新中の `src/deep/main.py` を見落として `work_stale` を誤検出する。<br>② ディレクトリへのシンボリックリンクが非ディレクトリ扱いとなってリンク先ディレクトリの mtime を拾いうるほか、循環シンボリックリンクで `OSError` が親フォルダ走査全体を中断しうる。<br>③ `seen` が `for d in dirs:` ごとにリセットされており、glob 展開で多数ディレクトリが当たると上限が効かない。 | **修正済**。`os.scandir` による**幅優先ラウンドロビン走査**（1ディレクトリあたり256件ずつ巡回し残りをキュー末尾へ回す、全体上限 `WALK_CAP=10000`）へ刷新。`DirEntry` ごとに `OSError` を局所捕捉し、ディレクトリ symlink や特殊ファイルを除外したことで、巨大な兄弟フォルダがあっても数ミリ秒で深い更新ファイルを捕捉できるようにした（テスト17a/17b強化）。 |
| 3 | 精度（見逃し） | **高** | `agy-delegation-watchdog.sh` L111–L114, L127–L129, L179–L181: `config_unreadable` / `config_invalid` / `target_check_failed` 時に `checked.append({"error": ...}); continue` するのみ。<br>新規委任の登録時に対象設定 JSON のカンマ余りや必須キー（`state_file` / `driver_def` / `phases`）の誤記があると、誰も起こさず5分ごとに永遠に `silent` で素通りし、監視が張られていないことにオーナーも回復役も気づけない。また `phases` 内の監視パスが空配列のときも `if paths:`（L172）が偽となり `work_stale` 判定が無言で無効化されていた。 | **修正済**。有効対象の設定破損・必須項目欠落・空 `phase`・空 `progress_paths`・チェック例外をすべて `state_broken`（`facts["state"]` に理由を記録）として既存のはしご（20分冷却×3＋最終報告）に乗せるよう変更。あわせて `"phases": {"running": ["..."]}` の配列短縮表記も互換受理（テスト20a/20b追加）。 |
| 4 | 精度（誤検出）・早さ | **中** | `agy-delegation-watchdog.sh` L198–L200 & `hook_definition.json` L6:<br>クールダウン起点が `last_wake`（番犬が `wake` を発火した時刻）のみ。`delivery.surface="main"` でメイン会話が稼働中の場合、回復役の実行開始が10分以上遅れることがある（例：`t=0` に `wake_no=1` → `t+12m` に回復役が cron 再有効化＆`rescue_epoch` 記録 → 再開した10分周期 cron の初回心拍は `t+22m`）。このとき `t+20m` の番犬ポーリングで `now - last_wake >= 20m` となり、初回心拍の2分前に `wake_no=2`（cron 削除→再登録）が誤発火して正常な cron をリセットしてしまう。 | **修正済**。既存の `last_wake` 20分冷却に加え、`kind == "driver_stale"` かつ `rescue_epoch > last_wake`（その `wake` に対する回復実行が完了した印）がある場合は `rescue_epoch` から最大15分（`min(cooldown, 900)`＝10分周期＋5分余裕）の猶予を与えるよう改善。初回未発火時（`last_wake == 0`）は猶予しないため、`rescue_epoch` が死んだドライバの隠れ蓑になることもない（テスト13維持＋テスト21a–21c追加）。 |
| 5 | 精度（誤検出・見逃し） | **中** | `agy-delegation-watchdog.sh` L43–L44: `pos_epoch(v)` が `int`/`float` かつ `> 0` のみ判定。<br>① ドライバ LLM が `jq --arg hb "$(date +%s)"` で文字列秒 `"1795550762"` を書いた場合 `0` 扱いとなり、`rescue_epoch` 記録後は毎回 `driver_stale` を誤検出する。<br>② ミリ秒エポック（13桁）や誤った未来時刻が1度書かれると `now - hb` が負値になり、数万年にわたり `driver_stale` / `work_stale` が永久不発（見逃し）になる。`NaN`/`Infinity` でも `OverflowError` が発生する。 | **修正済**。`pos_epoch` で数値文字列の受理、ミリ秒（`10^11 <= n < 10^14`）の秒正規化、`NaN`/`Infinity` 防御、および `now + 300` 超の未来時刻の無効化（`0` 扱い）を実装（テスト22a–22c追加）。 |
| 6 | 精度（誤検出） | **中** | `agy-delegation-watchdog.sh` L81–L99: `driver_enabled(path)`<br>① `line.strip()` 後に `startswith("enabled:")` を見るため、YAML フロントマター内のネスト項目（例：`metadata:\n  enabled: false`）を最上位 `enabled: false` と誤認する。<br>② 先頭に UTF-8 BOM（`\ufeff---`）があると `in_fm` が立たず、本文40行中の `enabled: false` まで誤マッチしうる。<br>③ 非 UTF-8 バイト混入時に `UnicodeDecodeError`（`OSError` ではない）でターゲット判定全体が落ちる。 | **修正済**。`errors="replace"`、先頭 BOM 除去、インデントなし最上位キー（`not line[:1].isspace()`）限定、クォート付き `"false"` / `'false'` 対応に整理し、フロントマターが無いファイルは1行目で即 `True` 返却とした（テスト18b/18c追加）。 |
| 7 | 軽さ（状態肥大・誤動作） | **低** | `agy-delegation-watchdog.sh` L106–L116, L225:<br>`targets/<id>.json` を削除または `"enabled": false` にしても `hook_state` 内の `agy_watchdog_incidents[<id>]` が永久に残留する。後日同じ `id` を再利用・再有効化した際、過去の `"gave_up": true` を引き継いで最初から無言放棄する恐れがあった。また bash 側で毎回 `$(date +%s)` サブシェルを起動し、`.watchdog_heartbeat.tmp` が固定名だった。 | **修正済**。有効対象 `active_ids` に含まれない古い `incidents` エントリを毎回自動パージ。時刻取得を `${EPOCHSECONDS:-$(date +%s)}`（Bash 5 組込み優先）にし、心拍一時ファイルを PID 付き `.watchdog_heartbeat.$$.tmp` に変更（テスト20c/20d追加）。 |
| 8 | 精度（ドライバ見本） | **中** | `driver_body.md` L6（手順2 進捗判定）:<br>進捗 mtime が新しくてもワーカーユニットが直前に異常終了しているケースで、「稼働中 **かつ** 進捗30分以内の両方が必要（非稼働なら手順3へ進む）」という条件が明示されておらず、LLM ドライバが「進捗が新しいから正常」と誤判定する余地があった（稼働中の点検ドライバでは個別追記で対処されていた点）。 | **修正済**。`driver_body.md` 手順2に「`active`（または `activating`）**かつ**進捗が30分以内の両方であるときのみ正常（進捗が新しくても非稼働なら手順3へ進む）」を明記。 |
| 9 | 無駄（文書重複） | **中** | `DESIGN.md`（§2 と §5 の内部重複）、`driver_body.md`（L1・L5・L10 で状態キー一覧と220文字の `launch_worker.sh` 起動コマンドを2回重複記載）、`SKILL.md`（L53–L79 で `launch_worker.sh` の内部実装フラグ `--collect`・CA バンドル等や `DESIGN.md` §5 の契約を再記述、L156–L179 で `templates/SETUP_CHECKLIST.md` のプレースホルダ一覧・手順を重複記述）。 | **修正済**。状態・起動・停止・終端・エスカレーション契約の正本を `DESIGN.md` §5 の1か所に集約し、`DESIGN.md` §2・`driver_body.md`・`SKILL.md` からは参照に寄せ、Colab 詳細手順も `templates/SETUP_CHECKLIST.md` 参照へ整理して計 4,400 バイト以上削減。 |
| 10 | 無駄（範囲外ファイルの重複） | **低** | `hook_definition.json` L6（および稼働中の `~/hooks/definitions/agy-delegation-watchdog.json`）:<br>`state_broken` と `work_stale` の2箇所に「ワーカーの生存確認・停止・再起動は `nohup` や `kill` を使わず、必ず `DESIGN.md` §5 どおり…」という同一文が2回繰り返されている。 | **未修正（意図的据え置き）**。ブリーフの修正対象（番犬スクリプト・`DESIGN.md`・`driver_body.md`・`SKILL.md`・テスト）外であるため編集せず記録にとどめた。実害はなく、次回フック定義更新時に手順冒頭の共通注意1文へまとめれば足りる。 |

---

## 3. 変更の要約（行数・バイト数の前後）

| ファイル | 変更前 | 変更後 | 変更内容の要約 |
|---|---:|---:|---|
| [agy-delegation-watchdog.sh](watchdog/agy-delegation-watchdog.sh) | 262行 (10,399 B) | 297行 (12,357 B) | 一時ファイル＋`bash -n`＋テスト＋`mv` で原子的差替。① `state_file` 不在時の死角解消、② `os.scandir` 幅優先ラウンドロビン走査（上限10,000件・ディレクトリ symlink／ループ耐性・リテラルパス直判定）、③ 設定破損／空パス／例外時の `state_broken` 昇格、④ `rescue_epoch` 実行後15分猶予、⑤ 文字列秒・ミリ秒・未来時刻の正規化／防御、⑥ YAML フロントマター最上位キー厳密化、⑦ 無効／削除対象の `incidents` 自動掃除、⑧ `$EPOCHSECONDS` 活用と一時ファイル PID 分離。 |
| [DESIGN.md](DESIGN.md) | 82行 (10,085 B) | 82行 (9,049 B) | §2 と §5 に二重記載されていた `launch_worker.sh`／`systemctl` 詳細を §5（唯一の共通契約正本）へ一本化し約1KB圧縮。§3・§4 に今回の走査仕様・設定破損検知・`rescue_epoch` 猶予・`incidents` 自動消去を反映。 |
| [driver_body.md](driver_body.md) | 12行 (4,658 B) | 14行 (3,888 B) | 冒頭の契約再説明を `DESIGN.md` §5 参照に寄せ、重複していた長大な `launch_worker.sh` 起動形を「案件パラメータ」欄の1か所に集約（約17%圧縮）。手順2に「稼働中かつ進捗30分以内の両方」の条件を明文化。 |
| [SKILL.md](SKILL.md) | 179行 (10,828 B) | 57行 (6,992 B) | 冒頭 `One system` と `launch gate` の契約詳細を `DESIGN.md` §5 参照へ整理し、`launch_worker.sh` 内部実装フラグの重複列挙を削除。後段 Colab アダプタは必須の設計骨格と Colab CLI 固有の罠（`mkdir` 先行・`--auth oauth2` 位置）を残しつつ、`templates/SETUP_CHECKLIST.md` と重複していたプレースホルダ全列挙・手順詳細を参照へ統合（122行・約35%削減）。 |
| [run_tests.sh](tests/run_tests.sh) | 158行 (9,059 B) | 202行 (12,481 B) | 既存18項目（34アサーション）をすべて維持した上で、今回修正した全境界（深い階層の更新 vs 新しい mtime の巨大兄弟フォルダ、ディレクトリ symlink／循環リンク、BOM・ネスト YAML キー、状態＋ドライバ同時欠損、対象設定 JSON 破損と冷却・無効化パージ、`rescue_epoch` 遅延猶予、文字列秒／ミリ秒／未来時刻）を検証するテストを追加し計48アサーションへ拡充。 |

※テストを除く本体4ファイルの合計は **535行（35,970 B）→ 450行（32,286 B）** となり、精度を高めながら全体で約10%（3,684 B）軽量化した。

---

## 4. テスト結果

### 4.1 自動境界テスト（砂場実行）
- 実行コマンド：
  ```bash
  bash ~/bantou/tests/run_tests.sh
  ```
- 結果：**`== 48 passed, 0 failed`（全48項目パス、終了コード `0`）**

### 4.2 本番環境 dry-run および実行速度計測
- 実行コマンド：
  ```bash
  HATCH_HOOK_DRY_RUN=1 HATCH_HOOK_RUNTIME=~/hooks/runtime/hatch_hook_runtime.sh \
    HATCH_HOOK_STATE_DIR=~/hooks/state HATCH_HOOK_ID=agy-delegation-watchdog \
    bash ~/hooks/scripts/agy-delegation-watchdog.sh
  ```
- 結果：稼働中の全4対象を正しく判定し `decision: "silent"` を出力。
- ポーリング1回あたりの実測所要時間：**`real=0.065s`（65ミリ秒、`python3 -I` 起動1回のみ）**。5分（300秒）ポーリングおよび60秒タイムアウトに対して負荷は無視できる水準にある。

---

## 5. 残した複雑さ・削らなかった項目とその理由

1. **異常種別（`kind`）5段階の維持**（`state_broken` / `driver_missing` / `driver_disabled` / `driver_stale` / `work_stale`）
   - `driver_missing`・`driver_disabled`・`driver_stale` を1つの `driver_down` に統合する案も検討したが、回復役プロンプト（`hook_definition.json`）が `kind` ごとに最適手順を分岐している（無効なら `enable` のみ、消失なら本文から新規登録、心拍途絶なら初回は1回代行のみで `wake_no>=2` で削除→再登録）ため、5種別を残す方が無用な cron 削除・再作成を防げて精度が高い。また `wake` ペイロード互換の絶対条件も満たす。
2. **閾値4つ（`driver_stale_min=25`, `work_stale_min=45`, `wake_cooldown_min=20`, `max_revives=3`）の維持**
   - ドライバ10分周期・ドライバ自身のハング判定30分・番犬5分周期に対して、「25分（ドライバ1回遅延許容）→ 30分（ドライバによるワーカー再起動）→ 45分（ドライバが空回りしたときの番犬介入）」および「20分冷却（ドライバ2周期分）×3回＋最終報告＝発生から60分でオーナーへ1回報告」が綺麗に噛み合っており、これ以上減らすと誤発火か報告遅延のどちらかを招くため現行値を維持した。
3. **旧スキーマ互換（トップレベル `progress_paths` と `driver_heartbeat_epoch` 不在時の状態ファイル mtime 代替）の維持**
   - 新規委任では `phases.<name>.progress_paths` と `driver_heartbeat_epoch` が必須だが、初回起動直後（ドライバ初回実行前）の状態ファイルや単一フェーズ簡易設定との後方互換にわずか数行で寄与しており、`rescue_epoch` ガードにより副作用も封じられているため残した。
4. **`SKILL.md` 後段の Colab アダプタ節の維持**
   - ローカルの `agy`／Claude Code 委任には不要だが、Colab の約3.3時間セッション回収・Drive 退避・Apps Script 死活監視・上限付き自動修理はローカル番犬だけでは代替できない固有のアダプタ層であるため、重複手順だけを `templates/SETUP_CHECKLIST.md` へ逃がしたうえで骨格と CLI 注意点を簡潔に保持した。
