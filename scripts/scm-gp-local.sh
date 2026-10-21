#!/usr/bin/env bash
###############################################################################
# scm-gp-local.sh — GlobalProtect portal + gateway for path B (Strata Cloud Manager).
#
# WHY LOCAL: SCM's public API has no NGFW GlobalProtect portal/gateway object (only
# /gp-tunnel-settings), so these live in the firewall's LOCAL configuration, written
# through the PAN-OS XML API. Live-verified on PAN-OS 12.2.3:
#   * local config SURVIVES pushes from SCM,
#   * local config is NOT replicated between the two SCM-managed HA peers (the local commit
#     warns "not synchronized to the HA peer"), so every mode must run on EACH unit,
#   * after a forced failover the same public address keeps serving the portal (once both
#     units have been built).
# Everything else GP needs (tunnel interface, vpn zone, loopback bind address, ARE
# routing, policy incl. the inbound-GP allow) is in phase2-scm-config.
#
# Modes:
#   admin       create the temporary local superuser `gpapi` (SSH + commit)
#   build       certificate (self-signed bootstrap), TLS profile, local auth, tunnel node,
#               gateway, portal; commit polled to completion
#   letsencrypt replace the bootstrap cert with the Let's Encrypt one from the root module
#               (terraform output custom_domain_cert_pem / _key_pem)
#   cleanup     delete the `gpapi` superuser again
#   content     download + install the latest Apps+Threats and Antivirus content (needs `admin`
#               first). A fresh firewall has NO threat content, and the predefined IP lists that
#               Advanced IP Defense rules use (panw-aipd-*) come with it: until it is installed an
#               SCM push with ip_defense_mode != off fails validation (seen live, Region B).
#
# Target: FW_IP if set (run once per unit: FW_IP=<unit 1>, then FW_IP=<unit 2>), else the
# ACTIVE unit of the pair given by MGMT_IPS (or of the whole tenant if MGMT_IPS is empty —
# set MGMT_IPS as soon as there is more than one pair, e.g. a second region).
#
# Required env (never commit values; keep them in an untracked file):
#   SCM_TSG_ID SCM_CLIENT_ID SCM_CLIENT_SECRET     (see scm-lib.sh)
#   GPAPI_PASSWORD     password of the temporary `gpapi` admin
#   GP_USER_PASSWORD   password of the GP test user (`gpuser`)
#   JUMP_INSTANCE_ID   SSM jump host (root output ssm_jumphost_instance_id)
#   KEY_FILE           SSH private key (for `admin`/`cleanup`, which use the CLI)
# Optional: GW_NAME PORTAL_NAME CERT_CN FLOATING IP_POOL SPLIT_ROUTES MGMT_IPS FW_IP
#   GATEWAYS  the portal's external gateways, space-separated "fqdn[:priority]" (default: GW_FQDN
#             with priority 1). Multi-region: GATEWAYS="gw-a.<zone>:1 gw-b.<zone>:2" on the
#             portal units of BOTH regions; clients then pick the best-available gateway.
#
# Usage: scm-gp-local.sh <admin|build|letsencrypt|cleanup>
###############################################################################
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scm-lib.sh
source "$HERE/scm-lib.sh"

MODE="${1:?usage: $0 <admin|build|letsencrypt|cleanup|content>}"
: "${JUMP_INSTANCE_ID:?JUMP_INSTANCE_ID required}"

