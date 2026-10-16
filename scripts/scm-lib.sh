#!/usr/bin/env bash
###############################################################################
# scm-lib.sh — shared helpers for the path-B (Strata Cloud Manager) scripts.
# SOURCE it; do not execute.
#
# Required env (never commit values; keep them in an untracked file, e.g.
# ~/.config/aws_ha_scm/secrets.env, and `source` that first):
#   SCM_TSG_ID, SCM_CLIENT_ID, SCM_CLIENT_SECRET
#
# Design notes (each one a lesson from path A):
#   * Every call checks the HTTP status and FAILS LOUDLY — path A's commit once
#     "succeeded" while the job had been rejected.
#   * Async operations (config push) are polled to a terminal state, never
#     fire-and-forget.
#   * jq everywhere, no sed -- BSD sed on macOS already hung a commit script.
#   * The auth API allows only ~10 concurrent token requests per tenant, so the
#     token is cached on disk (mode 600) and reused for ~13 of its 15 minutes.
###############################################################################

: "${SCM_TSG_ID:?SCM_TSG_ID required}"
: "${SCM_CLIENT_ID:?SCM_CLIENT_ID required}"
: "${SCM_CLIENT_SECRET:?SCM_CLIENT_SECRET required}"

SCM_AUTH_URL="${SCM_AUTH_URL:-https://auth.apps.paloaltonetworks.com/oauth2/access_token}"
SCM_API="${SCM_API:-https://api.strata.paloaltonetworks.com}"
_SCM_TOKEN_FILE="${TMPDIR:-/tmp}/scm-token-${SCM_TSG_ID}"

command -v jq >/dev/null || { echo "jq is required" >&2; return 1 2>/dev/null || exit 1; }

scm_log() { printf '[scm] %s\n' "$*" >&2; }
scm_die() { printf '[scm] ERROR: %s\n' "$*" >&2; exit 1; }

scm_token() {
  # Reuse a cached token younger than 13 minutes.
  if [ -s "$_SCM_TOKEN_FILE" ] && [ -n "$(find "$_SCM_TOKEN_FILE" -mmin -13 2>/dev/null)" ]; then
    cat "$_SCM_TOKEN_FILE"; return 0
  fi
  local resp tok
  resp="$(curl -sS --max-time 30 -u "${SCM_CLIENT_ID}:${SCM_CLIENT_SECRET}" \
    -d "grant_type=client_credentials" --data-urlencode "scope=tsg_id:${SCM_TSG_ID}" \
    "$SCM_AUTH_URL")" || scm_die "token request failed (network)"
  tok="$(jq -r '.access_token // empty' <<<"$resp")"
  [ -n "$tok" ] || scm_die "no access_token in auth response: $(jq -c 'del(.access_token)' <<<"$resp" 2>/dev/null)"
  ( umask 077; printf '%s' "$tok" > "$_SCM_TOKEN_FILE" )
  printf '%s' "$tok"
}

# scm_api METHOD URI [JSON_BODY]  -> response body on stdout; non-2xx => exit 1.
# URI is relative to $SCM_API, e.g. /config/setup/v1/devices?limit=200
# (NOT named "path": in zsh that variable is tied to PATH and a `local path`
# would blank the command search path for anyone sourcing this from zsh.)
scm_api() {
  local method="$1" uri="$2" body="${3:-}" out code tok
  tok="$(scm_token)"
  local args=(-sS --max-time 60 -X "$method" -H "Authorization: Bearer ${tok}" -H "Accept: application/json"
              -w '\n%{http_code}')
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
  out="$(curl "${args[@]}" "${SCM_API}${uri}")" || scm_die "$method $uri: curl failed"
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  case "$code" in
    2??) printf '%s' "$out" ;;
    *) printf '[scm] ERROR: %s %s -> HTTP %s: %s\n' "$method" "$uri" "$code" "$out" >&2; return 1 ;;
  esac
}

# URL-encode one query value.
scm_urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

