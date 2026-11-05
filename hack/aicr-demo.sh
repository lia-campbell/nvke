#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Install the NVKE controller stack on kind with NVKR inputs and AICR.
# deploy/aicr-demo.md describes the same steps.
#
#   hack/aicr-demo.sh up        a local OCI registry and a kind cluster
#   hack/aicr-demo.sh publish   build and push the images and charts, write release.json
#   hack/aicr-demo.sh resolve   deploy/aicr + release.json -> catalog/
#   hack/aicr-demo.sh bundle    aicr recipe and aicr bundle --vendor-charts
#   hack/aicr-demo.sh apply     the Secrets, then the bundle's deploy.sh
#   hack/aicr-demo.sh verify    pods Ready, controller digest matches the release
#   hack/aicr-demo.sh all       every step above, in order
#   hack/aicr-demo.sh down      delete the cluster and the registry
#
# release.json stands in for an NVKR release description. It names the
# images and charts this script pushed, by digest.
#
# Needs docker, kind, kubectl, helm, clusterctl, jq, yq (mikefarah v4),
# openssl and aicr.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${NVKE_AICR_DEMO_DIR:-${TMPDIR:-/tmp}/nvke-aicr-demo}"
CLUSTER="${KIND_CLUSTER_NAME:-nvke-aicr-demo}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"
REGISTRY_NAME="${REGISTRY_NAME:-nvke-aicr-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY="localhost:${REGISTRY_PORT}"
VERSION="${NVKE_DEMO_VERSION:-0.0.0-aicr.1}"
TRUST_DOMAIN="${NVKE_TRUST_DOMAIN:-nvke.local}"
AICR="${AICR:-aicr}"
NKTP_SITE_VALUES="${NKTP_SITE_VALUES:-${REPO}/nktp/hack/e2e-values.yaml}"
CAPI_VERSION="${CAPI_VERSION:-$(awk '$1 == "CAPI_VERSION" { print $3 }' "${REPO}/make/tool-versions.mk")}"
export KUBECONFIG="${WORK}/kubeconfig"

log() { printf '\n=== %s\n' "$*" >&2; }
die() { printf 'aicr-demo: %s\n' "$*" >&2; exit 1; }

need() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null || die "${tool} is not on PATH"
  done
}

node_arch() { docker info --format '{{.Architecture}}' | sed 's/x86_64/amd64/; s/aarch64/arm64/'; }

up() {
  need docker kind kubectl
  mkdir -p "${WORK}"
  if [[ -z "$(docker ps -aq --filter "name=^${REGISTRY_NAME}$")" ]]; then
    log "starting registry ${REGISTRY_NAME} on ${REGISTRY}"
    docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" --name "${REGISTRY_NAME}" registry:2 >/dev/null
  fi
  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
    log "creating kind cluster ${CLUSTER}"
    kind create cluster --name "${CLUSTER}" --kubeconfig "${KUBECONFIG}" --wait 5m ${KIND_NODE_IMAGE:+--image "${KIND_NODE_IMAGE}"}
  fi
  kind get kubeconfig --name "${CLUSTER}" >"${KUBECONFIG}"
  docker network connect kind "${REGISTRY_NAME}" 2>/dev/null || true
  # The node pulls localhost:<port> from the registry container over the kind network.
  local node
  for node in $(kind get nodes --name "${CLUSTER}"); do
    docker exec -i "${node}" sh -c "mkdir -p /etc/containerd/certs.d/${REGISTRY} && cat >/etc/containerd/certs.d/${REGISTRY}/hosts.toml" <<HOSTS
[host."http://${REGISTRY_NAME}:5000"]
  capabilities = ["pull", "resolve"]
HOSTS
  done
}

# push_image builds an image and prints its digest-pinned reference.
push_image() {
  local name="$1" file="$2" context="$3" ref="${REGISTRY}/nvke/$1:${VERSION}"
  log "building ${name}"
  docker build --platform "linux/$(node_arch)" -f "${file}" --build-arg "BUILD_VERSION=v${VERSION}" -t "${ref}" "${context}" >&2
  docker push "${ref}" >&2
  docker inspect --format '{{index .RepoDigests 0}}' "${ref}"
}

# push_chart pushes a chart archive and prints one release output for it.
push_chart() {
  local output="$1" tgz="$2" version="$3" chart digest
  chart="$(basename "${tgz}" "-${version}.tgz")"
  digest="$(helm push "${tgz}" "oci://${REGISTRY}/nvke/charts" 2>&1 | awk '$1 == "Digest:" { print $2 }')"
  [[ "${digest}" == sha256:* ]] || die "helm push ${tgz} printed no digest"
  jq -n --arg name "${output}" --arg ref "${REGISTRY}/nvke/charts/${chart}@${digest}" --arg version "${version}" \
    --arg archive "sha256:$(shasum -a 256 "${tgz}" | awk '{ print $1 }')" \
    '{name: $name, kind: "helm-oci", digest: ($ref | split("@")[1]), reference: $ref, chartVersion: $version, helm: {defaultDigest: $archive}}'
}