GW_NAME="${GW_NAME:-gp-gateway-eu-central}"
PORTAL_NAME="${PORTAL_NAME:-gp-portal}"
GW_FQDN="${GW_FQDN:?GW_FQDN required (e.g. gw-a.<your zone>)}"
CERT_CN="${CERT_CN:?CERT_CN required (portal FQDN, e.g. gp.<your zone>)}"
FLOATING="${FLOATING:-10.10.10.100/32}"      # the /32 on the loopback (SCM $untrust_floating)
IP_POOL="${IP_POOL:-10.10.200.0/24}"
SPLIT_ROUTES="${SPLIT_ROUTES:-0.0.0.0/0}"
# What the client's GlobalProtect adapter receives. To JOIN a machine to the AD domain over the
# VPN it needs both: the domain as DNS suffix AND a DNS server that can resolve it (the domain
# controller; the AWS VPC resolver does not know the AD zone). Without a suffix the adapter shows
# an empty "Connection-specific DNS Suffix" (seen live).
DNS_SERVER_PRIMARY="${DNS_SERVER_PRIMARY:-10.13.0.10}"   # the DC (root output dc_private_ip)
DNS_SERVER_SECONDARY="${DNS_SERVER_SECONDARY:-}"         # e.g. a second DC
DNS_SUFFIX="${DNS_SUFFIX:-panw.labs}"                    # root var dc_domain_name
TUN_IF="tunnel.1"; LOCAL_IF="loopback.1"     # SCM $gp_tunnel / $gp_loopback default_value
GPUSER="${GPUSER:-gpuser}"
LP="${LP:-22292}"

# Active unit = the connected device whose SCM ha_state is "active" (within MGMT_IPS, if set).
active_fw_ip() {
  scm_api GET "/config/setup/v1/devices?limit=500" \
    | jq -r --arg ips "${MGMT_IPS:-}" '($ips | split(" ") | map(select(. != ""))) as $want
        | (.data // []) | map(select(.is_connected == true and .ha_state == "active"
            and (($want | length) == 0 or (.ip_address as $i | $want | index($i)) != null)))
        | first | .ip_address // empty'
}
FW_IP="${FW_IP:-$(active_fw_ip)}"
[ -n "$FW_IP" ] || scm_die "no connected ACTIVE firewall found in SCM"
scm_log "active firewall: $FW_IP"

SSM_LOG="$(mktemp "${TMPDIR:-/tmp}/scm-gp-ssm.XXXXXX")"

open_tunnel() {  # $1 = remote port
  if nc -z -G 2 127.0.0.1 "$LP" >/dev/null 2>&1; then scm_die "local port $LP already in use (stale SSM tunnel?)"; fi
  aws ssm start-session --target "$JUMP_INSTANCE_ID" --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$FW_IP\"],\"portNumber\":[\"$1\"],\"localPortNumber\":[\"$LP\"]}" >"$SSM_LOG" 2>&1 &
  SSM_PID=$!
  # Kill the aws wrapper AND its session-manager-plugin child, or the port stays bound.
  trap 'kill $SSM_PID 2>/dev/null || true; pkill -f "session-manager-plugin.*$LP" 2>/dev/null || true; [ -n "${TMPD:-}" ] && rm -rf "$TMPD"; [ -n "${F:-}" ] && rm -f "$F"; rm -f "$SSM_LOG"' EXIT
}

cli_file() {  # $1 = file of CLI commands; runs them over SSH (admin/cleanup only)
  : "${KEY_FILE:?KEY_FILE required}"
  local opts=(-i "$KEY_FILE" -p "$LP" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
              -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=60 -o PreferredAuthentications=publickey)
  open_tunnel 22
  # A VM-Series answers the SSH banner slowly right after a commit or boot: 10 s / 15 s limits
  # produced "banner exchange timed out" on every attempt (seen live).
  for _ in $(seq 1 8); do perl -e 'alarm 70; exec @ARGV' ssh "${opts[@]}" admin@127.0.0.1 exit >/dev/null 2>&1 && break; sleep 4; done
  # The interactive SSH session does not close after the file's `exit`, so the alarm below ends
  # it (exit 142) even when everything worked — judge success by the firewall's own message,
  # not by the exit code (the exit code made every successful run look like a failure).
  local out
  # 480 s: a commit on a freshly onboarded unit (right after an SCM push / HA sync) took over
  # 3 minutes live, and a 240 s limit cut the session while the commit was still running.
  out="$(perl -e 'alarm shift; exec @ARGV' 480 ssh -tt "${opts[@]}" admin@127.0.0.1 < "$1" 2>&1 | tr -d '\r' || true)"
  grep -E "committed|Commit|rror|nvalid" <<<"$out" | head -8 || true
  if ! grep -q "Configuration committed successfully" <<<"$out"; then
    job="$(sed -nE 's/.*Commit job ([0-9]+) is in progress.*/\1/p' <<<"$out" | head -1)"
    [ -n "$job" ] && scm_die "commit job $job on $FW_IP was still running when the session ended; check it ('show jobs id $job') before re-running"
    scm_die "no 'Configuration committed successfully' from $FW_IP"
  fi
}

