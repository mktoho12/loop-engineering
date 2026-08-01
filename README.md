# loop-engineering

「ループエンジニアリング」を調べ、対話し、実際に手を動かして学ぶための作業場。

2026年6〜7月に Boris Cherny（Anthropic / Claude Code 作者）、Peter Steinberger（OpenAI / OpenClaw 作者）、Andrew Ng の発言をきっかけに広まった考え方。ざっくり言えば **「AIにプロンプトを打つ人間」という役割から自分を外し、代わりにプロンプトを打つ仕組み（ループ）を設計する** こと。

## ドキュメント

| ファイル | 内容 |
|---|---|
| [00-what-is-loop-engineering.md](00-what-is-loop-engineering.md) | 調査ノート。発端の3人、Andrew Ng の3つのループ、系譜、構成部品、コストと危険性 |
| [01-experiment-manual-loop.md](01-experiment-manual-loop.md) | 実験1: 手動ループ。**停止条件が3箇所壊れていた**話と、素朴な3条件が認可欠陥を見逃した話 |
| [02-issue-driven-loop.md](02-issue-driven-loop.md) | 設計転換: GitHub Issue をキューにして発見と修正を疎結合にする |
| [03-automated-loops.md](03-automated-loops.md) | 自動ループの実装。早期終了ガード、worktree 隔離、ハマったバグ、コスト実測 |
| [04-scheduled-operation.md](04-scheduled-operation.md) | **launchd で無人運転**。PATH・Keychain 認証・二重起動防止、実際に起きた障害 |
| [05-results-and-lessons.md](05-results-and-lessons.md) | **総括**。1日の成果、実行統計、コスト、学んだこと10個、ハマったバグ |
| [round1-spec.md](round1-spec.md) | 実験1で作り手エージェントに渡した仕様書 |

## 実装したループ

