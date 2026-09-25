#!/usr/bin/env bash
# test-deploy-curl.sh — Tests for deploy.sh curl error-handling
#
# Scenarios:
#   1. Mechanism: verifies || captures exit codes under set -euo pipefail
#      (covers exit 28 / timeout without needing a real 180s wait)
#   2. Connection refused (exit 7): deploy.sh exits 1 with friendly error box
#   3. Success (HTTP 200): deploy.sh exits 0 and sets deploy_success=true
#   4-7. Digest-aware feedback (including missing digests and aliased tags),
#      plus a targeted hint for 400 "does not exist in ACR" responses.
#   8. X-Pushed-Action: every request deploy.sh makes carries the release
#      identity (unstamped checkout and stamped tree), and every Base API curl
#      in the shipped action scripts sends the header.
#   Every mock server must release its port when the scenario finishes.
#
# Usage: bash deploy/test-deploy-curl.sh
# Exit:  0 if all pass, 1 if any fail.

set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/deploy.sh"

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

MOCK_PID=""
cleanup_mock() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
    MOCK_PID=""
  fi
}
trap cleanup_mock EXIT

# Check the actual listening port, not just the saved PID: a subshell can
# discard a newly assigned PID and leave cleanup pointing at an older server.
stop_mock() {
  local port="$1"
  cleanup_mock
  if python3 - "$port" <<'PYEOF'
import socket, sys
try:
    with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=1):
        sys.exit(1)
except OSError:
    pass
PYEOF
  then
    pass "mock server released its listening port"
  else
    fail "mock server still listening after cleanup"
  fi
}

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    pass "$label: exit $expected"
  else
    fail "$label: expected exit $expected, got $actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    pass "$label"
  else
    fail "$label — not found in: $haystack"
  fi
}

assert_file_contains() {
  local label="$1" needle="$2" file="$3"
  if grep -qF "$needle" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — not found in: $(cat "$file" 2>/dev/null || echo '<empty>')"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# SCENARIO 1: Mechanism — || pattern captures any exit code under set -e
#
# The old code was:
#   RESPONSE=$(curl ...) ; CURL_EXIT=$?
# Under set -e this dies before CURL_EXIT=$? on any non-zero exit.
#
# The fix is:
#   CURL_EXIT=0
#   RESPONSE=$(curl ...) || CURL_EXIT=$?
#
# This test proves the pattern works for exit 28 (timeout), exit 7
# (refused), and exit 0 (success) — without needing a real 180s wait.
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Scenario 1: curl exit-code capture mechanism under set -euo pipefail"

# 1a: exit 28 (timeout) — the bug that triggered the incident
S1_EXIT=0
(
  set -euo pipefail
  CURL_EXIT=0
  # shellcheck disable=SC2034  # RESULT mirrors what deploy.sh assigns to RESPONSE
  RESULT=$(bash -c 'exit 28') || CURL_EXIT=$?
  [ "$CURL_EXIT" -eq 28 ] || { echo "FAIL: expected 28, got $CURL_EXIT" >&2; exit 1; }
) || S1_EXIT=$?
assert_exit "exit 28 captured (CURL_EXIT=28, script continues)" 0 "$S1_EXIT"

# 1b: exit 7 (connection refused)
S1_EXIT=0
(
  set -euo pipefail
  CURL_EXIT=0
  # shellcheck disable=SC2034
  RESULT=$(bash -c 'exit 7') || CURL_EXIT=$?
  [ "$CURL_EXIT" -eq 7 ] || { echo "FAIL: expected 7, got $CURL_EXIT" >&2; exit 1; }
) || S1_EXIT=$?
assert_exit "exit 7 captured correctly" 0 "$S1_EXIT"

# 1c: exit 0 (success) — default stays 0
S1_EXIT=0
(
  set -euo pipefail
  CURL_EXIT=0
  # shellcheck disable=SC2034
  RESULT=$(bash -c 'echo hello') || CURL_EXIT=$?
  [ "$CURL_EXIT" -eq 0 ] || { echo "FAIL: expected 0, got $CURL_EXIT" >&2; exit 1; }
) || S1_EXIT=$?
assert_exit "exit 0 stays 0 on success (CURL_EXIT unchanged)" 0 "$S1_EXIT"

# ──────────────────────────────────────────────────────────────────────
# SCENARIO 2: Integration — connection refused (curl exit 7)
#
# Point deploy.sh at a port with no listener.  The script must:
#   • exit 1 (not exit 7)
#   • print the "DEPLOY REQUEST FAILED" error box
#   • print the "Connection refused" branch message
#   • set deploy_success=false in GITHUB_OUTPUT
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Scenario 2: deploy.sh with connection-refused API (curl exit 7)"

FREE_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)")
GH_OUT=$(mktemp)
DEPLOY_OUT=$(mktemp)
SCENARIO2_EXIT=0

