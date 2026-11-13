#!/bin/sh
# Run a work item one part per fresh Claude session, with a lean start context: no plugins, no MCP servers, no
# artifact/web tools (about 15k tokens instead of 35-56k, re-read on every turn).
# usage (from the item's worktree): tools/protocol-re/item.sh <ID> [--auto]
#   default: one interactive session for the next part
#   --auto:  one session per part until the status file says "**State:** done" or a session commits nothing;
#            inside Herdr each part is an interactive session in its own tab, elsewhere a headless `claude -p`
# env: MODEL (opus), EFFORT (high), PERM (auto)
set -eu
id=${1:?usage: item.sh <ID> [--auto]}
mode=${2:-}
st=docs/plan/status/$id.md
[ -f "docs/plan/items/$id.md" ] || { echo "no docs/plan/items/$id.md here; run from the repo or worktree root" >&2; exit 1; }
prompt="Execute the next part of docs/plan/items/$id.md as its \"How to work\" section describes (one part per session), following AGENTS.md. Commit the part on this branch, then stop."
lean='{"enabledPlugins":{"context-mode@context-mode":false,"impeccable@impeccable":false,"mattpocock-skills@claude-plugins-official":false,"ponytail@ponytail":false}}'
set -- --model "${MODEL:-opus}" --effort "${EFFORT:-high}" --permission-mode "${PERM:-auto}" \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' --settings "$lean" \
  --disallowedTools "Artifact,ArtifactComments,ArtifactData,ScheduleWakeup,SendFeedback,Skill,WebSearch,WebFetch,AskUserQuestion"

[ "$mode" = --auto ] || exec claude "$prompt" "$@"

# Inside Herdr: each part runs as an interactive session in a new tab of this space (watchable, can be stepped into).
# The tab is closed when the session has committed and gone idle; otherwise it is left open and the loop stops.
if [ -n "${HC_TERMINAL_ID:-}" ] && command -v herdr-app >/dev/null; then
  space=$(hc get "$HC_TERMINAL_ID" --json | jq -r '.labels["herdr.space"]')
  argv=$(printf '%s\n' "$@" | jq -Rnc --arg p "$prompt" '["claude", $p] + [inputs]')  # args contain no newlines
  n=0
  until grep -q '^\*\*State:\*\* done' "$st" 2>/dev/null; do
    n=$((n + 1)); [ $n -le 15 ] || { echo "15 sessions without reaching done; stopping" >&2; exit 1; }
    head=$(git rev-parse HEAD)
    echo "== $id session $n ($(date +%H:%M)), state: $(head -1 "$st" 2>/dev/null || echo none)"
    out=$(herdr-app do tab.new --space "$space" --folder "$PWD" --name "$id part $n" --argv "$argv")
    t=$(echo "$out" | jq -r .terminal); tab=$(echo "$out" | jq -r .tab)
    # Claude reports idle at startup (turn 0), then working, then idle/done when its turn ends.
    while :; do
      w=$(hc wait "$t" --timeout 600 --json 2>/dev/null) || w='{}'
      s=$(echo "$w" | jq -r '.status // ""')
      [ "$(echo "$w" | jq -r '.exit_code')" = null ] || { s=exited; break; }
      case $s in
        working) ;;
        idle|done) [ "$(echo "$w" | jq -r '.turn // 0')" -ge 1 ] && break; sleep 5 ;;
        *) break ;;  # blocked, error, unknown
      esac
    done
    if [ "$(git rev-parse HEAD)" = "$head" ] || { [ "$s" != idle ] && [ "$s" != done ]; }; then
      echo "session in tab \"$id part $n\" ($t) ended as '$s' without finishing a part; tab left open" >&2; exit 1
    fi
    echo "   $(git log -1 --format=%s)"
    herdr-app do tab.close --id "$tab" --confirmed true >/dev/null
    grep -q 'awaiting review' "$st" && { echo "awaiting review: run the review session, then item.sh again" >&2; exit 0; }
  done
  echo "$id done"; exit 0
fi

n=0
until grep -q '^\*\*State:\*\* done' "$st" 2>/dev/null; do
  n=$((n + 1)); [ $n -le 15 ] || { echo "15 sessions without reaching done; stopping" >&2; exit 1; }
  head=$(git rev-parse HEAD)
  echo "== $id session $n ($(date +%H:%M)), state: $(head -1 "$st" 2>/dev/null || echo none)"
  claude -p "$prompt" "$@" --output-format json |
    jq -r '"   \(.num_turns) turns, \(.usage.output_tokens) output tokens, cache read \(.usage.cache_read_input_tokens)\n   \(.result | tostring | .[0:600])"'
  [ "$(git rev-parse HEAD)" != "$head" ] || { echo "session committed nothing; stopping (see the status file)" >&2; exit 1; }
  grep -q 'awaiting review' "$st" && { echo "awaiting review: run the review session, then item.sh again" >&2; exit 0; }
done
echo "$id done"
