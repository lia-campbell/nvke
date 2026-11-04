# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Packages the AICR catalog as a content image, so a release can carry it next
# to the charts it names. Build context is this directory.
#
# No RUN: a build with no RUN step needs no emulation to target another
# architecture.
FROM scratch
COPY registry.yaml /aicr/registry.yaml
COPY overlays/ /aicr/overlays/
COPY components/ /aicr/components/
