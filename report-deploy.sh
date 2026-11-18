#!/usr/bin/env bash
# Tells Mainline which stories a deploy put into production. The stories come
# from the IDs in square brackets in the deployed commits' messages: the eight
# characters a card shows, or a full story ID, in any case. Or from a list
# given as MAINLINE_STORIES.
#
# Reads: MAINLINE_TEAM_ID, MAINLINE_TOKEN, MAINLINE_URL, MAINLINE_STORIES,
# MAINLINE_SINCE, PUSH_BEFORE (the push's previous head), DEPLOYED_SHA,
# DEPLOYED_REF_TYPE (tag when the deploy is of a tag).
# Writes the count Mainline reports to GITHUB_OUTPUT as deployed=N.
#
# It runs in any pipeline with bash, git and curl, not only GitHub Actions.
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

# GitHub Actions shows these on the run's summary. Other pipelines get a line.
warn() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::warning::$1"; else echo "Warning: $1" >&2; fi
}

fail() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::$1"; else echo "Error: $1" >&2; fi
  exit 1
}

has_commit() { git cat-file -e "$1^{commit}" 2>/dev/null; }

if [ -n "${MAINLINE_STORIES:-}" ]; then
  ids="$(tr ',' ' ' <<<"$MAINLINE_STORIES" | tr -s ' ' '\n' | sed '/^$/d')"
else
  # Reads from the commit given, else the push's previous head, else for a tag
  # the tag before it, else only the deployed commit.
  since="${MAINLINE_SINCE:-${PUSH_BEFORE:-}}"
  if [ "$since" = "$none" ]; then since=''; fi
  # A shallow checkout or a force-push leaves the previous head out of reach.
  missing=''
  if [ -n "$since" ] && ! has_commit "$since"; then missing="$since"; since=''; fi
  if [ -z "$since" ] && [ -z "${MAINLINE_SINCE:-}" ] && [ "${DEPLOYED_REF_TYPE:-}" = tag ]; then
    since="$(git describe --tags --abbrev=0 "$deployed_sha^" 2>/dev/null || true)"
    if [ -z "$since" ] && [ "$(git rev-parse --is-shallow-repository)" = true ]; then
      missing="${missing:-the tag before this one}"
    fi
  fi
  if [ -z "$since" ] && [ -n "$missing" ]; then
    warn "Cannot find $missing in this checkout, so only the deployed commit is read. Check out with fetch-depth: 0 to read every commit since it."
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
  fail "Could not reach Mainline at $url, so the deploy was not reported."
fi
if [ "$code" != '200' ]; then
  fail "Mainline did not take the deploy report ($code): $(cat "$body")"
fi

deployed="$(grep -oE '"deployed": *[0-9]+' "$body" | grep -oE '[0-9]+$' || echo 0)"
echo "Mainline recorded $deployed of $(wc -l <<<"$ids" | tr -d ' ') stories as deployed: $(paste -sd' ' - <<<"$ids")"
output "deployed=$deployed"
