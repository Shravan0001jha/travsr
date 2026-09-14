#!/usr/bin/env bash
#
# Tests for .github/scripts/vscode-version-gate.sh.
#
# The gate decides whether a release can be cut and whether a pull request goes
# red, and every one of its interesting cases involves a state that is awkward
# to reach on purpose: a gallery outage, a WAF challenge page, a backported
# patch release, a release PR mid-flight. PR #888 shipped this logic inline in
# YAML and both defects found in review (a release-PR deadlock, and `set -e`
# killing the run before the authored error could print) were only findable by
# extracting the step out of the workflow by hand and running it. So the logic
# lives in a script and the states are simulated here.
#
# `gh` and `curl` are stubbed on PATH rather than behind a flag in the gate:
# the code under test is the same code that runs in CI, with no test-only
# branch in it. The repository is a real throwaway git repo with real tags,
# because the drift check reads a shipped pin with `git show <tag>:...`.
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vscode-version-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# --- stubs -----------------------------------------------------------------

mkdir -p "$WORK/bin"

cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ -n "${FAKE_GH_FAIL:-}" ]; then
  echo "gh: HTTP 403: API rate limit exceeded" >&2
  exit 1
fi
cat "$FAKE_RELEASES"
STUB

# Mimics curl's contract as the gate relies on it: --fail means an HTTP error
# is a non-zero exit with no body, and a transport failure is a non-zero exit
# too. 22 = HTTP >= 400, 28 = timeout, 6 = DNS failure.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
rc="${FAKE_CURL_RC:-0}"
if [ "$rc" -ne 0 ]; then exit "$rc"; fi
cat "$FAKE_BODY"
STUB

chmod +x "$WORK/bin/gh" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

# --- fixtures --------------------------------------------------------------

RELEASES="$WORK/releases.json"
BODY="$WORK/body.json"
export FAKE_RELEASES="$RELEASES"
export FAKE_BODY="$BODY"
export GITHUB_REPOSITORY="Travsr-com/travsr"

# Ordered newest-created first, the way `gh release list` returns it. v0.11.1
# is a patch backported onto the 0.11 line AFTER v1.0.0 shipped, so it sits at
# index 0 while v1.0.0 is the highest version. Taking [0] here is the bug the
# reviewer flagged; every expectation below assumes v1.0.0 wins.
cat > "$RELEASES" <<'JSON'
[
  {"tagName":"vscode-v0.11.0","isPrerelease":false,"isDraft":false},
  {"tagName":"v0.11.1","isPrerelease":false,"isDraft":false},
  {"tagName":"v1.1.0","isPrerelease":true,"isDraft":false},
  {"tagName":"v1.0.1","isPrerelease":false,"isDraft":true},
  {"tagName":"v1.0.0","isPrerelease":false,"isDraft":false},
  {"tagName":"v0.9.0","isPrerelease":false,"isDraft":false}
]
JSON

marketplace_body() {  # $1 = published version
  cat > "$BODY" <<JSON
{"results":[{"extensions":[{"versions":[{"version":"$1"}]}]}]}
JSON
}

REPO="$WORK/repo"
mkdir -p "$REPO/packages/travsr-vscode/src"
git init -q "$REPO"
git -C "$REPO" config user.email ci@example.invalid
git -C "$REPO" config user.name CI

set_pin() {  # $1 = DOWNLOAD_VERSION literal to write into the working tree
  printf 'export const DOWNLOAD_VERSION = "%s";\n' "$1" \
    > "$REPO/packages/travsr-vscode/src/installer.ts"
}

# Two historical extension tags: 0.11.0 shipped a pin at 0.11.0 (the #882
# build), 0.12.0 shipped a pin at 1.0.0 (the republish that fixes it).
set_pin 0.11.0
git -C "$REPO" add -A && git -C "$REPO" commit -qm "vscode 0.11.0"
git -C "$REPO" tag vscode-v0.11.0
set_pin 1.0.0
git -C "$REPO" add -A && git -C "$REPO" commit -qm "vscode 0.12.0"
git -C "$REPO" tag vscode-v0.12.0

# --- harness ---------------------------------------------------------------

# run <event> <command>; leaves RC and OUT set.
run() {
  local event="$1" cmd="$2"
  OUT="$(cd "$REPO" && GITHUB_EVENT_NAME="$event" bash "$GATE" "$cmd" 2>&1)"
  RC=$?
}

expect() {  # <name> <want_rc> <want_substring>
  local name="$1" want_rc="$2" want="$3"
  if [ "$RC" != "$want_rc" ]; then
    printf 'FAIL %s\n     want exit %s, got %s\n%s\n' "$name" "$want_rc" "$RC" "$OUT" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  case "$OUT" in
    *"$want"*) ;;
    *)
      printf 'FAIL %s\n     want output containing: %s\n%s\n' "$name" "$want" "$OUT" >&2
      FAIL=$((FAIL + 1))
      return
      ;;
  esac
  PASS=$((PASS + 1))
  printf 'ok   %s\n' "$name"
}

refute() {  # <name> <unwanted_substring>: guards against a raw tool error
  local name="$1" unwanted="$2"
  case "$OUT" in
    *"$unwanted"*)
      printf 'FAIL %s\n     output must not contain: %s\n%s\n' "$name" "$unwanted" "$OUT" >&2
      FAIL=$((FAIL + 1))
      ;;
    *) PASS=$((PASS + 1)); printf 'ok   %s\n' "$name" ;;
  esac
}

# --- latest-stable ---------------------------------------------------------

unset FAKE_GH_FAIL FAKE_CURL_RC 2>/dev/null || true

