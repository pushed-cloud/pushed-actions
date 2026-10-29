#!/usr/bin/env bash
#
# Self-contained tests for the config directory lookup (lib/config-dir.sh) and
# its wiring into deploy.sh, pr.sh and sync-secrets.sh.
#
#   bash deploy/test-config-dir.sh
#
# Requires git and python3. Every case builds a fresh git repository, so the
# sparse-checkout guard is exercised with a real `git sparse-checkout`, the way
# actions/checkout leaves the working tree.
#
# Cases: only .pushed/, only .base/ (deprecation warning), both (.pushed/ wins,
# files only in .base/ named), .pushed/ in the commit but not checked out (run
# fails and says how to fix the checkout), neither, an explicit input, and no
# git repository at all.
#
# The script-level cases run on a simulated runner without a YAML parser: each
# script then stops with a message that names the path it was about to read,
# which shows which directory it chose without a real API.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_DIR/lib/config-dir.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { echo "  ok: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; echo "$2" | sed 's/^/      | /'; FAIL=$((FAIL + 1)); }

expect_contains() {
  local name="$1" out="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$out"; then ok "$name"; else fail "$name (missing: $needle)" "$out"; fi
}
expect_absent() {
  local name="$1" out="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$out"; then fail "$name (unexpected: $needle)" "$out"; else ok "$name"; fi
}
expect_status() {
  local name="$1" want="$2" got="$3" out="$4"
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail "$name (exit $got, want $want)" "$out"; fi
}

# --- fixtures --------------------------------------------------------------
# new_repo NAME DIR... : a committed repo with config.yaml and secrets.yaml in
# each DIR, plus a README so a sparse checkout still has a root file.
new_repo() {
  local repo="$WORK/$1"; shift
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo demo > "$repo/README.md"
  local d
  for d in "$@"; do
    mkdir -p "$repo/$d"
    printf 'environments:\n  stage:\n    replicas: 1\n' > "$repo/$d/config.yaml"
    printf 'environments:\n  stage:\n    - github: X\n      secret: X\n' > "$repo/$d/secrets.yaml"
  done
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m fixture
  echo "$repo"
}

# resolve DIR [VAR=value...]: source the lib in DIR, print the resolved
# CONFIG_FILE on the last line, exit with the lib's status.
resolve() {
  local dir="$1"; shift
  (
    cd "$dir" || exit 1
    unset CONFIG_FILE
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck source=/dev/null
    . "$LIB"
    config_file_default CONFIG_FILE config.yaml || exit 1
    echo "RESOLVED=$CONFIG_FILE"
  ) 2>&1
}

echo "=== lib/config-dir.sh ==="

# 1. Only .pushed/.
R=$(new_repo only-pushed .pushed)
OUT=$(resolve "$R"); ST=$?
expect_status "only .pushed: succeeds" 0 "$ST" "$OUT"
expect_contains "only .pushed: reads .pushed/" "$OUT" "RESOLVED=.pushed/config.yaml"
expect_absent "only .pushed: no warning" "$OUT" "::warning"

# 2. Only .base/: still works, with a deprecation warning.
R=$(new_repo only-base .base)
OUT=$(resolve "$R"); ST=$?
expect_status "only .base: succeeds" 0 "$ST" "$OUT"
expect_contains "only .base: reads .base/" "$OUT" "RESOLVED=.base/config.yaml"
expect_contains "only .base: deprecation warning" "$OUT" "::warning title=Rename .base/ to .pushed/::"

# 3. Both: .pushed/ wins, and a file only in .base/ is named.
R=$(new_repo both .pushed .base)
echo 'redirects: []' > "$R/.base/redirects.yaml"
OUT=$(resolve "$R"); ST=$?
expect_status "both: succeeds" 0 "$ST" "$OUT"
expect_contains "both: .pushed wins" "$OUT" "RESOLVED=.pushed/config.yaml"
expect_contains "both: names the file only in .base" "$OUT" "ignored: .base/redirects.yaml."
rm "$R/.base/redirects.yaml"
OUT=$(resolve "$R")
expect_contains "both, same files: says .base is ignored" "$OUT" "Config is read from .pushed/ only. Delete .base/."

# 4. .pushed/ in the commit, but the sparse-checkout still lists .base only.
R=$(new_repo sparse-base .pushed .base)
git -C "$R" sparse-checkout set .base
if [ -d "$R/.pushed" ] || [ ! -d "$R/.base" ]; then
  fail "sparse fixture: expected .base checked out and .pushed not" "$(ls -A "$R")"
