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
# 報告済み判定に使うキー。FINDINGS と同じ順で 1行1件。
FINDING_KEYS=""

# 問題を1件記録する。
#
# 第1引数は報告済みかを判定するためのキー、第2引数が本文。
# キーは「同じ事象なら同じ文字列」になるようにする（金額や経過分数のように
# 実行ごとに変わる値を混ぜない）。同じ事象を毎回報告し直さないための識別子。
add_finding() {
	FINDING_KEYS="${FINDING_KEYS}$1"$'\n'
	FINDINGS="${FINDINGS}$2"$'\n'
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
		add_finding "no-result:$name" \
			"**$name** — result イベントが無い。ハングしたまま強制終了した可能性が高い（結末を書き出せていない）"
	elif [ "$subtype" != "success" ]; then
		RECENT_FAILURES="${RECENT_FAILURES}${name}($reason) "
		add_finding "abnormal-exit:$name" \
			"**$name** — 異常終了 subtype=$subtype reason=$reason"
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

if [ "${#RECENT_ISSUES[@]}" -ge 2 ]; then
	# 直近の失敗のうち、同じ Issue 番号が2回以上出ているものを探す
	DUPES="$(printf '%s\n' "${RECENT_ISSUES[@]}" | sort | uniq -d)"
	for num in $DUPES; do
		count="$(printf '%s\n' "${RECENT_ISSUES[@]}" | grep -c "^${num}$")"
		# キーに回数を入れない。3回目・4回目と増えるたびに別の事象として
		# 報告し直すことになり、同じ Issue の話が何度も並ぶ
		add_finding "repeated-failure:$num" \
			"**Issue #$num が $count 回連続で失敗している** — ループでは解けない問題の可能性。Issue を分割するか \`$SKIP_LABEL\` を付けて人間が対応することを検討してください"
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
		last_mod="$(file_mtime "$LATEST_LOG")"
		idle_min=$(( ($(date +%s) - last_mod) / 60 ))
		if [ "$idle_min" -ge "$HANG_THRESHOLD_MIN" ]; then
			# キーに経過分数を入れない。1分ごとに別の事象になり、
			# ハングしている間ずっと報告し続けることになる。
			# 対象のログ1本につき1回だけ報告する
			add_finding "hang:$(basename "$LATEST_LOG" .log)" \
				"**実行中のループが ${idle_min} 分間ログを更新していない** — ハングの可能性: \`$(basename "$LATEST_LOG")\`"
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
		add_finding "pgrep-wait:$(basename "$lf" .log)" \
			"**$(basename "$lf" .log)** で \`pgrep -f\` による完了待ちが使われている — 自分自身にマッチして無限待ちになる。\`prompts/fix.md\` の禁止事項を確認してください"
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
		# キーに金額を入れない。同じ実行の話なので name だけで一意になる
		add_finding "costly-failure:$name" \
			"**$name** — 成果ゼロで \$$(awk -v c="$cost" 'BEGIN{printf "%.2f", c}') を消費"
	fi
done

# --- 検査6: 何も作れていない状態が続いていないか ---
#
# ここまでの検査は全て fix-*.jsonl を読む。しかし早期終了（early_exit）した実行は
# claude を起動しないので jsonl を残さない。つまり「ループが起動しているのに
# 毎回何もせず終わる」状態は、上の検査では原理的に検出できない。
#
# 実際、2026-08-11 から 7 日間、fix ループは 30 分ごとに起動し exit 0 で
# 正常終了し続けたが、その間 1 件も修正していなかった。オープン Issue 3 件すべてに
# 過去の失敗が残したブランチが居座り、「すべて着手済み」として毎回スキップされていた。
# launchd から見れば成功、監視ループから見れば無風。誰も気づけなかった。
#
# 早期終了は個別には正常な動作なので、1 回では異常と見なせない。連続した回数で判断する。
# 判定材料は launchd のログしかない（早期終了した実行は自分のログを残さない）。
#
# ただし早期終了の 2 種類を区別する。混ぜると、直したあとも鳴り続ける。
#
#   「すべて着手済み」          … 仕事はあるのに手が出せていない → 異常の疑い
#   「処理可能なオープン Issue がない」… そもそも仕事が無い       → 正常な待機
#
# 後者は needs-discussion だけが残った状態で普通に起きる（実績 90 回）。
# これを異常に混ぜると、人間が議論待ちの Issue を片付けるまで永久に
# 報告し続けることになり、本物の異常が埋もれる。
SKIP_STREAK_THRESHOLD=6   # 30 分間隔なので約 3 時間ぶん
LAUNCHD_FIX_LOG="$LOG_DIR/launchd-fix.log"
# 異常として数える早期終了の理由。fix-loop.sh の early_exit の文言に対応する
STUCK_SKIP_PATTERN='すべて着手済み'

if [ -f "$LAUNCHD_FIX_LOG" ]; then
	# ログを逆順にたどり、連続が途切れるところまで「着手済みスキップ」を数える。
	# これが「仕事があるのに手が出せていない連続回数」になる。
	#
	# 連続を切るもの:
	#   - 「worktree を作成した」… 実際に着手した（引き返せない地点。以降は
	#     必ず claude を起動するので jsonl が残り、他の検査の対象になる）
	#   - 上記以外の SKIP     … 仕事が無いだけの正常な待機
	# 「=== fix ループを開始 ===」は早期終了でも出るので目印に使えない。
	#
	# grep -a と LC_ALL=C: ログには claude の出力がそのまま流れ込むため
	# 不正なバイト列が混じることがある。バイナリ判定されて検査が黙って
	# 素通りするのを防ぐ。tac は macOS に無いので sed で行を逆順にする。
	#
	# 起点の時刻も同時に採る。報告済み判定のキーに使うので「何回目か」ではなく
	# 「どの期間か」を識別したい。詰まっている間はキーが変わらず（＝再報告
	# しない）、一度回復して再び詰まったときは別のキーになって改めて報告される。
	STREAK_RAW="$(
		LC_ALL=C grep -aE 'SKIP: |worktree を作成した' "$LAUNCHD_FIX_LOG" 2>/dev/null \
		| sed '1!G;h;$!d' \
		| LC_ALL=C awk -v pat="$STUCK_SKIP_PATTERN" '
			/worktree を作成した/ { exit }        # 着手した実行に到達したら打ち切る
			index($0, pat)        { n++; last = $0; next }
			/SKIP: /              { exit }        # 仕事が無いだけの正常な待機で切る
		  END {
			since = "unknown"
			if (match(last, /^\[[^]]*\]/)) since = substr(last, RSTART + 1, RLENGTH - 2)
			print (n + 0) "\t" since
		  }
		'
	)"
	STREAK_COUNT="$(printf '%s' "$STREAK_RAW" | cut -f1)"
	STREAK_SINCE="$(printf '%s' "$STREAK_RAW" | cut -f2)"
	[ -z "$STREAK_COUNT" ] && STREAK_COUNT=0
	[ -z "$STREAK_SINCE" ] && STREAK_SINCE="unknown"
	# 直近のスキップ理由（報告に添える）
	STREAK_LAST="$(LC_ALL=C grep -a 'SKIP: ' "$LAUNCHD_FIX_LOG" 2>/dev/null | tail -1)"

	if [ "$STREAK_COUNT" -ge "$SKIP_STREAK_THRESHOLD" ]; then
		# キーに回数を入れない。30 分ごとに回数が増えて別の事象になり、
		# 詰まっている間ずっと報告し続けることになる。
		# 代わりに起点の時刻を入れて「この空振り期間」を一意に識別する。
		add_finding "idle-streak:fix:$STREAK_SINCE" \
			"**fix ループが $STREAK_COUNT 回連続で何もせず終了している**（$STREAK_SINCE 以降、一度も着手していない）— 起動も終了コードも正常なので他の検査には映らない。直近: \`$STREAK_LAST\`。オープン Issue に残骸のブランチや worktree が居座って全件スキップされている可能性がある（\`git branch\` と \`git worktree list\` を \`gh issue list\` と突き合わせて確認してください）"
	else
		# 変数は必ず ${...} で囲む。直後が全角文字だと、bash がそれを
		# 変数名の一部と解釈して unbound variable で落ちる（set -u のため）
		say "fix ループが着手できずにスキップした連続回数: ${STREAK_COUNT} 回（しきい値 ${SKIP_STREAK_THRESHOLD}）"
	fi