api_login() {
  : "${GPAPI_PASSWORD:?GPAPI_PASSWORD required (run the admin mode first)}"
  open_tunnel 443
  BASE="https://127.0.0.1:$LP/api/"
  for _ in $(seq 1 40); do
    c="$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$LP/php/login.php" 2>/dev/null || true)"
    case "$c" in 200|302) break;; esac; sleep 6
  done
  # `|| true`: with set -e + pipefail a grep that finds no <key> would end the script SILENTLY
  # before the check below (seen live: both units "FAILED" with no message at all).
  # POST with the password read from stdin: never in a URL (logs) or on curl's command line (ps).
  KEY="$(printf '%s' "$GPAPI_PASSWORD" | curl -sk -m 60 "$BASE" --data-urlencode type=keygen \
         --data-urlencode user=gpapi --data-urlencode "password@-" | grep -o '<key>[^<]*' | cut -c6- || true)"
  [ -n "$KEY" ] || scm_die "no API key from $FW_IP: the gpapi admin does not exist on THIS unit (local config is per unit — run '$0 admin' with FW_IP=$FW_IP) or its management API is not up yet"
}

ok() { grep -q 'status="success"' <<<"$1"; }

# Commit and POLL the job. The result is the first NON-EMPTY <result> (the response
# wrapper contributes an empty one), and the details are printed on failure.
commit_wait() {
  local r job j st res
  r="$(curl -sk -m 60 "$BASE" --data-urlencode type=commit --data-urlencode "cmd=<commit></commit>" --data-urlencode "key=$KEY")"
  job="$(grep -o '<job>[0-9]*' <<<"$r" | cut -c6-)"
  [ -n "$job" ] || scm_die "no commit job id: $r"
  for _ in $(seq 1 90); do
    j="$(curl -sk -m 60 "$BASE" --data-urlencode type=op --data-urlencode "cmd=<show><jobs><id>$job</id></jobs></show>" --data-urlencode "key=$KEY")"
    st="$(grep -o '<status>[A-Z]*' <<<"$j" | head -1 | cut -c9-)"
    res="$(grep -o '<result>[A-Za-z][A-Za-z]*' <<<"$j" | head -1 | cut -c9-)"
    scm_log "commit $job status=${st:-?} result=${res:-?}"
    if [ "$st" = "FIN" ]; then
      [ "$res" = "OK" ] && { scm_log "COMMIT OK"; return 0; }
      # BSD sed has no \n in replacements: turn tags into line breaks with tr instead.
      sed -E 's/<[^>]+>/|/g' <<<"$j" | tr '|' '\n' | grep -vE '^[[:space:]]*$' | head -40 >&2 || true
      scm_die "commit failed"
    fi
    sleep 10
  done
  scm_die "commit did not finish in time"
}

VS="/config/devices/entry[@name='localhost.localdomain']/vsys/entry[@name='vsys1']"
NET="/config/devices/entry[@name='localhost.localdomain']/network"

case "$MODE" in
admin)
  : "${GPAPI_PASSWORD:?GPAPI_PASSWORD required}"
  F="$(umask 077; mktemp)"   # holds the password hash; removed below and by the EXIT trap
  printf 'set cli pager off\nconfigure\nset mgt-config users gpapi phash %s\nset mgt-config users gpapi permissions role-based superuser yes\ncommit description gpapiadmin\ny\nexit\nexit\n' \
    "$(printf '%s' "$GPAPI_PASSWORD" | openssl passwd -1 -stdin)" > "$F"
  cli_file "$F"; rm -f "$F" ;;