fi
OUT=$(resolve "$R"); ST=$?
expect_status ".pushed not checked out: fails" 1 "$ST" "$OUT"
expect_contains ".pushed not checked out: error annotation" "$OUT" "::error title=.pushed/ not checked out::"
expect_contains ".pushed not checked out: says how to fix" "$OUT" "sparse-checkout: .pushed"
expect_absent ".pushed not checked out: does not fall back to .base" "$OUT" "RESOLVED="

# 4b. Same, with nothing of the config checked out.
R=$(new_repo sparse-none .pushed)
mkdir -p "$R/src" && echo x > "$R/src/x" && git -C "$R" add -A \
  && git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m src
git -C "$R" sparse-checkout set src
OUT=$(resolve "$R"); ST=$?
expect_status ".pushed not checked out, no .base: fails" 1 "$ST" "$OUT"

# 4c. The repo still has only .base/, but the workflow already checks out
#     .pushed (as the docs now show): nothing is in the working tree. Must fail
#     and name .base, not deploy with no config.
R=$(new_repo sparse-new-line .base)
git -C "$R" sparse-checkout set .pushed
OUT=$(resolve "$R"); ST=$?
expect_status ".base in commit, sparse .pushed: fails" 1 "$ST" "$OUT"
expect_contains ".base in commit, sparse .pushed: names .base" "$OUT" "::error title=.base/ not checked out::"
expect_absent ".base in commit, sparse .pushed: no silent fallback" "$OUT" "RESOLVED="

# 4d. A file (or symlink) named .pushed is not the config directory.
R=$(new_repo pushed-file .base)
echo not-a-dir > "$R/.pushed" && git -C "$R" add -A \
  && git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m file
OUT=$(resolve "$R"); ST=$?
expect_status "file named .pushed: succeeds" 0 "$ST" "$OUT"
expect_contains "file named .pushed: reads .base/" "$OUT" "RESOLVED=.base/config.yaml"

# 4e. Container jobs: git sees the checkout as owned by someone else and
#     refuses it ("dubious ownership"). The guard must still work.
R=$(new_repo dubious .pushed .base)
git -C "$R" sparse-checkout set .base
if grep -q "dubious ownership" <<< "$(cd "$R" && GIT_TEST_ASSUME_DIFFERENT_OWNER=1 git status 2>&1)"; then
  OUT=$(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 resolve "$R"); ST=$?
  expect_status "dubious ownership: guard still fails the run" 1 "$ST" "$OUT"
  expect_contains "dubious ownership: names .pushed" "$OUT" ".pushed/ IS NOT CHECKED OUT"
else
  fail "dubious ownership simulation unavailable in this git" "$(git --version)"
fi

# 4f. Any other git failure is a warning, not silence.
R=$(new_repo broken-git .base)
printf '[core\n' >> "$R/.git/config"
OUT=$(resolve "$R"); ST=$?
expect_status "broken git: still reads .base" 0 "$ST" "$OUT"
expect_contains "broken git: warns that the checkout was not verified" "$OUT" "::warning title=Config checkout not verified::"

# 4g. A parent .git is never asked (shared runner, job without a checkout):
#     the working directory has no .git of its own, so the guard is skipped
#     even though the parent's commit has .pushed.
R=$(new_repo parent .pushed)
mkdir -p "$R/work/.base"
OUT=$(resolve "$R/work"); ST=$?
expect_status "parent .git: succeeds" 0 "$ST" "$OUT"
expect_contains "parent .git: reads the local .base/" "$OUT" "RESOLVED=.base/config.yaml"
expect_absent "parent .git: not consulted" "$OUT" "NOT CHECKED OUT"

# 4h. A non-English locale changes nothing: the guard still fails the run,
#     with no spurious warning.
R=$(new_repo locale .pushed .base)
git -C "$R" sparse-checkout set .base
OUT=$(LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 LANGUAGE=de resolve "$R"); ST=$?
expect_status "non-English locale: guard fails the run" 1 "$ST" "$OUT"
expect_absent "non-English locale: no spurious warning" "$OUT" "not verified"

# 5. Neither directory: no config, no warning, no failure.
R=$(new_repo neither)
OUT=$(resolve "$R"); ST=$?
expect_status "neither: succeeds" 0 "$ST" "$OUT"
expect_contains "neither: points at .pushed/ (absent file)" "$OUT" "RESOLVED=.pushed/config.yaml"
expect_absent "neither: no warning" "$OUT" "::warning"

