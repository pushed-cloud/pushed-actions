# `deploy` — Deploy to an Environment

Deploys a new image tag to any named environment (`dev`, `test`, `stage`, `prod`, or custom names you define). Handles config resolution, health polling, and optional staged (canary) rollouts.

## Quick Start

```yaml
- uses: actions/checkout@v4
  with:
    sparse-checkout: .base
- uses: pushed-cloud/pushed-actions/deploy@v1
  with:
    environment: stage
    image_tag: ${{ needs.build.outputs.image_tag }}
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

The `sparse-checkout: .base` line is required — the action reads `.base/config.yaml`, `.base/secrets.yaml`, `.base/nginx.yaml`, and `.base/redirects.yaml` from the runner's working directory.

## Full Example

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image_tag: ${{ steps.build.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
      - name: Build and push
        id: build
        run: |
          # Your build + push steps
          echo "tag=${{ github.run_number }}-${{ github.run_attempt }}-${GITHUB_SHA::7}" >> $GITHUB_OUTPUT

  deploy-stage:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { sparse-checkout: .base }
      - uses: pushed-cloud/pushed-actions/deploy@v1
        with:
          environment: stage
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}

  deploy-prod:
    needs: deploy-stage
    runs-on: ubuntu-latest
    environment: production  # Optional: requires GitHub approval
    steps:
      - uses: actions/checkout@v4
        with: { sparse-checkout: .base }
      - uses: pushed-cloud/pushed-actions/deploy@v1
        with:
          environment: prod
          image_tag: ${{ needs.build.outputs.image_tag }}
          api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

## Image Digests and Deploy Feedback

When the registry lookup succeeds, the platform pins the submitted image to its
`sha256` digest. Moving the registry tag later does not change that pinned
deployment. An explicit new deploy resolves the tag again and can pin new bytes
under the same tag. Digest pinning does not lock the tag in the registry.
Registry permissions or a separately configured tag lock can still reject a
push. Check the build/push log for the actual registry error.

What that means for your pipeline:

- **Use a tag that is unique per run**, not per commit. `${{ github.sha }}` alone
  collides when a workflow run is re-run for the same commit. The examples above
  use `<run_number>-<run_attempt>-<short sha>`; anything unique per build works.
- **Compare digests, not tags.** Identical previous and submitted digests set
  `image_changed=false`, even if the tags differ. Different digests set `true`,
  even if the tag is unchanged.
- **Missing digests mean `image_changed=unknown`.** Older APIs, a first pin,
  staged previews or registry lookup failures can omit either digest. The action
  does not fall back to comparing tags, even when the tags match. When the
  registry is unavailable, the platform preserves an existing pin for the same
  image when possible; otherwise an ordinary deploy can fall back to a tag.
- **A rollback with a recorded digest restores that digest.** If that manifest
  cannot be verified in the target repository, the rollback fails rather than
  deploying whatever the tag points at now.

`image_changed` compares the previous and submitted configuration; it does not
confirm that pods are running the new image. Identical image content can still
require a rollout for config changes. Continue to use the action's health checks.
For image-specific follow-up steps, treat `unknown` as requiring the normal
checks (for example, `steps.deploy.outputs.image_changed != 'false'`).

If you expected new code but get `image_changed=false`, inspect the build/push
result, image repository, tag and registry lookup warnings. A different tag
alone does not prove that a different image was built.
If the push log reports `denied` or `tag is locked`, resolve that push failure
before deploying the intended new image; an unsuccessful push has not replaced
the registry's existing image.

## Staged (Canary) Deployments

Set `auto_promote: false` to deploy a canary version first. The canary lives on a preview URL (the action's `preview_url` output) until you promote it with the [`promote` action](../promote/README.md). Config and secrets scoped to `<env>-preview` apply to the canary only and never to the live version; promoting makes the canary's image the live version.

```yaml
- uses: pushed-cloud/pushed-actions/deploy@v1
  id: deploy
  with:
    environment: prod
    image_tag: ${{ needs.build.outputs.image_tag }}
    auto_promote: false                              # canary pauses for review
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}

- name: Show preview URL
  run: echo "Preview → ${{ steps.deploy.outputs.preview_url }}"
```

Skip `auto_promote` to use the default configured in the portal (Settings → *Auto-promote*).

## Custom Image Name

When the container image name differs from the app name:

```yaml
- uses: pushed-cloud/pushed-actions/deploy@v1
  with:
    app: my-app
    environment: stage
    image: my-image                                  # deploys my-image:<tag>
    image_tag: ${{ needs.build.outputs.image_tag }}
    api_key: ${{ secrets.BASE_PLATFORM_API_KEY }}