`loops/` にシェルスクリプトで実装。題材は [EngineMaker/world-issue-tracker](https://github.com/EngineMaker/world-issue-tracker)。

```
loops/
├── config.sh            # 共通設定・run_claude / early_exit
├── discover-loop.sh     # 発見ループ（問題を見つけて Issue 化）
├── fix-loop.sh          # 修正ループ（Issue を直して PR 化）
├── format-stream.jq     # stream-json を人間可読に整形
└── prompts/             # 各ループのプロンプト
```

### 使い方

```bash
cd loops

# 修正ループ: オープンな Issue を1つ取り、worktree で直して PR を出す
./fix-loop.sh
./fix-loop.sh --issue 3      # Issue を指定
./fix-loop.sh --dry-run      # どの Issue を選ぶか見るだけ
./fix-loop.sh --keep         # worktree を残す（デバッグ用）

# 発見ループ: 観点をローテーションしながら問題を探して Issue 化
./discover-loop.sh
./discover-loop.sh --force   # ガードを無視して必ず実行
./discover-loop.sh --dry-run
```

**仕事がなければ `claude` を起動せず即終了する**（トークン消費ゼロ）。

- 修正ループ: オープン Issue がない / 全部着手済み → SKIP
- 発見ループ: HEAD が前回と同じ かつ 全観点を一巡済み → SKIP
- 発見ループ: オープン Issue が15件以上（修正が追いついていない）→ SKIP

### 定期実行の状態（launchd）

| ループ | 起動 | 状態 |
|---|---|---|
| 修正ループ | 毎時 **0分** | ✅ **稼働中** |
| 発見ループ | 毎時 30分 | ⏸ **停止中**（2026-08-02〜） |

**発見ループを止めている理由**: Issue を作る速度に、修正＋人間のマージが追いつかず、
オープン Issue が12件まで溜まったため。修正ループにバックログを消化させている。

再開するには:
```bash
launchctl load ~/Library/LaunchAgents/dev.mktoho.loop-engineering.discover.plist
```

```bash
# 状態を見る
launchctl list | grep loop-engineering

# 止める
launchctl unload ~/Library/LaunchAgents/dev.mktoho.loop-engineering.{fix,discover}.plist

# 再開する
launchctl load ~/Library/LaunchAgents/dev.mktoho.loop-engineering.{fix,discover}.plist

# 今すぐ1回だけ走らせる
launchctl start dev.mktoho.loop-engineering.fix

# ログを追う
tail -f loops/logs/launchd-fix.log
```

走っている最中に緊急停止するなら `pkill -f "fix-loop.sh"` と `rm -rf loops/state/*.lock`。

詳細は [04-scheduled-operation.md](04-scheduled-operation.md) を参照。

## これまでの成果

このループから実際に出た PR と Issue:

**マージされた PR: 9本 / クローズされた Issue: 7件**

| # | 内容 | 出どころ |
|---|---|---|
| [#1](https://github.com/EngineMaker/world-issue-tracker/pull/1) | 壊れていた typecheck と CI のテスト実行を修正 | 手動 |
| [#5](https://github.com/EngineMaker/world-issue-tracker/pull/5) | `DELETE /issues/:id` を追加 | 手動ループ |
| [#6](https://github.com/EngineMaker/world-issue-tracker/pull/6) | PATCH / DELETE に所有者チェックを追加 | 自動ループ |
| [#7](https://github.com/EngineMaker/world-issue-tracker/pull/7) | DELETE の重複テストを統合 | 自動 + worktree |
| [#11](https://github.com/EngineMaker/world-issue-tracker/pull/11) | 公開 GET から Clerk User ID の露出を防ぐ | **発見→修正 連結** |
| [#18](https://github.com/EngineMaker/world-issue-tracker/pull/18) | 書き込み系 API に Origin 検証を入れて CSRF を塞ぐ | **無人運転** |
| [#19](https://github.com/EngineMaker/world-issue-tracker/pull/19) | 環境変数サンプルと README 検証テスト | 取りこぼし回収 |
| [#20](https://github.com/EngineMaker/world-issue-tracker/pull/20) | GET /issues のクエリ検証に異常系テストを追加 | **無人運転** |
| [#27](https://github.com/EngineMaker/world-issue-tracker/pull/27) | Clerk 認証テストのモック層を下げる | **無人運転（3度目の正直）** |

**このうち5本は、人間がマージボタンを押しただけ。**
問題の発見、再現の実証、実装、テスト、レビュー、PR 作成はすべて自動。

見つかった実在の脆弱性: 誰でも他人の Issue を更新・削除できた / 公開 API が Clerk User ID を
露出していた / CSRF 対策が無かった。

総コスト: **約 $50**（1日、手動実験を含む）

### ループが一周した

**PR #11 は発見ループが立てた Issue #8 を修正ループが拾ったもの。**

```
発見ループ  → Issue #8 を作成（本番 API に curl を投げて実証つき）
              ↓
GitHub      → キュー / 外部メモリ
              ↓
修正ループ  → worktree で作業、レビュアーが変異体で検証、PR #11 を作成
              ↓
人間        → マージ（ここだけ人間）
              ↓
GitHub      → `Closes #8` で Issue #8 が自動クローズ
```

**人間がやったのはマージのボタンを押すことだけ。**
問題の発見も、再現の実証も、実装も、テストも、レビューも、PR の作成も自動で回った。

Boris Cherny の「スマホから1日に何十本ものPRを承認するだけ」という状態は、
この構造のことだったと分かる。

## 学んだことの要約

**1. ループを回す前に、停止条件が機能することを確かめる**

ループは「機械が判定できる停止条件」に全体重を預ける手法。だからこそ、その停止条件自体が
嘘をついていたら、ループは「何も検証していないのに緑を返し続ける装置」になる。

実際、題材のプロジェクトでは検証が3箇所壊れていた。3つとも「緑に見えていたが、実際には
検証できていなかった」という同じ形をしていた。

**2. 機械的検証は「壊れていないこと」しか見ていない**

test / lint / typecheck が全部緑でも、**「何もしない」が通る**。仕様を満たしたかは見ていない。
実際、3条件すべて緑の実装に重大な認可欠陥があった。

**3. 作り手と検証役を分けるのが一番効く**

検証役が見つけた問題は、機械的検証では1つも捕まえられなかった。
さらに自動ループでは、作り手の自己検証（ミューテーションテスト）を
レビュアーがより強い変異体で破る、という場面が実際に起きた。

**4. Issue をキューにすると構造が変わる**

発見と修正が疎結合になり、Issue が外部メモリになる（セッションが死んでも残る）。
人間が介入する場所（トリアージ）も明確になる。

**5. 無人ループの最大のリスクは「失敗が静かに永続化する」こと**

一時的な API 接続断で修正ループが3回死んだ。障害自体は避けられないが、
失敗した実行が空ブランチを残し、それが「着手済み」と誤判定されて
**その Issue が永久に処理されなくなっていた**。ログには WARN が出るが誰も見ていない。

**6. 禁止したら、代わりに何をすべきかを必ず書く**

人間なら聞きに来るが、ループは聞きに来る先がないと詰むか暴走する。

**7. マージが人間のボトルネックになる**

発見ループが Issue を作る速度に、修正＋人間のマージが追いつかない。
Cherny の「1日に何十本ものPRを承認する」は、**承認の速度が律速になる**ことを示している。

**8. 無人ループは「動いているか分からない」が一番困る**

進捗の可視化は快適さの問題ではなく、運用可能性の問題。

→ 詳細と残り2つは [05-results-and-lessons.md](05-results-and-lessons.md) を参照。

## 達成したこと

- [x] 手動でループの骨格を作る
- [x] 発見ループと修正ループを分け、GitHub Issue をキューにする
- [x] シェルスクリプトで自動化し、早期終了ガードでトークン消費をゼロにする
- [x] git worktree で隔離し、並行実行できるようにする
- [x] 2つのループを同時に走らせて連結を確認する
- [x] launchd に登録して無人運転する
- [x] 失敗時のリトライと空ブランチの自動回収（実地で機能を確認）

## 未検証のまま残っていること

- [ ] バックログ上限（Issue 15件）で発見ループが止まるか
- [ ] 発見ループを5周・10周と回したときの重複（2周目までは重複しなかった）
- [ ] 修正ループを2本同時に走らせる（worktree で隔離済みだが未検証）
- [ ] モデルへの信頼度に応じた自動マージ
