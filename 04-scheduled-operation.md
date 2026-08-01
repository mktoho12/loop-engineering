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