fi

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

# --- 報告済みを除く ---
#
# 検出は毎回ゼロから行うので、同じ事象が何度でも見つかる。ログが
# 入れ替わるまで（検査の窓は直近6件）同じ失敗が残り続けるため、
# 素朴に報告すると30分ごとに同じ内容を投稿することになる。
# 実際、これで Issue #57 に同じ2件が81回投稿された。
#
# 報告済みのキーを記録しておき、新しいものだけを報告する。
REPORTED_FILE="$STATE_DIR/watch-reported.txt"
mkdir -p "$STATE_DIR"
touch "$REPORTED_FILE"

NEW_FINDINGS=""
NEW_KEYS=""
# キーと本文は同じ順で溜めているので、行番号で対応付ける
line_no=0
while IFS= read -r key; do
	[ -z "$key" ] && continue
	line_no=$((line_no + 1))
	body="$(echo "$FINDINGS" | grep . | sed -n "${line_no}p")"
	# 完全一致で照合する（部分一致だと issue6 が issue61 に当たる）
	if grep -qxF "$key" "$REPORTED_FILE" 2>/dev/null; then
		continue
	fi
	NEW_KEYS="${NEW_KEYS}${key}"$'\n'
	NEW_FINDINGS="${NEW_FINDINGS}${body}"$'\n'
