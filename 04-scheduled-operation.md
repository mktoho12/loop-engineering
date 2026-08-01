# 定期実行の設定（launchd）

2026-08-01。手動起動だったループを launchd に登録し、**完全な無人運転**にした。

## 実行スケジュール

| ループ | 起動 | やること |
|---|---|---|
| **修正ループ** | 毎時 **0分** | オープンな Issue を1つ取り、worktree で直して PR を出す |
| **発見ループ** | 毎時 **30分** | 観点をローテーションしながら問題を探し、Issue を立てる |

30分ずらしているのは、`main` の `git pull` や worktree の操作が競合しないようにするため。

**仕事がなければ数秒で終わる**（トークン消費ゼロ）。
Issue が空なら修正ループは即 SKIP、HEAD が同じで全観点を一巡していれば発見ループも即 SKIP。

## 止め方・確認方法

```bash
# 状態を見る（PID がある = 実行中）
launchctl list | grep loop-engineering

# 一時的に止める
launchctl unload ~/Library/LaunchAgents/dev.mktoho.loop-engineering.fix.plist
launchctl unload ~/Library/LaunchAgents/dev.mktoho.loop-engineering.discover.plist

# 再開する
launchctl load ~/Library/LaunchAgents/dev.mktoho.loop-engineering.fix.plist
launchctl load ~/Library/LaunchAgents/dev.mktoho.loop-engineering.discover.plist

# 完全に削除する
launchctl unload ~/Library/LaunchAgents/dev.mktoho.loop-engineering.{fix,discover}.plist
rm ~/Library/LaunchAgents/dev.mktoho.loop-engineering.{fix,discover}.plist

# 今すぐ1回だけ手動で走らせる
launchctl start dev.mktoho.loop-engineering.fix

# ログを追う
tail -f loops/logs/launchd-fix.log
tail -f loops/logs/launchd-discover.log
```

**走っているループを緊急停止したい場合**:

```bash
pkill -f "fix-loop.sh"      # または discover-loop.sh
rm -rf loops/state/*.lock    # ロックを消す
```

## launchd で必要だったこと

素朴に登録しても動かない。3つ手当てが要った。

### 1. PATH が最小限しかない

launchd のデフォルト PATH は `/usr/bin:/bin:/usr/sbin:/sbin` だけ。
`claude` / `gh` / `bun` / `jq` がどれも見つからない。

`run-scheduled.sh` というラッパを作り、PATH を明示的に組み立てるようにした。
mise の shims も通している（bun のバージョン管理に必要）。

**先に必要なコマンドの存在を確認して落とす**ようにもした。
足りないまま起動すると原因が分かりにくいため。

### 2. 認証は Keychain にある

`claude` の認証情報は macOS の Keychain（`login.keychain`）に保存されている。
`.credentials.json` のようなファイルは存在しない。

検証中、`env -i` で環境を完全に空にしたら `Not logged in` で即死した。
調べた結果、**`HOME` と `USER` があれば Keychain にアクセスできる**と分かった。
先の失敗は `USER` が無かったため。

plist の `EnvironmentVariables` で両方を明示的に渡している。

さらに、ラッパの冒頭で Keychain の存在を確認するようにした:

```bash
if ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  echo "ERROR: Claude の認証情報が Keychain から読めません" >&2
  exit 1
fi
```

API を呼ばずに確認できるので、コストがかからない。
認証切れに気づかず空回りし続けるのを防ぐ。

### 3. 二重起動の防止

前回の実行が終わっていないのに次が始まると、worktree や状態ファイルが競合する。
1時間間隔でも、修正ループが15分以上かかることは普通にある。

macOS には `flock` がないので、`mkdir` のアトミック性を使ったロックにした:

```bash
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
  # ロックはあるが、プロセスが死んでいる可能性がある
  if [ -n "$OLD_PID" ] && ! kill -0 "$OLD_PID" 2>/dev/null; then
    rm -rf "$LOCK_FILE"; mkdir "$LOCK_FILE"    # 古いロックを回収
  else
    exit 0                                      # 実行中なので降りる
  fi
fi
echo $$ > "$LOCK_FILE/pid"
trap 'rm -rf "$LOCK_FILE"' EXIT
```

**PID を記録して生存確認する**のが要点。異常終了でロックが残っても、
次回に自動で回収される。実際、検証中に中断した実行の残骸を自動削除するのを確認した。

ロックは種類ごとに分けている（発見と修正は同時に走ってよいため）。

## 動作確認

`launchctl start` で実際に起動できることを確認した:

