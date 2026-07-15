variable "name_prefix" { type = string }
variable "node_subnet_ids" { type = list(string) }
variable "kubernetes_version" {
  type    = string
  default = "1.30"
}
variable "node_instance_type" {
  type    = string
  default = "t3.large"
}
variable "node_desired_size" {
  type    = number
  default = 2
}
variable "node_min_size" {
  type    = number
  default = 2
}
variable "node_max_size" {
  type    = number
  default = 3
}
variable "tags" {
  type    = map(string)
  default = {}
}