# scm_wait_job JOB_ID [TIMEOUT_SECONDS]
# Polls /config/operations/v1/jobs/<id> until status_str is terminal; success
# only if result_str == OK. The jobs response may be the object itself or wrapped
# in .data[]; both are handled.
scm_wait_job() {
  local id="$1" timeout="${2:-900}" waited=0 resp status result summary
  while [ "$waited" -lt "$timeout" ]; do
    resp="$(scm_api GET "/config/operations/v1/jobs/${id}")" || return 1
    status="$(jq -r '(.data // [.])[0] | .status_str // empty' <<<"$resp")"
    result="$(jq -r '(.data // [.])[0] | .result_str // empty' <<<"$resp")"
    summary="$(jq -r '(.data // [.])[0] | .summary // empty' <<<"$resp")"
    scm_log "job ${id}: status=${status:-?} result=${result:-?} ${summary}"
    case "$status" in
      FIN)
        [ "$result" = "OK" ] && return 0
        scm_log "job ${id} finished with result=${result}: ${resp}"; return 1 ;;
      PUSHFAIL|PUSHABORT|PUSHTIMEOUT)
        scm_log "job ${id} failed: ${resp}"; return 1 ;;
    esac
    sleep 10; waited=$((waited + 10))
  done
  scm_log "job ${id} did not finish within ${timeout}s"; return 1
}

# scm_wait_children PARENT_JOB_ID [TIMEOUT_SECONDS]
# A config push has TWO levels. The job returned by candidate:push is only SCM's
# own bookkeeping and finishes FIN/OK as soon as the request is accepted; the real
# work is one child job per firewall (type CommitAll, status PUSHSENT -> ... -> FIN)
# that runs the LOCAL commit on the device. Treating the parent as "done" reports
# success while the firewalls are still committing (or have rejected the config) —
# the same silent-failure class that path A's commit script once had. So: wait for
# every child (parent_id == PARENT) to reach FIN and require result OK on all.
scm_wait_children() {
  local parent="$1" timeout="${2:-1800}" waited=0 resp kids n_total n_fin n_bad
  sleep 5   # children are created just after the parent finishes
  while [ "$waited" -lt "$timeout" ]; do
    resp="$(scm_api GET "/config/operations/v1/jobs?limit=100")" || return 1
    # Only judge devices that are connected right now. A device that is still assigned
    # to the folder but no longer exists (a replaced firewall) always ends PUSHFAIL and
    # says nothing about the config; it is reported below, not allowed to fail the push.
    conn="$(scm_api GET "/config/setup/v1/devices?limit=500" \
      | jq -c '[ (.data // [])[] | select(.is_connected == true) | .name ]')" || return 1
    skipped="$(jq -c --arg p "$parent" --argjson c "$conn" '[ (if type=="array" then . else (.data // []) end)[]
      | select(.parent_id == $p and ((.device_name // "") as $d | ($c | index($d)) == null)) | .device_name ]' <<<"$resp")"
    [ "$skipped" != "[]" ] && scm_log "ignoring push jobs of devices that are not connected: $skipped (remove them from the folder in SCM)"
    kids="$(jq -c --arg p "$parent" --argjson c "$conn" '[ (if type=="array" then . else (.data // []) end)[]
      | select(.parent_id == $p and ((.device_name // "") as $d | ($c | index($d)) != null)) ]' <<<"$resp")"
    n_total="$(jq 'length' <<<"$kids")"
    n_fin="$(jq '[ .[] | select(.status_str == "FIN") ] | length' <<<"$kids")"
    n_bad="$(jq '[ .[] | select((.status_str == "FIN" and .result_str != "OK") or (.status_str | IN("PUSHFAIL","PUSHABORT","PUSHTIMEOUT"))) ] | length' <<<"$kids")"
    scm_log "push ${parent}: device jobs ${n_fin}/${n_total} finished, ${n_bad} failed"
    jq -r '.[] | "    \(.device_name // "?"): \(.status_str)/\(.result_str) \(.summary // "")"' <<<"$kids" >&2
    if [ "$n_bad" -gt 0 ]; then
      scm_log "at least one device rejected the push — details above; inspect with GET /config/operations/v1/jobs/<id>"
      return 1
    fi
    [ "$n_total" -gt 0 ] && [ "$n_fin" -eq "$n_total" ] && return 0
    sleep 15; waited=$((waited + 15))
  done
  scm_log "device jobs of push ${parent} did not all finish within ${timeout}s"; return 1
}

# scm_device_by_hostname KEY -> device JSON (first match) or empty. KEY is a serial
# (the device `name`) OR a hostname. Prefer the serial: the firewalls take their
# hostname from DHCP (dhcp-accept-server-hostname=yes), so the init-cfg hostname
# is overridden and shows up as e.g. ip-10-10-0-11, never "fw1".
scm_device_by_hostname() {
  scm_api GET "/config/setup/v1/devices?limit=500" \
    | jq -c --arg h "$1" '(.data // []) | map(select(.name == $h or .hostname == $h)) | first // empty'
}
