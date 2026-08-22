# 対象プロジェクトの設定

ループ本体（`../*.sh`）はどのプロジェクトにも依存しない。
「どのリポジトリを、どうやって検証するか」だけをこのディレクトリに分けてある。

## 使い方

既定は `world-issue-tracker`。別の対象に向けるには:

```bash
cp world-issue-tracker.sh my-project.sh
$EDITOR my-project.sh
LOOP_TARGET=my-project ../fix-loop.sh
```

launchd / systemd から使う場合は、ユニットの環境変数に `LOOP_TARGET` を足す。

## 設定できる項目

| 変数 | 必須 | 意味 |
| --- | --- | --- |
| `REPO` | ✅ | `owner/name`。gh がこのリポジトリを触る |
| `WORKDIR` | ✅ | ローカルの作業ディレクトリ |
| `BASE_BRANCH` | | PR の宛先と worktree の分岐元。既定 `main` |
| `WORKSPACE_PKGS` | | worktree に `node_modules` をリンクするサブパッケージ。モノレポでなければ `()` |
| `ENV_FILES` | | gitignore されていて worktree に引き継ぐファイル。無ければ `()` |
| `VERIFY_CMDS` | | 「直った」と判断するために通すコマンド。プロンプトにも差し込まれる |
| `PKG_MANAGER` | | 依存管理コマンド名。ループには「これを実行するな」と伝えるために使う |
| `PROD_SITE_URL` / `PROD_API_URL` | | 本番の URL。発見ループの user-voice 観点が使う。未設定ならその観点は使えない |
| `WATCH_REPO` | | 監視ループが健全性 Issue を立てる先。既定は `REPO` |

`REPO` と `WORKDIR` が未設定なら `config.sh` が起動時に落とす
（設定漏れのまま別のリポジトリを触るのを防ぐため）。

## 注意

`VERIFY_CMDS` を変えるだけでは足りない場合がある。`prompts/fix.md` には
bun / Turborepo / Cloudflare Workers を前提にした失敗談（マイグレーション番号の衝突、
`next/headers` のモック等）が例として残っている。別のスタックで回すときは、
そこが「役に立たない助言」になっていないか一度読むこと。
