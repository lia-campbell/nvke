# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Renders the NVKE seed stack from the AICR catalog in this directory.
#
#   make -C deploy/aicr validate    INVENTORY=<file>
#   make -C deploy/aicr seed-bundle INVENTORY=<file> OUT=<dir>
#
# INVENTORY is an AICR ArtifactInventory. It supplies every chart and the
# controller image. The catalog names none of them, so both targets need it.
# Nothing here pushes or installs anything.

AICR_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
CATALOG := $(AICR_DIR)/catalog
CONFIG := $(AICR_DIR)/config/seed.yaml
OVERLAY := $(CATALOG)/overlays/seed.yaml

AICR ?= aicr
INVENTORY ?=
OUT ?=

# Optional. VENDOR_CHARTS=1 pulls the charts into the bundle and checks their
# archive digests. ATTEST=1 signs the bundle.
VENDOR_CHARTS ?=
ATTEST ?=
BUNDLE_FLAGS := $(if $(VENDOR_CHARTS),--vendor-charts) $(if $(ATTEST),--attest)

# The config with INVENTORY as its inventory path, on stdout. AICR reads it
# from /dev/stdin, so no file is written.
SEED_CONFIG = sed 's|^\( *inventory:\) .*|\1 $(abspath $(INVENTORY))|' "$(CONFIG)"
AICR_FLAGS := --data "$(CATALOG)" --external-only --config /dev/stdin

.PHONY: validate seed-bundle check-inventory check-out

validate: check-inventory ## Validate the catalog against INVENTORY.
	@$(SEED_CONFIG) | "$(AICR)" recipe validate $(AICR_FLAGS)

# The overlay is passed directly, so no recipe file is written first.
seed-bundle: validate check-out ## Validate the catalog and render the seed Helmfile bundle into OUT.
	@$(SEED_CONFIG) | "$(AICR)" bundle $(AICR_FLAGS) \
		--recipe "$(OVERLAY)" --output "$(OUT)" $(BUNDLE_FLAGS)

check-inventory:
	@test -n "$(INVENTORY)" || { echo "INVENTORY=<file> is required" >&2; exit 1; }
	@test -f "$(INVENTORY)" || { echo "INVENTORY=$(INVENTORY) is not a file" >&2; exit 1; }

check-out:
	@test -n "$(OUT)" || { echo "OUT=<dir> is required" >&2; exit 1; }