```
[19:23:43] === fix ループを開始 ===
[19:23:45] 対象: Issue #9 — [api/index.ts:csrf] Cookie セッション認証を受け付けているが…
[19:23:45] worktree: /Users/mktoho/work/ai/.worktrees/issue-9  ブランチ: fix/issue-9
[19:23:46] worktree を作成した
[19:23:46] node_modules をリンクした
[19:23:46] apps/api/.dev.vars をコピーした
── セッション開始 (claude-opus-5[1m]) cwd=/Users/mktoho/work/ai/.worktrees/issue-9
💬 まず状態を確認します。
```

**launchd → ラッパ → ループ → worktree 作成 → claude 起動** まで全部通った。

## これで到達した状態

```
毎時 0分   修正ループ  → Issue があれば直して PR を出す
毎時 30分  発見ループ  → 問題を探して Issue を立てる
              ↓
        人間はマージの判断だけ
```

Boris Cherny の「スマホから1日に何十本ものPRを承認するだけ」に構造上は到達した。
違いは規模（彼は複数リポジトリで数十本、こちらは1リポジトリで数本）と、
モデルへの信頼度に応じた自動マージの有無だけ。

## 無人運転で実際に起きた障害（重要）

launchd に登録して数時間放置したところ、**2勝2敗**という結果になった。
無人ループの弱点が実物で出たので詳しく記録する。

| 時刻 | Issue | 結果 |
|---|---|---|
| 19:23 | #9 CSRF | ✅ PR #18 |
| 20:00 | #10 認証モック | ❌ **exit 1** |
| 21:14 | #12 updated_at | ❌ **exit 1** |
| 22:07 | #13 クエリ検証 | 🔄 進行中 |

### 直接の原因: API の接続断

両方の失敗ログの末尾に同じものがあった:

```
API Error: Connection closed mid-response. The response above may be incomplete.
```

生ログの終了イベントを見ると:

```
subtype=success is_error=true turns=10 reason=api_error
```

**コードやプロンプトの問題ではなく、ネットワーク／API 側の一時的な障害。**
`#10` は10ターン・$0.55、`#12` は7ターン・$0.33 の時点で死んでいる。

### 本当の問題: 失敗が「静かに永続化」する設計だった

一時的なエラー自体は避けられない。問題はその後始末が無かったこと。

**症状**: 失敗した実行がブランチ `fix/issue-10` `fix/issue-12` を作ったまま死んだ。
どちらもコミット0件の空ブランチ。

そして修正ループの着手済み判定は「ブランチがあればスキップ」だったので、

> **この2つの Issue は、以後永久に処理されない。**

ログには WARN が出るが、無人運転では誰も見ていない。
「静かに何もしなくなる」という、無人ループで最も避けたい壊れ方をしていた。

さらに調べると、**もう1件取りこぼしがあった**。`fix/issue-4` にはコミットが1件あり、
実装は完成していたのに push も PR もされずに埋もれていた
（これは私が手動で中断した実行の残骸。worktree 化より前の時刻のもの）。

### 3つの修正

**1. 空ブランチの自動回収**

着手済み判定を賢くした。ブランチがあっても、`origin/main` からのコミットが0件なら
失敗した実行の残骸とみなして削除し、その Issue を処理する。

```bash
COMMIT_COUNT="$(git rev-list --count "origin/main..$CANDIDATE_BRANCH")"
if [ "$COMMIT_COUNT" -eq 0 ]; then
    # ただしリモートに同名があれば他所で作業中かもしれないので触らない
    git branch -D "$STALE_BRANCH"
fi
```

実際に空ブランチを作って動作を確認した:

```
Issue #10 の空ブランチ fix/issue-10 を回収する（失敗した実行の残骸）
```

**2. 一時的な API エラーのリトライ**

生ログの `terminal_reason` を見て、`api_error` のときだけリトライする。
プロンプトの誤りや実装の詰まりは何度やっても同じなのでリトライしない。

```bash
is_transient_error() {
    reason="$(tail -5 "$raw_log" | jq -r 'select(.type=="result") | .terminal_reason')"
    [ "$reason" = "api_error" ]
}
```

**3. コミットがあるのに PR が無い場合の警告**

`fix/issue-4` のような取りこぼしを検知できるようにした。

- コミットあり + PR なし → **ブランチを残して警告**（消すと完成した作業が失われる）
- コミットなし + PR なし → **空ブランチを削除**（次回また拾われる）

### 教訓

> **無人ループの最大のリスクは、失敗することではなく「失敗が静かに永続化する」こと。**

一時的な障害は必ず起きる。設計すべきなのは:

1. **失敗を検知できるか** — WARN をログに出すだけでは無人運転では誰も見ない
2. **失敗が次回に持ち越されないか** — 残骸が「着手済み」と誤判定されないか
3. **成果が失われないか** — 完成した仕事が push 漏れで埋もれないか

今回は3つとも不備があった。**放置して初めて分かる種類の欠陥**だった。

