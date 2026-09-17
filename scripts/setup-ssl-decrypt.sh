#!/usr/bin/env bash
###############################################################################
# setup-ssl-decrypt.sh — give PAN-OS its own subordinate CA and stage the SSL
# Forward Proxy configuration. Decryption is created DISABLED.
#
# The firewall generates its own key and CSR; the AD CS issuing CA signs it as a
# subordinate. The forward-trust key therefore never exists anywhere but the
# firewall, and revoking it does not touch the AD PKI. (Exporting the issuing
# CA's own key into Panorama would be the easy path and the wrong one.)
#
# Two certificates are involved, and confusing them is the classic mistake:
#   forward-TRUST  - the CA the firewall re-signs with when the real server
#                    certificate is VALID. Clients must trust its chain.
#   forward-UNTRUST- a CA nobody trusts, used deliberately when the real server
#                    certificate is BAD, so the user still gets a warning
#                    instead of the firewall laundering a broken site into a
#                    trusted-looking one.
#
# Env: PANORAMA_HOST/PORT/USER/PASSWORD, TEMPLATE, DEVICE_GROUP,
#      SUB_CA_ID (SSM id of the issuing CA), AWS_REGION
###############################################################################
set -euo pipefail

MODE="${1:-setup}"   # setup | enable | disable

H="${PANORAMA_HOST:-127.0.0.1}"; P="${PANORAMA_PORT:-44300}"
U="${PANORAMA_USER:-admin}"; PW="${PANORAMA_PASSWORD:?PANORAMA_PASSWORD required}"
TPL="${TEMPLATE:-AWS-Transit-Template}"
DG="${DEVICE_GROUP:-AWS-Transit-DG}"
VSYS="${VSYS:-vsys1}"
SUB_ID="${SUB_CA_ID:?SUB_CA_ID required}"
REGION="${AWS_REGION:-eu-central-1}"
FT_NAME="${FORWARD_TRUST_NAME:-fwd-trust-ca}"
FU_NAME="${FORWARD_UNTRUST_NAME:-fwd-untrust-ca}"
BASE="https://${H}:${P}/api/"

say() { printf '[ssl-decrypt] %s\n' "$*"; }

KEY="$(curl -sk --max-time 20 --data-urlencode "type=keygen" --data-urlencode "user=${U}" \
      --data-urlencode "password=${PW}" "$BASE" | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
[ -n "$KEY" ] || { echo "[ssl-decrypt] Panorama keygen failed — is the tunnel up?" >&2; exit 1; }

api() { # $@ = --data-urlencode pairs
  curl -sk --max-time 60 "$@" --data-urlencode "key=${KEY}" "$BASE"
}

cfg_set() { # $1 = xpath, $2 = element, $3 = label
  local r; r="$(api --data-urlencode "type=config" --data-urlencode "action=set" \
                --data-urlencode "xpath=$1" --data-urlencode "element=$2")"
  printf '%s' "$r" | grep -q 'status="success"' \
    || { echo "[ssl-decrypt] FAILED ($3): $r" >&2; exit 1; }
  say "ok: $3"
}

TPL_PREFIX="/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='${TPL}']/config/devices/entry[@name='localhost.localdomain']"
VSYS_PREFIX="${TPL_PREFIX}/vsys/entry[@name='${VSYS}']"
DEC_XPATH="/config/devices/entry[@name='localhost.localdomain']/device-group/entry[@name='${DG}']/pre-rulebase/decryption/rules"

commit_push() {
  say "committing and pushing"
  DEVICE_GROUP="${DG}" TEMPLATE_STACK="${TEMPLATE_STACK:-AWS-Transit-Stack}" \
  PANORAMA_HOST="${H}" PANORAMA_PORT="${P}" PANORAMA_USER="${U}" PANORAMA_PASSWORD="${PW}" \
    "$(dirname "$0")/configure-panorama.sh" commit
}

toggle_rules() { # $1 = yes|no  (yes = disabled)
  for r in no-decrypt-sensitive decrypt-outbound; do
    cfg_set "${DEC_XPATH}/entry[@name='${r}']" "<disabled>$1</disabled>" "${r} disabled=$1"
  done
}

