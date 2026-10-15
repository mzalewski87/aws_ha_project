#!/usr/bin/env bash
###############################################################################
# scm-push.sh — push the SCM candidate configuration of a folder to its
# firewalls and WAIT for the job to finish (path-B equivalent of
# configure-panorama.sh commit / commit-all).
#
# Never fire-and-forget: a rejected push (validation error, content mismatch,
# lock) must fail this script. In path A a commit that was silently rejected
# left policy in Panorama's candidate config but absent from the firewalls, so
# traffic fell through to the default deny with no logs. Here a non-OK job is a
# non-zero exit, and the job summary is printed.
#
# Usage: scm-push.sh <folder> [description]
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scm-lib.sh
source "$HERE/scm-lib.sh"

FOLDER="${1:?usage: $0 <folder> [description]}"
DESC="${2:-terraform/scripts push to ${FOLDER}}"

body="$(jq -nc --arg f "$FOLDER" --arg d "$DESC" '{folders:[$f], description:$d}')"
resp="$(scm_api POST "/config/operations/v1/config-versions/candidate:push" "$body")" \
  || scm_die "push request rejected (see error above)"

# [VERIFY LIVE] the 201 body shape is not documented in the spec; accept the
# common spellings. If none is present, print the body so the key can be fixed.
job="$(jq -r '.job_id // .jobId // .id // (.data // [] | first | .id) // empty' <<<"$resp")"
[ -n "$job" ] || scm_die "push accepted but no job id found in response: $resp"
scm_log "push job id: $job"

scm_wait_job "$job" "${PUSH_TIMEOUT:-1200}" || scm_die "push job $job did not finish OK"
scm_log "push to folder '$FOLDER' finished OK"
