#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Pulls one chart archive and compares its sha256 with the artifacts file.
# Helmfile runs it as a prepare hook, before it pulls the chart itself.
# Usage: verify-chart-archive.sh <ref> <version> <sha256:digest> <plain-http>
set -eu

ref=$1
version=$2
want=$3
plain_http=$4

# A local chart directory has no archive to compare.
case "$ref" in
oci://*) ;;
*)
	echo "skip the archive digest check: $ref is not an OCI reference" >&2
	exit 0
	;;
esac

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

set -- pull "$ref" --version "$version" --destination "$dir"
if [ "$plain_http" = "true" ]; then
	set -- "$@" --plain-http
fi
"${HELM:-helm}" "$@" >/dev/null

if command -v sha256sum >/dev/null 2>&1; then
	sum=$(sha256sum "$dir"/*.tgz)
else
	sum=$(shasum -a 256 "$dir"/*.tgz)
fi
got="sha256:${sum%% *}"

if [ "$got" != "$want" ]; then
	echo "chart archive digest mismatch for $ref:$version: got $got, the artifacts file says $want" >&2
	exit 1
fi
echo "verified $ref:$version $got"
