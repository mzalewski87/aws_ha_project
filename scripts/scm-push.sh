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
DESC="${2:-terraform and scripts push to ${FOLDER}}"
# The API validates the description against a restricted character set: "+" was
# rejected live ("push-config -> description ... is invalid") while letters, digits,
# spaces and . , : - _ were accepted. Replace anything else so a stray symbol in a
# commit message cannot abort a push.
DESC="$(printf '%s' "$DESC" | tr -c 'A-Za-z0-9 ._,:-' '_')"

body="$(jq -nc --arg f "$FOLDER" --arg d "$DESC" '{folders:[$f], description:$d}')"
resp="$(scm_api POST "/config/operations/v1/config-versions/candidate:push" "$body")" \
  || scm_die "push request rejected (see error above)"

# The 201 body shape is not documented in the spec; accept the common spellings (live: the
# job id is returned). If none is present, print the body so the key can be fixed.
job="$(jq -r '.job_id // .jobId // .id // (.data // [] | first | .id) // empty' <<<"$resp")"
[ -n "$job" ] || scm_die "push accepted but no job id found in response: $resp"
scm_log "push job id: $job"

scm_wait_job "$job" "${PUSH_TIMEOUT:-1200}" || scm_die "push job $job did not finish OK"
scm_log "SCM accepted the push (job $job) — now waiting for each firewall's local commit"

# The parent job above is only SCM's side. The firewalls commit in child jobs.
expected="$(scm_api GET "/config/setup/v1/devices?limit=500" \
  | jq --arg f "$FOLDER" '[ (.data // [])[] | select(.folder == $f and .is_connected == true) ] | length')"
scm_log "waiting for ${expected} connected firewall(s) in '$FOLDER' to commit"
scm_wait_children "$job" "${PUSH_TIMEOUT:-1800}" "${expected:-1}" || scm_die "a firewall did not finish committing OK"
scm_log "push to folder '$FOLDER' finished OK on every device"
