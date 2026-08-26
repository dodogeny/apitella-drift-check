#!/usr/bin/env bash
# Polls an Apitella source and fails (exit 1) if the severity found meets
# FAIL_ON_SEVERITY. Shared by action.yml (GitHub Actions) and the Jenkins example in
# README.md -- one tested implementation instead of two copies to keep in sync.
#
# Required:  API_KEY, and either SOURCE_ID or SOURCE_URL (see "Auto-registration" below)
# Optional:  SOURCE_NAME, SOURCE_TYPE (default: mcp, only used with SOURCE_URL),
#            FAIL_ON_SEVERITY (default: breaking), API_URL (default: https://api.apitella.io/v1)
#
# Sets GITHUB_OUTPUT/GITHUB_STEP_SUMMARY when those env vars are already set (i.e. running
# inside a GitHub Actions step) -- skipped everywhere else, including Jenkins, so this
# script runs standalone in any shell without erroring on an unset/empty file path.
#
# A 429 (Free-plan on-demand poll limit) is deliberately NOT treated as a failure the same
# way a real API error is -- it means "we didn't check this time", not "we checked and it's
# broken". Failing the build either way would block a legitimate merge for a reason that has
# nothing to do with API safety, which is worse than just not checking that one run.
set -euo pipefail

: "${API_KEY:?API_KEY is required}"
FAIL_ON_SEVERITY="${FAIL_ON_SEVERITY:-breaking}"
API_URL="${API_URL:-https://api.apitella.io/v1}"
SOURCE_ID="${SOURCE_ID:-}"
SOURCE_URL="${SOURCE_URL:-}"
SOURCE_NAME="${SOURCE_NAME:-}"
SOURCE_TYPE="${SOURCE_TYPE:-mcp}"

if [ -z "$SOURCE_ID" ] && [ -z "$SOURCE_URL" ]; then
  echo "::error::Either SOURCE_ID (an existing source) or SOURCE_URL (to find-or-create one) is required."
  exit 1
fi

# Auto-registration: given a URL instead of an id, find the existing source with that URL
# on this account (so re-running the same workflow doesn't create a duplicate every time),
# or create one on first run. Lets a CI-first adopter go straight from "add this action" to
# "it's monitored" without a trip through the dashboard first. SOURCE_ID, if set, always
# wins -- this block is skipped entirely for the existing, explicit-id workflow.
if [ -z "$SOURCE_ID" ]; then
  case "$SOURCE_TYPE" in
    mcp | rest) ;;
    *)
      echo "::error::SOURCE_TYPE must be \"mcp\" or \"rest\" (got \"$SOURCE_TYPE\")"
      exit 1
      ;;
  esac

  set +e
  list_response=$(curl --silent --show-error --fail \
    --header "Authorization: Bearer $API_KEY" \
    "$API_URL/sources")
  list_exit=$?
  set -e
  if [ "$list_exit" -ne 0 ]; then
    echo "::error::Could not look up existing sources to auto-register $SOURCE_URL. Check API_URL, network connectivity, and that the API key is valid."
    exit 1
  fi

  SOURCE_ID=$(echo "$list_response" | jq -r --arg url "$SOURCE_URL" '[.[] | select(.url == $url)][0].id // empty')

  if [ -z "$SOURCE_ID" ]; then
    name="${SOURCE_NAME:-$SOURCE_URL}"
    create_payload=$(jq -n --arg type "$SOURCE_TYPE" --arg name "$name" --arg url "$SOURCE_URL" \
      '{type: $type, name: $name, url: $url}')

    set +e
    create_response_with_status=$(curl --silent --show-error \
      --request POST \
      --header "Authorization: Bearer $API_KEY" \
      --header "Content-Type: application/json" \
      --write-out '\n%{http_code}' \
      --data "$create_payload" \
      "$API_URL/sources")
    create_exit=$?
    set -e
    if [ "$create_exit" -ne 0 ]; then
      echo "::error::Could not reach the Apitella API to create a source for $SOURCE_URL."
      exit 1
    fi

    create_http_status="${create_response_with_status##*$'\n'}"
    create_response="${create_response_with_status%$'\n'*}"

    if [ "$create_http_status" -lt 200 ] || [ "$create_http_status" -ge 300 ]; then
      echo "::error::Could not create a source for $SOURCE_URL (HTTP $create_http_status). If you're on the Free plan, check the source-count limit."
      echo "$create_response"
      exit 1
    fi

    SOURCE_ID=$(echo "$create_response" | jq -r '.id')
    echo "Registered a new source for $SOURCE_URL (id: $SOURCE_ID) -- see it in the Apitella dashboard."
  fi
