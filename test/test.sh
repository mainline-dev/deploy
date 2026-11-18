#!/usr/bin/env bash
# Tests for report-deploy.sh, the script behind the GitHub Action. Each test
# makes a throwaway git repository, starts a stub of Mainline's deploy
# endpoint, runs the script and checks what it sent and said.
#
#   test/test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../report-deploy.sh"
team='3f2a1c4e-0000-4000-8000-000000000001'
failures=0
passes=0

# A git repository with one commit per message given, the last one deployed.
repo_with() {
  work="$(mktemp -d)"
  git -C "$work" init -q
  git -C "$work" config user.name Test
  git -C "$work" config user.email test@example.com
  for message in "$@"; do
    git -C "$work" commit -q --allow-empty -m "$message"
  done
}

commit_at() { git -C "$work" rev-parse "HEAD~$1"; }

start_stub() {
  record="$(mktemp)"
  port=$((20000 + RANDOM % 20000))
  python3 "$here/stub_mainline.py" "$port" "$record" "${1:-200}" "${2:-{\"deployed\": 1\}}" &
  stub=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port" -X POST -d '' 2>/dev/null && break
    sleep 0.1
  done
  : > "$record"
}

stop_stub() { kill "$stub" 2>/dev/null; wait "$stub" 2>/dev/null; }

run() {
  output_file="$(mktemp)"
  out="$(cd "$work" && env MAINLINE_TEAM_ID="$team" MAINLINE_TOKEN=secret-token \
    MAINLINE_URL="http://127.0.0.1:$port" GITHUB_OUTPUT="$output_file" "$@" bash "$script" 2>&1)"
  status=$?
}

sent_ids() { python3 -c "import json,sys; [print(i) for l in open(sys.argv[1]) for i in sorted(json.loads(json.loads(l)['body'])['story_ids'])]" "$record"; }
requests() { wc -l < "$record" | tr -d ' '; }

check() {
  if [ "$2" = "$3" ]; then
    passes=$((passes + 1))
  else
    failures=$((failures + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
  fi
}

test_reports_the_stories_named_in_the_pushed_commits() {
  repo_with 'Before the push [11111111]' 'Rotate the key [DBDF9FEF]' 'Fix the test [dbdf9fef] and [ABCDEF12]'
  start_stub
  run PUSH_BEFORE="$(commit_at 2)" DEPLOYED_SHA="$(commit_at 0)"
  check 'reports the stories named in the pushed commits, each once' $'abcdef12\ndbdf9fef' "$(sent_ids)"
  stop_stub
}

test_takes_a_full_story_id() {
  repo_with 'Rotate the key [DBDF9FEF-1234-4567-89AB-0123456789AB]'
  start_stub
  run
  check 'takes a full story ID' 'dbdf9fef-1234-4567-89ab-0123456789ab' "$(sent_ids)"
  stop_stub
}

test_reads_only_the_deployed_commit_without_a_previous_head() {
  repo_with 'Earlier [11111111]' 'Rotate the key [DBDF9FEF]'
  start_stub
  run DEPLOYED_SHA="$(commit_at 0)"
  check 'reads only the deployed commit when there is no previous head' 'dbdf9fef' "$(sent_ids)"
  stop_stub
}

test_reads_only_the_deployed_commit_for_a_new_branch() {
  repo_with 'Earlier [11111111]' 'Rotate the key [DBDF9FEF]'
  start_stub
  run PUSH_BEFORE=0000000000000000000000000000000000000000 DEPLOYED_SHA="$(commit_at 0)"
  check 'reads only the deployed commit for a push that made the branch' 'dbdf9fef' "$(sent_ids)"
  stop_stub
}

test_reads_only_the_deployed_commit_when_the_previous_head_is_missing() {
  repo_with 'Earlier [11111111]' 'Rotate the key [DBDF9FEF]'
  start_stub
  run PUSH_BEFORE=1111111111111111111111111111111111111111 DEPLOYED_SHA="$(commit_at 0)"
  check 'reads only the deployed commit when the previous head is not in the checkout' 'dbdf9fef' "$(sent_ids)"
  check 'succeeds when the previous head is not in the checkout' '0' "$status"
  check 'says how to read the whole push' 'yes' "$(grep -q 'fetch-depth: 0' <<<"$out" && echo yes || echo no)"
  stop_stub
}

test_reads_since_the_tag_before_for_a_tag() {
  repo_with 'Last release [11111111]' 'Rotate the key [DBDF9FEF]' 'Fix the test [ABCDEF12]'
  git -C "$work" tag v1 "$(commit_at 2)"
  git -C "$work" tag v2
  start_stub
  run DEPLOYED_REF_TYPE=tag PUSH_BEFORE=0000000000000000000000000000000000000000 DEPLOYED_SHA="$(commit_at 0)"
  check 'reads every commit since the tag before, for a tag' $'abcdef12\ndbdf9fef' "$(sent_ids)"
  stop_stub
}

test_reads_from_the_previous_head_for_a_moved_tag() {
  repo_with 'Last release [11111111]' 'Rotate the key [DBDF9FEF]' 'Fix the test [ABCDEF12]'
  git -C "$work" tag v1 "$(commit_at 2)"
  start_stub
  run DEPLOYED_REF_TYPE=tag PUSH_BEFORE="$(commit_at 1)" DEPLOYED_SHA="$(commit_at 0)"
  check 'reads from the previous head for a tag that moved' 'abcdef12' "$(sent_ids)"
  stop_stub
}

test_reads_only_the_deployed_commit_for_the_first_tag() {
  repo_with 'Earlier [11111111]' 'Rotate the key [DBDF9FEF]'
  git -C "$work" tag v1
  start_stub
  run DEPLOYED_REF_TYPE=tag DEPLOYED_SHA="$(commit_at 0)"
  check 'reads only the deployed commit for the first tag' 'dbdf9fef' "$(sent_ids)"
  check 'says nothing of the checkout for the first tag' 'no' "$(grep -q 'fetch-depth' <<<"$out" && echo yes || echo no)"
  stop_stub
}

test_says_when_a_shallow_checkout_hides_the_tag_before() {
  repo_with 'Last release [11111111]' 'Rotate the key [DBDF9FEF]'
  git -C "$work" tag v1 "$(commit_at 1)"
  git -C "$work" tag v2
  shallow="$(mktemp -d)"
  git clone -q --depth 1 "file://$work" "$shallow"
  work="$shallow"
  start_stub
  run DEPLOYED_REF_TYPE=tag
  check 'reads only the deployed commit for a tag in a shallow checkout' 'dbdf9fef' "$(sent_ids)"
  check 'says how to read back to the tag before' 'yes' "$(grep -q 'fetch-depth: 0' <<<"$out" && echo yes || echo no)"
  stop_stub
}

test_warns_in_the_way_the_pipeline_shows() {
  repo_with 'Rotate the key [DBDF9FEF]'
  start_stub
  run GITHUB_ACTIONS=true PUSH_BEFORE=1111111111111111111111111111111111111111
  check 'marks a warning for GitHub Actions' 'yes' "$(grep -q '^::warning::' <<<"$out" && echo yes || echo no)"
  run GITHUB_ACTIONS= PUSH_BEFORE=1111111111111111111111111111111111111111
  check 'gives a plain warning in any other pipeline' 'yes' "$(grep -q '^Warning: ' <<<"$out" && echo yes || echo no)"
  stop_stub
}

test_reads_from_since_when_given() {
  repo_with 'Long ago [11111111]' 'Earlier [22222222]' 'Rotate the key [DBDF9FEF]'
  start_stub
  run MAINLINE_SINCE="$(commit_at 2)" PUSH_BEFORE="$(commit_at 1)" DEPLOYED_SHA="$(commit_at 0)"
  check 'reads from the commit given as since' $'22222222\ndbdf9fef' "$(sent_ids)"
  stop_stub
}

test_reports_given_stories_without_reading_commits() {
  repo_with 'Rotate the key [DBDF9FEF]'
  start_stub
  run MAINLINE_STORIES='ABCDEF12 12345678'
  check 'reports the stories it is given, and no others' $'12345678\nabcdef12' "$(sent_ids)"
  stop_stub
}

test_leaves_out_brackets_that_are_not_story_ids() {
  repo_with 'Tidy up [WIP] [skip ci] [1234] [DBDF9FEF]'
  start_stub
  run
  check 'leaves out brackets that are not story IDs' 'dbdf9fef' "$(sent_ids)"
  stop_stub
}

test_says_so_and_calls_nothing_without_story_ids() {
  repo_with 'Tidy up the README'
  start_stub
  run
  check 'calls nothing without story IDs' '0' "$(requests)"
  check 'succeeds without story IDs' '0' "$status"
  check 'gives zero as the count without story IDs' 'deployed=0' "$(cat "$output_file")"
  stop_stub
}

test_posts_to_the_team_with_the_token() {
  repo_with 'Rotate the key [DBDF9FEF]'
  start_stub
  run
  check 'posts to the team deploy address' "/api/teams/$team/deploys" \
    "$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).readline())['path'])" "$record")"
  check 'sends the token as a bearer' 'Bearer secret-token' \
    "$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).readline())['auth'])" "$record")"
  stop_stub
}

