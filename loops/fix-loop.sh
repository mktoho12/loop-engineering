#!/usr/bin/env bash
#
# 修正ループ — オープンな GitHub Issue を1つ取り、直して PR を出す。
#
# 早期終了ガード:
#   処理できる Issue がなければ claude を起動せずに終了する。
#   判定はすべて gh / jq で行うのでトークン消費はゼロ。
#
# 隔離:
#   Issue ごとに git worktree を作って作業する。これにより
#   複数の修正ループを同時に走らせても互いの作業を壊さない。
#
# 使い方:
#   ./fix-loop.sh              通常実行
#   ./fix-loop.sh --issue 2    特定の Issue を指定して実行
#   ./fix-loop.sh --dry-run    どの Issue を選ぶか表示するだけ
#   ./fix-loop.sh --keep       終了後も worktree を残す（デバッグ用）

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

DRY_RUN=0
KEEP_WORKTREE=0
TARGET_ISSUE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1; shift ;;
		--keep) KEEP_WORKTREE=1; shift ;;
		--issue) TARGET_ISSUE="$2"; shift 2 ;;
		*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

mkdir -p "$STATE_DIR" "$LOG_DIR" "$WORKTREE_ROOT"

# --- 対象 Issue を選ぶ ---
#
# 除外するもの:
#   1. すでにブランチが存在する Issue（着手済み or 作業中）
#   2. SKIP_LABEL が付いている Issue（人間が議論中）
#
# 優先順位: PRIORITY_LABEL > bug > その他。同じなら Issue 番号が小さい順（古いものから）。
#
# PRIORITY_LABEL を最上位に置いているのは、「bug かどうか」だけで並べると
# ユーザーから見た重要度が全く反映されないため。実際、コード品質の bug が10件
# 並ぶ一方で「トップページが API を呼んでおらず画面が動かない」は後回しになり、
# 動かないプロダクトを磨き続ける順序になっていた。
# 人間が「これを先に」と判断したものを差し込めるようにする。

cd "$WORKDIR"

if [ -n "$TARGET_ISSUE" ]; then
	ISSUE_NUM="$TARGET_ISSUE"
	log "Issue #$ISSUE_NUM を指定実行"
