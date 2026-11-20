#!/usr/bin/env bash
# Test of changelog-check.sh in a throw-away repository: bash .github/scripts/changelog-check-test.sh
set -euo pipefail
check=$(cd "$(dirname "$0")" && pwd)/changelog-check.sh
repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
printf '# Changelog\n' > CHANGELOG.md && echo x > other.txt
git add . && git -c user.name=t -c user.email=t@t commit -q -m files
base=$(git rev-parse HEAD)
echo y >> other.txt && git -c user.name=t -c user.email=t@t commit -q -am other
no_line=$(git rev-parse HEAD)
echo '- a line (#1)' >> CHANGELOG.md && git -c user.name=t -c user.email=t@t commit -q -am line
with_line=$(git rev-parse HEAD)

expect() { # expect <pass|fail> <body> <to>
  if PR_BODY="$2" bash "$check" "$base" "$3" > /dev/null; then got=pass; else got=fail; fi
  if [ "$got" != "$1" ]; then echo "FAIL: expected $1, got $got (body: '$2', to: $3)"; exit 1; fi
}
expect fail "" "$no_line"
expect fail "Some text. Changelog: none, inline" "$no_line"
expect pass "$(printf 'Summary\r\n\r\nChangelog: none, CI only\r\n')" "$no_line"
expect pass "" "$with_line"
expect pass 'Changelog: none $(exit 1) `false` "' "$no_line"
echo "changelog-check: all cases pass"
