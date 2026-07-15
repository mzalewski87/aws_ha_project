variable "namespace" {
  type    = string
  default = "wordpress"
}
variable "chart_version" {
  type    = string
  default = "23.1.0"
}
variable "wordpress_username" {
  type    = string
  default = "admin"
}
variable "wordpress_password" {
  type      = string
  sensitive = true
}
variable "image_repository" {
  description = "WordPress image repo (Bitnami public images now live under bitnamilegacy)."
  type        = string
  default     = "bitnamilegacy/wordpress"
}