cleanup)
  F="$(mktemp)"
  printf 'set cli pager off\nconfigure\ndelete mgt-config users gpapi\ncommit description removegpapi\ny\nexit\nexit\n' > "$F"
  cli_file "$F"; rm -f "$F" ;;

build)
  : "${GP_USER_PASSWORD:?GP_USER_PASSWORD required}"
  api_login
  FAILED=0
  setcfg() {  # xpath element label
    local r i
    # "A commit is pending" = a job holds the config (live: on an active unit, every content
    # download (e.g. Frontier Virtual Patching, every few minutes) triggers an HA-Sync that
    # takes ~2 min). Wait it out instead of failing the whole build.
    for i in $(seq 1 20); do
      r="$(curl -sk -m 120 "$BASE" --data-urlencode type=config --data-urlencode action=set \
           --data-urlencode "xpath=$1" --data-urlencode "element=$2" --data-urlencode "key=$KEY")"
      grep -q "A commit is pending" <<<"$r" || break
      [ "$i" = 1 ] && scm_log "WAIT  $3: a commit/HA-sync job is running, retrying every 15 s"
      sleep 15
    done
    if ok "$r"; then scm_log "OK    $3"; else scm_log "FAIL  $3: $r"; FAILED=1; fi
  }
  # 1) Bootstrap certificate. A self-signed cert with identical subject/issuer MUST be a CA,
  #    and a CA cert has keyUsage "Certificate Sign" only, which browsers reject for TLS
  #    (ERR_SSL_KEY_USAGE_INCOMPATIBLE) — so this is only a placeholder until `letsencrypt`.
  #    IDEMPOTENCE: `build` is re-run whenever the GP settings change (e.g. DNS). If the real
  #    certificate (gp-le, from `letsencrypt`) is already on the unit it must stay in use —
  #    re-pointing the profile at the placeholder silently broke a working, trusted portal.
  # Look in vsys1 AND shared: an import without a vsys parameter can land in /config/shared.
  le=""
  for loc in "$VS" "/config/shared"; do
    le="$le$(curl -sk -m 60 "$BASE" --data-urlencode type=config --data-urlencode action=get \
          --data-urlencode "xpath=$loc/certificate/entry[@name='gp-le']" --data-urlencode "key=$KEY" || true)"
  done
  if grep -q 'name="gp-le"' <<<"$le"; then
    CERT_USE="gp-le"; scm_log "OK    certificate gp-le already present — keeping it (bootstrap certificate skipped)"
  else
    CERT_USE="gp-cert"
    r="$(curl -sk -m 180 "$BASE" --data-urlencode type=op --data-urlencode "key=$KEY" \
         --data-urlencode "cmd=<request><certificate><generate><certificate-name>gp-cert</certificate-name><name>$CERT_CN</name><algorithm><RSA><rsa-nbits>2048</rsa-nbits></RSA></algorithm><days-till-expiry>825</days-till-expiry><ca>yes</ca></generate></certificate></request>")"
    if ok "$r" || grep -qi 'already exists' <<<"$r"; then scm_log "OK    bootstrap certificate"; else scm_log "FAIL  certificate: $r"; FAILED=1; fi
  fi
  setcfg "$VS/ssl-tls-service-profile/entry[@name='gp-ssl-tls']" \
    "<certificate>$CERT_USE</certificate><protocol-settings><min-version>tls1-2</min-version><max-version>tls1-2</max-version></protocol-settings>" "ssl-tls profile"
  setcfg "$VS/local-user-database/user/entry[@name='$GPUSER']" "<phash>$(printf '%s' "$GP_USER_PASSWORD" | openssl passwd -1 -stdin)</phash>" "local user $GPUSER"
  setcfg "$VS/authentication-profile/entry[@name='gp-local']" \
    "<method><local-database/></method><allow-list><member>all</member></allow-list>" "authentication profile"
  # 2) Second config subtree of a tunnel-mode gateway (network/tunnel/global-protect-gateway);
  #    without it the commit fails with `gp_broker: <local-address> tag does not exist`.
  setcfg "$NET/tunnel/global-protect-gateway/entry[@name='${GW_NAME}-tun']" \
    "<local-address><interface>$LOCAL_IF</interface><ip-address-family>ipv4</ip-address-family></local-address><tunnel-interface>$TUN_IF</tunnel-interface>" "tunnel node"
  # 3) Client IP pool in EXACTLY one place (remote-user-tunnel-configs), never also at gateway level.
  setcfg "$VS/global-protect/global-protect-gateway/entry[@name='$GW_NAME']" \
    "<tunnel-mode>yes</tunnel-mode><local-address><interface>$LOCAL_IF</interface><ip-address-family>ipv4</ip-address-family><ip><ipv4>$FLOATING</ipv4></ip></local-address><ssl-tls-service-profile>gp-ssl-tls</ssl-tls-service-profile><remote-user-tunnel>$TUN_IF</remote-user-tunnel><client-auth><entry name=\"default\"><authentication-profile>gp-local</authentication-profile><os>Any</os></entry></client-auth><remote-user-tunnel-configs><entry name=\"gp-tunnel-config\"><ip-pool><member>$IP_POOL</member></ip-pool><split-tunneling><access-route><member>$SPLIT_ROUTES</member></access-route></split-tunneling><dns-server><member>$DNS_SERVER_PRIMARY</member>${DNS_SERVER_SECONDARY:+<member>$DNS_SERVER_SECONDARY</member>}</dns-server><dns-suffix><member>$DNS_SUFFIX</member></dns-suffix></entry></remote-user-tunnel-configs>" "gateway"
  # 4) The portal needs the three custom pages or the commit fails ("is missing 'custom-*-page'").
  #    Its external gateways: GATEWAYS ("fqdn[:priority] ..."), else GW_FQDN alone. An IP
  #    would go in <ip>, not <fqdn> ("fqdn <ip> is invalid" — path A); these are FQDNs.
  GW_ENTRIES=""
  for g in ${GATEWAYS:-$GW_FQDN:1}; do
    fq="${g%%:*}"; pr="${g##*:}"; [ "$pr" = "$g" ] && pr=1
    [[ "$fq" =~ ^[A-Za-z0-9.-]+$ && "$pr" =~ ^[0-9]+$ ]] || scm_die "bad GATEWAYS entry: $g"
    GW_ENTRIES="$GW_ENTRIES<entry name=\"${fq%%.*}\"><fqdn>$fq</fqdn><priority-rule><entry name=\"Any\"><priority>$pr</priority></entry></priority-rule></entry>"
  done
  setcfg "$VS/global-protect/global-protect-portal/entry[@name='$PORTAL_NAME']" \
    "<portal-config><custom-login-page>factory-default</custom-login-page><custom-home-page>factory-default</custom-home-page><custom-help-page>factory-default</custom-help-page><ssl-tls-service-profile>gp-ssl-tls</ssl-tls-service-profile><local-address><interface>$LOCAL_IF</interface><ip-address-family>ipv4</ip-address-family><ip><ipv4>$FLOATING</ipv4></ip></local-address><client-auth><entry name=\"default\"><authentication-profile>gp-local</authentication-profile><os>Any</os></entry></client-auth></portal-config><client-config><configs><entry name=\"default\"><gateways><external><list>$GW_ENTRIES</list></external></gateways></entry></configs></client-config>" "portal"
  [ "$FAILED" = "0" ] || scm_die "a step failed — not committing"
  commit_wait ;;

