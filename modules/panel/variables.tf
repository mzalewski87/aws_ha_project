variable "name_prefix" {
  type = string
}
variable "vpc_id" {
  description = "Management VPC (outside the firewall data path under test)."
  type        = string
}
variable "alb_subnet_ids" {
  description = "Public subnets (>= 2 AZs) for the internet-facing ALB."
  type        = list(string)
}
variable "host_subnet_ids" {
  description = "Private subnets (NAT egress for pip/dnf), one per AZ; one panel host is created in each."
  type        = list(string)
}
variable "certificate_arn" {
  description = "Issued ACM certificate (same region as the ALB) for the panel hostname."
  type        = string
}
variable "instance_type" {
  type    = string
  default = "t3.small"
}
variable "key_name" {
  type = string
}
variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB. The AD login (group-gated, rate-limited) is the control; narrow this to harden."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
variable "ldap_host" {
  description = "Domain controller IP used for the AD login bind."
  type        = string
}
variable "domain_name" {
  description = "AD DNS domain, e.g. panw.labs."
  type        = string
}
variable "admin_group" {
  description = "AD group whose members may sign in."
  type        = string
  default     = "panel-admins"
}
variable "fw_mgmt_ips" {
  description = "Management IPs of the firewall pair (XML API, read-only admin)."
  type        = list(string)
}
variable "fw_readonly_user" {
  description = "Restricted firewall admin the panel uses (custom role panel-ro, created by scripts/panel-setup.sh)."
  type        = string
  default     = "panelro"
}
variable "spoke_host" {
  description = "Default source address pre-filled in the simulation form (a spoke workload)."
  type        = string
  default     = "10.12.0.10"
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "enable_failover" {
  description = "Allow operators to run failover tests from the panel. Gives the hosts an IAM role that can stop/start ONLY the firewall instances in fw_map."
  type        = bool
  default     = false
}
variable "pairs" {
  description = "Firewall pairs, one per region: key => {label, region, eip_allocation_id, public_ip, units = {name => {ip (XML API), id (EC2, failover tests), untrust_eni / trust_eni (topology: who holds the EIP, who gets the routes)}}}. Unit names unique across pairs."
  type = map(object({
    label             = string
    region            = string
    eip_allocation_id = string
    public_ip         = string
    units = map(object({
      ip          = string
      id          = string
      untrust_eni = string
      trust_eni   = string
    }))
  }))
  default = {}
}
variable "operator_group" {
  description = "AD group whose members (who must also be in admin_group) may run failover tests."
  type        = string
  default     = "panel-operators"
}
variable "gp_portal_fqdn" {
  description = "GlobalProtect portal FQDN probed during failover tests to measure the outage. Empty = no probe."
  type        = string
  default     = ""
}
variable "ga_arn" {
  description = "Global Accelerator ARN in front of the portal (topology: endpoint health per region). Empty = no GA."
  type        = string
  default     = ""
}
