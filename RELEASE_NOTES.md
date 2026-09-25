# Release notes

What changed in the pushed-cloud/pushed-actions GitHub Actions (`deploy`, `promote`, `pr`,
`sync-secrets`), newest first. The same notes are published as GitHub Releases and on
https://base-docs.norce.tech/releases. Pin `@v1` to follow compatible releases, or an
exact `vX.Y.Z`.

## v1.3.0 — 2026-09-25

### All actions
- **Every run says which release it is and where it came from.** The first log line of each action names the repository and version that ran (`owner/repo@vX.Y.Z`), and the action sends the same identifier to the platform with each call. If a runner keeps serving a cached older release after `@v1` has moved, the log shows it at a glance, and support can see it too. Nothing to configure.

### deploy
- **A deploy that submits the same image says so.** When the image digest the platform pins for this deploy is identical to the one already running, the action prints a warning box that no new image content was rolled out and sets the new output `image_changed=false`. Configuration changes in the same deploy still apply and can still roll out. If you expected new code, check the build and push logs; a unique tag per build keeps versions traceable.
- **A reused tag with new content is deployed, and you are told.** If you push again under a tag that is already deployed and the content differs, the deploy submits the new digest, the environment rolls out the new bytes, and the log shows the old and new digest (`image_changed=true`). Pushing a rebuilt tag *without* deploying changes nothing that is running: environments are pinned to the digest they were deployed with.
- **Honest about unknowns.** When the platform reports no digest (older environments, first deploys, staged previews, registry lookup failures), `image_changed` is `unknown` and the action says so instead of guessing. Rollback restores exactly the bytes a version ran.

## v1.2.0 — 2026-09-03

**No action needed if you use `@v1`** (`NorceTech/base-actions/deploy@v1`, `promote@v1`, `pr@v1`, `sync-secrets@v1`): the `v1` tag now points at this release. If you pinned `v1.1.1` or a commit, move to `v1.2.0`.

### deploy
- **Staged deploys** (`auto_promote: false`) return the platform's preview URL as the `preview_url` output and end with a warning annotation, *"Canary staged — traffic has NOT shifted to the new version"*, so a green staged deploy is never mistaken for a live one.
- The portal's deployment history now links your **source commit, workflow run and the GitHub user** who triggered the deploy. Nothing to configure.
- A slow platform sync is no longer reported as a failed deployment. The action waits for the environment to be healthy on the new version and reports honestly when it times out.
- New optional input `force_https`, also settable in `.base/config.yaml`.
- The action fails loudly if the runner has no YAML parser instead of deploying an empty configuration.

### promote
- `canary: true` waits until the environment is healthy **on the promoted version** before returning, and the deployment history shows the promotion with your workflow run.

### pr (pull-request environments)
- A failed cleanup on PR close now **fails the job** with the platform's message. Only "environment not found" counts as success. If you see red cleanup jobs after this release, the environment was not removed: re-run the job or ask us.

### sync-secrets
- Fails loudly if the runner has no YAML parser.

## v1.1.1 — 2026-08-05

Two small releases on one day. `v1.1.0` documented the deploy action's error handling and test script; `v1.1.1` brought the redirect-limit error handling in line with it. No action needed if you use `@v1`.

### deploy
- Redirect-limit errors from the platform are surfaced with the platform's message instead of a generic failure.
- The README documents how the action handles errors and how to run its test script locally.

## v1.0.1 — 2026-07-01

Fixes to how the deploy action reports what happened. No action needed if you use `@v1`.

### deploy
- Timeouts and connection failures print the diagnostic box with what to check, instead of a bare `exit code 28`.
- A staged deploy that is paused waiting for promotion is reported as `needs-promotion`, not as a successful live deploy.
- Redirect-limit and route-filter-limit errors from the platform are shown in the CI log with the platform's message.

## v1.0.0 — 2026-05-12

First public release of the GitHub Actions for Norce Base: `deploy`, `promote`, `pr` and `sync-secrets`. Reference them as `NorceTech/base-actions/<action>@v1`; the `v1` tag always points at the latest compatible release.

### deploy
- Waits for the new version to appear before treating a degraded or missing environment as a failure, so a deploy is not reported red while the old version is still being replaced.
