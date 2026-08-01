#!/usr/bin/env bash
#
# launchd から呼ばれる起動ラッパ。
#
# launchd は対話シェルの環境変数を引き継がないため、PATH を明示的に整える。
# これがないと claude / gh / bun / jq が見つからずに失敗する。
#
# 使い方:
#   ./run-scheduled.sh discover        発見ループを回す
#   ./run-scheduled.sh fix             修正ループを回す
#   ./run-scheduled.sh discover --dry-run   引数はそのままループに渡る

set -euo pipefail

LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- PATH を整える ---
# launchd のデフォルト PATH は /usr/bin:/bin:/usr/sbin:/sbin しかない。
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.bun/bin:$PATH"

# mise を使っているので、その shims も通す（bun のバージョン管理に必要）
if [ -d "$HOME/.local/share/mise/shims" ]; then
	export PATH="$HOME/.local/share/mise/shims:$PATH"
fi

# --- 認証に必要な環境変数 ---
# claude の認証情報は macOS の Keychain (login.keychain) にある。
# Keychain へのアクセスには USER と HOME が必要。launchd の LaunchAgent は
# ユーザーセッション内で動くので、これらが揃っていれば読める。
export USER="${USER:-$(id -un)}"
export HOME="${HOME:-$(eval echo "~$USER")}"

# mise の「信頼されていない設定ファイル」警告を抑える。
# 対象リポジトリの .mise.toml は既知のものなので信頼してよい。
export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-$HOME/work/ai}"

# --- 必要なコマンドの存在確認 ---
# 足りないまま起動すると原因が分かりにくいので、先に落とす。
MISSING=""
for cmd in claude gh jq git bun; do
	command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
done
if [ -n "$MISSING" ]; then
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: コマンドが見つかりません:$MISSING" >&2
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] PATH=$PATH" >&2
	exit 1
fi

# --- 二重起動の防止 ---
# 前回の実行がまだ終わっていないのに次が始まると、worktree や状態ファイルが競合する。
# 発見ループと修正ループは同時に走ってよいので、ロックは種類ごとに分ける。
LOOP_TYPE="${1:-}"
case "$LOOP_TYPE" in
	discover|fix) shift ;;
	*) echo "使い方: $0 {discover|fix} [ループへの引数...]" >&2; exit 1 ;;
esac

# --- 認証の確認 ---
# 認証情報は Keychain (login.keychain) にある。ここが読めないと claude は
# "Not logged in" で即死する。ループを起動してから気づくとログを見ないと
# 分からないので、先に確認して分かりやすいエラーで落とす。
#
# API を呼ばずに確認できるよう、Keychain の存在だけを見る。
if ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Claude の認証情報が Keychain から読めません" >&2
	echo "  対話シェルで 'claude' を起動して /login を実行してください。" >&2
	echo "  既にログイン済みなら、Keychain のアクセス許可が原因の可能性があります。" >&2
	exit 1
fi

LOCK_FILE="$LOOP_DIR/state/$LOOP_TYPE.lock"
mkdir -p "$LOOP_DIR/state"

# mkdir はアトミックなのでロックとして使える（macOS には flock がない）
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
	# ロックが残っているが、プロセスが死んでいる可能性がある
	if [ -f "$LOCK_FILE/pid" ]; then
		OLD_PID="$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")"
		if [ -n "$OLD_PID" ] && ! kill -0 "$OLD_PID" 2>/dev/null; then
			echo "[$(date '+%Y-%m-%d %H:%M:%S')] 古いロックを削除 (PID $OLD_PID は不在)"
			rm -rf "$LOCK_FILE"
			mkdir "$LOCK_FILE"
		else
			echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: $LOOP_TYPE ループが既に実行中 (PID $OLD_PID)"
			exit 0
		fi
	else
		echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: $LOOP_TYPE ループが既に実行中"
		exit 0
	fi
fi
echo $$ > "$LOCK_FILE/pid"
trap 'rm -rf "$LOCK_FILE"' EXIT

# --- 実行 ---
#
# caffeinate でループ実行中だけスリープを抑制する。
#   -i  システムのアイドルスリープを防ぐ
#   -s  AC 電源時はシステムスリープを防ぐ（蓋を閉じても動き続ける）
# ディスプレイは消えていいので -d は付けない。
#
# コマンドに続けてユーティリティを渡すと、その実行中だけ assertion が有効になり、
# 終了すれば通常の電源管理に戻る。pmset でシステム設定を変えるのと違い、
# ループと無関係な時間までスリープしなくなることがない。
#
# 実際、バッテリー駆動の夜間に Maintenance Sleep が繰り返され、
# 起動直後のループが消えたり、856秒の処理に実時間で1時間半かかったりした。
cd "$LOOP_DIR"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === $LOOP_TYPE ループを開始 ==="
if command -v caffeinate >/dev/null 2>&1; then
	caffeinate -is "./${LOOP_TYPE}-loop.sh" "$@"
else
	# macOS 以外や caffeinate が無い環境ではそのまま実行する
	"./${LOOP_TYPE}-loop.sh" "$@"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === $LOOP_TYPE ループを終了 ==="
