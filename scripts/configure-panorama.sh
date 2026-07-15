#!/usr/bin/env bash
###############################################################################
# configure-panorama.sh — Phase 2a helper
#
# Subcommands:
#   ssh      Open an SSM port-forward to Panorama:22 (localhost:2222) through the
#            jump host. Use it for FIRST login (set the admin password): PAN-OS on
#            AWS has NO default password — initial access is the key_name SSH key.
#              ssh -i <key.pem> -p 2222 admin@127.0.0.1
#              > configure ; set mgmt-config users admin password ; commit
#   tunnel   Open the SSM port-forward to Panorama:443 (localhost:44300) so the
#            panos provider + XML API can reach it.
#   commit   Commit on Panorama and push to the device group / template stack
#            (invoked by the Phase 2a workspace null_resource.commit).
#
# Reachability is via the SSM jump host (ADR D8). PAN-OS/Panorama run
# no SSM agent, so we forward THROUGH the jump host to Panorama's private IP with
# AWS-StartPortForwardingSessionToRemoteHost.
###############################################################################
set -euo pipefail

cmd="${1:-tunnel}"
H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:-}"
DG="${DEVICE_GROUP:-AWS-Transit-DG}"; TS="${TEMPLATE_STACK:-AWS-Transit-Stack}"
BASE="https://${H}:${P}/api/"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

api_key() {
  curl -sk "${BASE}?type=keygen&user=${U}&password=${PW}" \
    | sed -n 's:.*<key>\(.*\)</key>.*:\1:p'
}

# Resolve JUMP (jump-host instance id) and PANO_IP defensively. Phase 1a is
# applied with -target, so `terraform output` is often incomplete (Terraform
# warns "output values may not be fully updated"). Fall back to authoritative
# AWS lookups by Name tag, then to the static value in terraform.tfvars.
resolve() {
  tf_out() { (cd "${ROOT_DIR}" && terraform output -raw "$1" 2>/dev/null) || true; }

  JUMP="$(tf_out ssm_jumphost_instance_id)"
  if [ -z "${JUMP}" ] || [ "${JUMP}" = "None" ]; then
    JUMP="$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=*-ssm-jumphost" \
                "Name=instance-state-name,Values=pending,running" \
      --query 'Reservations[].Instances[].InstanceId | [0]' --output text 2>/dev/null)"
  fi

  PANO_IP="$(tf_out panorama_private_ip)"
  if [ -z "${PANO_IP}" ] || [ "${PANO_IP}" = "None" ]; then
    PANO_IP="$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=*-panorama" \
                "Name=instance-state-name,Values=pending,running" \
      --query 'Reservations[].Instances[].PrivateIpAddress | [0]' --output text 2>/dev/null)"
  fi
  if [ -z "${PANO_IP}" ] || [ "${PANO_IP}" = "None" ]; then
    PANO_IP="$(sed -n 's/^[[:space:]]*panorama_private_ip[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
      "${ROOT_DIR}/terraform.tfvars" 2>/dev/null | head -1)"
  fi

  if [ -z "${JUMP}" ] || [ "${JUMP}" = "None" ] || [ -z "${PANO_IP}" ] || [ "${PANO_IP}" = "None" ]; then
    echo "ERROR: could not resolve jump host (JUMP='${JUMP}') or Panorama IP (PANO_IP='${PANO_IP}')."
    echo "       Check AWS_PROFILE/AWS_REGION and that Phase 1a (panorama) is applied."
    exit 1
  fi
}

forward() {  # $1 = remote port, $2 = local port
  resolve
  echo "[forward] localhost:$2 -> ${PANO_IP}:$1 via jump host ${JUMP}  (Ctrl-C to close)"
  exec aws ssm start-session --target "${JUMP}" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"${PANO_IP}\"],\"portNumber\":[\"$1\"],\"localPortNumber\":[\"$2\"]}"
}