case "$MODE" in
  enable)
    say "ENABLING SSL Forward Proxy. Clients that do not trust the root CA will start seeing errors."
    toggle_rules no; commit_push
    say "decryption is LIVE"; exit 0 ;;
  disable)
    say "disabling SSL Forward Proxy"
    toggle_rules yes; commit_push
    say "decryption is OFF"; exit 0 ;;
  setup) ;;
  *) echo "usage: $0 [setup|enable|disable]" >&2; exit 2 ;;
esac

# --- 1. firewall generates its own CA key + CSR ------------------------------
say "generating a CSR for the forward-trust CA on the firewall"
GEN="$(api --data-urlencode "type=op" --data-urlencode "cmd=<request><certificate><generate>
<certificate-name>${FT_NAME}</certificate-name>
<name>${FT_NAME}</name>
<algorithm><RSA><rsa-nbits>2048</rsa-nbits></RSA></algorithm>
<digest>sha256</digest>
<ca>yes</ca>
<signed-by>external</signed-by>
</generate></certificate></request>")"
printf '%s' "$GEN" | grep -q 'success' \
  || { echo "[ssl-decrypt] CSR generation failed: $GEN" >&2; exit 1; }

CSR="$(api --data-urlencode "type=export" --data-urlencode "category=certificate" \
      --data-urlencode "certificate-name=${FT_NAME}" --data-urlencode "format=pkcs10")"
printf '%s' "$CSR" | grep -q "CERTIFICATE REQUEST" \
  || { echo "[ssl-decrypt] CSR export failed" >&2; exit 1; }
printf '%s' "$CSR" > /tmp/panos-fwd-trust.csr
say "CSR exported ($(wc -c < /tmp/panos-fwd-trust.csr) bytes)"

# --- 2. issuing CA signs it as a SUBORDINATE CA ------------------------------
say "submitting the CSR to the AD CS issuing CA"
CSR_B64="$(base64 < /tmp/panos-fwd-trust.csr | tr -d '\n')"
CID="$(aws ssm send-command --region "$REGION" --instance-ids "$SUB_ID" \
      --document-name AWS-RunPowerShellScript --timeout-seconds 600 \
      --parameters "commands=$(jq -Rs '[.]' <<PSEOF
\$ErrorActionPreference='Stop'
[IO.File]::WriteAllBytes('C:\\panos.req', [Convert]::FromBase64String('${CSR_B64}'))
Remove-Item 'C:\\panos.cer' -ErrorAction SilentlyContinue
# SubCA template => basicConstraints CA:TRUE, which is what PAN-OS needs in
# order to re-sign server certificates on the fly.
certreq -submit -attrib 'CertificateTemplate:SubCA' 'C:\\panos.req' 'C:\\panos.cer' | Out-Null
if (-not (Test-Path 'C:\\panos.cer')) { Write-Error 'CA did not issue the certificate'; exit 1 }
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\\panos.cer'))
PSEOF
)" --query 'Command.CommandId' --output text)"

for _ in $(seq 1 60); do
  ST="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" \
       --instance-id "$SUB_ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$ST" in Success|Failed|TimedOut|Cancelled) break ;; esac
  sleep 5
done
[ "$ST" = "Success" ] || {
  aws ssm get-command-invocation --region "$REGION" --command-id "$CID" \
    --instance-id "$SUB_ID" --query 'StandardErrorContent' --output text >&2
  echo "[ssl-decrypt] signing failed ($ST)" >&2; exit 1; }

aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$SUB_ID" \
  --query 'StandardOutputContent' --output text | tr -d '\r\n ' | base64 -d > /tmp/panos-fwd-trust.der
openssl x509 -inform DER -in /tmp/panos-fwd-trust.der -out /tmp/panos-fwd-trust.pem
say "signed: $(openssl x509 -in /tmp/panos-fwd-trust.pem -noout -subject)"

# --- 3. import the signed certificate back onto the firewall -----------------
say "importing the signed certificate back into Panorama"
IMP="$(curl -sk --max-time 60 -F "file=@/tmp/panos-fwd-trust.pem" \
      "${BASE}?type=import&category=certificate&certificate-name=${FT_NAME}&format=pem&key=${KEY}&target-tpl=${TPL}&target-tpl-vsys=${VSYS}")"
