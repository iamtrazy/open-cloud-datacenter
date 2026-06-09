variable "vm_name_prefix" {
  type        = string
  description = "Name prefix for all VMs. Each VM is named <prefix>-<pool-name>-<index>."
}

variable "harvester_namespace" {
  type        = string
  description = "Harvester namespace for all resources."
  default     = "default"
}

variable "machine_pools" {
  description = <<-EOT
    List of machine pool definitions. Each pool creates <quantity> identical VMs.
    The very first VM of the very first pool is the bootstrap node (cluster-init).
    All other control_plane/etcd VMs join as RKE2 servers; pure worker pools join
    as RKE2 agents. ip_addresses must have exactly <quantity> entries.
  EOT
  type = list(object({
    name          = string
    quantity      = number
    cpu_count     = number
    memory_size   = string
    disk_size     = string
    control_plane = bool
    etcd          = bool
    worker        = bool
    ip_addresses  = list(string)
    gateway       = string
    subnet_prefix = number
  }))
}

variable "image_url" {
  type        = string
  description = "URL of the OS image to download. Leave empty if ubuntu_image_id is set."
  default     = ""
}

variable "ubuntu_image_id" {
  type        = string
  description = "Pre-existing Harvester image ID (<namespace>/<name>) to use instead of downloading."
  default     = ""
}

variable "image_name" {
  type    = string
  default = "ubuntu-2204-lts"
}

variable "image_display_name" {
  type    = string
  default = "Ubuntu 22.04 LTS"
}

variable "network_name" {
  type        = string
  description = "Bridge NAD name. Short name when create_bridge_network=true; full <ns>/<name> when false."
}

variable "create_bridge_network" {
  type    = bool
  default = true
}

variable "cluster_network_name" {
  type    = string
  default = "mgmt"
}

variable "cluster_vlan_id" {
  type    = number
  default = 100
}

variable "rke2_version" {
  type        = string
  description = "RKE2 version string, e.g. v1.34.7+rke2r1. Passed to rancherd kubernetesVersion."
  default     = "v1.34.7+rke2r1"
}

variable "tls_san_extra" {
  type        = list(string)
  description = "Additional IPs/hostnames for the kube-apiserver TLS SAN. Include the MetalLB API VIP."
  default     = []
}

variable "primary_dns" {
  type    = string
  default = ""
}

variable "vm_password" {
  type      = string
  sensitive = true
}

variable "harvester_kubeconfig_path" {
  type        = string
  description = "Path to the Harvester kubeconfig, used for storage class management."
  default     = ""
}

variable "manage_storage_class" {
  type    = bool
  default = true
}

variable "storage_class_name" {
  type    = string
  default = "harvester-longhorn-2r"
}

variable "storage_class_replicas" {
  type    = number
  default = 2
}

variable "manage_storage_network" {
  type    = bool
  default = false
}

variable "storage_network_vlan" {
  type    = number
  default = 0
}

variable "storage_network_cluster_network" {
  type    = string
  default = ""
}

variable "storage_network_range" {
  type    = string
  default = ""
}

variable "storage_network_exclude_ranges" {
  type    = list(string)
  default = []
}

# ── rancherd / Rancher ────────────────────────────────────────────────────────

variable "rancher_version" {
  type        = string
  description = "Rancher version to install, e.g. 2.14.0. Passed to rancherd rancherVersion."
  default     = "stable"
}

variable "rancher_hostname" {
  type        = string
  description = "FQDN for the Rancher UI (e.g. rancher-us-prod.iaas.sys.wso2.com)."
}

variable "rancher_replicas" {
  type        = number
  description = "Number of Rancher pod replicas. Should match the number of control-plane nodes."
  default     = 3
}

variable "bootstrap_password" {
  type        = string
  sensitive   = true
  description = "Initial Rancher admin password."
}

variable "tls_source" {
  type        = string
  description = "'secret' for BYO cert, 'rancher' for self-signed. Passed to Rancher ingress.tls.source."
  default     = "rancher"
}

variable "tls_cert" {
  type        = string
  sensitive   = true
  description = "PEM-encoded TLS certificate chain. Required when tls_source = 'secret'."
  default     = ""
}

variable "tls_key" {
  type        = string
  sensitive   = true
  description = "PEM-encoded TLS private key. Required when tls_source = 'secret'."
  default     = ""
}

# ── MetalLB ───────────────────────────────────────────────────────────────────

variable "metallb_version" {
  type        = string
  description = "MetalLB Helm chart version, e.g. 0.14.9."
  default     = "0.14.9"
}

variable "metallb_api_vip" {
  type        = string
  description = "MetalLB VIP for the kube-apiserver HA Service (ports 6443 + 9345). Must also be in tls_san_extra."
}

variable "metallb_ingress_vip" {
  type        = string
  description = "MetalLB VIP for RKE2 ingress-nginx (ports 80/443). DNS A record for rancher_hostname must point here."
}
