# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Wraps helmfile for the NVKE seed stack. Works with make 3.81.
#
#   make -C deploy/helmfile build ARTIFACTS=<file> SITE=<file>
#   make -C deploy/helmfile template ARTIFACTS=<file> SITE=<file> OUT=<dir>
#   make -C deploy/helmfile package ARTIFACTS=<file> SITE=<file> OUT=<dir>
#
# Relative paths resolve from this directory, because of `make -C`.
# `template` reads the Postgres password from NVKE_POSTGRES_PASSWORD.

DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

HELMFILE ?= helmfile
ENV ?= seed
# A packaged directory carries both files, so they are its defaults.
ARTIFACTS ?= $(wildcard $(DIR)/artifacts.yaml)
SITE ?= $(wildcard $(DIR)/site.yaml)
OUT ?=
# Set PLAIN_HTTP=true for a registry without TLS.
PLAIN_HTTP ?= false

RUN = $(HELMFILE) -f $(DIR)/helmfile.yaml.gotmpl -e $(ENV) \
	--state-values-file $(abspath $(ARTIFACTS)) \
	--state-values-file $(abspath $(SITE)) \
	--state-values-set registry.plainHttp=$(PLAIN_HTTP)

.PHONY: help build list template package check-inputs check-out

help: ## List the targets.
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check-inputs:
	@test -n "$(ARTIFACTS)" || { echo "ARTIFACTS is not set. Pass ARTIFACTS=<artifacts file>." >&2; exit 1; }
	@test -f "$(ARTIFACTS)" || { echo "ARTIFACTS=$(ARTIFACTS) is not a file." >&2; exit 1; }
	@test -n "$(SITE)" || { echo "SITE is not set. Pass SITE=<site file>." >&2; exit 1; }
	@test -f "$(SITE)" || { echo "SITE=$(SITE) is not a file." >&2; exit 1; }

check-out:
	@test -n "$(OUT)" || { echo "OUT is not set. Pass OUT=<directory>." >&2; exit 1; }

build: check-inputs ## Print the resolved state. Pulls the charts and checks their digests.
	$(RUN) build

list: check-inputs ## List the releases. Needs no registry.
	$(RUN) list

template: check-inputs check-out ## Render the manifests into OUT, one directory per release.
	$(RUN) template --include-crds --output-dir $(abspath $(OUT)) \
		--output-dir-template '{{ .OutputDir }}/{{ .Release.Name }}'

package: check-inputs check-out ## Write the helmfile and both state values files into OUT.
	@test ! -e "$(OUT)" || { echo "OUT=$(OUT) exists. Pass a new directory." >&2; exit 1; }
	$(RUN) list >/dev/null
	mkdir -p $(OUT)
	cp $(DIR)/helmfile.yaml.gotmpl $(DIR)/Makefile $(OUT)/
	cp -R $(DIR)/environments $(DIR)/values $(DIR)/manifests $(DIR)/hooks $(OUT)/
	cp $(ARTIFACTS) $(OUT)/artifacts.yaml
	cp $(SITE) $(OUT)/site.yaml
	@echo "Wrote $(OUT). Run: make -C $(OUT) build"
