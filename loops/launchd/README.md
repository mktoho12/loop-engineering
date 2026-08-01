# launchd の設定ファイル

`~/Library/LaunchAgents/` に置く plist の控え。git 管理外の場所にあるものをここに複製している。

## インストール

**パスとユーザー名が `/Users/mktoho` 決め打ちなので、別の環境では書き換えが必要。**

```bash
# 1. 自分のパスに書き換える（別ユーザーの場合）
sed -i '' "s|/Users/mktoho|$HOME|g; s|<string>mktoho</string>|<string>$(id -un)</string>|g" \
  dev.mktoho.loop-engineering.*.plist

# 2. 配置する
cp dev.mktoho.loop-engineering.*.plist ~/Library/LaunchAgents/

# 3. 検証する
plutil -lint ~/Library/LaunchAgents/dev.mktoho.loop-engineering.*.plist

# 4. 登録する
launchctl load ~/Library/LaunchAgents/dev.mktoho.loop-engineering.fix.plist
launchctl load ~/Library/LaunchAgents/dev.mktoho.loop-engineering.discover.plist

# 5. 確認する（Status が 0 なら正常）
launchctl list | grep loop-engineering
```

## 前提条件

- `claude` にログイン済みであること（認証情報が Keychain にある）
  - 確認: `security find-generic-password -s "Claude Code-credentials"`
- `gh` に認証済みであること（`gh auth status`）
- 対象リポジトリがローカルにクローンされていること
- `loops/config.sh` の `REPO` / `WORKDIR` / `WORKTREE_ROOT` が正しいこと

## 変更したとき

plist を編集したら、**unload → load をやり直さないと反映されない**。

```bash
launchctl unload ~/Library/LaunchAgents/dev.mktoho.loop-engineering.fix.plist
launchctl load ~/Library/LaunchAgents/dev.mktoho.loop-engineering.fix.plist
```

編集後はこのディレクトリの控えも更新すること:

```bash
cp ~/Library/LaunchAgents/dev.mktoho.loop-engineering.*.plist .
```