```

## Health Polling

By default the action waits for the deployment to become healthy before exiting. The CI run reflects actual deployment status, not just "the API accepted the request".

**What's checked:**
- Health status reaches `Healthy`. Values seen during polling: `Progressing`, `Degraded`, `Missing`, `Healthy`, and `Suspended` (staged deploys — the canary is live on the preview URL and awaiting promotion).
- Running image tag matches the one you deployed

**Example log:**

```
⏳ Waiting for deployment to become healthy (timeout: 300s)…
  [10s] Health: Progressing, Tag: main-bc5059
  [20s] Health: Progressing, Tag: main-bc5059
  [35s] Health: Healthy,     Tag: main-bc5059

✅ Deployment healthy and synced (35s)
```

Disable polling (not recommended):

```yaml
wait_for_healthy: 'false'
```

Extend the timeout for slow-starting apps:

```yaml
wait_timeout: '1200'  # 20 minutes
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `environment` | Yes | — | Target environment (`stage`, `prod`, `brand-a-prod`, …) |
| `image_tag` | Yes | — | Image tag to deploy |
| `api_key` | Yes | — | Platform API key — identifies the partner |
| `app` | No | repo name | App name |
| `image` | No | app name | Container image name (when the image name differs from the app) |
| `config_file` | No | `.base/config.yaml` | Path to app config |
| `nginx_config_file` | No | `.base/nginx.yaml` | Path to custom proxy config |
| `redirects_file` | No | `.base/redirects.yaml` | Path to bulk redirects file (`.yaml` or `.csv`). Falls back to `.csv` if `.yaml` is not present. See [proxy config & redirects](../docs/nginx.md). |
| `api_url` | No | `https://base-api.norce.tech` | Platform API URL |
| `wait_for_healthy` | No | `true` | Wait for the deploy to become healthy before exiting |
| `wait_timeout` | No | `900` | Health-polling timeout (seconds). Must exceed ArgoCD's reconcile time — measured at 6–11 min on the shared controller. |
| `auto_promote` | No | — | `false` → staged canary, `true` → instant rollout. Omit to use portal setting. |

## Outputs

| Output | Description |
|--------|-------------|
| `success` | Whether the deploy succeeded (includes health check if enabled) |
| `namespace` | Deployment namespace |
| `git_commit_sha` | Commit SHA the platform recorded for this deploy |
| `previous_image_tag` | Tag that was running before this deploy |
| `image_digest` | Digest returned by the platform for the submitted image. Empty when the API does not provide one. |
| `image_changed` | String: `true` for different previous/submitted digests, `false` for identical digests, `unknown` if either is missing. Describes image content, not rollout completion; see [Image Digests and Deploy Feedback](#image-digests-and-deploy-feedback). |
| `message` | Result message |
| `health_status` | Final health status (`Healthy`, `Progressing`, `Degraded`, `Suspended`, `Missing`, `Timeout`) |
| `sync_status` | Final sync status (`Synced`, `OutOfSync`, etc.) |
| `preview_url` | Preview URL for staged deploys. Populated when `health_status=Suspended`; empty for standard deploys. |

## Error Handling

When the deploy API call fails, the action exits with code 1 and prints an actionable diagnostic box:

| Situation | Message |
|-----------|---------|
| curl timeout (`--max-time 180`) | `Timeout: backend did not respond within 180s — check the portal` |
| Connection refused / DNS failure | `Connection refused or DNS failure — verify API_URL is reachable` |
| HTTP 4xx / 5xx | Response body included in the error box |

In all cases `deploy_success=false` is written to `$GITHUB_OUTPUT` so downstream steps can branch on it.

## Development

A self-contained test script covers the curl error-handling and happy-path scenarios:

```bash
bash deploy/test-deploy-curl.sh    # curl error handling in deploy.sh
bash deploy/test-wait-healthy.sh   # health-polling verdicts in wait-healthy.sh
```

Both require `python3` (stdlib only). `test-deploy-curl.sh` validates:
1. `|| CURL_EXIT=$?` captures exit codes 28/7/0 under `set -euo pipefail`
2. Connection-refused run exits 1 with the friendly error box
3. Mock-HTTP-200 run exits 0 with correct `GITHUB_OUTPUT` values

`test-wait-healthy.sh` runs the action against a mock Base API and asserts the two
verdicts this action must never get wrong:
1. A slow ArgoCD reconcile is **not** reported as a failed deployment — while your tag
   is not live, the reported health belongs to the release you are replacing
2. A paused canary belonging to the **previous** release is not reported as your
   staged release awaiting promotion

A genuine crash-loop on your own tag still fails within `DEGRADED_GRACE` (60s).

## Related Docs

- [`.base/config.yaml` reference](../docs/config.md)
- [Autoscaling](../docs/scaling.md)
- [Secrets](../docs/secrets.md)
- [Proxy config & redirects](../docs/nginx.md)
- [Multi-brand deploys](../docs/multi-brand.md)
