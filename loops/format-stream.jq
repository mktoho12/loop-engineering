# claude -p --output-format stream-json の出力を人間可読な1行ログに変換する。
# 使い方: claude ... --output-format stream-json --verbose | jq -r -f format-stream.jq

def trunc($n): if (. | length) > $n then .[0:$n] + "…" else . end;
def clean: gsub("\n"; " ") | gsub("\\s+"; " ");

if .type == "system" and .subtype == "init" then
  "── セッション開始 (\(.model)) cwd=\(.cwd)"

elif .type == "assistant" then
  (.message.content // [])
  | map(
      if .type == "text" then
        (.text // "" | clean | trunc(300)) as $t
        | if ($t | length) > 0 then "💬 \($t)" else empty end
      elif .type == "tool_use" then
        (.name // "?") as $tool
        | (.input // {}) as $in
        | if $tool == "Bash" then
            "🔧 Bash: \($in.command // "" | clean | trunc(160))"
          elif $tool == "Read" then
            "📖 Read: \($in.file_path // "")"
          elif $tool == "Write" then
            "✏️  Write: \($in.file_path // "")"
          elif $tool == "Edit" then
            "✏️  Edit: \($in.file_path // "")"
          elif $tool == "Task" then
            "🤖 Task(\($in.subagent_type // "?")): \($in.description // "" | clean | trunc(80))"
          elif $tool == "Grep" then
            "🔍 Grep: \($in.pattern // "" | clean | trunc(80))"
          elif $tool == "Glob" then
            "🔍 Glob: \($in.pattern // "")"
          else
            "🔧 \($tool)"
          end
      else empty end
    )
  | .[]

elif .type == "user" then
  # ツールの実行結果。エラーだけ拾う（成功をすべて出すと冗長すぎる）
  (.message.content // [])
  | map(
      select(.type == "tool_result" and (.is_error == true))
      | "❌ ツールエラー: \((.content // "" | tostring) | clean | trunc(200))"
    )
  | .[]

elif .type == "result" then
  "── 終了 (\(.subtype // "?")) turns=\(.num_turns // 0) " +
  "時間=\(((.duration_ms // 0) / 1000 | floor))s " +
  "コスト=$\((.total_cost_usd // 0) * 1000 | round / 1000)"

else empty end
