#!/usr/bin/env bash
#
# 発見ループ — コードを漁って問題を見つけ、GitHub Issue として記録する。
#
# 早期終了ガード:
#   前回スキャン時から HEAD が変わっておらず、かつ同じ観点を最近見ているなら
#   claude を起動せずに終了する。これによりトークン消費がゼロになる。
#
# 使い方:
#   ./discover-loop.sh            通常実行（ガードあり）
#   ./discover-loop.sh --force    ガードを無視して必ず実行
#   ./discover-loop.sh --dry-run  何をするか表示するだけ

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

FORCE=0
DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--force) FORCE=1 ;;
		--dry-run) DRY_RUN=1 ;;
		*) echo "unknown option: $arg" >&2; exit 1 ;;
	esac
done

STATE_FILE="$STATE_DIR/discover.json"
mkdir -p "$STATE_DIR" "$LOG_DIR"

# --- 観点のローテーション ---
# HEAD が変わらなくても、違う角度から見れば新しい発見がある。
# 実際、手動実験でも観点を変えるたびに新しい問題が出てきた。
LENSES=(
	"security:認証・認可の欠落、入力検証の漏れ、秘密情報の混入、SQL インジェクション、権限昇格"
	"test-quality:テストが実質何も検証していないもの、抜けている異常系、モックが本物と乖離しているもの"
	"spec-drift:README や CLAUDE.md に書かれているのに実装されていないもの、ドキュメントと実装の食い違い"
	"correctness:境界値・null・並行アクセスで壊れる箇所、エラーハンドリングの漏れ、リソースリーク"
)

# --- 現在の状態を取得 ---
cd "$WORKDIR"
CURRENT_HEAD="$(git rev-parse HEAD)"

# --- 前回の状態を読む ---
PREV_HEAD=""
PREV_LENS_INDEX=-1
RUN_COUNT=0
if [ -f "$STATE_FILE" ]; then
	PREV_HEAD="$(jq -r '.head // ""' "$STATE_FILE")"
	PREV_LENS_INDEX="$(jq -r '.lens_index // -1' "$STATE_FILE")"
	RUN_COUNT="$(jq -r '.run_count // 0' "$STATE_FILE")"
fi

