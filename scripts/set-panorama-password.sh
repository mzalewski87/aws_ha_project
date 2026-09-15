#!/usr/bin/env bash
###############################################################################
# set-panorama-password.sh — invoked by Terraform (terraform_data local-exec).
#
# WHY: PAN-OS on AWS has no platform admin-password injection like Azure's
# admin_password (EC2 has no password field, and Panorama on AWS has NO
# bootstrap — PANW's documented procedure is "SSH with the EC2 key, then set the
# password"). This automates exactly that one unavoidable step so
# `terraform apply` is hands-off, matching the Azure experience.
#
# Flow: SSM port-forward jump-host -> Panorama:22, wait for SSH, set the admin
# password via native PAN-OS ops (request password-hash -> set mgt-config users
# <user> phash -> commit), then verify via an API keygen. Idempotent.
#
# Inputs (env, so the secret never lands in argv / process list):
#   AWS_REGION, JUMP (jump-host instance id), PANO_IP, KEY_FILE,
#   PANO_USER (default admin), PANO_PASSWORD
###############################################################################
set -euo pipefail

: "${JUMP:?JUMP (jump-host instance id) required}"
: "${PANO_IP:?PANO_IP required}"
: "${PANO_PASSWORD:?PANO_PASSWORD required}"
KEY_FILE="${KEY_FILE:?KEY_FILE (SSH private key path) required}"
PANO_USER="${PANO_USER:-admin}"
LP="${SSH_LOCAL_PORT:-2299}"
VP="${API_LOCAL_PORT:-24430}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"

KEY_FILE="${KEY_FILE/#\~/$HOME}"                       # expand leading ~
if [ ! -f "${KEY_FILE}" ]; then
  echo "[set-pw] ERROR: SSH private key not found: ${KEY_FILE}" >&2
  echo "        Set ssh_private_key_file, or place the key at ~/.ssh/<key_name>.pem" >&2
  exit 1
fi
for bin in aws ssh session-manager-plugin curl python3 openssl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[set-pw] ERROR: '$bin' not found in PATH" >&2; exit 1; }
done

SSH_OPTS=(-i "${KEY_FILE}" -p "${LP}"
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR
  -o ConnectTimeout=10 -o PreferredAuthentications=publickey)

SSM_PID=""; API_PID=""
cleanup() { kill "${SSM_PID}" "${API_PID}" 2>/dev/null || true; }
trap cleanup EXIT

echo "[set-pw] opening SSM tunnel ${JUMP} -> ${PANO_IP}:22 (local ${LP})"
aws ssm start-session --target "${JUMP}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${PANO_IP}\"],\"portNumber\":[\"22\"],\"localPortNumber\":[\"${LP}\"]}" \
  >"/tmp/ssm-pano-ssh.$$.log" 2>&1 &
SSM_PID=$!

# Wait for SSH to answer through the tunnel. A COLD PAN-OS boot can take
# 15-25 min before the mgmt plane / SSH is up — and on large Panorama AMIs /
# constrained instance types genuinely >30 min (live-hit). Default budget is
# ~45 min (270 x 10s); override with PANO_SSH_WAIT_TRIES for slower boots. If it
# still times out, the infra is fine — just re-run the Phase 1a apply
# (the provisioner is idempotent) once Panorama's API answers.
WAIT_TRIES="${PANO_SSH_WAIT_TRIES:-270}"
echo "[set-pw] waiting for Panorama SSH (up to $((WAIT_TRIES * 10 / 60)) min; cold PAN-OS boot is slow)..."
ready=0
for _ in $(seq 1 "${WAIT_TRIES}"); do
  if ssh "${SSH_OPTS[@]}" "${PANO_USER}@127.0.0.1" 'exit' >/dev/null 2>&1; then ready=1; break; fi
  sleep 10
done
if [ "${ready}" -ne 1 ]; then
  echo "[set-pw] ERROR: SSH to Panorama never became ready after $((WAIT_TRIES * 10 / 60)) min." >&2
  echo "[set-pw] The infra is fine — re-run the Phase 1a apply once Panorama's mgmt plane is up (idempotent)." >&2
  tail -n 20 "/tmp/ssm-pano-ssh.$$.log" >&2 || true
  exit 1
fi