run schedule latest-stable
expect "latest-stable takes the semver maximum, not the newest created" 0 "v1.0.0"
refute "latest-stable ignores the newer backport v0.11.1" "v0.11.1"

run schedule latest-stable
refute "latest-stable ignores the vscode-v* tag family" "vscode-"

FAKE_GH_FAIL=1 run schedule latest-stable
expect "a gh failure is reported, never treated as no releases" 1 "could not list releases"
unset FAKE_GH_FAIL

# --- tree-pin --------------------------------------------------------------

set_pin 1.0.0
run pull_request tree-pin
expect "tree pin equal to the latest release passes" 0 "OK: DOWNLOAD_VERSION 1.0.0"

set_pin 0.11.0
run pull_request tree-pin
expect "tree pin behind the latest release fails the PR (#882)" 1 "::error::DOWNLOAD_VERSION 0.11.0 is behind"

set_pin 0.11.0
run schedule tree-pin
expect "tree pin behind the latest release fails on schedule too" 1 "is behind the latest stable release"

# The blocker from review: a release PR for v1.1.0 bumps the pin ahead of the
# published latest while release.yml is about to require exactly that value at
# tag time. Requiring equality here made the two constraints unsatisfiable.
set_pin 1.1.0
run pull_request tree-pin
expect "tree pin ahead does not deadlock a release PR" 0 "::notice::DOWNLOAD_VERSION 1.1.0 is ahead"

set_pin 1.1.0
run release tree-pin
expect "tree pin ahead does not fail a release run either" 0 "is ahead of the latest stable release"

set_pin "1.0"
run pull_request tree-pin
expect "a malformed pin fails on every trigger" 1 "is not a release version"

set_pin 1.0.0
printf 'const nothing = 1;\n' > "$REPO/packages/travsr-vscode/src/installer.ts"
run pull_request tree-pin
expect "an unreadable pin fails rather than passing empty" 1 "could not read DOWNLOAD_VERSION"

set_pin 1.0.0
FAKE_GH_FAIL=1 run pull_request tree-pin
expect "tree-pin says so when the release list cannot be read" 1 "could not resolve the latest stable release"
unset FAKE_GH_FAIL

# --- publish-pin -----------------------------------------------------------

set_pin 1.0.0
run push publish-pin
expect "publish pin equal to the latest release publishes" 0 "OK: DOWNLOAD_VERSION 1.0.0"

set_pin 0.11.0
run push publish-pin
expect "publish pin behind the latest release blocks the publish" 1 "!= latest stable release v1.0.0"

# Equality at publish time is what stops a pin naming a release that does not
# exist from reaching the Marketplace, which is why tree-pin can allow ahead.
set_pin 1.1.0
run push publish-pin
expect "publish pin ahead of any real release blocks the publish" 1 "!= latest stable release v1.0.0"

# --- marketplace-drift -----------------------------------------------------

set_pin 1.0.0

marketplace_body 0.12.0
run schedule marketplace-drift
expect "a published extension installing the current release is clean" 0 "OK: the published extension installs v1.0.0"

marketplace_body 0.11.0
run schedule marketplace-drift
expect "a stale published extension is drift on a scheduled run" 1 "::error::the published extension installs v0.11.0"

marketplace_body 0.11.0
run release marketplace-drift
expect "a stale published extension is drift on a post-release run" 1 "::error::the published extension installs v0.11.0"

marketplace_body 0.11.0
run workflow_dispatch marketplace-drift
expect "a stale published extension is drift on a manual run" 1 "::error::the published extension installs v0.11.0"

marketplace_body 0.11.0
run pull_request marketplace-drift
expect "drift is informational on a pull request, which cannot republish" 0 "::warning::the published extension installs v0.11.0"

marketplace_body 0.9.9
run pull_request marketplace-drift
expect "a published version with no tag here cannot be ruled clean" 0 "no vscode-v0.9.9 tag exists"

# The gallery failure modes. Each must reach the authored message and the
# event-aware routing, not die at a jq parse error under set -e.
FAKE_CURL_RC=22 run schedule marketplace-drift
expect "an HTTP error fails a scheduled run" 1 "could not determine the published extension version"
FAKE_CURL_RC=22 run schedule marketplace-drift
refute "an HTTP error does not surface as a raw jq error" "parse error"

FAKE_CURL_RC=28 run schedule marketplace-drift
expect "a timeout fails a scheduled run" 1 "marketplace request failed (curl exit 28)"

FAKE_CURL_RC=22 run pull_request marketplace-drift
expect "an unreachable gallery does not fail a pull request" 0 "::warning::could not determine the published extension version"
unset FAKE_CURL_RC

printf '<html><body>403 Forbidden</body></html>\n' > "$BODY"
run schedule marketplace-drift
expect "an HTML error page served with 200 is a failure, not no drift" 1 "could not determine the published extension version"
run schedule marketplace-drift
refute "an HTML error page does not surface as a raw jq error" "parse error"
run pull_request marketplace-drift
expect "an HTML error page only warns on a pull request" 0 "::warning::could not determine"

printf '{"results":[{"extensions":[]}]}\n' > "$BODY"
run schedule marketplace-drift
expect "valid JSON naming no extension is not read as no drift" 1 "could not determine the published extension version"

printf '{"results":[{"extensions":[{"versions":[{"version":"not-a-version"}]}]}]}\n' > "$BODY"
run schedule marketplace-drift
expect "an unusable version string is a failure" 1 "could not determine the published extension version"

marketplace_body 0.12.0
FAKE_GH_FAIL=1 run pull_request marketplace-drift
expect "drift cannot be judged without the release list, on any trigger" 1 "could not resolve the latest stable release"
unset FAKE_GH_FAIL

# --- result ----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
