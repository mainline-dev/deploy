# Report a deploy to Mainline, from GitHub Actions

Add a step after your deploy:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0

# ... your deploy ...

- uses: mainline-dev/deploy/github@v1
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

On a push, the Action reads every commit since the branch's previous head, which is why the checkout above fetches the whole history. Otherwise it reads only the deployed commit. Each story is reported once, and Mainline counts only stories that have started and are not yet released.

## Inputs

| Input | |
| --- | --- |
| `team-id` | Your Mainline team's ID. Required. |
| `token` | The team's deploy webhook token. Required. |
| `url` | Where Mainline runs, for a self-hosted install. Defaults to `https://mainline.dev`. |
| `stories` | Story IDs to report, separated by spaces, instead of reading them from the commits. |
| `since` | A commit to read story IDs from, instead of the push's previous head. |

## Output

`deployed`: how many stories Mainline recorded as deployed.

## What it does when

- No commit names a story: it says so, tells Mainline nothing, and succeeds.
- Mainline refuses the report, such as for a wrong token: the step fails and shows Mainline's error.

## Testing

`github/test/test.sh` runs the script against a stand-in for Mainline. It needs bash, git, curl and Python 3.
