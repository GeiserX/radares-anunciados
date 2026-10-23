#!/usr/bin/env bash
# Fail if a tracked file in this repository states a credential literally.
#
# Ported from CashPilot-android, where a release keystore password sat in a tracked doc of a public repo for months
# while an entropy-based secret scanner reported green: a short memorable phrase after "password:" does not look
# like a token. This check looks for the shape a person writes when documenting a credential, whatever the value
# looks like. It reads tracked files only and runs from anywhere in the repo.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# "password: value" where value is a literal, not a variable: quoted or backticked, or containing a character an
# identifier cannot (a hyphen, an @, a dot), which is what most real passwords look like.
PATTERN_QUOTED='(password|passwd|passphrase|secret|api[_-]?key|auth[_-]?token)[[:space:]]*(is|:|=)[[:space:]]*[`"'"'"'][A-Za-z0-9_@.+-]{8,}[`"'"'"']'
PATTERN_BARE='(password|passwd|passphrase|secret|api[_-]?key|auth[_-]?token)[[:space:]]*(is|:|=)[[:space:]]*[A-Za-z0-9_]*[-@.][A-Za-z0-9_@.+-]{6,}'

# Generous on purpose: a false positive costs one allowlist term, a false negative a public credential.
# `fingerprint|SHA-256|SHA256`: the public signing-certificate fingerprint in docs/ANDROID.md is meant to be public.
# `secrets\.`: GitHub Actions expressions such as ${{ secrets.ANDROID_KEY_PASSWORD }}.
# No `_KEY`-style terms: the match is case-insensitive, so they would also allow `api_key = "..."`.
ALLOW='example|placeholder|your-|<[a-z]|\$\{|\$\(|env|environment|variable|getenv|System\.|findProperty|BuildConfig|NOT recorded|storePassword|keyPassword|keystorePass|keyPass|secret: (true|false)|the (password|secret|token|key)|a (password|secret|token|key)|app signing key|upload key|Play App Signing|fingerprint|SHA-256|SHA256|secrets\.'

# Test sources and the Swift test fixtures are excluded: fixtures are meant to hold credential-shaped strings, and
# scanning them gives permanent noise. A real secret pasted into a test file is the gap this leaves.
hits=$(git ls-files -z \
  | grep -zvE '(^|/)src/(test|androidTest)/|^Tests/' \
  | xargs -0 grep -nEiI -e "$PATTERN_QUOTED" -e "$PATTERN_BARE" 2>/dev/null \
  | grep -viE "$ALLOW" || true)

if [ -n "$hits" ]; then
  echo "A tracked file appears to state a credential literally:" >&2
  echo "$hits" >&2
  echo >&2
  echo "This repository is PUBLIC. If it is a real credential: remove it, rotate it," >&2
  echo "and remember that redacting HEAD does not clear the history." >&2
  echo "If it is a false positive, add a term to ALLOW in $0." >&2
  exit 1
fi
echo "no literal credentials in tracked files"
