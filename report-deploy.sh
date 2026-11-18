#!/usr/bin/env bash
# Tells Mainline which stories a deploy put into production. The stories come
# from the IDs in square brackets in the deployed commits' messages: the eight
# characters a card shows, or a full story ID, in any case. Or from a list
# given as MAINLINE_STORIES.
#
# Reads: MAINLINE_TEAM_ID, MAINLINE_TOKEN, MAINLINE_URL, MAINLINE_STORIES,
# MAINLINE_SINCE, PUSH_BEFORE (the push's previous head), DEPLOYED_SHA.
# Writes the count Mainline reports to GITHUB_OUTPUT as deployed=N.
set -euo pipefail

: "${MAINLINE_TEAM_ID:?team-id is required}"
: "${MAINLINE_TOKEN:?token is required}"
url="${MAINLINE_URL:-https://mainline.dev}"
url="${url%/}"
deployed_sha="${DEPLOYED_SHA:-HEAD}"
none='0000000000000000000000000000000000000000'

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

if [ -n "${MAINLINE_STORIES:-}" ]; then
  ids="$(tr ',' ' ' <<<"$MAINLINE_STORIES" | tr -s ' ' '\n' | sed '/^$/d')"
else
  since="${MAINLINE_SINCE:-${PUSH_BEFORE:-}}"
  if [ "$since" = "$none" ]; then since=''; fi
  # A shallow checkout or a force-push leaves the previous head out of reach.
  if [ -n "$since" ] && ! git cat-file -e "$since^{commit}" 2>/dev/null; then
    echo "::warning::Commit $since is not in this checkout, so only the deployed commit is read. Check out with fetch-depth: 0 to read every commit since it."
    since=''
  fi
  if [ -n "$since" ]; then
    messages="$(git log --format=%B "$since..$deployed_sha")"
  else
    messages="$(git log -1 --format=%B "$deployed_sha")"
  fi
  hex='[0-9A-Fa-f]'
  ids="$(grep -oE "\\[$hex{8}(-$hex{4}-$hex{4}-$hex{4}-$hex{12})?\\]" <<<"$messages" | tr -d '[]' || true)"
fi
ids="$(tr 'A-F' 'a-f' <<<"$ids" | sort -u | sed '/^$/d')"

if [ -z "$ids" ]; then
  echo "No story IDs in the deployed commits, so nothing to tell Mainline."
  output 'deployed=0'
  exit 0
fi

quoted=''
while read -r id; do quoted+="\"$id\","; done <<<"$ids"
json="{\"story_ids\":[${quoted%,}]}"
body="$(mktemp)"
# Tries again when Mainline is down or busy, and gives up rather than hang.
reached=0
code="$(curl -sS -o "$body" -w '%{http_code}' --connect-timeout 10 --max-time 30 --retry 3 --retry-connrefused \
  -X POST "$url/api/teams/$MAINLINE_TEAM_ID/deploys" \
  -H "Authorization: Bearer $MAINLINE_TOKEN" -H 'Content-Type: application/json' --data "$json")" || reached=$?

if [ "$reached" -ne 0 ]; then
  echo "::error::Could not reach Mainline at $url, so the deploy was not reported."
  exit 1
fi
if [ "$code" != '200' ]; then
  echo "::error::Mainline did not take the deploy report ($code): $(cat "$body")"
  exit 1
fi

deployed="$(grep -oE '"deployed": *[0-9]+' "$body" | grep -oE '[0-9]+$' || echo 0)"
echo "Mainline recorded $deployed of $(wc -l <<<"$ids" | tr -d ' ') stories as deployed: $(paste -sd' ' - <<<"$ids")"
output "deployed=$deployed"
