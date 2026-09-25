# shellcheck shell=bash
# Which release of these actions is executing, and from which repo.
#
# Partners pin the moving `v1` tag — that is deliberate, we cannot ask them to bump a
# pin on every minor. The cost is that a runner which caches
# `_work/_actions/<owner>/<repo>/v1` can keep serving an old release long after `v1`
# has moved. On 2026-08-21 a partner ran v1.0.x code while `v1` had pointed at v1.1.1
# for 16 days, and it took timing forensics against a mock API to establish that.
# Printing the version makes that a one-line read in the job log instead.
#
# The same release is published to more than one public repo, and partners call it
# from private repos we cannot search. Every API call therefore carries
# `X-Pushed-Action: <source>@<version>`, so the platform can tell which repo is still
# in use before an old one is archived. It is statistics only, never authorization.
#
# VERSION and SOURCE are written into each published tree by the release workflow,
# so an unreleased/internal checkout reports `pushed-actions-internal@dev`.
#
# Sourced by every action script: `. "$(dirname "${BASH_SOURCE[0]}")/../lib/action-id.sh"`.

_ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

action_version() {
  local vf="${_ACTION_ROOT}/VERSION"
  if [ -f "$vf" ]; then
    tr -d '[:space:]' < "$vf"
  else
    echo "dev"
  fi
}

action_source() {
  local sf="${_ACTION_ROOT}/SOURCE"
  if [ -f "$sf" ]; then
    tr -d '[:space:]' < "$sf"
  else
    echo "pushed-actions-internal"
  fi
}

# `<source>@<version>`, the value of the X-Pushed-Action header.
action_id() {
  echo "$(action_source)@$(action_version)"
}

# shellcheck disable=SC2034  # used by the scripts that source this file
ACTION_ID_HEADER="X-Pushed-Action: $(action_id)"
