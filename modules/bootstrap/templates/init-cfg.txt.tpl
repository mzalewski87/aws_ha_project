type=dhcp-client
ip-address=
netmask=
default-gateway=
hostname=${hostname}
%{ if management_mode == "scm" ~}
# Strata Cloud Manager: the firewall dials SCM itself. The device certificate
# (auto-registration PIN below) is what authenticates it to the tenant; there is
# no vm-auth-key, template stack or device group at bootstrap time.
panorama-server=cloud
# Advanced Routing Engine (logical routers). Path B is built on ARE; SCM's own
# bootstrap push fails on interfaces that are not in a logical router.
plugin-op-commands=advance-routing:enable
%{ else ~}
%{ if panorama_vm_auth_key != "" ~}
vm-auth-key=${panorama_vm_auth_key}
%{ endif ~}
panorama-server=${panorama_server}
panorama-server-2=
tplname=${panorama_template_stack}
dgname=${panorama_device_group}
%{ endif ~}
%{ if authcodes != "" ~}
authcodes=${authcodes}
%{ endif ~}
%{ if vm_series_auto_registration_pin_id != "" ~}
vm-series-auto-registration-pin-id=${vm_series_auto_registration_pin_id}
vm-series-auto-registration-pin-value=${vm_series_auto_registration_pin_value}
%{ endif ~}
# AWS deltas vs Azure: no magic 168.63.129.16. Use VPC resolver (.2 of VPC CIDR)
# or a public resolver. Set these from a variable at implementation time.
dns-primary=${dns_primary}
dns-secondary=${dns_secondary}
ntp-server-1=0.europe.pool.ntp.org
ntp-server-2=1.europe.pool.ntp.org
timezone=Europe/Warsaw
dhcp-send-hostname=yes
dhcp-send-client-id=yes
dhcp-accept-server-hostname=yes
dhcp-accept-server-domain=yes
# This init-cfg is delivered via EC2 user-data (base64) read over IMDSv2 —
# the AWS analog of Azure custom_data. See modules/bootstrap/README.md.