env -i \
  HOME="$HOME" \
  PATH="$PATH" \
  APP=test-app \
  ENVIRONMENT=stage \
  IMAGE_TAG=sha-abc123 \
  COMMIT_SHA=abc123 \
  CONFIG_FILE=/nonexistent-config.yaml \
  API_URL="http://127.0.0.1:${FREE_PORT}" \
  API_KEY=test-key \
  GITHUB_OUTPUT="$GH_OUT" \
  ENABLE_HEALTH_PROBE=false \
  USE_NOPROXY=false \
  bash "$DEPLOY_SH" > "$DEPLOY_OUT" 2>&1 || SCENARIO2_EXIT=$?

assert_exit "exit code 1 (not 7 — script handled the error)" 1 "$SCENARIO2_EXIT"
assert_file_contains "error box printed" "DEPLOY REQUEST FAILED" "$DEPLOY_OUT"
assert_file_contains "connection-refused message present" "Connection refused" "$DEPLOY_OUT"
assert_file_contains "deploy_success=false in GITHUB_OUTPUT" "deploy_success=false" "$GH_OUT"

rm -f "$GH_OUT" "$DEPLOY_OUT"

# ──────────────────────────────────────────────────────────────────────
# SCENARIO 3: Integration — success (HTTP 200)
#
# Spin a minimal HTTP server that returns a valid deploy-success JSON.
# deploy.sh must:
#   • exit 0
#   • set deploy_success=true in GITHUB_OUTPUT
#   • set namespace=partnersense-test-app-stage
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Scenario 3: deploy.sh with successful API response (HTTP 200)"

MOCK_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)")

python3 - "$MOCK_PORT" <<'PYEOF' &
import http.server, json, sys

PORT = int(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        content_len = int(self.headers.get('Content-Length', 0))
        self.rfile.read(content_len)
        resp = json.dumps({
            'data': {
                'success': True,
                'namespace': 'partnersense-test-app-stage',
                'message': 'Deployed',
                'gitCommitSha': 'deadbeef',
                'previousImageTag': 'sha-old'
            }
        }).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)
    def log_message(self, fmt, *args): pass

server = http.server.HTTPServer(('127.0.0.1', PORT), Handler)
server.serve_forever()
PYEOF
MOCK_PID=$!

# Give the server a moment to bind
sleep 0.3

GH_OUT=$(mktemp)
DEPLOY_OUT=$(mktemp)
SCENARIO3_EXIT=0

env -i \
  HOME="$HOME" \
  PATH="$PATH" \
  APP=test-app \
  ENVIRONMENT=stage \
  IMAGE_TAG=sha-abc123 \
  COMMIT_SHA=abc123 \
  CONFIG_FILE=/nonexistent-config.yaml \
  API_URL="http://127.0.0.1:${MOCK_PORT}" \
  API_KEY=test-key \
  GITHUB_OUTPUT="$GH_OUT" \
  ENABLE_HEALTH_PROBE=false \
  USE_NOPROXY=false \
  bash "$DEPLOY_SH" > "$DEPLOY_OUT" 2>&1 || SCENARIO3_EXIT=$?

assert_exit "exit code 0 (success)" 0 "$SCENARIO3_EXIT"
assert_file_contains "deploy_success=true in GITHUB_OUTPUT" "deploy_success=true" "$GH_OUT"
assert_file_contains "namespace set in GITHUB_OUTPUT" "namespace=partnersense-test-app-stage" "$GH_OUT"
assert_file_contains "success message printed" "Deploy submitted" "$DEPLOY_OUT"

stop_mock "$MOCK_PORT"
rm -f "$GH_OUT" "$DEPLOY_OUT"

# ──────────────────────────────────────────────────────────────────────
# SCENARIOS 4-7: same-tag feedback and the tag-not-found hint
#
# Tags alone do not identify image content. Compare the platform's previous
# and new digests when both are available, and report unknown otherwise.
# ──────────────────────────────────────────────────────────────────────

assert_not_contains() {
  local label="$1" needle="$2" file="$3"
  if grep -qF "$needle" "$file" 2>/dev/null; then
    fail "$label — unexpectedly found: $needle"
  else
    pass "$label"
  fi
}

