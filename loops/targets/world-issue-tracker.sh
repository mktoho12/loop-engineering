#!/usr/bin/env bash
# 対象プロジェクト: EngineMaker/world-issue-tracker
#
# ループを別のプロジェクトに向けるときは、このファイルを複製して書き換え、
# LOOP_TARGET=<名前> で選ぶ（既定は world-issue-tracker）。

# --- 対象リポジトリ ---
REPO="EngineMaker/world-issue-tracker"
WORKDIR="${LOOP_WORKDIR:-$HOME/work/ai/world-issue-tracker}"
# 既定のベースブランチ。PR の宛先と worktree の分岐元になる。
BASE_BRANCH="main"

# --- ワークスペース構成 ---
# worktree に node_modules をリンクするサブパッケージ。
# bun install を毎回走らせると遅いため、メインから借りる。
# モノレポでなければ空にしてよい（ルートの node_modules は別途リンクされる）。
WORKSPACE_PKGS=(apps/api apps/web packages/shared)

# gitignore されていて worktree に引き継ぐ必要があるファイル（テストに必要）。
ENV_FILES=(apps/api/.dev.vars apps/web/.env.local)

# --- 検証コマンド ---
# 修正ループが「直った」と判断するために通す必要があるコマンド。
# プロンプトにもこの一覧が差し込まれる。
VERIFY_CMDS=(
	"bun run test"
	"bun run lint"
	"bun run check"
	"bun run build"
)

# 依存の追加・更新に使うコマンド名。ループはこれを実行してはいけない
# （worktree の node_modules はメインへのシンボリックリンクのため、
#   実行するとリンク先＝本体を書き換えてしまう）。
PKG_MANAGER="bun"

# --- 本番環境 ---
# 発見ループの user-voice 観点が、利用者の声を読むために叩く。
PROD_SITE_URL="https://issues.emaker.dev"
PROD_API_URL="https://world-issue-tracker-api.mktoho.workers.dev"