publish() {
  need docker helm jq yq shasum
  local charts="${WORK}/charts" outputs="${WORK}/outputs.jsonl" arch ref name component version
  rm -rf "${charts}" "${outputs}"
  mkdir -p "${charts}"
  arch="$(node_arch)"
  for name in cwe controller-profiles; do
    if [[ "${name}" == cwe ]]; then
      ref="$(push_image nvke-controller "${REPO}/controller/Dockerfile" "${REPO}")"
    else
      ref="$(push_image controller-profiles "${REPO}/controller/test/fixtures/Dockerfile" "${REPO}/controller/test/fixtures")"
    fi
    jq -cn --arg name "${name}" --arg ref "${ref}" --arg arch "${arch}" \
      '{name: $name, kind: "oci", digest: ($ref | split("@")[1]), reference: $ref, os: "linux", arch: $arch}' >>"${outputs}"
  done

  log "packaging the NVKE charts"
  helm package "${REPO}/controller/deploy/charts/controller" --version "${VERSION}" --app-version "${VERSION}" -d "${charts}" >&2
  push_chart controller-chart "${charts}/nvke-controller-${VERSION}.tgz" "${VERSION}" | jq -c . >>"${outputs}"
  rm -rf "${WORK}/nktp-src" "${WORK}/helm"
  cp -R "${REPO}/nktp/deploy/charts/nktp" "${WORK}/nktp-src"
  # A throwaway Helm config, as make nktp-chart-deps does.
  (
    export HELM_REPOSITORY_CONFIG="${WORK}/helm/repositories.yaml" HELM_REPOSITORY_CACHE="${WORK}/helm/cache"
    n=0
    while read -r url; do
      n=$((n + 1))
      helm repo add "nktp-dep-${n}" "${url}" >/dev/null
    done < <(awk '$1 == "repository:" { print $2 }' "${WORK}/nktp-src/Chart.yaml" | sort -u)
    helm dependency build "${WORK}/nktp-src" --skip-refresh >&2
  )
  helm package "${WORK}/nktp-src" --version "${VERSION}" -d "${charts}" >&2
  rm -rf "${WORK}/nktp-src" "${WORK}/helm"
  push_chart nktp "${charts}/nktp-${VERSION}.tgz" "${VERSION}" | jq -c . >>"${outputs}"

  log "mirroring the third-party charts at the catalog's versions"
  for component in postgresql spire-crds spire temporal; do
    export COMPONENT="${component}"
    local repo chart
    repo="$(yq '.components[] | select(.name == strenv(COMPONENT)) | .helm.defaultRepository' "${REPO}/deploy/aicr/registry.yaml")"
    chart="$(yq '.components[] | select(.name == strenv(COMPONENT)) | .helm.defaultChart' "${REPO}/deploy/aicr/registry.yaml")"
    version="$(yq '.components[] | select(.name == strenv(COMPONENT)) | .helm.defaultVersion' "${REPO}/deploy/aicr/registry.yaml")"
    if [[ "${repo}" == oci://* ]]; then
      helm pull "${repo}/${chart}" --version "${version}" -d "${charts}" >&2
    else
      helm pull "${chart}" --repo "${repo}" --version "${version}" -d "${charts}" >&2
    fi
    push_chart "${component}" "${charts}/${chart}-${version}.tgz" "${version}" | jq -c . >>"${outputs}"
  done

  jq -s --arg root "sha256:$(cat "${outputs}" | shasum -a 256 | awk '{ print $1 }')" \
    '{schemaVersion: "nvkr.dev/release-description/v1", reference: ("nvkr.local/nvke/releases@" + $root), rootDigest: $root, totalOutputs: length, outputs: .}' \
    "${outputs}" >"${WORK}/release.json"
  rm -f "${outputs}"
  log "wrote ${WORK}/release.json"
}

resolve() {
  rm -rf "${WORK}/catalog"
  bash "${REPO}/deploy/aicr-resolve.sh" --release "${WORK}/release.json" --out "${WORK}/catalog"
  cat "${WORK}/catalog/release.txt"
}

bundle() {
  need "${AICR}" kubectl yq
  local node_ip key nktp_values=()
  node_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${CLUSTER}-control-plane")"
  [[ -n "${node_ip}" ]] || die "cannot read the kind node's address"
  rm -rf "${WORK}/bundle" "${WORK}/recipe.yaml"
  # nktp sized for one kind node. Each top-level key goes in as one --set-json.
  while read -r key; do
    nktp_values+=(--set-json "nktp:${key}=$(KEY="${key}" yq -o=json -I=0 '.[strenv(KEY)]' "${NKTP_SITE_VALUES}")")
  done < <(yq 'keys | .[] | select(. != "global")' "${NKTP_SITE_VALUES}")
  "${AICR}" recipe --service nvke-management --data "${WORK}/catalog" -o "${WORK}/recipe.yaml"
  # kind has no NICo and no TPM. The SPIRE chart's TPM plugin checksum is
  # also amd64 only.
  # aicr refuses to vendor from a loopback or private registry. This names
  # the demo registry as allowed; stock aicr ignores it.
  AICR_VENDOR_ALLOWED_HOSTS="${AICR_VENDOR_ALLOWED_HOSTS:-localhost}" \
    "${AICR}" bundle --recipe "${WORK}/recipe.yaml" --data "${WORK}/catalog" --vendor-charts \
    --set "nvke-controller:spiffe.trustDomain=${TRUST_DOMAIN}" \
    --set "nvke-controller:spiffe.spire.serverAddress=${node_ip}" \
    --set "spire:global.spire.trustDomain=${TRUST_DOMAIN}" \
    --set-json "spire:spire-server.adminIDs=[\"spiffe://${TRUST_DOMAIN}/nvke-service/nvke-controller\"]" \
    --set "nktp:global.clusterName=${CLUSTER}" "${nktp_values[@]}" \
    --set "nvke-controller:controllers.nico.enabled=false" \
    --set "spire:spire-server.nodeAttestor.tpmDirect.enabled=false" \
    -o "${WORK}/bundle"
}

apply() {
  need kubectl openssl clusterctl
  local password ns
  log "creating the namespaces, Secrets and ConfigMap the bundle expects"
  for ns in nktp postgres temporal nvke-controller nvke-system; do
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  password="$(kubectl -n postgres get secret nvke-database -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || true)"
  [[ -n "${password}" ]] || password="$(openssl rand -hex 16)"
  for ns in postgres temporal nvke-controller; do
    kubectl -n "${ns}" create secret generic nvke-database \
      --from-literal=postgres-password="${password}" \
      --from-literal=database-connection-string="postgresql://postgres:${password}@nvke-postgresql.postgres.svc.cluster.local:5432/nvke-controller?sslmode=disable" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  kubectl -n nvke-controller create secret generic dgxc-tenant-credentials \
    --from-literal=user=nvke --from-literal=password="$(openssl rand -hex 16)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # nktp labels its telemetry with the cluster name from this ConfigMap.
  kubectl -n nktp create configmap nktp-cluster --from-literal=name="${CLUSTER}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Cluster API is not in the catalog, and the controller does not start
  # without its Machine CRD. clusterctl needs cert-manager, so the bundle's
  # cert-manager goes first.
  log "installing cert-manager from the bundle, then Cluster API ${CAPI_VERSION}"
  bash "${WORK}"/bundle/*-cert-manager/install.sh
  kubectl get namespace capi-system >/dev/null 2>&1 ||
    clusterctl init --core "cluster-api:${CAPI_VERSION}" --bootstrap "kubeadm:${CAPI_VERSION}" \
      --control-plane "kubeadm:${CAPI_VERSION}" --wait-providers
  log "running the bundle's deploy.sh"
  (cd "${WORK}/bundle" && ./deploy.sh)
}

verify() {
  need kubectl jq
  local target ids digest
  for target in statefulset/nvke-postgresql:postgres deployment/temporal-frontend:temporal statefulset/spire-server:spire-server \
    deployment/nvke-controller:nvke-controller; do
    kubectl -n "${target#*:}" rollout status "${target%%:*}" --timeout=5m || die "${target} is not ready"
  done
  kubectl get pods -A -o wide | grep -Ev '^kube-system|^local-path-storage' >&2
  digest="$(jq -r '.outputs[] | select(.name == "cwe") | .reference | split("@")[1]' "${WORK}/release.json")"
  ids="$(kubectl -n nvke-controller get pods -l app.kubernetes.io/name=nvke-controller \
    -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}{end}')"
  grep -q "${digest}" <<<"${ids}" || die "the controller does not run ${digest}: ${ids}"
  log "PASS: the controller runs ${digest} from the release"
}

down() {
  kind delete cluster --name "${CLUSTER}" 2>/dev/null || true
  docker rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
}

case "${1:-}" in
  up | publish | resolve | bundle | apply | verify | down) "$1" ;;
  all) up && publish && resolve && bundle && apply && verify ;;
  *) sed -n '5,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