# 1) Hash the password locally as MD5-crypt ($1$...). PAN-OS SSH ignores
#    exec-style commands (`ssh host 'cmd'` just prints "Welcome admin."), so we
#    must NOT try `request password-hash` over ssh-exec — generate it here and
#    set it via phash (which takes the hash as an argument, no interactive
#    password prompt). PAN-OS accepts the $1$ MD5-crypt format.
echo "[set-pw] generating MD5-crypt password hash locally"
HASH="$(openssl passwd -1 "${PANO_PASSWORD}" 2>/dev/null || true)"
if [ -z "${HASH}" ]; then
  echo "[set-pw] ERROR: could not generate password hash (openssl passwd -1 failed)" >&2
  exit 1
fi

# 2) Apply the hash to the admin user and commit. Must use an interactive pty
#    (-tt) fed by a here-doc; PAN-OS does not run ssh-exec commands.
#
#    CRITICAL: do NOT close stdin right after `commit`. A commit on a freshly
#    booted Panorama runs for several MINUTES; feeding `exit` (or letting the
#    here-doc EOF) tears the session down before the commit finishes, so the
#    password silently never takes effect. Instead hold stdin open with a long
#    sleep and let step 3 kill the session as soon as the API confirms the new
#    password — that is the real "commit finished" signal.
echo "[set-pw] setting admin phash + commit (holding the session open until the commit lands)"
{
  printf 'set cli pager off\n'
  printf 'configure\n'
  printf 'set mgt-config users %s phash %s\n' "${PANO_USER}" "${HASH}"
  printf 'commit description "terraform: set admin password"\n'
  sleep "${PANO_COMMIT_WAIT:-900}"
} | ssh -tt "${SSH_OPTS[@]}" "${PANO_USER}@127.0.0.1" >"/tmp/ssm-pano-set.$$.log" 2>&1 &
SET_PID=$!
# make sure the held-open SSH session is reaped even on an early exit
cleanup() { kill "${SSM_PID}" "${API_PID}" "${SET_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT

# 3) Verify the new password authenticates against the API (what Phase 2a needs).
#    This doubles as the commit-completion probe, so the budget must comfortably
#    exceed a cold-boot commit (default 20 min).
echo "[set-pw] verifying API keygen with the new password"
aws ssm start-session --target "${JUMP}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${PANO_IP}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"${VP}\"]}" \
  >"/tmp/ssm-pano-api.$$.log" 2>&1 &
API_PID=$!
ENC_PW="$(PW="${PANO_PASSWORD}" python3 -c 'import urllib.parse,os;print(urllib.parse.quote(os.environ["PW"],safe=""))')"
VERIFY_TRIES="${PANO_VERIFY_TRIES:-240}" # 240 x 5s = 20 min
ok=0
for _ in $(seq 1 "${VERIFY_TRIES}"); do
  resp="$(curl -sk --max-time 8 "https://127.0.0.1:${VP}/api/?type=keygen&user=${PANO_USER}&password=${ENC_PW}" 2>/dev/null || true)"
  if printf '%s' "${resp}" | grep -q "<key>"; then ok=1; break; fi
  sleep 5
done
kill "${SET_PID}" 2>/dev/null || true
if [ "${ok}" -eq 1 ]; then
  echo "[set-pw] OK: admin password is set and the API authenticates."
else
  # MUST fail hard. Exiting 0 here makes Terraform record
  # terraform_data.set_admin_password as complete, so re-running Phase 1a is a
  # no-op and the failure resurfaces much later as an opaque Phase 2a
  # "API Error: Invalid Credential" (403).
  echo "[set-pw] ERROR: admin password did not take effect — API keygen still fails" >&2
  echo "        after $((VERIFY_TRIES * 5 / 60)) min. Last 20 lines of the SSH session:" >&2
  # REDACT before printing: PAN-OS runs on a pty and echoes every command back,
  # so this log contains the literal `set mgt-config users <user> phash $1$...`
  # line. That is the MD5-crypt hash of the Panorama admin password — cheap to
  # crack — and this tail goes to stderr, i.e. into Terraform/CI output. Strip
  # the hash (and any stray $1$/$5$/$6$ crypt string) before it is shown.
  tail -n 20 "/tmp/ssm-pano-set.$$.log" 2>/dev/null \
    | sed -E -e 's/(phash)[[:space:]]+[^[:space:]]+/\1 <redacted>/g' \
             -e 's/\$[0-9a-z]+\$[^[:space:]]+/<redacted-hash>/g' >&2 || true
  exit 1
fi
