#!/usr/bin/env bash
#
# 監視ループ — ループ自身の実行ログを見て、異常を見つけて報告する。
#
# 発見ループと修正ループは「対象リポジトリのコード」を見るが、
# このループは「ループ自身の動き」を見る。内側のループは、自分を実行している
# 仕組みの欠陥を原理的に観測できないため、それを外から見る役割。
#
# LLM を使わない。判定はすべて jq / シェルで行うのでトークン消費はゼロ。
# 「何が起きたか」を機械的に検出し、「どうするか」は人間に委ねる。
# 判断が要る問題（Issue の切り方が悪い等）を自動で直そうとすると、
# 内側のループと同じように詰まるため、ここでは検出と報告に徹する。
#
# 使い方:
#   ./watch-loop.sh            検査して結果を表示
#   ./watch-loop.sh --issue    問題が見つかったら GitHub Issue を作る
#   ./watch-loop.sh --quiet    問題がなければ何も出力しない（cron 向け）

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

CREATE_ISSUE=0
QUIET=0
for arg in "$@"; do
	case "$arg" in
		--issue) CREATE_ISSUE=1 ;;
		--quiet) QUIET=1 ;;
		*) echo "unknown option: $arg" >&2; exit 1 ;;
	esac
done

# 検出した問題を溜める。1行1件。
FINDINGS=""
add_finding() {
	FINDINGS="${FINDINGS}$1"$'\n'
}

say() {
	[ "$QUIET" -eq 1 ] && return 0
	log "$*"
}

say "ログを検査: $LOG_DIR"

# --- 検査1: 直近の実行が異常終了していないか ---
#
# 正常終了は result イベントに subtype=success が入る。
# タイムアウトで殺されると aborted_tools になるか、
# ハングしたまま SIGTERM を受けると result 自体が書かれない。
# 後者の方が重症（結末を書き出す間もなく死んでいる）。
RECENT_FAILURES=""
for raw in $(ls -t "$LOG_DIR"/fix-*.jsonl 2>/dev/null | head -6); do
	name="$(basename "$raw" .jsonl)"

	# まだ実行中のものは判定しない
	if [ -d "$STATE_DIR/fix.lock" ] && [ "$raw" -nt "$STATE_DIR/fix.lock" ]; then
		continue
	fi

	subtype="$(jq -r 'select(.type=="result") | .subtype' "$raw" 2>/dev/null | tail -1 || true)"
	reason="$(jq -r 'select(.type=="result") | .terminal_reason // "-"' "$raw" 2>/dev/null | tail -1 || true)"

	if [ -z "$subtype" ]; then
		RECENT_FAILURES="${RECENT_FAILURES}${name}(result なし) "
		add_finding "**$name** — result イベントが無い。ハングしたまま強制終了した可能性が高い（結末を書き出せていない）"
	elif [ "$subtype" != "success" ]; then
		RECENT_FAILURES="${RECENT_FAILURES}${name}($reason) "
		add_finding "**$name** — 異常終了 subtype=$subtype reason=$reason"
	fi
done

# --- 検査2: 同じ Issue で連続して失敗していないか ---
#
# 2回続けて同じ Issue に失敗するなら、それはループでは解けない問題である
# 可能性が高い（Issue の粒度が大きすぎる、設計判断を含む等）。
# 3回目を走らせても同じ結果になるので、人間に判断を促す。
declare -a RECENT_ISSUES=()
while read -r raw; do
	[ -z "$raw" ] && continue
	name="$(basename "$raw" .jsonl)"
	issue_num="$(echo "$name" | sed -n 's/.*-issue\([0-9]*\).*/\1/p')"
	[ -z "$issue_num" ] && continue

	subtype="$(jq -r 'select(.type=="result") | .subtype' "$raw" 2>/dev/null | tail -1 || true)"
	# 成功していれば連続失敗ではない
	[ "$subtype" = "success" ] && continue

	RECENT_ISSUES+=("$issue_num")
done < <(ls -t "$LOG_DIR"/fix-*.jsonl 2>/dev/null | head -6)

if [ "${#RECENT_ISSUES[@]:-0}" -ge 2 ]; then
	# 直近の失敗のうち、同じ Issue 番号が2回以上出ているものを探す
	DUPES="$(printf '%s\n' "${RECENT_ISSUES[@]}" | sort | uniq -d)"
	for num in $DUPES; do
		count="$(printf '%s\n' "${RECENT_ISSUES[@]}" | grep -c "^${num}$")"
		add_finding "**Issue #$num が $count 回連続で失敗している** — ループでは解けない問題の可能性。Issue を分割するか \`$SKIP_LABEL\` を付けて人間が対応することを検討してください"
	done
fi

