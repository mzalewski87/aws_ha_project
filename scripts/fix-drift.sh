#!/usr/bin/env bash
###############################################################################
# fix-drift.sh — re-assert Phase 2a config after out-of-band Panorama edits.
# Runs a targeted refresh + apply on the panos workspace, then commits.
###############################################################################
set -euo pipefail
cd "$(dirname "$0")/../phase2-panorama-config"
echo "[drift] refreshing panos state"
terraform apply -refresh-only -auto-approve
echo "[drift] re-applying declarative config"
terraform apply -auto-approve
echo "[drift] done — verify with scripts/check-panorama.sh"
