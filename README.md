# Report a deploy to Mainline

Tells [Mainline](https://mainline.dev) which stories a deploy put into production. Put a story's ID in square brackets in a commit message, run this Action after your deploy, and it reads the story IDs from the deployed commits and reports them to your Mainline team as deployed.

## Usage

Add a step after your deploy:

```yaml
name: Deploy

on:
  push:
    branches: [master]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      # ... your deploy ...

      - uses: mainline-dev/deploy@v1
        with:
          team-id: ${{ secrets.MAINLINE_TEAM_ID }}
          token: ${{ secrets.MAINLINE_DEPLOY_TOKEN }}
```

Your team's ID and deploy token are on the deploy webhook page in your Mainline team settings. Keep both in secrets.

## Naming a story in a commit

Put the story's ID in square brackets anywhere in the commit message: the eight characters its card shows, or the full ID from Copy ID, in any case.

```
Guests can pay with a saved card [DBDF9FEF]
```

Other brackets, such as `[WIP]` or `[skip ci]`, are left alone. Any eight characters from 0 to 9 and A to F in brackets are read as a story's ID, so a date such as `[20261118]` is sent too, and Mainline counts only the IDs of its own stories. A commit that reverts another is passed over, since it names the story it takes back out.

On a push, the Action reads every commit since the branch's previous head, which is why the checkout above fetches the whole history. Otherwise, such as for a push that creates the branch or a run started by hand, it reads only the deployed commit. To read the commits after a different one, give that commit as `since`. To skip the commits and name the stories yourself, give them as `stories`.

For a tag or a release, it reads every commit since the tag before it. A tag with a hyphen in its name, such as `v1.1.0-rc1`, is not taken as the tag before unless the deployed tag has a hyphen too. To say which tags count, give a pattern as `tag-pattern`, such as `v*.*.*`.

Each story is reported once, and Mainline counts only stories that have started and are not yet released.

A push is read from its own previous head, not from the last deploy that worked. If a push's deploy fails or is skipped, the next push's deploy does not report that push's stories. Run the failed deploy again, or give the last deployed commit as `since`.

## Inputs

| Input | |
| --- | --- |
| `team-id` | Your Mainline team's ID. Required. |
| `token` | The team's deploy webhook token. Required. |
| `url` | Where Mainline runs, for a self-hosted install. Defaults to `https://mainline.dev`. |
| `stories` | Story IDs to report, separated by spaces or commas, instead of reading them from the commits. |
| `since` | A commit to read the story IDs after, instead of the push's previous head. The commit itself is not read. |
| `tag-pattern` | Which tags count as the one before, for a deploy of a tag, such as `v*.*.*`. |

## Outputs

| Output | |
| --- | --- |
| `deployed` | How many stories Mainline recorded as deployed. |

```yaml
      - id: mainline
        uses: mainline-dev/deploy@v1
        with:
          team-id: ${{ secrets.MAINLINE_TEAM_ID }}
          token: ${{ secrets.MAINLINE_DEPLOY_TOKEN }}
      - run: echo "${{ steps.mainline.outputs.deployed }} stories deployed"
```

## Self-hosted Mainline

If you run Mainline yourself, give its address as `url`:

```yaml
      - uses: mainline-dev/deploy@v1
        with:
          team-id: ${{ secrets.MAINLINE_TEAM_ID }}
          token: ${{ secrets.MAINLINE_DEPLOY_TOKEN }}
          url: https://mainline.example.com
```

## Any other pipeline

The Action makes one request, so any pipeline that can run curl can report a deploy. After the deploy, post the story IDs to your team:

```sh
curl -sf -X POST \
  "https://mainline.dev/api/teams/$MAINLINE_TEAM_ID/deploys" \
  -H "Authorization: Bearer $MAINLINE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"story_ids": ["DBDF9FEF"]}'
```

Give each story's eight characters from its card, or its full ID. Mainline answers with `{"deployed": N}`, the number of stories it recorded as deployed. For a self-hosted install, use its address in place of `https://mainline.dev`.

To have the story IDs read from your commits, as the Action does, run its script instead. It needs bash, git and curl, and a checkout with the whole history.

```sh
curl -sfO https://raw.githubusercontent.com/mainline-dev/deploy/v1/report-deploy.sh
bash report-deploy.sh
```

It reads these from the environment:

| Variable | |
| --- | --- |
| `MAINLINE_TEAM_ID` | Your Mainline team's ID. Required. |
| `MAINLINE_TOKEN` | The team's deploy webhook token. Required. |
| `MAINLINE_URL` | Where Mainline runs, for a self-hosted install. |
| `DEPLOYED_SHA` | The deployed commit. Defaults to `HEAD`. |
| `PUSH_BEFORE` | The branch's head before the push, to read every commit since it. |
| `DEPLOYED_TAG` | The tag's name when the deploy is of a tag, to read every commit since the tag before it. |
| `MAINLINE_STORIES`, `MAINLINE_SINCE`, `MAINLINE_TAG_PATTERN` | The same as the `stories`, `since` and `tag-pattern` inputs. |

In GitLab CI, with the team's ID and token as CI/CD variables named as above:

```yaml
report-deploy:
  variables:
    GIT_DEPTH: 0
  script:
    - curl -sfO https://raw.githubusercontent.com/mainline-dev/deploy/v1/report-deploy.sh
    - PUSH_BEFORE="$CI_COMMIT_BEFORE_SHA" DEPLOYED_SHA="$CI_COMMIT_SHA" DEPLOYED_TAG="$CI_COMMIT_TAG" bash report-deploy.sh
```

## What it does when

- No commit names a story: it says so, tells Mainline nothing, and succeeds with `deployed` as 0.
- The push's previous head, or the tag before, is not in the checkout, such as without `fetch-depth: 0` or after a force-push: it warns and reads only the deployed commit.
- Mainline refuses the report, such as for a wrong token: the step fails and shows Mainline's error.
- Mainline cannot be reached, or is failing: it tries three more times, then the step fails.
- The answer is not Mainline's, such as a sign-in page from a wrong `url`: the step fails.
- `url` does not start with `https://` or `http://`, or `stories` has something that is not a story ID: the step fails before anything is sent.

A failed step fails your job, even though the deploy went out. To carry on regardless, add `continue-on-error: true` to the step.

## Testing

`test/test.sh` runs the script against a stand-in for Mainline. It needs bash, git, curl and Python 3.

## Licence

MIT, see LICENSE. Mainline® is a registered trade mark of Kipple Pty Ltd.