else
	CANDIDATES="$(gh issue list -R "$REPO" --state open --limit 50 \
		--json number,title,labels \
		--jq "[.[] | select([.labels[].name] | index(\"$SKIP_LABEL\") | not)]")"

	CANDIDATE_COUNT="$(echo "$CANDIDATES" | jq 'length')"

	# --- ガード1: 処理できる Issue がない ---
	if [ "$CANDIDATE_COUNT" -eq 0 ]; then
		early_exit "処理可能なオープン Issue がない"
	fi

	# ブランチが既にあるものを除外する。
	# ローカルとリモートの両方を見る（他のループが作業中かもしれない）。
	git fetch --quiet origin 2>/dev/null || true
	EXISTING_BRANCHES="$(
		{
			git branch --format='%(refname:short)'
			git branch -r --format='%(refname:short)' | sed 's|^origin/||'
		} | sort -u
	)"

	SELECTED=""
	while read -r num; do
		[ -z "$num" ] && continue

		# worktree が残っている = 別のループが作業中。手を出さない。
		if [ -d "$WORKTREE_ROOT/issue-$num" ]; then
			log "Issue #$num は worktree が存在するのでスキップ（作業中の可能性）"
			continue
		fi

		if echo "$EXISTING_BRANCHES" | grep -qE "^(fix|feat)/issue-${num}$"; then
			# ブランチはあるが、中身が無い（コミット0件）なら失敗した実行の残骸。
			# API エラー等で claude が途中で死ぬと、ブランチだけ残って以後
			# 永久にスキップされ続けるので、ここで回収する。
			STALE_BRANCH=""
			for prefix in fix feat; do
				CANDIDATE_BRANCH="$prefix/issue-$num"
				git show-ref --verify --quiet "refs/heads/$CANDIDATE_BRANCH" || continue
				COMMIT_COUNT="$(git rev-list --count "origin/main..$CANDIDATE_BRANCH" 2>/dev/null || echo 1)"
				if [ "$COMMIT_COUNT" -eq 0 ]; then
					STALE_BRANCH="$CANDIDATE_BRANCH"
				fi
			done

			if [ -n "$STALE_BRANCH" ]; then
				# リモートに同名ブランチがある場合は、他所で作業中かもしれないので触らない
				if git show-ref --verify --quiet "refs/remotes/origin/$STALE_BRANCH"; then
					log "Issue #$num はローカルが空だがリモートに $STALE_BRANCH があるのでスキップ"
					continue
				fi
				log "Issue #$num の空ブランチ $STALE_BRANCH を回収する（失敗した実行の残骸）"
				git branch -D "$STALE_BRANCH" >/dev/null 2>&1 || true
			else
				log "Issue #$num はブランチが既にあるのでスキップ"
				continue
			fi
		fi

		SELECTED="$num"
		break
	done < <(echo "$CANDIDATES" | jq -r --arg prio "$PRIORITY_LABEL" '
		sort_by(
			(if ([.labels[].name] | index($prio)) then 0 else 1 end),
			(if ([.labels[].name] | index("bug")) then 0 else 1 end),
			.number
		) | .[].number
	')

	# --- ガード2: 全部が着手済みだった ---
	if [ -z "$SELECTED" ]; then
		early_exit "オープン Issue は $CANDIDATE_COUNT 件あるが、すべて着手済み"
	fi

	ISSUE_NUM="$SELECTED"
fi

ISSUE_TITLE="$(gh issue view "$ISSUE_NUM" -R "$REPO" --json title --jq '.title')"
log "対象: Issue #$ISSUE_NUM — $ISSUE_TITLE"

WORKTREE="$WORKTREE_ROOT/issue-$ISSUE_NUM"
BRANCH="fix/issue-$ISSUE_NUM"
log "worktree: $WORKTREE  ブランチ: $BRANCH"

if [ "$DRY_RUN" -eq 1 ]; then
	log "DRY RUN: ここで worktree を作って claude を起動する"
	exit 0
fi

# --- worktree を作る ---
# 既存のものが残っていたら消す（前回の異常終了の後始末）
if [ -d "$WORKTREE" ]; then
	log "既存の worktree を削除して作り直す"
	git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
	git worktree prune
fi
git branch -D "$BRANCH" 2>/dev/null || true

git fetch --quiet origin main
git worktree add --quiet -b "$BRANCH" "$WORKTREE" origin/main
log "worktree を作成した"

# 後片付け。成功しても失敗しても worktree は消す（ブランチは残す）。
# 空ブランチを削除するかのフラグ。worktree がブランチを掴んでいる間は
# 削除できないので、cleanup が worktree を消した後で処理する。
DELETE_EMPTY_BRANCH=0

cleanup() {
	local code=$?
	if [ "$KEEP_WORKTREE" -eq 1 ]; then
		log "worktree を残した: $WORKTREE"
		return $code
	fi
	if [ -d "$WORKTREE" ]; then
		cd "$WORKDIR"
		git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
		git worktree prune
		log "worktree を削除した"
	fi
	# worktree が消えた後なら空ブランチを削除できる
	if [ "$DELETE_EMPTY_BRANCH" -eq 1 ]; then
		cd "$WORKDIR"
		git branch -D "$BRANCH" >/dev/null 2>&1 && log "空ブランチ $BRANCH を削除した"
	fi
	return $code
}
trap cleanup EXIT

# --- 依存関係 ---
# worktree は node_modules を持たないので、メインからシンボリックリンクを張る。
# bun install を毎回走らせると遅いため。
if [ -d "$WORKDIR/node_modules" ] && [ ! -e "$WORKTREE/node_modules" ]; then
	ln -s "$WORKDIR/node_modules" "$WORKTREE/node_modules"
	log "node_modules をリンクした"
fi
for pkg in apps/api apps/web packages/shared; do
	if [ -d "$WORKDIR/$pkg/node_modules" ] && [ ! -e "$WORKTREE/$pkg/node_modules" ]; then
		ln -s "$WORKDIR/$pkg/node_modules" "$WORKTREE/$pkg/node_modules"
	fi
done

# gitignore されている環境変数ファイルも引き継ぐ（テストに必要）
for envfile in apps/api/.dev.vars apps/web/.env.local; do
	if [ -f "$WORKDIR/$envfile" ] && [ ! -f "$WORKTREE/$envfile" ]; then
		cp "$WORKDIR/$envfile" "$WORKTREE/$envfile"
		log "$envfile をコピーした"
	fi
done

# --- Issue の本文とコメントを取得 ---
ISSUE_BODY="$(gh issue view "$ISSUE_NUM" -R "$REPO" --json body,comments \
	--jq '.body + "\n\n---\n\n## コメント\n\n" + ([.comments[] | "**\(.author.login)**: \(.body)"] | join("\n\n"))')"

PROMPT="$(cat "$PROMPT_DIR/fix.md")"
PROMPT="${PROMPT//\{\{REPO\}\}/$REPO}"
PROMPT="${PROMPT//\{\{WORKDIR\}\}/$WORKTREE}"
PROMPT="${PROMPT//\{\{BRANCH\}\}/$BRANCH}"
PROMPT="${PROMPT//\{\{ISSUE_NUM\}\}/$ISSUE_NUM}"
PROMPT="${PROMPT//\{\{ISSUE_TITLE\}\}/$ISSUE_TITLE}"
PROMPT="${PROMPT//\{\{ISSUE_BODY\}\}/$ISSUE_BODY}"

STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="$LOG_DIR/fix-$STAMP-issue${ISSUE_NUM}.log"
RAW_LOG="$LOG_DIR/fix-$STAMP-issue${ISSUE_NUM}.jsonl"
log "ログ: $LOG_FILE"

# claude は worktree の中で起動する
cd "$WORKTREE"

# 一時的な API エラー（接続断など）は実際に起きるので、その場合だけリトライする。
# プロンプトの誤りや実装の詰まりは何度やっても同じなのでリトライしない。
MAX_ATTEMPTS=2
ATTEMPT=1
while :; do
	if [ "$ATTEMPT" -gt 1 ]; then
		log "リトライ $ATTEMPT/$MAX_ATTEMPTS（前回は一時的な API エラー）"
		RAW_LOG="$LOG_DIR/fix-$STAMP-issue${ISSUE_NUM}-retry${ATTEMPT}.jsonl"
	fi

	set +e
	run_claude_in "$WORKTREE" "$PROMPT" "$RAW_LOG" | tee -a "$LOG_FILE"
	CLAUDE_EXIT=${PIPESTATUS[0]}
	set -e

	[ "$CLAUDE_EXIT" -eq 0 ] && break

	log "WARN: claude が非ゼロ終了 (exit $CLAUDE_EXIT)"

	if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
		log "リトライ上限に達した"
		break
	fi
	if ! is_transient_error "$RAW_LOG"; then
		log "一時的なエラーではないのでリトライしない"
		break
	fi

	ATTEMPT=$((ATTEMPT + 1))
	sleep 30
done

# --- 結果を確認 ---
# PR ができたかを機械的に判定する。claude の自己申告は信用しない。
#
# worktree の中にいるとブランチの削除ができないので、メインに戻ってから判定する。
cd "$WORKDIR"
PR_URL="$(gh pr list -R "$REPO" --state open --limit 30 \
	--json url,headRefName \
	--jq ".[] | select(.headRefName == \"$BRANCH\") | .url" | head -1)"

if [ -n "$PR_URL" ]; then
	log "PR ができた: $PR_URL"
else
	log "WARN: PR が見つからない。ログを確認: $LOG_FILE"

	# ブランチにコミットがあるかで、後始末の仕方が変わる。
	COMMITS="$(git rev-list --count "origin/main..$BRANCH" 2>/dev/null || echo 0)"
	if [ "$COMMITS" -gt 0 ]; then
		# 仕事は終わっているが push か PR 作成で失敗した。ブランチを残して人間に知らせる。
		# ここで消すと完成した作業が失われる。
		log "  ⚠️  $COMMITS 件のコミットが $BRANCH に残っている（push または PR 作成に失敗）"
		log "     内容を確認して、必要なら手動で PR を作ってください:"
		log "       git log origin/main..$BRANCH"
		log "       git push -u origin $BRANCH && gh pr create -R $REPO --head $BRANCH"
	else
		# 何も成果がない。空ブランチを残すと次回以降ずっとスキップされるので消す。
		# ただし worktree がブランチを掴んでいる間は削除できないため、
		# cleanup（trap EXIT）が worktree を消した後に削除するようフラグを立てる。
		log "  コミットがないので空ブランチ $BRANCH を削除する（次回また拾われます）"
		DELETE_EMPTY_BRANCH=1
	fi
fi
