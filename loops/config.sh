#!/usr/bin/env bash
# 発見ループ・修正ループの共通設定。各ループから source される。

# --- 対象 ---
REPO="EngineMaker/world-issue-tracker"
# メインの作業ディレクトリ。発見ループ（読むだけ）はここを使う。
# 修正ループは書き込むので、ここではなく worktree を作って隔離する。
WORKDIR="/Users/mktoho/work/ai/world-issue-tracker"
# worktree の置き場所。修正ループが Issue ごとに1つ作る。
WORKTREE_ROOT="/Users/mktoho/work/ai/.worktrees"

# --- このディレクトリ ---
LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$LOOP_DIR/state"
LOG_DIR="$LOOP_DIR/logs"
PROMPT_DIR="$LOOP_DIR/prompts"

# --- 上限 ---
# 1回の発見ループで作成する Issue の最大数。Issue の氾濫を防ぐ。
MAX_NEW_ISSUES=3
# 修正ループが1回で処理する Issue 数。1つずつ確実に片付ける。
MAX_FIX_PER_RUN=1
# claude -p の実行時間上限（秒）。ハングしたループが居座るのを防ぐ。
CLAUDE_TIMEOUT=1800

# --- ラベル ---
# 修正ループが「触ってはいけない」Issue に付けるラベル。
# 人間が議論中のもの、方針が決まっていないものを除外する。
SKIP_LABEL="needs-discussion"
# 発見ループが立てた Issue に付けるラベル（人間が立てたものと区別する）。
BOT_LABEL="found-by-loop"

# --- ログ ---
log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# 早期終了。理由を記録して抜ける。トークンを1つも使わずに終わるのがこの関数の目的。
early_exit() {
	log "SKIP: $*"
	exit 0
}

# claude -p を実行する。
#
# 引数1: プロンプト文字列
# 引数2: 生 JSON の保存先（省略可）
#
# --permission-mode bypassPermissions:
#   無人ループなので許可プロンプトに応答できる人間がいない。acceptEdits では
#   Bash の実行（gh / bun / git）で止まってしまうため bypass を使う。
#   対象は自分のリポジトリに限定され、破壊的操作はプロンプト側で禁じている。
#
# --output-format stream-json:
#   デフォルトの text 形式は「全処理が終わってから一括出力」なので、
#   実行中はログが 0 バイトのままになり進捗が全く見えない。
#   数分〜十数分かかる処理では「動いていない」と誤認する原因になるため、
#   逐次出力される stream-json を jq で人間可読に整形する。
#   （--verbose は stream-json を使うとき必須）
#
# `< /dev/null`:
#   これがないと claude -p は標準入力を待ち、スクリプトから起動したとき
#   出力が一切出ないまま止まる（"no stdin data received in 3s" の警告が出る）。
run_claude() {
	run_claude_in "$WORKDIR" "$@"
}

# 作業ディレクトリを指定して claude -p を実行する。
# 修正ループは worktree ごとに違うディレクトリを使うため、こちらを呼ぶ。
#
# 引数1: 作業ディレクトリ
# 引数2: プロンプト文字列
# 引数3: 生 JSON の保存先（省略可）
run_claude_in() {
	local cwd="$1"
	local prompt="$2"
	local raw_log="${3:-/dev/null}"

	local timeout_prefix=""
	if command -v timeout >/dev/null 2>&1; then
		timeout_prefix="timeout $CLAUDE_TIMEOUT"
	elif command -v gtimeout >/dev/null 2>&1; then
		timeout_prefix="gtimeout $CLAUDE_TIMEOUT"
	fi

	(
		cd "$cwd" || exit 1
		# shellcheck disable=SC2086
		$timeout_prefix claude -p "$prompt" \
			--permission-mode bypassPermissions \
			--add-dir "$cwd" \
			--output-format stream-json \
			--verbose \
			< /dev/null 2>&1
	) | tee "$raw_log" \
		| jq -r --unbuffered -f "$LOOP_DIR/format-stream.jq" 2>/dev/null
}

# 生ログを見て、失敗が「一時的な API エラー」かどうかを判定する。
#
# `Connection closed mid-response` のようなネットワーク起因の中断は、
# コードやプロンプトの問題ではないのでリトライする価値がある。
# 一方、プロンプトの誤りや実装の詰まりは何度やっても同じなのでリトライしない。
#
# 引数1: 生ログ (.jsonl) のパス
# 戻り値: 一時的なエラーなら 0
is_transient_error() {
	local raw_log="$1"
	[ -f "$raw_log" ] || return 1

	# result イベントの terminal_reason が api_error なら一時的とみなす
	local reason
	reason="$(tail -5 "$raw_log" 2>/dev/null \
		| jq -r 'select(.type=="result") | .terminal_reason // empty' 2>/dev/null \
		| tail -1)"

	[ "$reason" = "api_error" ]
}