test_gives_back_the_count_mainline_reports() {
  repo_with 'Rotate the key [DBDF9FEF] [ABCDEF12]'
  start_stub 200 '{"deployed":2}'
  run
  check 'succeeds when Mainline takes the report' '0' "$status"
  check 'gives back the count Mainline reports' 'deployed=2' "$(cat "$output_file")"
  stop_stub
}

test_fails_with_the_error_when_mainline_refuses() {
  repo_with 'Rotate the key [DBDF9FEF]'
  start_stub 401 '{"error":"unauthorized"}'
  run
  check 'fails when Mainline refuses' '1' "$status"
  check 'shows the error Mainline gave' 'yes' "$(grep -q unauthorized <<<"$out" && echo yes || echo no)"
  stop_stub
}

test_tries_again_when_mainline_is_failing() {
  repo_with 'Rotate the key [DBDF9FEF]'
  start_stub 503 '{"error":"unavailable"}'
  run
  check 'tries three more times when Mainline is failing' '4' "$(requests)"
  check 'fails when Mainline keeps failing' '1' "$status"
  stop_stub
}

test_fails_with_a_reason_when_mainline_cannot_be_reached() {
  repo_with 'Rotate the key [DBDF9FEF]'
  start_stub
  stop_stub
  run
  check 'fails when Mainline cannot be reached' '1' "$status"
  check 'says Mainline could not be reached' 'yes' "$(grep -q 'Could not reach Mainline' <<<"$out" && echo yes || echo no)"
}

test_needs_a_team_and_a_token() {
  repo_with 'Rotate the key [DBDF9FEF]'
  start_stub
  run MAINLINE_TEAM_ID=''
  check 'fails without a team' '1' "$( [ "$status" -ne 0 ] && echo 1 || echo 0)"
  run MAINLINE_TOKEN=''
  check 'fails without a token' '1' "$( [ "$status" -ne 0 ] && echo 1 || echo 0)"
  check 'calls nothing without a team or token' '0' "$(requests)"
  stop_stub
}

for test in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$test"
done
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