printf '%s' "$IMP" | grep -q 'success' \
  || { echo "[ssl-decrypt] import failed: $IMP" >&2; exit 1; }
say "forward-trust CA installed"

# --- 4. a forward-UNTRUST CA, self-signed on purpose -------------------------
# Deliberately NOT chained to the AD PKI: when the real server certificate is
# invalid the firewall re-signs with this, the client does not trust it, and the
# user sees the warning they should have seen. Without it, decryption would turn
# every broken certificate into a trusted-looking page.
say "creating the forward-untrust CA (intentionally untrusted)"
api --data-urlencode "type=op" --data-urlencode "cmd=<request><certificate><generate>
<certificate-name>${FU_NAME}</certificate-name><name>${FU_NAME}</name>
<algorithm><RSA><rsa-nbits>2048</rsa-nbits></RSA></algorithm>
<digest>sha256</digest><ca>yes</ca><signed-by>${FU_NAME}</signed-by>
</generate></certificate></request>" >/dev/null || true

cfg_set "${VSYS_PREFIX}/certificate/entry[@name='${FT_NAME}']" \
  "<forward-trust-certificate>yes</forward-trust-certificate>" "mark forward-trust"
cfg_set "${VSYS_PREFIX}/certificate/entry[@name='${FU_NAME}']" \
  "<forward-untrust-certificate>yes</forward-untrust-certificate>" "mark forward-untrust"

# --- 5. decryption profile ---------------------------------------------------
# Block the things interception must not silently paper over.
say "creating the decryption profile"
cfg_set "${VSYS_PREFIX}/profiles/decryption/entry[@name='fwd-proxy-strict']" \
  "<ssl-forward-proxy>
     <block-expired-certificate>yes</block-expired-certificate>
     <block-untrusted-issuer>yes</block-untrusted-issuer>
     <block-unknown-cert>no</block-unknown-cert>
   </ssl-forward-proxy>
   <ssl-protocol-settings>
     <min-version>tls1-2</min-version>
     <auth-algo-md5>no</auth-algo-md5>
     <auth-algo-sha1>no</auth-algo-sha1>
   </ssl-protocol-settings>" "decryption profile"

# --- 6. the rule itself — DISABLED --------------------------------------------
# Created but switched off, so the client machine can be domain-joined and pick
# up the root CA before anything is intercepted. Enable with:
#   scripts/setup-ssl-decrypt.sh enable
#
# no-decrypt exclusions come first and stay permanent: certificate-pinned and
# regulated traffic breaks under interception, it does not merely get inspected.
say "creating the decryption rules (disabled)"

cfg_set "${DEC_XPATH}/entry[@name='no-decrypt-sensitive']" \
  "<from><member>vpn</member><member>trust</member></from>
   <to><member>untrust</member></to>
   <source><member>any</member></source>
   <destination><member>any</member></destination>
   <service><member>any</member></service>
   <category>
     <member>financial-services</member>
     <member>health-and-medicine</member>
     <member>government</member>
   </category>
   <action>no-decrypt</action>
   <type><ssl-forward-proxy/></type>
   <disabled>yes</disabled>
   <description>Never intercept regulated categories. Keep ABOVE the decrypt rule.</description>" \
  "no-decrypt exclusions"

cfg_set "${DEC_XPATH}/entry[@name='decrypt-outbound']" \
  "<from><member>vpn</member><member>trust</member></from>
   <to><member>untrust</member></to>
   <source><member>any</member></source>
   <destination><member>any</member></destination>
   <service><member>any</member></service>
   <category><member>any</member></category>
   <action>decrypt</action>
   <type><ssl-forward-proxy/></type>
   <profile>fwd-proxy-strict</profile>
   <disabled>yes</disabled>
   <description>SSL Forward Proxy. DISABLED until clients trust the root CA.</description>" \
  "decrypt rule"

say "done. Both decryption rules exist and are DISABLED."
say "Enable later with: $0 enable"
