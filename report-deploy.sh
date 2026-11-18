#!/usr/bin/env bash
# Tells Mainline which stories a deploy put into production. The stories come
# from the IDs in square brackets in the deployed commits' messages: the eight
# characters a card shows, or a full story ID, in any case. Or from a list
# given as MAINLINE_STORIES.
#
# Reads: MAINLINE_TEAM_ID, MAINLINE_TOKEN, MAINLINE_URL, MAINLINE_STORIES,
# MAINLINE_SINCE, MAINLINE_TAG_PATTERN, PUSH_BEFORE (the push's previous head),
# DEPLOYED_SHA, DEPLOYED_TAG (the tag's name, when the deploy is of a tag).
# Writes the count Mainline reports to GITHUB_OUTPUT as deployed=N.
#
# It runs in any pipeline with bash, git and curl, not only GitHub Actions.
set -euo pipefail

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

# GitHub Actions reads a line that starts with :: as a command to it, so text
# from outside, such as Mainline's answer, must not bring its own line ends.
escaped() {
  local text="$1"
  text="${text//'%'/%25}"
  text="${text//$'\r'/%0D}"
  text="${text//$'\n'/%0A}"
  printf '%s' "$text"
}

# GitHub Actions shows these on the run's summary. Other pipelines get a line.
warn() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::warning::$(escaped "$1")"; else echo "Warning: $1" >&2; fi
}

fail() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::$(escaped "$1")"; else echo "Error: $1" >&2; fi
  exit 1
}

# Without the spaces and line ends a pasted secret often carries.
trimmed() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

team="$(trimmed "${MAINLINE_TEAM_ID:-}")"
token="$(trimmed "${MAINLINE_TOKEN:-}")"
url="$(trimmed "${MAINLINE_URL:-}")"
url="${url:-https://mainline.dev}"
url="${url%/}"
deployed_sha="${DEPLOYED_SHA:-HEAD}"

plain='^[A-Za-z0-9._-]+$'
if [ -z "$team" ]; then fail 'team-id is required.'; fi
if [ -z "$token" ]; then fail 'token is required.'; fi
if ! [[ "$team" =~ $plain ]]; then fail 'team-id is not a team ID: copy it from the deploy webhook page in your team settings.'; fi
case "$token" in *[[:space:]]*) fail 'token has a space or a line end inside it.' ;; esac
# Without one, curl would send the token over plain http.
case "$url" in
  https://*|http://*) ;;
  *) fail "url must start with https:// or http://, and $url does not." ;;
esac

hex='[0-9A-Fa-f]'
story="$hex{8}(-$hex{4}-$hex{4}-$hex{4}-$hex{12})?"

has_commit() { git cat-file -e "$1^{commit}" 2>/dev/null; }

# The nearest tag before the deployed commit. A tag with a hyphen, such as
# v1.1.0-rc1, is passed over unless the deployed tag has one too.
tag_before() {
  if [ -n "${MAINLINE_TAG_PATTERN:-}" ]; then
    git describe --tags --abbrev=0 --match "$MAINLINE_TAG_PATTERN" "$deployed_sha^" 2>/dev/null || true
    return
  fi
  case "$DEPLOYED_TAG" in
    *-*) git describe --tags --abbrev=0 "$deployed_sha^" 2>/dev/null || true ;;
    *) git describe --tags --abbrev=0 --exclude '*-*' "$deployed_sha^" 2>/dev/null || true ;;
  esac
}

# The messages of the commits asked for, without those that revert another:
# a revert names the story it takes back out. Reverting a revert puts it back.
messages_of() {
  git log --format='%x01%B' "$@" | awk 'BEGIN { RS = "\001" } !/^Revert "/ || /^Revert "Revert "/'
}

if [ -n "${MAINLINE_STORIES:-}" ]; then
  ids="$(tr ',[:space:]' '\n' <<<"$MAINLINE_STORIES" | tr -d '[]' | sed '/^$/d')"
  wrong="$(grep -vxE "$story" <<<"$ids" | head -n 1 || true)"
  if [ -n "$wrong" ]; then
    fail "stories has $wrong, which is not a story ID: give the eight characters a card shows, or the full ID."
  fi
else
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail 'There is no git checkout here to read commits from. Run this after the checkout, in the repository.'
  fi
  if ! has_commit "$deployed_sha"; then
    fail "Cannot find the deployed commit $deployed_sha in this checkout."
  fi
  # Reads from after the commit given, else the push's previous head, else for
  # a tag the tag before it, else only the deployed commit.
  since="${MAINLINE_SINCE:-${PUSH_BEFORE:-}}"
  zeros='^0+$'
  if [[ "$since" =~ $zeros ]]; then since=''; fi
  # A shallow checkout or a force-push leaves the previous head out of reach.
  missing=''
  if [ -n "$since" ] && ! has_commit "$since"; then missing="commit $since"; since=''; fi
  if [ -z "$since" ] && [ -z "${MAINLINE_SINCE:-}" ] && [ -n "${DEPLOYED_TAG:-}" ]; then
    since="$(tag_before)"
    if [ -z "$since" ] && [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
      missing="${missing:-the tag before this one}"
    fi
  fi
  if [ -z "$since" ] && [ -n "$missing" ]; then
    warn "Cannot find $missing in this checkout, so only the deployed commit is read. Check out with fetch-depth: 0 to read every commit since it."
  fi
  if [ -n "$since" ]; then
    messages="$(messages_of "$since..$deployed_sha")"
  else
    messages="$(messages_of -1 "$deployed_sha")"
  fi
  ids="$(grep -oE "\\[$story\\]" <<<"$messages" | tr -d '[]' || true)"
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
trap 'rm -f "$body"' EXIT

# The token goes to curl on its input, where other processes cannot read it.
header="Authorization: Bearer $token"
header="${header//\\/\\\\}"
header="${header//\"/\\\"}"

# Tries three more times when Mainline is down or busy, a little later each
# time, and gives up on a try after half a minute rather than hang.
attempt=1
while :; do
  reached=0
  code="$(curl -sS -o "$body" -w '%{http_code}' --connect-timeout 10 --max-time 30 \
    -X POST "$url/api/teams/$team/deploys" -H 'Content-Type: application/json' --data "$json" \
    --config - <<<"header = \"$header\"")" || reached=$?
  case "$reached:$code" in
    0:408|0:429|0:5??) ;;
    0:*) break ;;
  esac
  if [ "$attempt" -ge 4 ]; then break; fi
  sleep $((1 << (attempt - 1)))
  attempt=$((attempt + 1))
done

if [ "$reached" -ne 0 ]; then
  fail "Could not reach Mainline at $url, so the deploy was not reported."
fi
if [ "$code" != '200' ]; then
  fail "Mainline did not take the deploy report ($code): $(head -c 500 "$body")"
fi

deployed="$(tr -d '\r\n' < "$body" | grep -oE '"deployed"[[:space:]]*:[[:space:]]*[0-9]+' | head -n 1 | grep -oE '[0-9]+$' || true)"
if [ -z "$deployed" ]; then
  fail "The answer from $url had no count of deployed stories, so check that url is where Mainline runs."
fi
echo "Mainline recorded $deployed of $(wc -l <<<"$ids" | tr -d ' ') stories as deployed: $(paste -sd' ' - <<<"$ids")"
output "deployed=$deployed"