letsencrypt)
  CERT="$(terraform -chdir="$HERE/.." output -raw custom_domain_cert_pem 2>/dev/null || true)"
  KEYP="$(terraform -chdir="$HERE/.." output -raw custom_domain_cert_key_pem 2>/dev/null || true)"
  grep -q 'BEGIN CERTIFICATE' <<<"$CERT" || scm_die "no Let's Encrypt cert in the root outputs (custom_domain_cert_mode = letsencrypt, then apply)"
  umask 077; TMPD="$(mktemp -d)"
  printf '%s\n' "$CERT" > "$TMPD/c.pem"; printf '%s\n' "$KEYP" > "$TMPD/k.pem"
  PASS="$(openssl rand -hex 12)"
  api_login
  r="$(curl -sk -m 120 "${BASE}?type=import&category=certificate&certificate-name=gp-le&format=pem&key=$KEY" -F "file=@$TMPD/c.pem")"; ok "$r" || scm_die "certificate import: $r"
  r="$(curl -sk -m 120 "${BASE}?type=import&category=private-key&certificate-name=gp-le&format=pem&passphrase=$PASS&key=$KEY" -F "file=@$TMPD/k.pem")"; ok "$r" || scm_die "key import: $r"
  r="$(curl -sk -m 60 "$BASE" --data-urlencode type=config --data-urlencode action=edit \
       --data-urlencode "xpath=$VS/ssl-tls-service-profile/entry[@name='gp-ssl-tls']" \
       --data-urlencode "element=<entry name=\"gp-ssl-tls\"><certificate>gp-le</certificate><protocol-settings><min-version>tls1-2</min-version><max-version>tls1-2</max-version></protocol-settings></entry>" \
       --data-urlencode "key=$KEY")"
  ok "$r" || scm_die "TLS profile: $r (\"A commit is pending\" = another commit is running; retry)"
  curl -sk -m 60 "$BASE" --data-urlencode type=config --data-urlencode action=delete \
       --data-urlencode "xpath=$VS/certificate/entry[@name='gp-cert']" --data-urlencode "key=$KEY" >/dev/null || true
  commit_wait ;;

