#!/bin/sh
# Run a work item one part per fresh Claude session, with a lean start context: no plugins, no MCP servers, no
# artifact/web tools (about 15k tokens instead of 35-56k, re-read on every turn).
# usage (from the item's worktree): tools/protocol-re/item.sh <ID> [--auto]
#   default: one interactive session for the next part
#   --auto:  headless sessions, one per part, until the status file says "**State:** done" or a session commits nothing
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
