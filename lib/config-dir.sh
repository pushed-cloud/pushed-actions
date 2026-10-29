# shellcheck shell=bash
# Where an app's Pushed config lives: `.pushed/`, or the old name `.base/`.
#
# The directory was renamed with the platform (S9.2, PUSHED-111). Partner repos
# move at their own pace, so both names are read for now:
#
#   - an explicit action input (config_file, secrets_file, ...) always wins;
#   - otherwise the whole directory is chosen, never single files: `.pushed/` if
#     it exists, else `.base/` with a deprecation warning. If both exist,
#     `.pushed/` wins and `.base/` is ignored, with a warning naming every file
#     that exists only in `.base/`. Reading per file would let a half-renamed
#     repo take config.yaml from one place and redirects.yaml from the other
#     without anyone noticing.
#
# Guard: partner workflows usually check out only the config directory
# (`sparse-checkout: .base`). A partner who renames the directory but not that
# line, or the other way round, gets a working tree without the directory the
# commit has, and the action would deploy with no config at all, which is not
# neutral (absent autoscaling fields reset to defaults). So when `.pushed/` is
# not in the working tree, the checked-out commit is asked with
# `git ls-tree -d HEAD -- .pushed .base`; a config directory that is in the
# commit but not in the working tree fails the run with a message that says how
# to fix the checkout. Only directories count (`-d`, type tree): a file, symlink
# or submodule with that name is not config.
#
# The git calls are read-only and fenced in to the working directory itself:
# `GIT_CEILING_DIRECTORIES` stops discovery from walking up to a parent `.git`
# (on a shared self-hosted runner that may belong to someone else, and its
# config must never be loaded), and `-c safe.directory=<this directory>` trusts
# only this checkout, which container jobs often see as owned by another user.
# No `.git` in the working directory means no checkout to compare against, and
# the guard is skipped. Any git failure past that point is a loud warning,
# decided on exit codes, not on git's (localized) messages.
#
# Sourced by deploy.sh, pr.sh and sync-secrets.sh:
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/config-dir.sh"
#   config_file_default CONFIG_FILE config.yaml || exit 1

PUSHED_CONFIG_DIR=""

# Prints which of .pushed and .base are directories in the checked-out commit,
# one per line. Prints nothing when there is no checkout to ask.
_config_dirs_in_commit() {
  command -v git &> /dev/null || return 0
  [ -e .git ] || return 0
  local here out err
  here=$(pwd -P)
  err=$(mktemp)
  if out=$(LC_ALL=C GIT_CEILING_DIRECTORIES="$(dirname "$here")" \
      git -c safe.directory="$here" ls-tree -d HEAD -- .pushed .base 2>"$err"); then
    rm -f "$err"
    awk -F'\t' '{ split($1, m, " "); if (m[2] == "tree") print $2 }' <<< "$out"
    return 0
  fi
  echo "::warning title=Config checkout not verified::Could not ask git which config directories this commit has, so a .pushed/ or .base/ left out of the checkout cannot be detected. git said: $(tr '\n' ' ' < "$err")" >&2
  rm -f "$err"
  return 0
}

# _not_checked_out DIR: the boxed error for a config directory left out of the checkout.
_not_checked_out() {
  local dir="$1" fix
  if [ "$dir" = .pushed ]; then
    fix="sparse-checkout: .pushed"
  else
    fix="sparse-checkout: .base   (or rename .base/ to .pushed/ and use .pushed)"
  fi
  echo ""
  echo "╔══════════════════════════════════════════════════════"
  echo "║ ❌ ${dir}/ IS NOT CHECKED OUT"
  echo "╠══════════════════════════════════════════════════════"
  echo "║"
  echo "║ This commit has a ${dir}/ directory, but it is not in"
  echo "║ the working tree, so the action cannot read your config."
  echo "║ The usual cause is a sparse-checkout that lists the other"
  echo "║ directory name. In the actions/checkout step, write:"
  echo "║"
  echo "║   - uses: actions/checkout@v4"
  echo "║     with:"
  echo "║       ${fix}"
  echo "║"
  echo "║ or remove sparse-checkout to check out the whole repo."
  echo "║"
  echo "║ Stopped instead of running without config: missing"
  echo "║ settings are not neutral (autoscaling falls back to"
  echo "║ defaults, env vars are dropped)."
  echo "╚══════════════════════════════════════════════════════"
  echo "::error title=${dir}/ not checked out::This commit has a ${dir}/ directory, but the workflow did not check it out. Add ${dir} to the sparse-checkout of the actions/checkout step (or remove sparse-checkout)."
}

# Sets PUSHED_CONFIG_DIR once and prints the warnings. Returns 1 (after an
# error annotation) when a config directory is in the commit but not checked out.
resolve_config_dir() {
  if [ -d .pushed ]; then
    PUSHED_CONFIG_DIR=.pushed
    if [ -d .base ]; then
      local only_base=() f
      while IFS= read -r f; do
        [ -e ".pushed/${f#.base/}" ] || only_base+=("$f")
      done < <(find .base -type f | LC_ALL=C sort)
      if [ "${#only_base[@]}" -gt 0 ]; then
        echo "::warning title=.base/ ignored::Both .pushed/ and .base/ exist. Config is read from .pushed/ only, so these files in .base/ are ignored: ${only_base[*]}. Move them to .pushed/ and delete .base/."
      else
        echo "::warning title=.base/ ignored::Both .pushed/ and .base/ exist. Config is read from .pushed/ only. Delete .base/."
      fi
    fi
    return 0
  fi

  local in_commit
  in_commit=$(_config_dirs_in_commit)
  if grep -qFx .pushed <<< "$in_commit"; then
    _not_checked_out .pushed
    return 1
  fi

  if [ -d .base ]; then
    PUSHED_CONFIG_DIR=.base
    echo "::warning title=Rename .base/ to .pushed/::Config is read from .base/, the old directory name, which is deprecated. Rename the directory to .pushed/ and, if the workflow uses sparse-checkout, change .base to .pushed there in the same commit."
    return 0
  fi

  if grep -qFx .base <<< "$in_commit"; then
    _not_checked_out .base
    return 1
  fi

  # Neither directory in the commit: the files below do not exist, same as an
  # app without config.
  PUSHED_CONFIG_DIR=.pushed
  return 0
}

# config_file_default VAR NAME: when VAR (an action input) is empty, set and
# export it to <config dir>/NAME. The directory is resolved on first use only.
config_file_default() {
  local var="$1" name="$2"
  if [ -n "${!var:-}" ]; then
    return 0
  fi
  if [ -z "$PUSHED_CONFIG_DIR" ]; then
    resolve_config_dir || return 1
  fi
  printf -v "$var" '%s/%s' "$PUSHED_CONFIG_DIR" "$name"
  export "${var?}"
}
