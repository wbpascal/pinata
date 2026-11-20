#!/usr/bin/env bash
# Changelog step of server.yml (server/AGENTS.md, "Changelog checklist"): passes when the change <from>..<to> adds a
# line to CHANGELOG.md or when the PR description (environment variable PR_BODY) has a line starting with
# "Changelog: none". Checks nothing else.
#   PR_BODY=... .github/scripts/changelog-check.sh <from> <to>
set -euo pipefail
added=$(git diff --numstat "$1" "$2" -- CHANGELOG.md | cut -f1)
if [ "${added:-0}" != 0 ] && [ "${added:-0}" != - ]; then
  echo "CHANGELOG.md: $added line(s) added"
  exit 0
fi
if printf '%s\n' "${PR_BODY:-}" | tr -d '\r' | grep -q '^Changelog: none'; then
  echo "CHANGELOG.md unchanged; the description says why (Changelog: none)"
  exit 0
fi
echo "::error::Add a line to CHANGELOG.md, or a line starting with 'Changelog: none' and the reason to the PR description (server/AGENTS.md, \"Changelog checklist\")."
exit 1