done < <(echo "$FINDING_KEYS" | grep .)

if [ -z "$NEW_FINDINGS" ]; then
	log "新しい異常はありません（$COUNT 件はすべて報告済み）"
	exit 0
fi

NEW_COUNT="$(echo "$NEW_FINDINGS" | grep -c . || true)"
log "未報告: $NEW_COUNT 件"

# 報告する内容だけを Issue 本文に載せる
FINDINGS="$NEW_FINDINGS"
COUNT="$NEW_COUNT"

# --- Issue を作る ---
#
# 同じ内容の Issue を毎回作らないよう、既存のオープン Issue を確認する。
WATCH_LABEL="loop-health"
TITLE_KEY="[loops:health]"

# ラベルは検索より先に用意する。存在しないラベルで `--label` 検索をかけると
# `gh` がエラーになり、下の取得失敗の分岐に落ちてしまう。
gh label create "$WATCH_LABEL" -R "$REPO" --color "fbca04" \
	--description "ループ自身の健全性に関する報告" >/dev/null 2>&1 || true

# 既存の Issue を探す。
#
# `|| echo "null"` で握りつぶしてはいけない。`gh` が失敗したとき
# （レート制限・ネットワークの瞬断）に「既存が無い」と解釈され、
# 新しい Issue を作ってしまう。実際にこれで #78 と #79 が生まれた。
# 取得の失敗と「見つからなかった」は別物として扱う。
#
# `--limit` にも注意。オープン Issue がこの数を超えると、
# 対象の Issue が一覧に入らず同じことが起きる。
# ラベルで絞れば健全性報告だけが対象になるので上限に当たらない。
if ! EXISTING_RAW="$(gh issue list -R "$REPO" --state open --limit 100 \
	--label "$WATCH_LABEL" --json number,title 2>/dev/null)"; then
	log "既存 Issue の取得に失敗しました。重複を避けるため今回は報告を見送ります" >&2
	exit 1
fi

EXISTING="$(echo "$EXISTING_RAW" | jq -r "[.[] | select(.title | startswith(\"$TITLE_KEY\"))] | .[0].number // \"null\"")"

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

POSTED=0
if [ "$EXISTING" != "null" ] && [ -n "$EXISTING" ]; then
	if gh issue comment "$EXISTING" -R "$REPO" --body-file "$BODY_FILE" >/dev/null; then
		log "既存 Issue #$EXISTING にコメントしました（$COUNT 件）"
		POSTED=1
	else
		log "Issue #$EXISTING へのコメントに失敗しました" >&2
	fi
else
	if URL="$(gh issue create -R "$REPO" \
		--title "$TITLE_KEY 自動ループの実行に異常があります" \
		--label "$WATCH_LABEL,$SKIP_LABEL" \
		--body-file "$BODY_FILE")"; then
		log "Issue を作成しました: $URL"
		POSTED=1
	else
		log "Issue の作成に失敗しました" >&2
	fi
fi

rm -f "$BODY_FILE"

# 報告済みとして記録するのは、投稿が成功したときだけ。
#
# 先に記録してしまうと、`gh` が失敗したときにその異常は二度と報告されない。
# 「報告した」ことの記録なので、報告できていないなら書かない。
if [ "$POSTED" -eq 1 ]; then
	echo "$NEW_KEYS" | grep . >> "$REPORTED_FILE"

	# 記録が無限に伸びないよう、直近 500 件に切り詰める。
	# 検査の窓は直近6件のログなので、これだけあれば取りこぼさない。
	if [ "$(grep -c . "$REPORTED_FILE" 2>/dev/null || echo 0)" -gt 500 ]; then
		tail -500 "$REPORTED_FILE" > "$REPORTED_FILE.tmp" && mv "$REPORTED_FILE.tmp" "$REPORTED_FILE"
	fi
else
	exit 1
fi
