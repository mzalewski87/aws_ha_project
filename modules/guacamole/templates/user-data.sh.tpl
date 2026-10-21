#!/bin/bash
# Guacamole first-boot provisioning (rendered by Terraform; shell vars use $VAR
# only, never braces, so templatefile leaves them alone).
set -euo pipefail
exec > >(tee /var/log/guacamole-bootstrap.log) 2>&1

GUAC_VER=1.6.0
PG_VER=16
REGION="${region}"

dnf install -y docker jq
systemctl enable --now docker

# IMDSv2 is required on this host, but the AWS CLI handles that itself.
SECRET=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "${secret_id}" --query SecretString --output text)
ADMIN_PW=$(echo "$SECRET" | jq -r .password)
DB_PW=$(echo "$SECRET" | jq -r .db_password)
RDP_PW=$(echo "$SECRET" | jq -r .rdp_password)

docker network create guac || true
mkdir -p /opt/guacamole/init /opt/guacamole/pgdata
docker run --rm "guacamole/guacamole:$GUAC_VER" /opt/guacamole/bin/initdb.sh --postgresql > /opt/guacamole/init/001-schema.sql

docker run -d --name guac-db --network guac --restart always \
  -e POSTGRES_DB=guacamole_db -e POSTGRES_USER=guacamole_user -e POSTGRES_PASSWORD="$DB_PW" \
  -v /opt/guacamole/init:/docker-entrypoint-initdb.d:ro \
  -v /opt/guacamole/pgdata:/var/lib/postgresql/data \
  "postgres:$PG_VER"

docker run -d --name guacd --network guac --restart always "guacamole/guacd:$GUAC_VER"

# ORDER MATTERS (a first live boot got this wrong): with TOTP enabled even the very
# first REST login as guacadmin gets "TOTP required" instead of a token, so the
# bootstrap could not create the admin and aborted -- leaving the default
# guacadmin/guacadmin alive on an internet-facing host. So:
#   1. provision WITHOUT TOTP, with the container bound to 127.0.0.1 only, so the
#      ALB cannot reach it while the default password still exists;
#   2. create the admin, delete guacadmin, create the RDP connection;
#   3. recreate the container WITH TOTP on 0.0.0.0 (ALB health check goes green);
#   4. verify TOTP is really enforced and guacadmin is really gone -- otherwise
#      stop the container (fail closed) rather than serve an insecure login.
# EXTENSIONS / TOTP_ENABLED: the image documents one or the other depending on the
# release; setting both is harmless. [VERIFY on first live boot]
# (No bash arrays / braces here: templatefile would try to interpolate them.)
start_guac() {  # $1 = bind address, $2 = yes|no (TOTP)
  TOTP_ENV=""
  [ "$2" = "yes" ] && TOTP_ENV="-e EXTENSIONS=auth-totp -e TOTP_ENABLED=true"
  docker rm -f guacamole >/dev/null 2>&1 || true
  docker run -d --name guacamole --network guac --restart always -p "$1:8080:8080" \
    -e GUACD_HOSTNAME=guacd \
    -e POSTGRESQL_HOSTNAME=guac-db -e POSTGRESQL_DATABASE=guacamole_db \
    -e POSTGRESQL_USER=guacamole_user -e POSTGRESQL_PASSWORD="$DB_PW" \
    -e POSTGRESQL_AUTO_CREATE_ACCOUNTS=false \
    $TOTP_ENV \
    "guacamole/guacamole:$GUAC_VER"
}
wait_ready() {
  for i in $(seq 1 90); do
    curl -fs -o /dev/null "http://127.0.0.1:8080/guacamole/" && return 0
    sleep 5
  done
  echo "guacamole never became ready" >&2
  return 1
}

API=http://127.0.0.1:8080/guacamole/api

# token USER PASS -> prints a token, or returns non-zero (never the string "null").
token() {
  local t
  t="$(curl -fs -d "username=$1" --data-urlencode "password=$2" "$API/tokens" | jq -r '.authToken // empty')"
  [ -n "$t" ] || { echo "no auth token for $1" >&2; return 1; }
  printf '%s' "$t"
}

# 1) provisioning container: loopback only, no TOTP
start_guac 127.0.0.1 no
wait_ready

# 2) replace the well-known guacadmin/guacadmin account
T="$(token guacadmin guacadmin)"
jq -n --arg u "${admin_user}" --arg p "$ADMIN_PW" '{username:$u,password:$p,attributes:{}}' |
  curl -fs -X POST -H 'Content-Type: application/json' -d @- "$API/session/data/postgresql/users?token=$T" > /dev/null
echo '[{"op":"add","path":"/systemPermissions","value":"ADMINISTER"}]' |
  curl -fs -X PATCH -H 'Content-Type: application/json' -d @- "$API/session/data/postgresql/users/${admin_user}/permissions?token=$T" > /dev/null

T="$(token "${admin_user}" "$ADMIN_PW")"
curl -fs -X DELETE "$API/session/data/postgresql/users/guacadmin?token=$T" > /dev/null

