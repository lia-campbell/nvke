# Install the NVKE controller stack with an NVKR release and AICR

This demo installs the controller stack on a kind cluster.
It uses three inputs: a release description, the catalog template in `deploy/aicr`, and site values.
`hack/aicr-demo.sh` runs the same steps. Each step below is one subcommand of it.

The release description stands in for NVKR output.
The demo builds the images and charts from this checkout and pushes them to a local registry.
It then writes a release description that names them by digest.

## What you need

- docker, kind, kubectl, helm, clusterctl, jq, openssl.
- yq v4 from mikefarah.
- aicr. `aicr bundle --vendor-charts` refuses a chart registry on a loopback or private address.
  The demo registry is on `localhost`, so the demo needs an aicr that reads `AICR_VENDOR_ALLOWED_HOSTS`.
  Stock aicr does not read it yet.

Set these once:

```bash
export NVKE_AICR_DEMO_DIR=<work directory>          # default: $TMPDIR/nvke-aicr-demo
export AICR=<path to aicr>
export REGISTRY=localhost:5001                      # the script takes REGISTRY_PORT
export NVKE_DEMO_VERSION=<chart and image version>   # default: 0.0.0-aicr.1
export KUBECONFIG=$NVKE_AICR_DEMO_DIR/kubeconfig
```

## 1. Start a registry and a cluster

`hack/aicr-demo.sh up` does this step.

```bash
docker run -d --restart=always -p 127.0.0.1:5001:5000 --name nvke-aicr-registry registry:2
kind create cluster --name nvke-aicr-demo --kubeconfig $KUBECONFIG
docker network connect kind nvke-aicr-registry
docker exec -i nvke-aicr-demo-control-plane sh -c \
  "mkdir -p /etc/containerd/certs.d/$REGISTRY && cat >/etc/containerd/certs.d/$REGISTRY/hosts.toml" <<EOF
[host."http://nvke-aicr-registry:5000"]
  capabilities = ["pull", "resolve"]
EOF
```

## 2. Publish the release

`hack/aicr-demo.sh publish` does this step.
It builds and pushes two images and six charts, then writes `release.json`.

| Output | What | From |
|---|---|---|
| `cwe` | controller image | `controller/Dockerfile` |
| `controller-profiles` | profiles image | `controller/test/fixtures/Dockerfile` |
| `controller-chart` | controller chart | `controller/deploy/charts/controller` |
| `nktp` | NKTP chart | `nktp/deploy/charts/nktp` |
| `postgresql`, `spire-crds`, `spire`, `temporal` | upstream charts | pulled from their upstream repositories at the `valuesWrittenFor` versions in `deploy/aicr/nvkr-bindings.yaml` |

For each chart it records the OCI reference by digest, the chart version, and the SHA-256 of the chart archive.
For example:

```bash
helm package controller/deploy/charts/controller --version $NVKE_DEMO_VERSION --app-version $NVKE_DEMO_VERSION -d charts
helm push charts/nvke-controller-$NVKE_DEMO_VERSION.tgz oci://$REGISTRY/nvke/charts   # prints the manifest digest
shasum -a 256 charts/nvke-controller-$NVKE_DEMO_VERSION.tgz                            # the archive digest
```

One output in `release.json`:

```json
{
  "name": "controller-chart",
  "kind": "helm-oci",
  "digest": "sha256:<manifest digest>",
  "reference": "localhost:5001/nvke/charts/nvke-controller@sha256:<manifest digest>",
  "chartVersion": "<version>",
  "helm": { "defaultDigest": "sha256:<archive digest>" }
}
```

Check the file against the NVKE contract:

```bash
nvkectl inspect nvkr-release $NVKE_AICR_DEMO_DIR/release.json --artifacts
```

## 3. Resolve the catalog

`hack/aicr-demo.sh resolve` does this step.

```bash
deploy/aicr-resolve.sh --release $NVKE_AICR_DEMO_DIR/release.json --out $NVKE_AICR_DEMO_DIR/catalog
cat $NVKE_AICR_DEMO_DIR/catalog/release.txt
```

The template in `deploy/aicr` names the components, their order, their values and the glue manifests.
It names no chart repository, version or digest; those come from the release.
`deploy/aicr/nvkr-bindings.yaml` says which output goes where.
A chart output sets its registry entry: repository, chart, version and archive digest.
An image output sets a repository and a digest in the controller values.
An image output the release does not carry keeps the template value.
The resolve fails without `cwe` or `controller-chart`, and for any chart no output resolves.
Each chart binding also records `valuesWrittenFor`, the chart version its values file was written against.
A release with another version resolves with a warning; `--strict` makes it fail.