case "${cmd}" in
  ssh)
    LP="${SSH_LOCAL_PORT:-2222}"
    echo "[ssh] After this opens, in another shell:"
    echo "      ssh -i <your-key.pem> -p ${LP} admin@127.0.0.1"
    echo "      PAN-OS> configure"
    echo "      PAN-OS# set mgmt-config users admin password   # sets the panos_password"
    echo "      PAN-OS# commit"
    forward 22 "${LP}"
    ;;
  tunnel)
    forward 443 "${P}"
    ;;
  commit)
    : "${PW:?set PANORAMA_PASSWORD}"
    key="$(api_key)"; [ -n "${key}" ] || { echo "[commit] keygen failed"; exit 1; }

    # PAN-OS commit/commit-all are ASYNC (a job id comes back immediately; the
    # actual work runs for anywhere from seconds to minutes). The previous
    # A fire-and-forget commit (submit, sleep a fixed interval, discard the
    # HTTP response) is unsafe: a failed/rejected commit (job-lock, a
    # validation error, a stale/expired session) is reported as "done" and
    # Terraform sees a clean exit 0. That silence can leave the
    # security-policy rules existing in Terraform state
    # (the panos_security_policy/panos_nat_policy resources) while being
    # completely absent from Panorama's actual running config and therefore
    # never pushed to the firewalls (traffic silently hits interzone-default
    # deny). Poll every job to FIN and fail loudly on anything but result=OK.
    # Poll budget: default 240 tries x 5s = 20 min. A multi-region commit-all
    # (template-stack + device-group push to 4 firewalls across 2 regions) can
    # legitimately run for many minutes — the per-device commits
    # succeed but the aggregate push job reports FIN late, and too short a
    # timeout would mis-flag that as a failure (all devices show "committed
    # successfully"). Override with COMMIT_POLL_TRIES for very large fleets.
    wait_job() {  # $1 = job id -> prints final job status XML on stdout
      local jid="$1" xml status tries=0 poll_tries="${COMMIT_POLL_TRIES:-240}"
      while [ "${tries}" -lt "${poll_tries}" ]; do
        xml="$(curl -sk --data-urlencode "type=op" \
          --data-urlencode "cmd=<show><jobs><id>${jid}</id></jobs></show>" \
          --data-urlencode "key=${key}" "${BASE}")"
        # Job-level status is the FIRST <status> in the response. A CommitAll
        # response also carries per-device <status> entries ("commit succeeded"),
        # so a greedy sed would latch onto the LAST one and never see FIN — the
        # job would appear to hang until the poll budget expired even though it
        # finished. grep -o keeps each match separate; head -1 = the job status.
        status="$(printf '%s' "${xml}" | grep -oE '<status>[^<]*</status>' | head -1 | sed -E 's:</?status>::g')"
        if [ "${status}" = "FIN" ]; then
          printf '%s' "${xml}"
          return 0
        fi
        tries=$((tries + 1))
        sleep 5
      done
      echo "[commit] job ${jid} did not reach FIN within $((poll_tries * 5 / 60)) minutes" >&2
      printf '%s' "${xml}"
      return 1
    }

    run_commit() {  # $1 = label, $2 = cmd xml, $3 = extra curl args (action=all or empty)
      local label="$1" cmdxml="$2" extra="${3:-}" resp jid xml result
      if [ -n "${extra}" ]; then
        resp="$(curl -sk --data-urlencode "type=commit" --data-urlencode "${extra}" \
          --data-urlencode "cmd=${cmdxml}" --data-urlencode "key=${key}" "${BASE}")"
      else
        resp="$(curl -sk --data-urlencode "type=commit" \
          --data-urlencode "cmd=${cmdxml}" --data-urlencode "key=${key}" "${BASE}")"
      fi
      if printf '%s' "${resp}" | grep -q 'status="error"'; then
        if printf '%s' "${resp}" | grep -qi 'no changes'; then
          echo "[commit] ${label}: no changes to commit (already up to date)"
          return 0
        fi
        echo "[commit] ${label}: FAILED to submit:"; printf '%s\n' "${resp}"; return 1
      fi
      jid="$(printf '%s' "${resp}" | sed -n 's:.*<job>\([0-9]*\)</job>.*:\1:p' | head -1)"
      if [ -z "${jid}" ]; then
        echo "[commit] ${label}: no job id in response (nothing queued):"; printf '%s\n' "${resp}"
        return 0
      fi
      echo "[commit] ${label}: job ${jid} submitted, waiting for FIN..."
      xml="$(wait_job "${jid}")" || { printf '%s\n' "${xml}"; return 1; }
      # Robust result check for commit-all: a CommitAll response carries a
      # job-level <result> AND one per pushed device, so a greedy single-<result>
      # extraction is unreliable (it can latch onto a per-device entry or trailing
      # <warnings>/<details> text and mis-report a fully-OK push as failed,
      # notably on multi-region template-stack pushes). Treat the job as
      # successful when it reached FIN (guaranteed by wait_job) and NO <result>
      # anywhere is FAIL. grep the FIRST <result> only for the log line.
      if printf '%s' "${xml}" | grep -oE '<result>[^<]*</result>' | grep -q '<result>FAIL</result>'; then
        echo "[commit] ${label}: job ${jid} FAILED:"; printf '%s\n' "${xml}"
        return 1
      fi
      result="$(printf '%s' "${xml}" | grep -oE '<result>[^<]*</result>' | head -1 | sed -E 's:</?result>::g')"
      echo "[commit] ${label}: job ${jid} succeeded (result=${result:-OK})"
      return 0
    }

    ok=0
    run_commit "commit" "<commit></commit>" || ok=1
    ca="<commit-all><shared-policy><device-group><entry name=\"${DG}\"/></device-group></shared-policy></commit-all>"
    run_commit "commit-all/device-group ${DG}" "${ca}" "action=all" || ok=1
    ct="<commit-all><template-stack><name>${TS}</name></template-stack></commit-all>"
    run_commit "commit-all/template-stack ${TS}" "${ct}" "action=all" || ok=1

    if [ "${ok}" -ne 0 ]; then
      echo "[commit] one or more commit/push steps FAILED — see output above"
      exit 1
    fi
    echo "[commit] all commit/push steps succeeded"
    ;;
  *) echo "usage: $0 {ssh|tunnel|commit}"; exit 2;;
esac
