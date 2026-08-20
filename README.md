# Apitella Drift Check

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A GitHub Action that polls an [Apitella](https://apitella.io) source on demand and fails
the build if schema drift, a failed assertion, a security finding, or a value-drift
finding meets your severity threshold — turning the existing `assertions` feature into a
CI/CD quality gate.

It calls `POST /sources/:id/poll-now`, which runs a real poll synchronously and returns
`severity` plus the full breakdown (`changes`, `assertionFailures`, `securityFindings`,
`valueDriftFindings`) — nothing new on the Apitella side, this is a thin wrapper.

## Usage

```yaml
- name: Check for breaking API drift
  uses: dodogeny/apitella-drift-check@v1
  with:
    api-key: ${{ secrets.APITELLA_API_KEY }}
    source-id: src_your_source_id
    fail-on-severity: breaking # optional, default: breaking
```

Find `source-id` in the URL of the source's page in the Apitella dashboard. Create
`api-key` under **Settings → API keys** and store it as a repo or org secret — never
commit it.

## Inputs

| Input              | Required | Default                       | Description                                                       |
| ------------------ | -------- | ------------------------------ | ------------------------------------------------------------------ |
| `api-key`           | yes      | —                               | Apitella API key (`apt_live_...`).                                 |
| `source-id`         | yes      | —                               | The source UUID to poll.                                           |
| `fail-on-severity`  | no       | `breaking`                      | Minimum severity that fails the step: `breaking`, `risky`, `notable`, or `cosmetic`. |
| `api-url`           | no       | `https://api.apitella.io/v1`    | Override for self-hosted or local testing.                         |

## Outputs

| Output     | Description                                                        |
| ---------- | -------------------------------------------------------------------- |
| `drifted`  | `"true"` if anything was detected at all, regardless of severity.    |
| `severity` | `breaking`, `risky`, `notable`, `cosmetic`, or empty if nothing was found. |

## Example: only warn, never fail

```yaml
- name: Check for API drift
  id: drift
  uses: dodogeny/apitella-drift-check@v1
  continue-on-error: true
  with:
    api-key: ${{ secrets.APITELLA_API_KEY }}
    source-id: src_your_source_id

- name: Notify on drift
  if: steps.drift.outputs.drifted == 'true'
  run: echo "Drift detected: ${{ steps.drift.outputs.severity }}"
```