# 2b) pre-provision the RDP connection to the DC. Credentials are only stored when
#     supplied; otherwise users type them at connect time.
jq -n --arg name "${rdp_target_name}" --arg host "${rdp_target_host}" \
      --arg dom "${rdp_target_domain}" --arg user "${rdp_username}" --arg pw "$RDP_PW" '
  {parentIdentifier:"ROOT", name:$name, protocol:"rdp", attributes:{},
   parameters: ({hostname:$host, port:"3389", security:"nla", "ignore-cert":"true",
                 "resize-method":"display-update", "enable-wallpaper":"false"}
                + (if $dom  != "" then {domain:$dom}     else {} end)
                + (if $user != "" then {username:$user}  else {} end)
                + (if $pw   != "" then {password:$pw}    else {} end))}' |
  curl -fs -X POST -H 'Content-Type: application/json' -d @- "$API/session/data/postgresql/connections?token=$T" > /dev/null
%{ if ldap_enabled ~}

# 2c) AD login (LDAP). Everything LDAP lives in this one optional block, so a deployment
#     without it renders exactly the user_data it had before (any change replaces the host
#     and wipes its database). Guacamole matches a user's AD groups to DB user groups BY
#     NAME, so a DB group named like the AD group, holding the DC connection, means AD
#     membership alone grants access -- nobody is added by hand in Guacamole.
CONN_ID=$(curl -fs "$API/session/data/postgresql/connections?token=$T" |
  jq -r --arg n "${rdp_target_name}" 'to_entries[] | select(.value.name == $n) | .key' | head -n 1)
[ -n "$CONN_ID" ] || { echo "connection '${rdp_target_name}' not found" >&2; exit 1; }
jq -n --arg g "${ldap_group}" '{identifier:$g, attributes:{}}' |
  curl -fs -X POST -H 'Content-Type: application/json' -d @- "$API/session/data/postgresql/userGroups?token=$T" > /dev/null
jq -n --arg c "$CONN_ID" '[{op:"add", path:("/connectionPermissions/" + $c), value:"READ"}]' |
  curl -fs -X PATCH -H 'Content-Type: application/json' -d @- "$API/session/data/postgresql/userGroups/${ldap_group}/permissions?token=$T" > /dev/null

# Settings go in an env-file (root-only): docker takes its values verbatim, so the search
# filter's parentheses and the bind password need no shell quoting. Plain LDAP on 389: the DC
# has no LDAPS certificate yet; the bind crosses only the TGW and the firewalls.
LDAP_BIND_PW=$(echo "$SECRET" | jq -r '.ldap_bind_password // empty')
[ -n "$LDAP_BIND_PW" ] || { echo "ldap_bind_password missing from the secret" >&2; exit 1; }
install -m 600 /dev/null /opt/guacamole/ldap.env
cat > /opt/guacamole/ldap.env <<EOF
LDAP_ENABLED=true
LDAP_HOSTNAME=${rdp_target_host}
LDAP_PORT=389
LDAP_ENCRYPTION_METHOD=none
LDAP_USER_BASE_DN=${ldap_base_dn}
LDAP_USERNAME_ATTRIBUTE=sAMAccountName
LDAP_SEARCH_BIND_DN=${ldap_bind_dn}
LDAP_SEARCH_BIND_PASSWORD=$LDAP_BIND_PW
LDAP_USER_SEARCH_FILTER=(&(objectCategory=person)(memberOf:1.2.840.113556.1.4.1941:=CN=${ldap_group},CN=Users,${ldap_base_dn}))
LDAP_GROUP_BASE_DN=${ldap_base_dn}
LDAP_GROUP_NAME_ATTRIBUTE=cn
LDAP_MEMBER_ATTRIBUTE=member
LDAP_MEMBER_ATTRIBUTE_TYPE=dn
EOF

# Same as start_guac above, plus LDAP for the production container, and DB accounts are
# auto-created for AD users on first sign-in (their TOTP key is stored there). The OID in the
# filter makes nested group membership count too.
start_guac() {  # $1 = bind address, $2 = yes|no (TOTP + LDAP)
  TOTP_ENV=""
  [ "$2" = "yes" ] && TOTP_ENV="-e EXTENSIONS=auth-ldap,auth-totp -e TOTP_ENABLED=true --env-file /opt/guacamole/ldap.env"
  docker rm -f guacamole >/dev/null 2>&1 || true
  docker run -d --name guacamole --network guac --restart always -p "$1:8080:8080" \
    -e GUACD_HOSTNAME=guacd \
    -e POSTGRESQL_HOSTNAME=guac-db -e POSTGRESQL_DATABASE=guacamole_db \
    -e POSTGRESQL_USER=guacamole_user -e POSTGRESQL_PASSWORD="$DB_PW" \
    -e POSTGRESQL_AUTO_CREATE_ACCOUNTS=true \
    $TOTP_ENV \
    "guacamole/guacamole:$GUAC_VER"
}
%{ endif ~}
curl -fs -X DELETE "$API/tokens/$T" > /dev/null || true

# 3) production container: TOTP on, reachable by the ALB
start_guac 0.0.0.0 yes
wait_ready

# 4) fail closed: TOTP must be enforced and guacadmin must be gone
fail_closed() {
  echo "FATAL: $1 -- stopping guacamole" >&2
  docker stop guacamole >/dev/null 2>&1 || true
  exit 1
}
if token "${admin_user}" "$ADMIN_PW" >/dev/null 2>&1; then
  fail_closed "admin login returned a token WITHOUT a TOTP step (TOTP not enforced)"
fi
if token guacadmin guacadmin >/dev/null 2>&1; then
  fail_closed "default guacadmin/guacadmin still works"
fi
echo "guacamole bootstrap complete (TOTP enforced, default account removed)"