# Call directly (never via command substitution) so PORT and MOCK_PID remain
# available to the caller and the EXIT trap.
# start_mock <http-status> <json-body> → sets PORT and MOCK_PID
start_mock() {
  local status="$1" body="$2" port
  cleanup_mock
  port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)")
  python3 - "$port" "$status" "$body" >/dev/null 2>&1 <<'PYEOF' &
import http.server, sys
PORT, STATUS, BODY = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3].encode()
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.send_response(STATUS)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)
    def log_message(self, fmt, *args): pass
http.server.HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
PYEOF
  MOCK_PID=$!
  sleep 0.3
  PORT="$port"
}

# run_deploy <port> <image-tag> → sets DEPLOY_EXIT, GH_OUT, DEPLOY_OUT
run_deploy() {
  local port="$1" tag="$2"
  GH_OUT=$(mktemp)
  DEPLOY_OUT=$(mktemp)
  DEPLOY_EXIT=0
  env -i \
    HOME="$HOME" \
    PATH="$PATH" \
    APP=test-app \
    ENVIRONMENT=stage \
    IMAGE_TAG="$tag" \
    COMMIT_SHA=abc123 \
    CONFIG_FILE=/nonexistent-config.yaml \
    API_URL="http://127.0.0.1:${port}" \
    API_KEY=test-key \
    GITHUB_OUTPUT="$GH_OUT" \
    ENABLE_HEALTH_PROBE=false \
    USE_NOPROXY=false \
    bash "$DEPLOY_SH" > "$DEPLOY_OUT" 2>&1 || DEPLOY_EXIT=$?
}

DIGEST_A="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DIGEST_B="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

success_body() { # <previousImageTag> <newImageTag> [previousImageDigest] [newImageDigest]
  python3 - "$@" <<'PYEOF'
import json, sys
prev_tag, new_tag = sys.argv[1], sys.argv[2]
data = {'success': True, 'namespace': 'partnersense-test-app-stage', 'message': 'Deployed',
        'gitCommitSha': 'deadbeef', 'previousImageTag': prev_tag, 'newImageTag': new_tag}
if len(sys.argv) > 3 and sys.argv[3]: data['previousImageDigest'] = sys.argv[3]
if len(sys.argv) > 4 and sys.argv[4]: data['newImageDigest'] = sys.argv[4]
print(json.dumps({'data': data}))
PYEOF
}

echo ""
echo "Scenario 4: same tag, same digest — unchanged image content"
start_mock 200 "$(success_body sha-abc123 sha-abc123 "$DIGEST_A" "$DIGEST_A")"
run_deploy "$PORT" sha-abc123
stop_mock "$PORT"
assert_exit "still exit 0 (a deliberate re-run is not an error)" 0 "$DEPLOY_EXIT"
assert_file_contains "image_changed=false" "image_changed=false" "$GH_OUT"
assert_file_contains "image_digest output" "image_digest=$DIGEST_A" "$GH_OUT"
assert_file_contains "warning box" "IMAGE CONTENT UNCHANGED" "$DEPLOY_OUT"
assert_file_contains "allows a config-only rollout" "Config changes can still trigger a rollout" "$DEPLOY_OUT"
assert_file_contains "GitHub warning annotation" "::warning::" "$DEPLOY_OUT"
assert_file_contains "success line marks the image unchanged" "(image unchanged)" "$DEPLOY_OUT"
rm -f "$GH_OUT" "$DEPLOY_OUT"

echo ""
echo "Scenario 5: same tag, different digest — tag was re-pushed with new content"
start_mock 200 "$(success_body sha-abc123 sha-abc123 "$DIGEST_A" "$DIGEST_B")"
run_deploy "$PORT" sha-abc123
stop_mock "$PORT"
assert_exit "exit 0" 0 "$DEPLOY_EXIT"
assert_file_contains "image_changed=true" "image_changed=true" "$GH_OUT"
assert_file_contains "notice about re-pushed content" "pushed again with different content" "$DEPLOY_OUT"
assert_not_contains "no unchanged warning" "IMAGE CONTENT UNCHANGED" "$DEPLOY_OUT"
rm -f "$GH_OUT" "$DEPLOY_OUT"

