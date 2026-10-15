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

# TOTP is mandatory for every account (the ALB is internet-facing by design).
# EXTENSIONS / TOTP_ENABLED: the image documents one or the other depending on
# the release; setting both is harmless. [VERIFY on first live boot]
docker run -d --name guacamole --network guac --restart always -p 8080:8080 \
  -e GUACD_HOSTNAME=guacd \
  -e POSTGRESQL_HOSTNAME=guac-db -e POSTGRESQL_DATABASE=guacamole_db \
  -e POSTGRESQL_USER=guacamole_user -e POSTGRESQL_PASSWORD="$DB_PW" \
  -e POSTGRESQL_AUTO_CREATE_ACCOUNTS=false \
  -e EXTENSIONS=auth-totp -e TOTP_ENABLED=true \
  "guacamole/guacamole:$GUAC_VER"

API=http://127.0.0.1:8080/guacamole/api
for i in $(seq 1 90); do
  curl -fs -o /dev/null "http://127.0.0.1:8080/guacamole/" && break
  sleep 5
done

token() { curl -fs -d "username=$1" --data-urlencode "password=$2" "$API/tokens" | jq -r .authToken; }

# 1) Replace the well-known guacadmin/guacadmin account.
T=$(token guacadmin guacadmin)
jq -n --arg u "${admin_user}" --arg p "$ADMIN_PW" '{username:$u,password:$p,attributes:{}}' |
  curl -fs -X POST -H 'Content-Type: application/json' -d @- "$API/session/data/postgresql/users?token=$T" > /dev/null
echo '[{"op":"add","path":"/systemPermissions","value":"ADMINISTER"}]' |
  curl -fs -X PATCH -H 'Content-Type: application/json' -d @- "$API/session/data/postgresql/users/${admin_user}/permissions?token=$T" > /dev/null

T=$(token "${admin_user}" "$ADMIN_PW")
curl -fs -X DELETE "$API/session/data/postgresql/users/guacadmin?token=$T" > /dev/null

# 2) Pre-provision the RDP connection to the DC. Credentials are only stored
#    when supplied; otherwise users type them at connect time.
jq -n --arg name "${rdp_target_name}" --arg host "${rdp_target_host}" \
      --arg dom "${rdp_target_domain}" --arg user "${rdp_username}" --arg pw "$RDP_PW" '
  {parentIdentifier:"ROOT", name:$name, protocol:"rdp", attributes:{},
   parameters: ({hostname:$host, port:"3389", security:"nla", "ignore-cert":"true",
                 "resize-method":"display-update", "enable-wallpaper":"false"}
                + (if $dom  != "" then {domain:$dom}     else {} end)
                + (if $user != "" then {username:$user}  else {} end)
                + (if $pw   != "" then {password:$pw}    else {} end))}' |
  curl -fs -X POST -H 'Content-Type: application/json' -d @- "$API/session/data/postgresql/connections?token=$T" > /dev/null

curl -fs -X DELETE "$API/tokens/$T" > /dev/null || true
echo "guacamole bootstrap complete"