### 取りこぼしていた PR #19

`fix/issue-4` は内容を検証してから PR にした（41 tests / lint / check / build すべて緑）。

中身も良かった。単に `.example` ファイルを足すだけでなく、
**README のセットアップ手順を実際にパースして検証するテスト**まで書いてあった。

- README 中の `cp <元> <先>` の元ファイルが git 管理下にあるか
- `.example` のキー名が実際にコードが読む環境変数と一致するか

同じ問題の再発を防ぐ作りになっている。

## スリープ対策（caffeinate）

夜間の障害を受けて対策した。

### 調べて分かったこと

`pmset -g custom` を見ると、**AC 電源時は既に `sleep 0`（スリープしない）** になっていた。
バッテリー時だけ `sleep 1`。

昨夜の障害時のログを見ると全部 `Using Batt` だったので、
**原因は単純に「バッテリー駆動だったこと」**。

つまり電源に繋ぐだけでほぼ解決するが、それだと:
- 蓋を閉じるとスリープする（clamshell sleep）
- 電源を挿し忘れたら元の木阿弥

### caffeinate を組み込んだ

`run-scheduled.sh` の実行部を1行変えた:

```bash
caffeinate -is "./${LOOP_TYPE}-loop.sh" "$@"
```

| オプション | 意味 |
|---|---|
| `-i` | システムのアイドルスリープを防ぐ |
| `-s` | AC 電源時はシステムスリープを防ぐ（**蓋を閉じても動く**） |
| ~~`-d`~~ | ディスプレイのスリープ防止。**画面は消えていいので付けない** |

**利点は「必要な間だけ」であること。** `caffeinate` にユーティリティを渡すと、
その実行中だけ assertion が立ち、終了すれば通常の電源管理に戻る。
`pmset` でシステム設定を変えると、ループと無関係な時間もスリープしなくなり、
電力と発熱で損をする。

### 動作を確認した

```
$ caffeinate -is bash -c "sleep 6" &
$ pmset -g assertions

pid 99325(caffeinate): PreventUserIdleSystemSleep named: "caffeinate command-line tool"
	Details: caffeinate asserting on behalf of 'bash' (pid 99323)
pid 99325(caffeinate): PreventSystemSleep named: "caffeinate command-line tool"

   PreventSystemSleep             1     ← -s が効いている
   PreventUserIdleSystemSleep     1     ← -i が効いている

# 終了後
   on behalf of の assertion: 0         ← 通常の電源管理に戻った
```

`caffeinate` は macOS 標準（`/usr/bin/caffeinate`）なので追加インストールは不要。
無い環境（Linux 等）ではそのまま実行するようフォールバックを入れてある。

## 将来: クラウドで回す

ローカルマシンでの定期実行はスリープ以外にも制約がある
（マシンを持ち歩くと止まる、電源を挿し忘れる、OS アップデートで再起動する）。

今の構成は移行しやすくできている:

- ループ本体はシェルスクリプトなので Linux でもほぼそのまま動く
- 状態は `state/*.json` と **GitHub Issue** にあり、マシンに依存しない
- launchd の部分だけ cron / systemd timer / GitHub Actions に差し替える

ただしローカルと違う考慮が2つ:

1. **認証** — Keychain が使えないので `ANTHROPIC_API_KEY` になる。
   課金がサブスクから API 従量に変わる
2. **コスト** — 1日で約 $50 使った実績があるので、常時稼働の設計は慎重に。
   早期終了ガードがあるとはいえ、発見ループが毎回何か見つける状態だと回り続ける

## 運用上の注意

### コストの見積もり

実測値:

| 種類 | 時間 | コスト |
|---|---|---|
| 発見ループ（1回） | 330〜450s | $1.9〜2.3 |
| 修正ループ（1回） | 370〜880s | $2.0〜5.3 |
| **早期終了（ガード発動）** | **< 1s** | **$0** |

Issue が溜まっている間は回り続けるが、消化しきれば $0 に落ち着く。
今のバックログ（6件）なら数時間で消化し、その後は発見ループが観点を一巡するまで動いて止まる。

**バックログ上限**（オープン Issue 15件で発見ループが止まる）も効くはずだが、未検証。

### 見ておくべきもの

- **PR が溜まっていないか** — マージは人間の仕事なので、放置すると修正ループが
  「着手済み」として次々スキップし、やがて何もしなくなる
- **同じ問題で Issue が乱立していないか** — 2周目では重複しなかったが、
  周回数が増えたときは未検証
- **コスト** — `claude` の使用量を定期的に確認する

### 止めるべきとき

- 対象リポジトリで大きなリファクタリングをしているとき（発見ループがノイズを大量に出す）
- Issue のトリアージが追いついていないとき
- コストが想定を超えたとき