echo ""
echo "Scenario 6: new tag — plain success, no warning"
start_mock 200 "$(success_body sha-old sha-abc123 "$DIGEST_A" "$DIGEST_B")"
run_deploy "$PORT" sha-abc123
stop_mock "$PORT"
assert_exit "exit 0" 0 "$DEPLOY_EXIT"
assert_file_contains "image_changed=true" "image_changed=true" "$GH_OUT"
assert_file_contains "digest shown in the success line" "Deploy submitted: sha-abc123 (${DIGEST_B:0:19}" "$DEPLOY_OUT"
assert_not_contains "no warning" "::warning::" "$DEPLOY_OUT"
assert_not_contains "no notice" "::notice::" "$DEPLOY_OUT"
rm -f "$GH_OUT" "$DEPLOY_OUT"

echo ""
echo "Scenario 6b: same tag on an older platform (no digests) — unknown"
start_mock 200 "$(success_body sha-abc123 sha-abc123)"
run_deploy "$PORT" sha-abc123
stop_mock "$PORT"
assert_exit "exit 0" 0 "$DEPLOY_EXIT"
assert_file_contains "image_changed=unknown" "image_changed=unknown" "$GH_OUT"
assert_file_contains "empty image_digest output" "image_digest=" "$GH_OUT"
assert_file_contains "unknown comparison explained" "cannot determine whether image content changed" "$DEPLOY_OUT"
assert_not_contains "no unchanged claim" "(image unchanged)" "$DEPLOY_OUT"
rm -f "$GH_OUT" "$DEPLOY_OUT"

# Compare bytes independently of tag aliases, and never invent a comparison
# when either side is missing (older APIs, first pins, registry outages or
# staged previews that do not return a previous image).
for case_name in alias first-pin missing-new new-tag-unknown new-tag-first-pin first-deploy; do
  previous_tag=sha-abc123
  new_tag=sha-abc123
  previous_digest="$DIGEST_A"
  new_digest="$DIGEST_A"
  expected=unknown
  case "$case_name" in
    alias) new_tag=sha-alias; expected=false ;;
    first-pin) previous_digest=""; new_digest="$DIGEST_B" ;;
    missing-new) new_digest="" ;;
    new-tag-unknown) new_tag=sha-new; previous_digest=""; new_digest="" ;;
    new-tag-first-pin) new_tag=sha-new; previous_digest=""; new_digest="$DIGEST_B" ;;
    first-deploy) previous_tag=""; previous_digest=""; new_digest="$DIGEST_B" ;;
  esac
  echo ""
  echo "Scenario 6/$case_name: image_changed=$expected"
  start_mock 200 "$(success_body "$previous_tag" "$new_tag" "$previous_digest" "$new_digest")"
  run_deploy "$PORT" "$new_tag"
  stop_mock "$PORT"
  assert_exit "exit 0" 0 "$DEPLOY_EXIT"
  assert_file_contains "image_changed=$expected" "image_changed=$expected" "$GH_OUT"
  if [ "$expected" = false ]; then
    assert_file_contains "same content despite a new tag" "IMAGE CONTENT UNCHANGED" "$DEPLOY_OUT"
  else
    assert_file_contains "unknown comparison explained" "cannot determine whether image content changed" "$DEPLOY_OUT"
    assert_file_contains "success line marks comparison unknown" "(image change unknown)" "$DEPLOY_OUT"
    assert_not_contains "no unchanged claim" "(image unchanged)" "$DEPLOY_OUT"
    assert_not_contains "no no-rollout claim" "NOTHING NEW TO ROLL OUT" "$DEPLOY_OUT"
  fi
  rm -f "$GH_OUT" "$DEPLOY_OUT"
done

echo ""
echo "Scenario 7: 400 'does not exist in ACR' — targeted hint"
ERR_BODY='{"error":{"code":"VALIDATION_ERROR","message":"Image tag '"'"'sha-abc123'"'"' does not exist in ACR repository '"'"'test-app'"'"' on basepartnersense.azurecr.io. Ensure the image was pushed to ACR before deploying.","requestId":"req-1"}}'
start_mock 400 "$ERR_BODY"
run_deploy "$PORT" sha-abc123
stop_mock "$PORT"
assert_exit "exit 1" 1 "$DEPLOY_EXIT"
assert_file_contains "tag-not-found hint" "IMAGE TAG NOT FOUND IN THE REGISTRY" "$DEPLOY_OUT"
assert_file_contains "mentions the push step" "build/push step failed" "$DEPLOY_OUT"
assert_file_contains "deploy_success=false" "deploy_success=false" "$GH_OUT"
rm -f "$GH_OUT" "$DEPLOY_OUT"

