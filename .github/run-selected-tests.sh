#!/usr/bin/env bash
# Request a "Run selected tests" workflow run (selected-tests.yml) on the
# fork, wait for it, and download the results.
#
#   run-selected-tests.sh [-R owner/repo] [-r ref] [-c "configs"] [-W]
#                         [-o outdir] [--no-wait] test[,test...]
#
#   -R  repository (default: Momen-G-Ar/compiler)
#   -r  branch, tag or commit to test (default: the current branch, which
#       must be pushed to the repository)
#   -c  space-separated configurations (default: all four)
#   -W  record expected output; recorded.patch is downloaded to outdir
#   -o  where to download artifacts (default: ./.tmp/selected-tests/<run id>)
#
# The request is committed to .github/selected-tests.env on the
# selected-tests branch through the GitHub API, so no checkout of that
# branch is needed.  Example:
#
#   run-selected-tests.sh -W regressions/gh-90,imported/gnu/cpp/init/ref19
#   git apply .tmp/selected-tests/<run id>/recorded-output/recorded.patch

set -euo pipefail

repo=Momen-G-Ar/compiler
ref=
configs="edg_x86_64 edg_x86_64_cp edg_x86_32 edg_x86_32_cp"
record=false
outdir=
wait=true
while [ $# -gt 0 ]; do
  case "$1" in
    -R) repo=$2; shift 2 ;;
    -r) ref=$2; shift 2 ;;
    -c) configs=$2; shift 2 ;;
    -W) record=true; shift ;;
    -o) outdir=$2; shift 2 ;;
    --no-wait) wait=false; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || { echo "usage: $0 [options] test[,test...]" >&2; exit 2; }
tests=$1

if [ -z "$ref" ]; then
  ref=$(git rev-parse --abbrev-ref HEAD)
  [ "$ref" != HEAD ] || ref=$(git rev-parse HEAD)
fi
# Warn if the code to test is not what is on GitHub.
remote_sha=$(gh api "repos/$repo/commits/$ref" --jq .sha 2>/dev/null || true)
if [ -z "$remote_sha" ]; then
  echo "error: $ref is not on $repo; push it first" >&2
  exit 1
fi
local_sha=$(git rev-parse --verify -q "$ref^{commit}" 2>/dev/null || true)
if [ -n "$local_sha" ] && [ "$local_sha" != "$remote_sha" ]; then
  echo "warning: local $ref ($local_sha) differs from $repo ($remote_sha);" \
       "testing the version on GitHub" >&2
fi

path=.github/selected-tests.env
content=$(printf 'REF=%s\nTESTS=%s\nCONFIGS=%s\nRECORD=%s\n# %s\n' \
  "$remote_sha" "$tests" "$configs" "$record" "$(date -u +%FT%TZ)")
old_sha=$(gh api "repos/$repo/contents/$path?ref=selected-tests" --jq .sha)
commit=$(gh api -X PUT "repos/$repo/contents/$path" \
  -f message="Run selected tests on ${ref} (${remote_sha:0:10})" \
  -f content="$(printf '%s' "$content" | base64 | tr -d '\n')" \
  -f branch=selected-tests -f sha="$old_sha" --jq .commit.sha)
echo "Requested: ref=$ref (${remote_sha:0:10}) tests=$tests record=$record"

run_id=
for _ in $(seq 30); do
  run_id=$(gh run list -R "$repo" -w "Run selected tests" -b selected-tests \
    -L 5 --json databaseId,headSha \
    --jq ".[] | select(.headSha == \"$commit\") | .databaseId" | head -1)
  [ -z "$run_id" ] || break
  sleep 5
done
[ -n "$run_id" ] || { echo "error: no run started for $commit" >&2; exit 1; }
echo "Run: https://github.com/$repo/actions/runs/$run_id"
$wait || exit 0

gh run watch "$run_id" -R "$repo" --exit-status --interval 30 >/dev/null || true
conclusion=$(gh run view "$run_id" -R "$repo" --json conclusion --jq .conclusion)
echo "Conclusion: $conclusion"
gh run view "$run_id" -R "$repo" --json jobs \
  --jq '.jobs[] | "  \(.name): \(.conclusion)"'

outdir=${outdir:-.tmp/selected-tests/$run_id}
mkdir -p "$outdir"
gh run download "$run_id" -R "$repo" -D "$outdir" 2>/dev/null || true
for log in "$outdir"/test-results-*/*/changes.elog; do
  [ -s "$log" ] || continue
  echo "== ${log#"$outdir"/test-results-}"
  cat "$log"
done
if [ -s "$outdir/recorded-output/recorded.patch" ]; then
  echo "Recorded: $outdir/recorded-output/recorded.patch"
  cat "$outdir/recorded-output/recorded.stat"
fi
[ "$conclusion" = success ]
