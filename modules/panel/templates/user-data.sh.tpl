#!/bin/bash
# Admin panel first-boot provisioning (rendered by Terraform; shell vars use $VAR only,
# never braces, so templatefile leaves them alone).
set -euo pipefail
exec > >(tee /var/log/panel-bootstrap.log) 2>&1

dnf install -y python3-pip jq
mkdir -p /opt/panel
# app code revision: ${app_sha}
APP=$(aws secretsmanager get-secret-value --region "${region}" --secret-id "${app_secret_id}" --query SecretString --output text)
echo "$APP" | base64 -d | gunzip > /opt/panel/bundle.json
for f in $(jq -r 'keys[]' /opt/panel/bundle.json); do
  mkdir -p "/opt/panel/$(dirname "$f")"
  jq -r --arg f "$f" '.[$f]' /opt/panel/bundle.json > "/opt/panel/$f"
done
chmod -R a+rX /opt/panel
python3 -m venv /opt/panel/venv
/opt/panel/venv/bin/pip install --quiet "flask>=3.1,<3.2" "gunicorn>=23,<24" "requests>=2.32,<3" "ldap3>=2.9,<2.10" "pycryptodome>=3.20,<4" "boto3>=1.34,<2"  # pycryptodome: MD4 for NTLM (OpenSSL 3 dropped it)

SECRET=$(aws secretsmanager get-secret-value --region "${region}" --secret-id "${secret_id}" --query SecretString --output text)
umask 077
cat > /etc/panel.env <<ENV
PANEL_LDAP_HOST=${ldap_host}
PANEL_DOMAIN=${domain}
PANEL_NETBIOS=${netbios}
PANEL_BASE_DN=${base_dn}
PANEL_ADMIN_GROUP=${admin_group}
PANEL_FW_IPS=${fw_ips}
PANEL_SPOKE_HOST=${spoke_host}
PANEL_TOPO_B64=${topo_b64}
PANEL_FAILOVER_ENABLED=${failover_enabled}
PANEL_RUNS_TABLE=${runs_table}
PANEL_OPERATOR_GROUP=${operator_group}
PANEL_GP_FQDN=${gp_fqdn}
AWS_DEFAULT_REGION=${region}
PANEL_FW_USER=$(echo "$SECRET" | jq -r .fw_user)
PANEL_FW_PASSWORD=$(echo "$SECRET" | jq -r .fw_password)
PANEL_SESSION_SECRET=$(echo "$SECRET" | jq -r .session_secret)
ENV
useradd --system --no-create-home --shell /sbin/nologin panel || true
chown root:panel /etc/panel.env && chmod 640 /etc/panel.env

# One worker: login rate-limit state is in memory, so several workers would multiply the limit.
cat > /etc/systemd/system/panel.service <<UNIT
[Unit]
Description=Lab admin panel
After=network-online.target
[Service]
User=panel
EnvironmentFile=/etc/panel.env
WorkingDirectory=/opt/panel
ExecStart=/opt/panel/venv/bin/gunicorn --workers 1 --threads 8 --bind 0.0.0.0:8080 --access-logfile - app:app
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now panel
