# Apitella Drift Check

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Polls an [Apitella](https://apitella.io) source on demand and fails the build if schema
drift, a failed assertion, a security finding, or a value-drift finding meets your
severity threshold — turning the existing `assertions` feature into a CI/CD quality gate.
Ships two ways to use it: a GitHub Action, and [`drift-check.sh`](drift-check.sh) for
Jenkins or any other shell-based CI.

Both call `POST /sources/:id/poll-now`, which runs a real poll synchronously and returns
`severity` plus the full breakdown (`changes`, `assertionFailures`, `securityFindings`,
`valueDriftFindings`) — nothing new on the Apitella side, this is a thin wrapper. In fact
the GitHub Action *is* `drift-check.sh` under the hood — one tested implementation, not
two copies to keep in sync.

## GitHub Actions

```yaml
- name: Check for breaking API drift
  uses: dodogeny/apitella-drift-check@v1
  with:
    api-key: ${{ secrets.APITELLA_API_KEY }}
    source-id: <your-source-id>
    fail-on-severity: breaking # optional, default: breaking
```

Find `source-id` in the URL of the source's page in the Apitella dashboard. Create
`api-key` under **Settings → API keys** and store it as a repo or org secret — never
commit it.

### Skip the dashboard: auto-register from a URL

Don't have a source set up yet? Give it a URL instead of an id, and the action creates
the source on its first run — every run after that finds the same one by URL instead of
creating a duplicate, so this is safe to leave in place permanently, not just for a
one-time setup:

```yaml
- name: Check for breaking API drift
  uses: dodogeny/apitella-drift-check@v1
  with:
    api-key: ${{ secrets.APITELLA_API_KEY }}
    source-url: https://mcp.example.com/mcp
    source-name: My MCP server # optional, defaults to source-url
    source-type: mcp # optional, "mcp" or "rest", default: mcp
```

`source-id` always wins if both are set. This is the whole point of a CI-first setup:
add the workflow file, and monitoring exists — no trip through the dashboard required
first.

## Inputs

| Input              | Required | Default                       | Description                                                       |
| ------------------ | -------- | ------------------------------ | ------------------------------------------------------------------ |
| `api-key`           | yes      | —                               | Apitella API key (`apt_live_...`).                                 |
| `source-id`         | no       | —                               | The source UUID to poll. Leave unset to auto-register from `source-url` instead. |
| `source-url`        | no       | —                               | Endpoint to monitor. Only used when `source-id` is unset — see auto-registration above. |
| `source-name`       | no       | `source-url`                    | Display name for an auto-registered source. Ignored if `source-id` is set. |
| `source-type`       | no       | `mcp`                           | `mcp` or `rest`, for an auto-registered source. Ignored if `source-id` is set. |
| `fail-on-severity`  | no       | `breaking`                      | Minimum severity that fails the step: `breaking`, `risky`, `notable`, or `cosmetic`. |
| `api-url`           | no       | `https://api.apitella.io/v1`    | Override for self-hosted or local testing.                         |

## Outputs

| Output          | Description                                                        |
| ---------------- | -------------------------------------------------------------------- |
| `drifted`        | `"true"` if anything was detected at all, regardless of severity.    |
| `severity`       | `breaking`, `risky`, `notable`, `cosmetic`, or empty if nothing was found. |
| `rate_limited`   | `"true"` if this run hit the Free-plan on-demand poll limit (see below) — unset otherwise. |

## Free-plan rate limit

On-demand polls (this action's whole job) are capped per source on the Free plan — enough
for real CI usage, not a script hammering the same source in a loop. Hitting it **does not
fail the build**: it means this run wasn't checked, not that it found a problem. You'll see
a `::warning::` in the log and a note in the step summary instead, plus `rate_limited=true`
on the step's output if a later step wants to react to it. Pro accounts aren't subject to
this limit.

## Example: only warn, never fail

```yaml
- name: Check for API drift
  id: drift
  uses: dodogeny/apitella-drift-check@v1
  continue-on-error: true
  with:
    api-key: ${{ secrets.APITELLA_API_KEY }}
    source-id: <your-source-id>

- name: Notify on drift
  if: steps.drift.outputs.drifted == 'true'
  run: echo "Drift detected: ${{ steps.drift.outputs.severity }}"
```

## Jenkins

Download [`drift-check.sh`](drift-check.sh) and run it from a pipeline stage — same logic
and same environment variables as the GitHub Action's inputs, just uppercase. Requires
`curl` and `jq` on the agent (`jq` is not preinstalled on most Jenkins agents, unlike
GitHub-hosted runners — install it in your base image or add an `apt-get install -y jq`
step first).

Store the API key as a Jenkins credential (Manage Jenkins → Credentials) rather than in
the pipeline script — referenced below as `apitella-api-key`. A ready-to-copy starting
point is [`Jenkinsfile.example`](Jenkinsfile.example) — download it and adapt it rather
than retyping this snippet.

```groovy
pipeline {
    agent any

    environment {
        API_KEY = credentials('apitella-api-key')
        SOURCE_ID = '<your-source-id>'
        FAIL_ON_SEVERITY = 'breaking' // optional, default: breaking
    }

    stages {
        stage('Check for breaking API/MCP drift') {
            steps {
                sh '''
                    curl -fsSL -o drift-check.sh \\
                      https://raw.githubusercontent.com/dodogeny/apitella-drift-check/v1/drift-check.sh
                    bash drift-check.sh
                '''
            }
        }
    }
}
```

Pin the URL to a tag (`v1` above), not `main` — otherwise a change to this repo changes
what your pipeline runs without you choosing to update it.
