#!/usr/bin/env bash
###############################################################################
# scm-folder-release.sh — first step of a path-B teardown: move every device out of
# the deployment folder, so `terraform destroy` in phase2-scm-config can delete it.
#
# SCM refuses to delete a folder that still holds devices, and its API cannot delete
# devices. The devices go back to a parent folder (default ngfw-shared); remove them
# for good by deactivating their serials in the Customer Support Portal, which also
# frees the licence credits.
#
# Usage: scm-folder-release.sh <folder> [target_folder=ngfw-shared] [serial ...]
#   With serials: move ONLY those devices, and only if they are disconnected — the case after a
#   pair rebuild, where the old units must leave the folder (scm-upgrade.sh refuses to run while a
#   device of the folder is disconnected) but the live ones stay.
# Env:   SCM_TSG_ID SCM_CLIENT_ID SCM_CLIENT_SECRET (see scm-lib.sh)
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scm-lib.sh
source "$HERE/scm-lib.sh"

FOLDER="${1:?usage: $0 <folder> [target_folder] [serial ...]}"
TARGET="${2:-ngfw-shared}"
shift $(( $# >= 2 ? 2 : $# ))
ONLY="$*"
n=0
for id in $(scm_api GET "/config/setup/v1/devices?limit=500" \
              | jq -r --arg f "$FOLDER" --arg only "$ONLY" '($only | split(" ") | map(select(. != ""))) as $o
                  | (.data // [])[] | select(.folder == $f)
                  | select(($o | length) == 0 or ((.name as $n | $o | index($n)) != null and .is_connected != true))
                  | .id'); do
  scm_api PUT "/config/setup/v1/devices/$id" "$(jq -nc --arg t "$TARGET" '{folder:$t}')" >/dev/null \
    || scm_die "could not move device $id"
  scm_log "moved device $id -> $TARGET"; n=$((n + 1))
done
scm_log "$n device(s) moved out of '$FOLDER'. Next: terraform -chdir=phase2-scm-config destroy -parallelism=4"