content)
  api_login
  job_wait() {  # $1 = op XML that starts a job; $2 = label
    local r job j st res
    r="$(curl -sk -m 120 "$BASE" --data-urlencode type=op --data-urlencode "cmd=$1" --data-urlencode "key=$KEY")"
    job="$(grep -o '<job>[0-9]*' <<<"$r" | cut -c6-)"
    if [ -z "$job" ]; then
      grep -qi "already\|no update\|up to date\|is the latest" <<<"$r" && { scm_log "OK    $2: nothing to do"; return 0; }
      scm_die "$2 did not start: $(tr -d '\n' <<<"$r" | cut -c1-300)"
    fi
    for _ in $(seq 1 120); do
      j="$(curl -sk -m 60 "$BASE" --data-urlencode type=op --data-urlencode "cmd=<show><jobs><id>$job</id></jobs></show>" --data-urlencode "key=$KEY")"
      st="$(grep -o '<status>[A-Z]*' <<<"$j" | head -1 | cut -c9-)"
      res="$(grep -o '<result>[A-Za-z][A-Za-z]*' <<<"$j" | head -1 | cut -c9-)"
      if [ "$st" = "FIN" ]; then
        [ "$res" = "OK" ] && { scm_log "OK    $2 (job $job)"; return 0; }
        scm_die "$2 failed (job $job): $(sed -E 's/<[^>]+>/ /g' <<<"$j" | tr -s ' ' | cut -c1-400)"
      fi
      sleep 10
    done
    scm_die "$2 did not finish in time (job $job)"
  }
  # "check" refreshes the list of available versions; it answers directly (no job).
  curl -sk -m 120 "$BASE" --data-urlencode type=op --data-urlencode "cmd=<request><content><upgrade><check/></upgrade></content></request>" --data-urlencode "key=$KEY" >/dev/null || true
  job_wait "<request><content><upgrade><download><latest/></download></upgrade></content></request>" "Apps+Threats download"
  job_wait "<request><content><upgrade><install><version>latest</version></install></upgrade></content></request>" "Apps+Threats install"
  curl -sk -m 120 "$BASE" --data-urlencode type=op --data-urlencode "cmd=<request><anti-virus><upgrade><check/></upgrade></anti-virus></request>" --data-urlencode "key=$KEY" >/dev/null || true
  job_wait "<request><anti-virus><upgrade><download><latest/></download></upgrade></anti-virus></request>" "Antivirus download"
  job_wait "<request><anti-virus><upgrade><install><version>latest</version></install></upgrade></anti-virus></request>" "Antivirus install" ;;

*) scm_die "unknown mode '$MODE'" ;;
esac
