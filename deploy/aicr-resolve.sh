#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Resolve the AICR catalog template against an NVKR release description.
#
#   deploy/aicr-resolve.sh --release release.json [--catalog deploy/aicr] --out DIR
#
# Copies the template to DIR and applies nvkr-bindings.yaml. Chart outputs
# set the registry entry's repository, chart, version and archive digest.
# Image outputs set a repository and a digest in a values file. DIR gets a
# release.txt that records what was bound.
#
# The release is nvkr.dev/release-description/v1 or a hand-written file with
# only outputs. Needs jq and yq (mikefarah, v4).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="${REPO}/deploy/aicr"
RELEASE=""
OUT=""

die() { printf 'aicr-resolve: %s\n' "$*" >&2; exit 1; }
warn() { printf 'aicr-resolve: warning: %s\n' "$*" >&2; }
usage() { sed -n '5,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="${2:?--release needs a file}"; shift 2 ;;
    --catalog) CATALOG="${2:?--catalog needs a directory}"; shift 2 ;;
    --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'aicr-resolve: unknown argument %s\n' "$1" >&2; usage 1 ;;
  esac
done
[[ -n "${RELEASE}" && -n "${OUT}" ]] || usage 1
for tool in jq yq; do
  command -v "${tool}" >/dev/null || die "${tool} is not on PATH"
done
yq --version 2>&1 | grep -q 'mikefarah' || die "yq must be mikefarah yq v4"
[[ -f "${RELEASE}" ]] || die "no release file at ${RELEASE}"
[[ -f "${CATALOG}/registry.yaml" ]] || die "${CATALOG} has no registry.yaml"
[[ -f "${CATALOG}/nvkr-bindings.yaml" ]] || die "${CATALOG} has no nvkr-bindings.yaml"
jq -e '.outputs | type == "array"' "${RELEASE}" >/dev/null || die "${RELEASE} has no outputs array"
if [[ -e "${OUT}" && -n "$(ls -A "${OUT}")" ]]; then
  die "${OUT} is not empty"
fi

mkdir -p "${OUT}"
cp -R "${CATALOG}/." "${OUT}/"
BINDINGS="${OUT}/nvkr-bindings.yaml"
REGISTRY="${OUT}/registry.yaml"
RECORD=""

DIGEST_REF='^[^@[:space:]]+@sha256:[0-9a-f]{64}$'
VALUES_PATH='^(\.[A-Za-z0-9_-]+)+$'

# output prints the named output as JSON, or nothing.
output() { jq -c --arg n "$1" '[.outputs[] | select(.name == $n)] | first // empty' "${RELEASE}"; }

# missing handles an output the release does not carry.
missing() {
  local name="$1" required="$2"
  [[ "${required}" != true ]] || die "the release has no ${name} output, which is required"
  warn "the release has no ${name} output; the template value stays"
}

# checked_output prints the output after checking its kind and reference.
checked_output() {
  local name="$1" kind="$2" out ref
  out="$(output "${name}")"
  [[ -n "${out}" ]] || return 0
  [[ "$(jq -r '.kind' <<<"${out}")" == "${kind}" ]] || die "output ${name} is not of kind ${kind}"
  ref="$(jq -r '.reference // ""' <<<"${out}")"
  [[ "${ref}" =~ ${DIGEST_REF} ]] || die "output ${name} reference is not digest-pinned: ${ref}"
  printf '%s\n' "${out}"
}

while IFS=$'\t' read -r name component required; do
  out="$(checked_output "${name}" helm-oci)"
  if [[ -z "${out}" ]]; then
    missing "${name}" "${required}"
    continue
  fi
  COMPONENT="${component}" yq -e '.components[] | select(.name == strenv(COMPONENT))' "${REGISTRY}" >/dev/null 2>&1 ||
    die "binding ${name}: registry.yaml has no component ${component}"
  # A componentRef source overrides the registry, and AICR then skips the
  # archive digest. The registry must be the only place a chart lives.
  for overlay in "${OUT}"/overlays/*.yaml; do
    if COMPONENT="${component}" yq -e '.spec.componentRefs[] | select(.name == strenv(COMPONENT)) | has("source")' "${overlay}" 2>/dev/null | grep -qx true; then
      die "$(basename "${overlay}") sets a source for ${component}; remove it so the registry entry applies"
    fi
  done
  ref="$(jq -r '.reference' <<<"${out}")"
  path="${ref%@*}"
  version="$(jq -r '.chartVersion // ""' <<<"${out}")"
  [[ -n "${version}" ]] || die "output ${name} has no chartVersion"
  digest="$(jq -r '.helm.defaultDigest // ""' <<<"${out}")"
  export COMPONENT="${component}" HELM_REPO="oci://${path%/*}" HELM_CHART="${path##*/}" HELM_VERSION="${version}" HELM_DIGEST="${digest}"
  yq -i '(.components[] | select(.name == strenv(COMPONENT)) | .helm) |=
    (.defaultRepository = strenv(HELM_REPO) | .defaultChart = strenv(HELM_CHART) | .defaultVersion = strenv(HELM_VERSION))' "${REGISTRY}"
  if [[ -n "${digest}" ]]; then
    [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "output ${name} helm.defaultDigest is malformed: ${digest}"
    yq -i '(.components[] | select(.name == strenv(COMPONENT)) | .helm.defaultDigest) = strenv(HELM_DIGEST)' "${REGISTRY}"
  else
    yq -i 'del(.components[] | select(.name == strenv(COMPONENT)) | .helm.defaultDigest)' "${REGISTRY}"
    warn "output ${name} has no helm.defaultDigest; aicr bundle --vendor-charts cannot check ${component}"
  fi
  RECORD+="$(printf 'chart\t%s\t%s\t%s:%s\t%s' "${name}" "${component}" "${HELM_REPO}/${HELM_CHART}" "${version}" "${digest:-unchecked}")"$'\n'
done < <(yq -o=json '.charts // []' "${BINDINGS}" | jq -r '.[] | [.output, .component, (.required // false)] | @tsv')

while IFS=$'\t' read -r name values repo_key digest_key required; do
  [[ "${repo_key}" =~ ${VALUES_PATH} && "${digest_key}" =~ ${VALUES_PATH} ]] || die "binding ${name}: bad values path"
  [[ -f "${OUT}/${values}" ]] || die "binding ${name}: no values file ${values}"
  out="$(checked_output "${name}" oci)"
  if [[ -z "${out}" ]]; then
    missing "${name}" "${required}"
    continue
  fi
  ref="$(jq -r '.reference' <<<"${out}")"
  export IMAGE_REPO="${ref%@*}" IMAGE_DIGEST="${ref##*@}"
  yq -i "${repo_key} = strenv(IMAGE_REPO) | ${digest_key} = strenv(IMAGE_DIGEST)" "${OUT}/${values}"
  RECORD+="$(printf 'image\t%s\t%s\t%s' "${name}" "${values}" "${ref}")"$'\n'
done < <(yq -o=json '.images // []' "${BINDINGS}" | jq -r '.[] | [.output, .valuesFile, .repository, .digest, (.required // false)] | @tsv')

{
  printf 'reference\t%s\n' "$(jq -r '.reference // "none"' "${RELEASE}")"
  printf 'rootDigest\t%s\n' "$(jq -r '.rootDigest // "none"' "${RELEASE}")"
  printf '%s' "${RECORD}"
} >"${OUT}/release.txt"
printf 'aicr-resolve: wrote %s\n' "${OUT}" >&2