# ──────────────────────────────────────────────────────────────────────
# SCENARIO 8: X-Pushed-Action on every request
#
# The platform counts a call without the header as an old release, and the
# old public repo can only be archived once nobody calls from it — so a curl
# that loses the header must fail CI. A mock records the header of every
# request (health probe + deploy); deploy.sh runs from this checkout
# (no SOURCE/VERSION → pushed-actions-internal@dev) and from a copy stamped
# like a published tree (→ pushed-cloud/pushed-actions@v9.9.9).
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Scenario 8: X-Pushed-Action header on every request"

HDR_LOG=$(mktemp)
H_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)")
python3 - "$H_PORT" "$HDR_LOG" >/dev/null 2>&1 <<'PYEOF' &
import http.server, json, sys
PORT, LOG = int(sys.argv[1]), sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def record(self):
        with open(LOG, 'a') as f:
            f.write(f"{self.command} {self.path.split('?')[0]} {self.headers.get('X-Pushed-Action', '<missing>')}\n")
    def reply(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self.record(); self.reply({'status': 'ok'})
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.record()
        self.reply({'data': {'success': True, 'namespace': 'ns', 'message': 'Deployed', 'gitCommitSha': 'deadbeef'}})
    def log_message(self, fmt, *args): pass
http.server.HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
PYEOF
MOCK_PID=$!
sleep 0.3

# run_stamped_deploy <deploy.sh path>
run_stamped_deploy() {
  local gh_out; gh_out=$(mktemp)
  env -i HOME="$HOME" PATH="$PATH" APP=test-app ENVIRONMENT=stage IMAGE_TAG=sha-abc123 \
    COMMIT_SHA=abc123 CONFIG_FILE=/nonexistent-config.yaml \
    API_URL="http://127.0.0.1:${H_PORT}" API_KEY=test-key GITHUB_OUTPUT="$gh_out" \
    ENABLE_HEALTH_PROBE=true USE_NOPROXY=false \
    bash "$1" >/dev/null 2>&1 || true
  rm -f "$gh_out"
}

# a) this checkout: no SOURCE / VERSION
: > "$HDR_LOG"
run_stamped_deploy "$DEPLOY_SH"
assert_file_contains "health probe stamped (internal)" "GET /health pushed-actions-internal@dev" "$HDR_LOG"
assert_file_contains "deploy call stamped (internal)" "POST /api/v1/deploy pushed-actions-internal@dev" "$HDR_LOG"

# b) a tree stamped like a published release
STAMPED=$(mktemp -d)
cp -R "$SCRIPT_DIR/../deploy" "$SCRIPT_DIR/../lib" "$STAMPED/"
printf 'v9.9.9\n' > "$STAMPED/VERSION"
printf 'pushed-cloud/pushed-actions\n' > "$STAMPED/SOURCE"
: > "$HDR_LOG"
run_stamped_deploy "$STAMPED/deploy/deploy.sh"
assert_file_contains "health probe stamped (published)" "GET /health pushed-cloud/pushed-actions@v9.9.9" "$HDR_LOG"
assert_file_contains "deploy call stamped (published)" "POST /api/v1/deploy pushed-cloud/pushed-actions@v9.9.9" "$HDR_LOG"
assert_not_contains "no request without the header" "<missing>" "$HDR_LOG"
rm -rf "$STAMPED"

stop_mock "$H_PORT"
rm -f "$HDR_LOG"

# c) static guard: every curl to the Base API in the shipped scripts sends the
#    header. A curl command is its line plus any backslash continuations.
if MISSING=$(python3 - "$SCRIPT_DIR/.." <<'PYEOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
bad = []
for f in sorted(root.glob('*/*.sh')):
    if f.name.startswith('test-'):
        continue
    lines = f.read_text().splitlines()
    i = 0
    while i < len(lines):
        if re.search(r'\bcurl\b', lines[i]) and not lines[i].lstrip().startswith('#'):
            start, cmd = i, lines[i]
            while cmd.rstrip().endswith('\\') and i + 1 < len(lines):
                i += 1
                cmd += '\n' + lines[i]
            if 'API_URL' in cmd and 'ACTION_ID_HEADER' not in cmd:
                bad.append(f"{f.relative_to(root)}:{start + 1}")
        i += 1
print(' '.join(bad))
sys.exit(1 if bad else 0)
PYEOF
); then
  pass "every Base API curl in the action scripts sends X-Pushed-Action"
else
  fail "Base API curl without X-Pushed-Action: $MISSING"
fi

# ──────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "────────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
