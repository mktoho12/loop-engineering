# 作業ログ — loop-engineering

> **迷ったらここだけ読めば戻れます。** 詳細は下に追記式で続きます。

## 🔖 いまの状況（2026-08-22 時点）

**このプロジェクトは何**: 「ループエンジニアリング」（人間がプロンプトを打つのをやめ、
プロンプトを打つ仕組み＝ループを設計する）を、調べて・実装して・実運用まで持っていく作業場。
題材として [EngineMaker/world-issue-tracker](https://github.com/EngineMaker/world-issue-tracker)（以下 WIT）に
ループを向けているが、**このリポジトリに置くのは汎用的な方法論と仕組みだけ**。

| | 状態 |
|---|---|
| **ループの実装** | ✅ 発見／修正／監視の3ループが動いている |
| **稼働場所** | ✅ **Linux 機 `em105-mktoho` の systemd**（Mac の launchd からは 2026-08-19 に移設済み。Mac 側は登録なし） |
| **いまループは仕事をしているか** | ✅ **復活（8/22 13:56 確認）。Issue #143 を選んで動き出す状態** |
| **リポジトリ分離（8/22 の作業）** | ✅ 完了。ただし **Mac と em105 の main が分岐したまま** |

### 👉 次にやること

1. **修正ループが #143 を再実行した結果を見る** — 8/22 14:00 以降のタイマーで走る。
   前回はタイムアウトで死んだが、`CLAUDE_TIMEOUT` を 3600 に上げ、手順5で
   push・ドラフト PR まで済ませるようにしたので、今度は PR まで到達するはず
   ```bash
   ssh em105-mktoho 'cd ~/work/ai/loop-engineering && ls -t loops/logs/fix-*issue143* | head -2'
   ```
2. **WIT の `needs-discussion` 2 件をトリアージする（後回しでよい）** —
   #70（隣り合う Issue が視野を広げる）／#66（LLM 自動翻訳）。どちらも
   「何を作るか」から決める話。#143 が片付くとまた選べる Issue が無くなる
3. **WIT の PR #156 をマージする** — 8/22 の資料分離の WIT 側。マージは人間に委ねられたまま
   （https://github.com/EngineMaker/world-issue-tracker/pull/156 ）

### ✅ 2026-08-22 に片付いたこと

**152 回連続 SKIP の詰まりを解消し、根本原因を3つとも直した。**

- 滞留していた2ブランチを救出 — **PR #157（#139）はマージ済み**、PR #158（#143）は保全
- `CLAUDE_TIMEOUT` 2700 → **3600**（#143 は上限の**2秒前**に殺されていた）。
  systemd の `TimeoutStopSec` も 3000 → 3900（README の「必ず大きく保つ」に反して逆転していた）
- `fix.md` の手順5を「コミット・push・ドラフト PR まで」に変更。
  コミットだけではローカルに埋もれて Issue をロックし続けるため
- `watch-loop.sh` に**検査7**を追加 — ログを見ず現在のブランチを直接見て未 push 滞留を検出。
  仕込みテストで検出を確認済み
- em105 と origin の分岐も解消（`git pull --rebase` → push 済み）
- WIT Issue #136（ループの異常報告）を**クローズ**
- **PR #158（#143）は破棄**し、Issue #143 をループに拾わせ直すことにした。
  レビュー未通過・18コミット遅れで衝突する 997 行を人力で見るより、直ったループに
  再実行させる方が確実という判断。コミットは em105 の
  `abandoned/fix-issue-143-4db60ec` に退避してあるので中身は失っていない
- `fix-loop.sh --dry-run` で **#143 を選ぶ状態に戻ったことを確認**（152回連続 SKIP から復帰）

詳細は `06-recovering-a-stalled-loop.md` の末尾に追記した。

**教訓**: 前回この欠陥を doc 06 に**記録しただけで仕組みを直していなかった**ため、
同じ形で再発した。記録と修正は別物。

---

## 📁 ドキュメントの地図（どこに何が書いてあるか）

連番の順に読むと「調べる → 手で回す → 設計を変える → 自動化する → 無人運転する → 総括 → 復旧」になる。
**現在地を知りたいなら `06` → `05` の順に読むのが早い。**

| ファイル | 何が書いてあるか | いつ読むか |
|---|---|---|
| `README.md` | 全体の入口。ループの一覧、使い方、成果（PR 10本）、学んだことの要約 | まずここ |
| `00-what-is-loop-engineering.md` | 調査ノート。Boris Cherny / Peter Steinberger / Andrew Ng、Ng の3つのループ、Osmani の構成部品 | 「そもそも何の話？」のとき |
| `01-experiment-manual-loop.md` | 実験1: 手で回した記録。**停止条件が3箇所壊れていた**話 | 「なぜ検証を疑うのか」の根拠 |
| `02-issue-driven-loop.md` | 設計転換。GitHub Issue をキューにして発見と修正を疎結合にした理由 | いまの構造の由来 |
| `03-automated-loops.md` | シェル実装。早期終了ガード、worktree 隔離、ハマったバグ、コスト実測 | スクリプトを触る前 |
| `04-scheduled-operation.md` | **launchd での無人運転**。PATH・Keychain・二重起動防止。※ 現在の稼働は systemd なので `loops/systemd/README.md` も見る | 定期実行を触るとき |
| `05-results-and-lessons.md` | **総括**。1日の成果、実行統計、コスト約 $50、学んだこと10個 | 「何が分かったのか」 |
| `06-recovering-a-stalled-loop.md` | **7日間の停止からの復旧**（2026-08-18）。exit 0 なのに何も作らないループ、観測の穴、WIT #98 の本番 Clerk 移行 | **いまの詰まりを解くときの手順書** |

### `loops/` の中身

```
loops/
├── config.sh            # 共通設定・run_claude / early_exit
├── targets/             # 対象プロジェクトごとの設定（対象依存はここだけ。LOOP_TARGET で選ぶ）
├── discover-loop.sh     # 発見ループ（観点をローテーションして問題を Issue 化）
├── fix-loop.sh          # 修正ループ（Issue を1件取り、worktree で直して PR 化）
├── watch-loop.sh        # 監視ループ（LLM を使わずログを機械的に検査。検査は6種）
├── run-scheduled.sh     # launchd / systemd から呼ぶラッパ
├── launchd/             # macOS 用 plist（※ 現在 Mac には未登録）
├── systemd/             # Linux 用 user unit（★ こちらが現役）
├── prompts/             # discover.md / fix.md
├── logs/  state/        # git 管理外（.gitignore）。マシンごとに違う
└── format-stream.jq
```

**注意**: `logs/` と `state/` は git 管理外なので、**Mac 側の `loops/state/discover.json` は
2026-08-01 で止まったまま**。現役の状態は em105 側にある。Mac のログを見て現状を判断しないこと。

---

## 稼働環境の現在地

| | Mac (`mk-mac2021`) | Linux (`em105-mktoho` / `em105-claw`) |
|---|---|---|
| スケジューラ | launchd — **登録なし**（`launchctl list \| grep loop-engineering` が空） | systemd user timer — **稼働中** |
| 役割 | 開発・ドキュメント編集 | ループの実運用 |
| リポジトリ | `~/work/ai/loop-engineering` | `~/work/ai/loop-engineering` |

**両方で同時に動かしてはいけない。** 同じ Issue を2台が拾って PR が重複する
（worktree のロックはマシン内にしか効かない）。`loops/systemd/README.md` に明記あり。

状態確認:
```bash
ssh em105-mktoho 'systemctl --user list-timers | grep loop'
ssh em105-mktoho 'journalctl --user -u loop-engineering-fix.service -n 30 --no-pager'
```

---

## world-issue-tracker（WIT）との関係

**WIT はループを回す「題材」**。ループ本体と汎用的な方法論は loop-engineering に、
WIT 固有のプロダクト判断（想定利用者、デザイン方針、Issue の論点整理）は
WIT の `docs/product/` に置く、という分離を 2026-08-22 に実施した
（WIT 側は PR #156 / ブランチ `chore/import-loop-docs` で**マージ待ち**）。

---

## 経緯（新しい順）

### 2026-08-22 — 2つのリポジトリの役割を分けた

ユーザーの発端の問い:
> これっていまworld-issue-trackerとloop-engineeringの2つのリポジトリにわかれてるじゃないですか？
> 一緒にしたりできますかね
> （…）ループエンジニアリングのすべてをwitに入れるんじゃなくて、それぞれのプロジェクトに
> witに特化したものだけそれぞれのプロジェクトに入れて、共通的・汎用的なものは
> ループエンジニアリングの方に残すとか。そもそも、もともとループを試してみるのが目的だったわけだし

→ 統合ではなく**役割で分ける**方針に。2つのコミットになった。

**`9f8c126` WIT 固有のプロダクト資料を WIT へ移設**
リポジトリ直下にあった `design-mockup.html` / `discussion-needs-discussion.md` /
`question-to-founder.{md,html}` / `round1-spec.md` を削除（計 1,413 行）。
WIT 側 `docs/product/` に移設され PR #156 になっている。

**`a4ca5d4` ループを対象プロジェクトから切り離した**
`REPO` / 検証コマンド / ワークスペース構成が `config.sh` とプロンプトに直書きで、
WIT 以外では動かせなかった。`loops/targets/<名前>.sh` に分離し `LOOP_TARGET` で選ぶ形に。

- 移した変数: `REPO` `BASE_BRANCH` `WORKSPACE_PKGS` `ENV_FILES` `VERIFY_CMDS` `PKG_MANAGER` `PROD_SITE_URL` `PROD_API_URL`
- `origin/main` 決め打ち6箇所 → `$BASE_BRANCH`
- **`WATCH_REPO` を分離** — 監視ループが自分の健全性 Issue を WIT に立てていた問題（WIT #79）への対応。既定は `REPO` のまま
- `run-scheduled.sh` の必須コマンド `bun` 決め打ちを `LOOP_REQUIRED_CMDS` で上書き可能に
- 空配列は bash 3.2 + `set -u` で unbound になるため `${arr[@]+"${arr[@]}"}` で保護（`03` の既知のハマりどころと同型）

検証済み: WIT 既定で生成されるプロンプトが従来と**バイト単位で同一**／Python プロジェクト想定
（モノレポでない・`pytest`/`ruff`・`develop` ブランチ）でスモークテスト成功／未置換プレースホルダ 0。

**この作業時点で残った課題**（当時の申し送り）:
`prompts/fix.md` には bun / Turborepo / Cloudflare Workers 前提の失敗談
（マイグレーション番号衝突、`next/headers` のモック等）が例として残っている。
これは**このリポジトリで最も価値のある内容**でもあるので機械的に置換せず、
`loops/targets/README.md` に注意として書くに留めた。別スタックで回すときに
「教訓として一般化するか、脚注に落とすか」を判断する。

### 2026-08-19 — 発見ループを em105 で再開した（未 push）

em105 側にのみ 2 コミットある（origin に上がっていない）:
- `ff7f687` 監視ループが「コミットは作ったが PR 化されなかった実行」を成果ゼロと誤報するのを直した
- `df66f83` 発見ループの systemd unit を追加して Linux 機で有効化した

→ 2026-08-02 から止めていた発見ループが、この時点で**再開している**。
`README.md` の「発見ループ: ⏸ 停止中（2026-08-02〜）」の記述は**古い**。

### 2026-08-20 — ループを Mac から常時起動 Linux 機へ移設

ユーザーの動機:
> Macは電源OFFにしてることもあるので、常時起動のLinuxで動いてくれると都合がいいのですよ

移設で書き換えたのは 2 点だけだった:
1. 認証確認 — `security find-generic-password`（macOS Keychain）→ `~/.claude/.credentials.json` の存在チェック
2. スケジューラ — launchd plist 3本 → systemd user timer（`OnCalendar`）

Linux の方がむしろ素直（`caffeinate` が不要、`timeout` と `flock` が標準）。

**移設中に見つかった環境依存のバグ**（`4f16820` `303aabe` `82b30b9` `0a71879`）。
特に `${#ARR[@]:-0}` は **bash 3.2 では通るが 5.2 で構文エラー**になり、
Mac 側で `bash -n` が通ってしまうため実際に動かすまで気づけなかった。

移設後、ループは自力で WIT の PR #120（Issue #67）と #128（Issue #124）を仕上げた。
同じ日に地図が白い問題（WIT PR #126/#129/#130/#131/#132）も解決している
（真因は MapLibre のワーカーが 404 で読み込めていなかったこと。これは WIT 側の話）。

### 2026-08-18 — 7日間止まっていたループの復旧

→ 詳細は **`06-recovering-a-stalled-loop.md`**。要点だけ:

- fix ループは 703 回 exit 0 で終了していたが、**最後に実作業したのは 7 日前**だった
- 原因: オープン Issue 3 件すべてに、過去の異常終了が残したブランチが居座っていた。
  `fix-loop.sh` は**空ブランチしか回収できない**ので、中身のあるブランチは永久に候補を塞ぐ
- 気づけなかった理由: 監視ループの検査 1〜5 はすべて `fix-*.jsonl` を読むが、
  早期終了は claude を起動しないので **jsonl を 1 バイトも残さない**。
  観測系が「実行の記録」を前提にしていたため、**実行しなかったことは観測できなかった**
- 検査 6（連続スキップ回数）を追加。ただし「仕事が無いだけの正常な待機」を誤検知したので、
  「すべて着手済み」だけを数えるよう直した（`bc2f288` → `2fbb415`）
- 同日、WIT #98（本番が Clerk の開発用インスタンスで動いていた）も解消。
  「キーを差し替えるだけ」ではなく**独自ドメインが必須**だった。費用は $0

### 2026-08-01〜08-02 — 0 から無人運転まで

→ 詳細は `01`〜`05`。1日で「手で回す → Issue キュー化 → シェル自動化 → worktree 隔離 →
launchd で無人運転」まで通した。マージされた PR 9本（うち5本は人間がマージボタンを押しただけ）、
実在の脆弱性3件を発見、総コスト約 $50。

---

## 現時点で確認した数字（2026-08-22）

| 項目 | 値 | 出どころ |
|---|---|---|
| WIT のオープン Issue | 5 件（うち `needs-discussion` 3 件） | `gh issue list` |
| ループが触れる Issue | 2 件（#139, #143）— **どちらもブランチで塞がれている** | fix ループのログ |
| fix ループの連続 SKIP | 152 回（直近10日） | `journalctl` |
| 最後に実作業した時刻 | 2026-08-20 19:31 | `journalctl`（`worktree を作成した`） |
| discover の状態 | `lens_index: 6` / `completed_cycles: 1` / HEAD `75786ba1` で足踏み | em105 の `loops/state/discover.json` |
| ループから出た PR | README では 10本（2026-08-02 時点）。その後 #120/#128/#148〜#153 等が追加でマージ済み | `gh pr list` |

---

## 未検証・未解決のまま残っていること

`05` と `README.md` に列挙されているもの:

- [ ] バックログ上限（オープン Issue 15件）で発見ループが止まるか — 実地未検証
- [ ] 発見ループを5周・10周と回したときの重複（2周目までは重複しなかった）
- [ ] 修正ループを2本同時に走らせる（worktree で隔離済みだが未検証）
- [ ] モデルへの信頼度に応じた自動マージ

この WORKLOG を書く時点で追加で見えたもの:

- [ ] **「中身のあるブランチが Issue を永久に塞ぐ」欠陥が未修正** — `06` で手作業では解消したが、
      仕組みとしては直っていない。2026-08-20 以降に**同じ形で再発している**
- [ ] `README.md` の「発見ループ ⏸ 停止中（2026-08-02〜）」「launchd で稼働中」の記述が実態と合っていない
      （実際は em105 の systemd で3ループとも有効）
- [ ] `prompts/fix.md` の bun / Turborepo / Workers 前提の失敗談を、汎用化するか脚注に落とすか未決

---

## 覚えておくこと（過去に指摘されたこと）

`~/.claude/projects/-Users-mktoho-work-ai-loop-engineering/memory/` にある:

- **日本語で応答する** — 応答・コミット・PR 本文・Issue コメントすべて。
  長い調査の途中で英語に戻りやすく、実際に2回指摘されている
- **細かい判断は聞かずに実行して事後報告する** — 聞いてよいのは
  「金銭が絡む」「外部に影響が出る」「取り返しがつかない」の3つだけ。報告は短く
