#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Tests for aicr-resolve.sh against deploy/aicr and the release in
# aicr-resolve/. Needs jq and yq (mikefarah v4). With AICR set to an aicr
# binary, the resolved catalog is also rendered with aicr recipe.
#
# Usage: ./test_aicr_resolve.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${HERE}/.." && pwd)"
RESOLVE="${DEPLOY_DIR}/aicr-resolve.sh"
CATALOG="${DEPLOY_DIR}/aicr"
RELEASE="${HERE}/aicr-resolve/release.json"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aicr-resolve-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*"
  failures=$((failures + 1))
}
equal() {
  local what="$1" want="$2" got="$3"
  if [[ "${got}" == "${want}" ]]; then pass "${what}"; else fail "${what}: want ${want}, got ${got}"; fi
}
expect() {
  local what="$1" pattern="$2" text="$3"
  if grep -qE -- "${pattern}" <<<"${text}"; then pass "${what}"; else fail "${what}: no line matches ${pattern}"; fi
}

# resolve runs the script into a fresh OUT and keeps its stderr in LOG.
n=0
resolve() {
  n=$((n + 1))
  OUT="${WORK}/out-${n}"
  LOG="${WORK}/log-${n}"
  bash "${RESOLVE}" --catalog "${1:-${CATALOG}}" --release "${2:-${RELEASE}}" --out "${OUT}" >"${LOG}" 2>&1
}
# variant writes the release with a jq filter applied and prints its path.
variant() {
  local file
  file="$(mktemp "${WORK}/release.XXXXXX")"
  jq "$1" "${RELEASE}" >"${file}"
  printf '%s\n' "${file}"
}
registry() { COMPONENT="$1" yq ".components[] | select(.name == strenv(COMPONENT)) | .helm.$2" "${OUT}/registry.yaml"; }
values() { yq "$1" "${OUT}/components/nvke-controller/values.yaml"; }

before="$(cd "${CATALOG}" && find . -type f -exec shasum -a 256 {} + | sort)"

# A full release binds every chart and both images.
if resolve; then pass "a full release resolves"; else fail "a full release resolves: $(cat "${LOG}")"; fi
equal "the controller chart repository" "oci://registry.example.com/nvke/charts" "$(registry nvke-controller defaultRepository)"
equal "the controller chart name" "nvke-controller" "$(registry nvke-controller defaultChart)"
equal "the controller chart version" "0.4.0" "$(registry nvke-controller defaultVersion)"
equal "the controller chart archive digest" "sha256:$(printf 'f%.0s' {1..64})" "$(registry nvke-controller defaultDigest)"
equal "a third-party chart moves to the release" "oci://registry.example.com/nvke/charts" "$(registry temporal defaultRepository)"
equal "the controller image repository" "registry.example.com/nvke/nvke-controller" "$(values .image.repository)"
equal "the controller image digest" "sha256:$(printf '%064d' 2)" "$(values .image.digest)"
equal "the profiles image digest" "sha256:$(printf '%064d' 3)" "$(values .profiles.image.digest)"
equal "the rest of the values file stays" "nvke-database" "$(values .secrets.dbSecretName)"
expect "release.txt records the root digest" "^rootDigest	sha256:0{63}1$" "$(cat "${OUT}/release.txt")"
expect "release.txt records the controller image" "^image	cwe	" "$(cat "${OUT}/release.txt")"
equal "the template is unchanged" "${before}" "$(cd "${CATALOG}" && find . -type f -exec shasum -a 256 {} + | sort)"

if [[ -n "${AICR:-}" ]]; then
  if render="$("${AICR}" recipe --service nvke-management --data "${OUT}" -o "${WORK}/recipe.yaml" 2>&1)"; then
    pass "aicr renders the resolved catalog"
    equal "the recipe pins the controller chart" "oci://registry.example.com/nvke/charts" \
      "$(yq '.componentRefs[] | select(.name == "nvke-controller") | .source' "${WORK}/recipe.yaml")"
  else
    fail "aicr renders the resolved catalog: ${render}"
  fi
fi

# A hand-written file with only outputs, and only the required ones.
release="$(variant '{outputs: [.outputs[] | select(.name == "cwe" or .name == "controller-chart")]}')"
if resolve "" "${release}"; then pass "a hand-written release resolves"; else fail "a hand-written release resolves: $(cat "${LOG}")"; fi
expect "a missing optional output is named" "no temporal output; the template value stays" "$(cat "${LOG}")"
equal "a missing optional output keeps the template" "https://go.temporal.io/helm-charts" "$(registry temporal defaultRepository)"
expect "release.txt says there is no root digest" "^rootDigest	none$" "$(cat "${OUT}/release.txt")"

# No archive digest: the chart binds, the digest is dropped, and it says so.
release="$(variant '(.outputs[] | select(.name == "controller-chart")) |= del(.helm)')"
if resolve "" "${release}"; then pass "a chart without an archive digest resolves"; else fail "a chart without an archive digest resolves: $(cat "${LOG}")"; fi
expect "a missing archive digest is named" "controller-chart has no helm.defaultDigest" "$(cat "${LOG}")"
equal "no archive digest is written" "null" "$(registry nvke-controller defaultDigest)"

# Refusals.
refuse() {
  local what="$1" pattern="$2"
  shift 2
  if "$@"; then fail "${what}: resolved"; else expect "${what}" "${pattern}" "$(cat "${LOG}")"; fi
}
refuse "a release without the controller image" "no cwe output, which is required" \
  resolve "" "$(variant 'del(.outputs[] | select(.name == "cwe"))')"
refuse "a tag reference" "not digest-pinned" \
  resolve "" "$(variant '(.outputs[] | select(.name == "cwe") | .reference) = "registry.example.com/nvke/nvke-controller:v1"')"
refuse "a chart output of the wrong kind" "controller-chart is not of kind helm-oci" \
  resolve "" "$(variant '(.outputs[] | select(.name == "controller-chart") | .kind) = "oci"')"
refuse "a chart without a version" "controller-chart has no chartVersion" \
  resolve "" "$(variant '(.outputs[] | select(.name == "controller-chart")) |= del(.chartVersion)')"
refuse "a file without outputs" "has no outputs array" resolve "" "$(variant 'del(.outputs)')"
mkdir -p "${WORK}/full"
touch "${WORK}/full/x"
resolve_into() {
  LOG="${WORK}/log-into"
  bash "${RESOLVE}" --release "${RELEASE}" --out "$1" >"${LOG}" 2>&1
}
refuse "a non-empty output directory" "is not empty" resolve_into "${WORK}/full"
cp -R "${CATALOG}" "${WORK}/sourced"
yq -i '(.spec.componentRefs[] | select(.name == "temporal") | .source) = "https://go.temporal.io/helm-charts"' "${WORK}/sourced/overlays/nvke-management.yaml"
refuse "an overlay that names a source for a bound chart" "sets a source for temporal" resolve "${WORK}/sourced"

if [[ "${failures}" -eq 0 ]]; then
  echo "all aicr-resolve tests passed"
else
  echo "${failures} aicr-resolve test(s) failed"
  exit 1
fi