## 4. Render the bundle

`hack/aicr-demo.sh bundle` does this step.
The site values are the trust domain and the address of the node that publishes SPIRE.

```bash
aicr recipe --service nvke-management --data $NVKE_AICR_DEMO_DIR/catalog -o $NVKE_AICR_DEMO_DIR/recipe.yaml
AICR_VENDOR_ALLOWED_HOSTS=localhost aicr bundle --recipe $NVKE_AICR_DEMO_DIR/recipe.yaml \
  --data $NVKE_AICR_DEMO_DIR/catalog --vendor-charts \
  --set nvke-controller:spiffe.trustDomain=<trust domain> \
  --set nvke-controller:spiffe.spire.serverAddress=<node address> \
  --set spire:global.spire.trustDomain=<trust domain> \
  --set-json 'spire:spire-server.adminIDs=["spiffe://<trust domain>/nvke-service/nvke-controller"]' \
  --set nktp:global.clusterName=<cluster name> \
  --set-json 'nktp:metrics-server={"enabled":true,"args":["--kubelet-insecure-tls"]}' \
  --set nvke-controller:controllers.nico.enabled=false \
  --set spire:spire-server.nodeAttestor.tpmDirect.enabled=false \
  -o $NVKE_AICR_DEMO_DIR/bundle
```

The `metrics-server` line is one of the kind sizes for nktp.
The script passes every top-level key of `nktp/hack/e2e-values.yaml` the same way.
kind has no NICo and no TPM, so the NICo controllers and the SPIRE TPM attestor are off.
The SPIRE chart pins an amd64 checksum for the TPM plugin, so it does not start on arm64 either.

`--vendor-charts` copies every chart into the bundle.
It refuses a chart whose archive digest differs from the release.

## 5. Apply

`hack/aicr-demo.sh apply` does this step.
Create the Secrets and the `nktp-cluster` ConfigMap first.
No file in the catalog or the bundle holds a credential.

```bash
kubectl create namespace nktp; kubectl create namespace postgres; kubectl create namespace temporal
kubectl create namespace nvke-controller; kubectl create namespace nvke-system
PASSWORD=$(openssl rand -hex 16)
for ns in postgres temporal nvke-controller; do
  kubectl -n $ns create secret generic nvke-database \
    --from-literal=postgres-password=$PASSWORD \
    --from-literal=database-connection-string="postgresql://postgres:$PASSWORD@nvke-postgresql.postgres.svc.cluster.local:5432/nvke-controller?sslmode=disable"
done
kubectl -n nvke-controller create secret generic dgxc-tenant-credentials \
  --from-literal=user=nvke --from-literal=password=$(openssl rand -hex 16)
kubectl -n nktp create configmap nktp-cluster --from-literal=name=<cluster name>
```

Cluster API is not in the catalog.
The controller does not start without its Machine CRD.
clusterctl needs cert-manager, so install the bundle's cert-manager first.

```bash
bash $NVKE_AICR_DEMO_DIR/bundle/001-cert-manager/install.sh
clusterctl init --core cluster-api:v1.13.6 --bootstrap kubeadm:v1.13.6 \
  --control-plane kubeadm:v1.13.6 --wait-providers
cd $NVKE_AICR_DEMO_DIR/bundle && ./deploy.sh
```

The Cluster API version is `CAPI_VERSION` in `make/tool-versions.mk`.

## 6. Verify

`hack/aicr-demo.sh verify` does this step.

```bash
kubectl get pods -A
kubectl -n nvke-controller get pods -l app.kubernetes.io/name=nvke-controller \
  -o jsonpath='{.items[*].status.containerStatuses[*].imageID}'
jq -r '.outputs[] | select(.name == "cwe") | .reference' $NVKE_AICR_DEMO_DIR/release.json
```

The two digests must match.

## What the demo does not cover

- CAPNICo and NICo. The NICo controllers are off.
- TPM attestation. kind nodes have no TPM.
- A signed NVKR release. The root digest in `release.json` is a hash of its outputs.
- Stock aicr with a private registry. See "What you need".

## Clean up

```bash
hack/aicr-demo.sh down
```