fi

case "$FAIL_ON_SEVERITY" in
  breaking) threshold=3 ;;
  risky) threshold=2 ;;
  notable) threshold=1 ;;
  cosmetic) threshold=0 ;;
  *)
    echo "::error::FAIL_ON_SEVERITY must be one of: breaking, risky, notable, cosmetic (got \"$FAIL_ON_SEVERITY\")"
    exit 1
    ;;
esac

set +e
response_with_status=$(curl --silent --show-error \
  --request POST \
  --header "Authorization: Bearer $API_KEY" \
  --write-out '\n%{http_code}' \
  "$API_URL/sources/$SOURCE_ID/poll-now")
curl_exit=$?
set -e

if [ "$curl_exit" -ne 0 ]; then
  echo "::error::Could not reach the Apitella API. Check API_URL and network connectivity."
  exit 1
fi

http_status="${response_with_status##*$'\n'}"
response="${response_with_status%$'\n'*}"

if [ "$http_status" = "429" ]; then
  message=$(echo "$response" | jq -r '.error // "Rate limit exceeded for on-demand polls on this source."')
  echo "::warning::$message"
  echo "Not failing the build for this -- it means this run wasn't checked, not that it found a problem."
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "rate_limited=true" >> "$GITHUB_OUTPUT"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Apitella drift check"
      echo "⏱️ **Rate limited — not checked this run.** $message"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

if [ "$http_status" -lt 200 ] || [ "$http_status" -ge 300 ]; then
  echo "::error::Poll request failed (HTTP $http_status). Check the source id and that the API key is valid."
  echo "$response"
  exit 1
fi

drifted=$(echo "$response" | jq -r '.drifted')
severity=$(echo "$response" | jq -r '.severity // empty')
changes=$(echo "$response" | jq '.changes | length')
assertion_failures=$(echo "$response" | jq '.assertionFailures | length')
security_findings=$(echo "$response" | jq '.securityFindings | length')
value_drift_findings=$(echo "$response" | jq '.valueDriftFindings | length')

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "drifted=$drifted" >> "$GITHUB_OUTPUT"
  echo "severity=$severity" >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Apitella drift check"
    if [ "$drifted" = "true" ]; then
      echo "**Severity: $severity** — $changes schema change(s), $assertion_failures assertion failure(s), $security_findings security finding(s), $value_drift_findings value-drift finding(s)."
    else
      echo "No drift detected."
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$drifted" != "true" ]; then
  echo "No drift detected."
  exit 0
fi

rank=0
case "$severity" in
  breaking) rank=3 ;;
  risky) rank=2 ;;
  notable) rank=1 ;;
  cosmetic) rank=0 ;;
esac

echo "Severity: $severity ($changes schema change(s), $assertion_failures assertion failure(s), $security_findings security finding(s), $value_drift_findings value-drift finding(s))"

if [ "$rank" -ge "$threshold" ]; then
  echo "::error::Apitella detected $severity drift, at or above the fail-on-severity threshold ($FAIL_ON_SEVERITY). See the source's Drift history in the Apitella dashboard for details."
  exit 1
else
  echo "Drift detected but below the fail-on-severity threshold ($FAIL_ON_SEVERITY) — not failing the build."
fi