# 次に使う観点を決める（前回の次へ。一巡したら最初に戻る）
LENS_INDEX=$(( (PREV_LENS_INDEX + 1) % ${#LENSES[@]} ))
LENS_ENTRY="${LENSES[$LENS_INDEX]}"
LENS_NAME="${LENS_ENTRY%%:*}"
LENS_DESC="${LENS_ENTRY#*:}"

log "対象: $REPO"
log "HEAD: ${CURRENT_HEAD:0:8}  (前回: ${PREV_HEAD:0:8})"
log "観点: $LENS_NAME  (通算 $RUN_COUNT 回目)"

# --- ガード1: HEAD が変わっておらず、全観点を一巡済みなら終了 ---
# 一巡していなければ、HEAD が同じでも別観点で見る価値がある。
if [ "$FORCE" -eq 0 ] && [ "$CURRENT_HEAD" = "$PREV_HEAD" ]; then
	COMPLETED_CYCLES="$(jq -r '.completed_cycles // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
	if [ "$COMPLETED_CYCLES" -ge 1 ]; then
		early_exit "HEAD が前回から変わっておらず、全観点を一巡済み (${CURRENT_HEAD:0:8})"
	fi
	log "HEAD は同じだが未一巡の観点があるので続行"
fi

# --- ガード2: 未対応の Issue が溜まりすぎていたら発見を止める ---
# 直す先から詰まっているのに発見だけ進めても意味がない。
OPEN_COUNT="$(gh issue list -R "$REPO" --state open --json number --jq 'length')"
BACKLOG_LIMIT=15
if [ "$FORCE" -eq 0 ] && [ "$OPEN_COUNT" -ge "$BACKLOG_LIMIT" ]; then
	early_exit "オープンな Issue が $OPEN_COUNT 件あり上限 $BACKLOG_LIMIT に達している。修正が追いつくまで発見を止める"
fi

log "実行する（オープン Issue: $OPEN_COUNT 件）"

if [ "$DRY_RUN" -eq 1 ]; then
	log "DRY RUN: ここで claude を起動する"
	log "  観点: $LENS_NAME — $LENS_DESC"
	exit 0
fi

# --- 既存 Issue の一覧を渡す（重複排除のため） ---
# LLM に全 Issue を読ませると高くつくので、タイトルだけを渡す。
EXISTING_ISSUES="$(gh issue list -R "$REPO" --state all --limit 100 \
	--json number,title,state \
	--jq '.[] | "#\(.number) [\(.state)] \(.title)"')"

# --- 差分の範囲を決める ---
if [ -n "$PREV_HEAD" ] && [ "$CURRENT_HEAD" != "$PREV_HEAD" ]; then
	SCAN_HINT="前回のスキャン以降に変更されたのは以下のファイルです。ここを重点的に見てください（ただしここに限定はしません）:

$(git diff --name-only "$PREV_HEAD" "$CURRENT_HEAD" 2>/dev/null | head -40)"
else
	# 変数の直後に全角文字が来ると bash 3.2 が変数名の一部と解釈するため、
	# 波括弧で境界を明示する（`$LENS_NAME」` は `LENS_NAME」` という変数名になる）
	SCAN_HINT="前回スキャンからコードの変更はありません。今回は「${LENS_NAME}」の観点で、これまで見落とされていた問題を探してください。"
fi

PROMPT="$(cat "$PROMPT_DIR/discover.md")"
PROMPT="${PROMPT//\{\{REPO\}\}/$REPO}"
PROMPT="${PROMPT//\{\{WORKDIR\}\}/$WORKDIR}"
PROMPT="${PROMPT//\{\{LENS_NAME\}\}/$LENS_NAME}"
PROMPT="${PROMPT//\{\{LENS_DESC\}\}/$LENS_DESC}"
PROMPT="${PROMPT//\{\{MAX_NEW_ISSUES\}\}/$MAX_NEW_ISSUES}"
PROMPT="${PROMPT//\{\{BOT_LABEL\}\}/$BOT_LABEL}"
PROMPT="${PROMPT//\{\{EXISTING_ISSUES\}\}/$EXISTING_ISSUES}"
PROMPT="${PROMPT//\{\{SCAN_HINT\}\}/$SCAN_HINT}"

STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="$LOG_DIR/discover-$STAMP-$LENS_NAME.log"
RAW_LOG="$LOG_DIR/discover-$STAMP-$LENS_NAME.jsonl"
log "ログ: $LOG_FILE"
log "生ログ: $RAW_LOG"

set +e
run_claude "$PROMPT" "$RAW_LOG" | tee "$LOG_FILE"
CLAUDE_EXIT=${PIPESTATUS[0]}
set -e

if [ "$CLAUDE_EXIT" -ne 0 ]; then
	log "WARN: claude が非ゼロ終了 (exit $CLAUDE_EXIT)"
fi

# --- 状態を保存 ---
# 一巡したかどうかを記録。最後の観点まで回ったら completed_cycles を増やす。
COMPLETED_CYCLES="$(jq -r '.completed_cycles // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
if [ "$CURRENT_HEAD" != "$PREV_HEAD" ]; then
	# コードが変わったら周回カウントをリセット（新しいコードは全観点で見直す）
	COMPLETED_CYCLES=0
elif [ "$LENS_INDEX" -eq $(( ${#LENSES[@]} - 1 )) ]; then
	COMPLETED_CYCLES=$(( COMPLETED_CYCLES + 1 ))
fi

jq -n \
	--arg head "$CURRENT_HEAD" \
	--argjson lens_index "$LENS_INDEX" \
	--argjson run_count "$(( RUN_COUNT + 1 ))" \
	--argjson completed_cycles "$COMPLETED_CYCLES" \
	--arg last_run "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
	--arg last_lens "$LENS_NAME" \
	'{head: $head, lens_index: $lens_index, run_count: $run_count, completed_cycles: $completed_cycles, last_run: $last_run, last_lens: $last_lens}' \
	> "$STATE_FILE"

AFTER_COUNT="$(gh issue list -R "$REPO" --state open --json number --jq 'length')"
log "完了。オープン Issue: $OPEN_COUNT → $AFTER_COUNT 件"
