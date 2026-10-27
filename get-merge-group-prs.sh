#!/usr/bin/env bash
# t/4567 C2: enumerate every PR in a merge_group batch and fail closed on any
# enumeration problem -- zero PRs found, an API failure, or a count mismatch
# against the queue position are all treated as "cannot prove this batch is
# safe," not as "no PRs to check."
#
# A merge-group commit (base_sha..head_sha) contains one commit per PR queued
# at or before this entry's position. We resolve each commit in that range to
# its originating PR via GET /commits/{sha}/pulls, then cross-check that the
# PR at head_sha itself matches the PR number GitHub embeds in head_ref
# (refs/heads/gh-readonly-queue/<branch>/pr-<N>-<sha> -- CORRECTED by live-fire,
# t/4567: N is this entry's OWN PR number, the newest/last-queued PR in the
# batch, NOT a count of PRs in the group as originally assumed. The cross-check
# is therefore an IDENTITY check on the last commit, not a COUNT check.)
#
# Usage: get-merge-group-prs.sh <repo> <base_sha> <head_sha> <head_ref>
# Prints a JSON array of {number, labels: [string...]} to stdout on success.
# Exits 1 (fail closed) on ANY problem, with a legible ::error:: line.
set -euo pipefail

REPO="$1"
BASE_SHA="$2"
HEAD_SHA="$3"
HEAD_REF="$4"

errfile="${RUNNER_TEMP:-/tmp}/get-merge-group-prs.err"

# ---- 1. list the commits in this group (retry 3x, fail closed on exhaustion) ----
COMMITS_JSON=""
last_err=""
for attempt in 1 2 3; do
  if COMMITS_JSON=$(gh api "repos/${REPO}/compare/${BASE_SHA}...${HEAD_SHA}" --jq '[.commits[].sha]' 2>"$errfile"); then
    break
  fi
  COMMITS_JSON=""
  last_err=$(head -c 400 "$errfile" 2>/dev/null | tr '\n' ' ')
  echo "::warning::get-merge-group-prs: compare attempt ${attempt}/3 failed -- ${last_err} -- retrying in $((attempt * 3))s" >&2
  sleep $((attempt * 3))
done
if [ -z "$COMMITS_JSON" ]; then
  echo "::error::get-merge-group-prs: could NOT list commits in ${BASE_SHA}...${HEAD_SHA} after 3 attempts -- API/INFRA failure. Last error: ${last_err}. FAILING CLOSED (cannot enumerate the group)." >&2
  exit 1
fi

COMMIT_COUNT=$(echo "$COMMITS_JSON" | jq 'length')
if [ "$COMMIT_COUNT" -eq 0 ]; then
  echo "::error::get-merge-group-prs: compare returned ZERO commits for ${BASE_SHA}...${HEAD_SHA} -- cannot be a valid merge-queue group. FAILING CLOSED." >&2
  exit 1
fi

# ---- 2. resolve each commit to its PR (retry per-commit; any failure fails the whole batch) ----
PR_NUMBERS=()
for sha in $(echo "$COMMITS_JSON" | jq -r '.[]'); do
  PULLS_JSON=""
  last_err=""
  for attempt in 1 2 3; do
    if PULLS_JSON=$(gh api "repos/${REPO}/commits/${sha}/pulls" 2>"$errfile"); then
      break
    fi
    PULLS_JSON=""
    last_err=$(head -c 400 "$errfile" 2>/dev/null | tr '\n' ' ')
    sleep $((attempt * 3))
  done
  if [ -z "$PULLS_JSON" ]; then
    echo "::error::get-merge-group-prs: could NOT resolve commit ${sha} to a PR after 3 attempts -- ${last_err}. FAILING CLOSED (a commit in this group has no provable owner)." >&2
    exit 1
  fi
  PR_COUNT_FOR_COMMIT=$(echo "$PULLS_JSON" | jq 'length')
  if [ "$PR_COUNT_FOR_COMMIT" -eq 0 ]; then
    echo "::error::get-merge-group-prs: commit ${sha} in the group resolves to ZERO PRs -- cannot prove this batch is safe. FAILING CLOSED." >&2
    exit 1
  fi
  NUM=$(echo "$PULLS_JSON" | jq -r '.[0].number')
  PR_NUMBERS+=("$NUM")
  HEAD_SHA_PR_NUM="$NUM"  # the LAST commit in the range is at head_sha
done

# De-dupe (a PR can have multiple commits in a non-squash group).
UNIQUE_NUMBERS=$(printf '%s\n' "${PR_NUMBERS[@]}" | sort -un)

# ---- 3. cross-check: the PR at head_sha must match head_ref's own PR number ----
# head_ref shape: refs/heads/gh-readonly-queue/<branch>/pr-<N>-<sha>, where N is
# THIS entry's PR number (not a group size/count -- corrected by live-fire).
HEAD_REF_PR_NUM=$(echo "$HEAD_REF" | grep -oP 'gh-readonly-queue/[^/]+/pr-\K[0-9]+' || true)
if [ -z "$HEAD_REF_PR_NUM" ]; then
  echo "::error::get-merge-group-prs: could not parse a PR number out of head_ref '${HEAD_REF}' -- expected gh-readonly-queue/<branch>/pr-<N>-<sha>. FAILING CLOSED (cannot cross-check group identity)." >&2
  exit 1
fi
if [ "$HEAD_SHA_PR_NUM" != "$HEAD_REF_PR_NUM" ]; then
  echo "::error::get-merge-group-prs: the commit at head_sha resolves to PR #${HEAD_SHA_PR_NUM}, but head_ref names PR #${HEAD_REF_PR_NUM} -- IDENTITY MISMATCH. FAILING CLOSED (base_sha/head_sha resolution is probably wrong)." >&2
  exit 1
fi

# ---- 4. fetch labels for every PR and emit the final JSON ----
RESULT="[]"
while IFS= read -r num; do
  [ -z "$num" ] && continue
  PR_JSON=""
  for attempt in 1 2 3; do
    if PR_JSON=$(gh pr view "$num" --repo "$REPO" --json number,labels 2>"$errfile"); then
      break
    fi
    PR_JSON=""
    sleep $((attempt * 3))
  done
  if [ -z "$PR_JSON" ]; then
    last_err=$(head -c 400 "$errfile" 2>/dev/null | tr '\n' ' ')
    echo "::error::get-merge-group-prs: could NOT read labels for PR #${num} after 3 attempts -- ${last_err}. FAILING CLOSED." >&2
    exit 1
  fi
  RESULT=$(echo "$RESULT" | jq --argjson pr "$PR_JSON" '. + [{number: $pr.number, labels: [$pr.labels[].name]}]')
done <<< "$UNIQUE_NUMBERS"

echo "$RESULT"