# --- 検査3: 実行中のループがハングしていないか ---
#
# ログの更新が止まっていれば、何かを待ち続けている。
# 実行時間の上限に達するまで気づけないので、その前に知らせる。
HANG_THRESHOLD_MIN=10
if [ -d "$STATE_DIR/fix.lock" ]; then
	LATEST_LOG="$(ls -t "$LOG_DIR"/fix-*.log 2>/dev/null | head -1)"
	if [ -n "$LATEST_LOG" ]; then
		# stat の -f %m は最終更新時刻（エポック秒）
		last_mod="$(stat -f %m "$LATEST_LOG" 2>/dev/null || echo 0)"
		idle_min=$(( ($(date +%s) - last_mod) / 60 ))
		if [ "$idle_min" -ge "$HANG_THRESHOLD_MIN" ]; then
			add_finding "**実行中のループが ${idle_min} 分間ログを更新していない** — ハングの可能性: \`$(basename "$LATEST_LOG")\`"
		else
			say "実行中のループは正常（${idle_min} 分前に更新）"
		fi
	fi
fi

# --- 検査4: 終わらないコマンドのパターンが使われていないか ---
#
# `pgrep -f <文字列>` による完了待ちは、コマンド自身にマッチするため
# 永久に終わらない。実際にこれで40分以上を溶かした実行がある。
# PID 指定（ps -p）は自己参照しないので安全。
for lf in $(ls -t "$LOG_DIR"/fix-*.log 2>/dev/null | head -6); do
	if grep -q "until ! pgrep -f\|while pgrep -f" "$lf" 2>/dev/null; then
		add_finding "**$(basename "$lf" .log)** で \`pgrep -f\` による完了待ちが使われている — 自分自身にマッチして無限待ちになる。\`prompts/fix.md\` の禁止事項を確認してください"
	fi
done

# --- 検査5: 成果ゼロなのにコストがかかっていないか ---
#
# 失敗そのものより「高くついた失敗」を優先して知らせる。
COST_THRESHOLD=5
for raw in $(ls -t "$LOG_DIR"/fix-*.jsonl 2>/dev/null | head -6); do
	name="$(basename "$raw" .jsonl)"
	subtype="$(jq -r 'select(.type=="result") | .subtype' "$raw" 2>/dev/null | tail -1 || true)"
	[ "$subtype" = "success" ] && continue

	cost="$(jq -r 'select(.type=="result") | .total_cost_usd // 0' "$raw" 2>/dev/null | tail -1 || true)"
	[ -z "$cost" ] && continue
	# bc が無い環境もあるので awk で比較する
	over="$(awk -v c="$cost" -v t="$COST_THRESHOLD" 'BEGIN{print (c>t)?1:0}')"
	if [ "$over" = "1" ]; then
		add_finding "**$name** — 成果ゼロで \$$(awk -v c="$cost" 'BEGIN{printf "%.2f", c}') を消費"
	fi
done

# --- 結果 ---
if [ -z "$FINDINGS" ]; then
	say "問題は見つかりませんでした"
	exit 0
fi

COUNT="$(echo "$FINDINGS" | grep -c . || true)"

# --quiet でも問題があれば出す。黙って見逃すのが最も困るため。
log "検出: $COUNT 件"
echo "$FINDINGS" | grep . | sed 's/^/  - /'

if [ "$CREATE_ISSUE" -eq 0 ]; then
	exit 0
fi

# --- Issue を作る ---
#
# 同じ内容の Issue を毎回作らないよう、既存のオープン Issue を確認する。
WATCH_LABEL="loop-health"
TITLE_KEY="[loops:health]"

EXISTING="$(gh issue list -R "$REPO" --state open --limit 50 \
	--json number,title --jq "[.[] | select(.title | startswith(\"$TITLE_KEY\"))] | .[0].number" 2>/dev/null || echo "null")"

BODY_FILE="$(mktemp)"
{
	echo "## 概要"
	echo
	echo "監視ループ（\`loops/watch-loop.sh\`）が、自動ループの実行ログに $COUNT 件の異常を検出しました。"
	echo
	echo "検出は機械的に行っています（LLM は使っていません）。**どう対応するかの判断は人間に委ねます。**"
	echo
	echo "## 検出内容"
	echo
	echo "$FINDINGS" | grep . | sed 's/^/- /'
	echo
	echo "## 確認方法"
	echo
	echo '```bash'
	echo "cd $LOOP_DIR && ./watch-loop.sh"
	echo '```'
	echo
	echo "生ログは \`$LOG_DIR\` にあります（\`.jsonl\` が生データ、\`.log\` が人間可読）。"
	echo
	echo "---"
	echo
	echo "検出日時: $(date '+%Y-%m-%d %H:%M:%S')"
} > "$BODY_FILE"

gh label create "$WATCH_LABEL" -R "$REPO" --color "fbca04" \
	--description "ループ自身の健全性に関する報告" >/dev/null 2>&1 || true

if [ "$EXISTING" != "null" ] && [ -n "$EXISTING" ]; then
	gh issue comment "$EXISTING" -R "$REPO" --body-file "$BODY_FILE" >/dev/null
	log "既存 Issue #$EXISTING にコメントしました"
else
	URL="$(gh issue create -R "$REPO" \
		--title "$TITLE_KEY 自動ループの実行に異常があります" \
		--label "$WATCH_LABEL,$SKIP_LABEL" \
		--body-file "$BODY_FILE")"
	log "Issue を作成しました: $URL"
fi

rm -f "$BODY_FILE"
