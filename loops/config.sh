#!/usr/bin/env bash
# 発見ループ・修正ループの共通設定。各ループから source される。

# --- このディレクトリ ---
LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 対象 ---
# 対象プロジェクトの設定は loops/targets/<名前>.sh に分けてある。
# 別のプロジェクトでループを回すときは、そのファイルを複製して
# LOOP_TARGET=<名前> を指定する。ループ本体は書き換えなくてよい。
LOOP_TARGET="${LOOP_TARGET:-world-issue-tracker}"
TARGET_FILE="$LOOP_DIR/targets/${LOOP_TARGET}.sh"
if [ ! -f "$TARGET_FILE" ]; then
	printf 'ERROR: 対象の設定が見つかりません: %s\n' "$TARGET_FILE" >&2
	printf '       利用できる対象: %s\n' "$(ls "$LOOP_DIR/targets" 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' ')" >&2
	exit 1
fi
# shellcheck source=/dev/null
. "$TARGET_FILE"

# 対象ファイルが必ず定義すべきもの。未設定のまま走ると
# gh が別のリポジトリを触りかねないので、ここで止める。
: "${REPO:?targets/${LOOP_TARGET}.sh で REPO を設定してください}"
: "${WORKDIR:?targets/${LOOP_TARGET}.sh で WORKDIR を設定してください}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# worktree の置き場所。修正ループが Issue ごとに1つ作る。
WORKTREE_ROOT="${LOOP_WORKTREE_ROOT:-$HOME/work/ai/.worktrees}"

STATE_DIR="$LOOP_DIR/state"
LOG_DIR="$LOOP_DIR/logs"
PROMPT_DIR="$LOOP_DIR/prompts"

# --- 上限 ---
# 1回の発見ループで作成する Issue の最大数。Issue の氾濫を防ぐ。
MAX_NEW_ISSUES=3
# 修正ループが1回で処理する Issue 数。1つずつ確実に片付ける。
MAX_FIX_PER_RUN=1
# claude -p の実行時間上限（秒）。ハングしたループが居座るのを防ぐ。
#
# 45分。実測（修正ループ11回）の分布は中央値 6.4分・最長 44.1分で、
# 正常に完了する実行が 44分かかった実績がある。30分にすると、
# 詰まった実行ではなく「時間のかかる正常な実行」を殺すことになる。
#
# なお launchd 側の ExitTimeOut はこれより大きくしておくこと
# （先にこちらが効いて、生ログとログ出力が残るようにするため）。
CLAUDE_TIMEOUT=2700

# --- 本番環境 ---
# 利用者が実際に使っているサイトと、その API（対象ごとに違うので targets/ で設定する）。
# 発見ループの user-voice 観点が、利用者の声を読むために叩く。
# 未設定なら user-voice 観点は使えないが、他の観点は動く。
PROD_SITE_URL="${PROD_SITE_URL:-}"
PROD_API_URL="${PROD_API_URL:-}"

# --- ラベル ---
# 修正ループが「触ってはいけない」Issue に付けるラベル。
# 人間が議論中のもの、方針が決まっていないものを除外する。
SKIP_LABEL="needs-discussion"
# 発見ループが立てた Issue に付けるラベル（人間が立てたものと区別する）。
BOT_LABEL="found-by-loop"
# ループ自身の健全性レポートを立てる先。既定は対象リポジトリだが、
# ループの不調は対象プロダクトの課題ではないので、分けたい場合はここを変える
# （targets/ か環境変数 LOOP_WATCH_REPO で上書きする）。
WATCH_REPO="${LOOP_WATCH_REPO:-${WATCH_REPO:-$REPO}}"

# 修正ループが最優先で着手する Issue のラベル。
# 「bug かどうか」だけで並べるとユーザーから見た重要度が反映されないため、
# 人間が「これを先に」と指定するための差し込み口。
PRIORITY_LABEL="priority-high"

# --- ログ ---
log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# ファイルの最終更新時刻をエポック秒で返す。取れなければ 0。
#
# GNU coreutils は `stat -c %Y`、BSD/macOS は `stat -f %m` と書式が違う。
# 以前は macOS 版だけを書いていたため、Linux では stat が「ファイルシステム情報」を
# 出力してしまい（-f の意味が違う）、その文字列が算術式に流れ込んで
# 監視ループが unbound variable で落ちていた。
file_mtime() {
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
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

	# タイムアウトコマンドを探す。macOS には標準の `timeout` がないため、
	# 通常は coreutils の `gtimeout` が使われる。
	#
	# 見つからない場合は警告を出す。以前はここで黙って無効化していたため、
	# CLAUDE_TIMEOUT が設定されているのに一度も効いておらず、44分の実行が
	# そのまま通っていた（実際にハングしても止まらない状態だった）。
	# 静かに無防備になるくらいなら、うるさく知らせる。
	local timeout_prefix=""
	if command -v timeout >/dev/null 2>&1; then
		timeout_prefix="timeout $CLAUDE_TIMEOUT"
	elif command -v gtimeout >/dev/null 2>&1; then
		timeout_prefix="gtimeout $CLAUDE_TIMEOUT"
	else
		log "WARN: timeout / gtimeout が見つかりません。実行時間の上限なしで claude を起動します"
		log "      修正するには: brew install coreutils"
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
