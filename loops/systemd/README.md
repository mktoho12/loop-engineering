# systemd user unit（Linux 常時起動機向け）

Mac を電源 OFF にしていてもループを回すため、常時起動の Linux 機で動かすための unit。
macOS 版は \`../launchd/\` にある。**両方を同時に動かさないこと** — 同じ Issue を2台が
拾って PR が重複する（worktree のロックはマシン内にしか効かない）。

## 導入

\\`\\`\\`bash
cp loop-engineering-*.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now loop-engineering-fix.timer loop-engineering-watch.timer
\\`\\`\\`

ホスト側に以下が必要:

- \`claude\` がログイン済み（\`~/.claude/.credentials.json\`）
- \`gh auth login\` 済みで対象リポジトリに push 権限がある
- \`bun\` / \`jq\` / \`git\` / \`node\`
- \`loginctl enable-linger $USER\` — SSH を切っても user unit を動かし続けるために必要

## 確認

\\`\\`\\`bash
systemctl --user list-timers | grep loop
journalctl --user -u loop-engineering-fix.service -f
\\`\\`\\`

## launchd との対応

| launchd | systemd | 備考 |
|---|---|---|
| \`StartCalendarInterval\` | \`OnCalendar\` | fix は 0・30 分、watch は 15・45 分 |
| \`ExitTimeOut\` | \`TimeoutStopSec\` | config.sh の \`CLAUDE_TIMEOUT\` より必ず大きく保つ |
| \`Nice\` / \`ProcessType=Background\` | \`Nice\` / \`IOSchedulingClass=idle\` | 対話作業を邪魔しない |
| （なし） | \`Persistent=true\` | 停止中に逃した起動を復帰後に1回だけ実行 |
| \`caffeinate\` | 不要 | Linux ではスリープ抑制が要らない |

\`RandomizedDelaySec\` は launchd 版には無い。実行内容に即時性がないため、
:00 ちょうどの集中を避けて数十秒ずらしている。