# 6. An explicit input wins and skips the lookup.
R=$(new_repo explicit .pushed .base)
OUT=$(resolve "$R" CONFIG_FILE=.base/config.yaml); ST=$?
expect_status "explicit input: succeeds" 0 "$ST" "$OUT"
expect_contains "explicit input: used as given" "$OUT" "RESOLVED=.base/config.yaml"
expect_absent "explicit input: no warning" "$OUT" "::warning"

# 7. No git repository: the guard has nothing to compare and stays quiet.
mkdir -p "$WORK/nogit/.base"
OUT=$(resolve "$WORK/nogit"); ST=$?
expect_status "no git repo: succeeds" 0 "$ST" "$OUT"
expect_contains "no git repo: reads .base/" "$OUT" "RESOLVED=.base/config.yaml"

# --- the actions -----------------------------------------------------------
mkdir -p "$WORK/noyaml" "$WORK/bin"
printf 'raise ImportError("No module named %s")\n' "'yaml'" > "$WORK/noyaml/yaml.py"
for t in jq git; do
  p=$(command -v "$t") || { echo "$t is required"; exit 1; }
  ln -sf "$p" "$WORK/bin/$t"
done

# run_script SCRIPT DIR: run an action script with empty inputs on a runner
# without a YAML parser. The API points at a closed port.
run_script() {
  local script="$1" dir="$2"
  (
    cd "$dir" || exit 1
    export APP=demo ENVIRONMENT=stage IMAGE_TAG=t-123 COMMIT_SHA=deadbeef
    export CONFIG_FILE="" NGINX_CONFIG_FILE="" REDIRECTS_FILE="" SECRETS_FILE=""
    export ACTION=create PR_NUMBER=42
    export API_URL=http://127.0.0.1:9 API_KEY=x TARGET_ENV=""
    export GITHUB_OUTPUT="$WORK/gh_out"
    : > "$GITHUB_OUTPUT"
    export PATH="$WORK/bin:/usr/bin:/bin"
    export PYTHONPATH="$WORK/noyaml"
    bash "$script" 2>&1
  )
}

PUSHED=$(new_repo s-pushed .pushed)
BASE=$(new_repo s-base .base)
SPARSE=$(new_repo s-sparse .pushed .base)
git -C "$SPARSE" sparse-checkout set .base
NEWLINE=$(new_repo s-newline .base)
git -C "$NEWLINE" sparse-checkout set .pushed

for s in deploy/deploy.sh pr/pr.sh sync-secrets/sync-secrets.sh; do
  echo "=== $s ==="
  case "$s" in
    deploy/*)       want_p="cannot read your .pushed/*.yaml config"; want_b="cannot read your .base/*.yaml config" ;;
    pr/*)           want_p="cannot read .pushed/config.yaml";        want_b="cannot read .base/config.yaml" ;;
    sync-secrets/*) want_p="Reading secrets mapping from: .pushed/secrets.yaml"; want_b="Reading secrets mapping from: .base/secrets.yaml" ;;
  esac
  OUT=$(run_script "$REPO_DIR/$s" "$PUSHED")
  expect_contains "$s: only .pushed -> reads .pushed/" "$OUT" "$want_p"
  OUT=$(run_script "$REPO_DIR/$s" "$BASE")
  expect_contains "$s: only .base -> reads .base/" "$OUT" "$want_b"
  expect_contains "$s: only .base -> deprecation warning" "$OUT" "Rename .base/ to .pushed/"
  OUT=$(run_script "$REPO_DIR/$s" "$SPARSE"); ST=$?
  expect_status "$s: .pushed not checked out -> fails" 1 "$ST" "$OUT"
  expect_contains "$s: .pushed not checked out -> says how to fix" "$OUT" ".pushed/ IS NOT CHECKED OUT"
  expect_absent "$s: .pushed not checked out -> reads nothing from .base" "$OUT" "$want_b"
  OUT=$(run_script "$REPO_DIR/$s" "$NEWLINE"); ST=$?
  expect_status "$s: .base in commit, sparse .pushed -> fails" 1 "$ST" "$OUT"
  expect_contains "$s: .base in commit, sparse .pushed -> says how to fix" "$OUT" ".base/ IS NOT CHECKED OUT"
done

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
