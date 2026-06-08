variable "vm_name_prefix" {
  type        = string
  description = "Name prefix applied to every VM. Each VM is named <prefix>-<pool>-<index>."
}

variable "harvester_namespace" {
  type        = string
  description = "Harvester namespace for all resources (VMs, secrets, network)."
  default     = "default"
}

variable "image_url" {
  type        = string
  description = "URL of the OS image to download and register. Leave empty if ubuntu_image_id is set."
  default     = ""
}

variable "ubuntu_image_id" {
  type        = string
  description = "Pre-existing Harvester image ID (<namespace>/<name>) to use instead of downloading."
  default     = ""
}

variable "image_name" {
  type        = string
  description = "Name for the registered Harvester image resource."
  default     = "ubuntu-2204-lts"
}

variable "image_display_name" {
  type        = string
  description = "Display name shown in the Harvester UI for the image."
  default     = "Ubuntu 22.04 LTS"
}

variable "machine_pools" {
  description = <<-EOT
    List of machine pool definitions. Each pool creates <quantity> identical VMs.
    The very first VM of the very first pool becomes the cluster bootstrap node
    (cluster-init: true). All other control-plane/etcd VMs join as servers; pools
    with control_plane=false and etcd=false join as RKE2 agents (worker-only).
    ip_addresses must contain exactly <quantity> entries.
  EOT
  type = list(object({
    name          = string
    quantity      = number
    cpu_count     = number
    memory_size   = string # e.g. "8Gi"
    disk_size     = string # e.g. "60Gi"
    control_plane = bool
    etcd          = bool
    worker        = bool
    ip_addresses  = list(string) # one per VM in the pool
    gateway       = string
    subnet_prefix = number # CIDR prefix length, e.g. 25
  }))
}

variable "network_name" {
  type        = string
  description = "Bridge NetworkAttachmentDefinition name. Short name when create_bridge_network=true; full <namespace>/<name> when false."
}

variable "create_bridge_network" {
  type        = bool
  description = "Create the NAD before VMs start. Set false when the NAD already exists."
  default     = true
}

variable "cluster_network_name" {
  type        = string
  description = "Harvester cluster network the VLAN attaches to (e.g. 'vm-network')."
  default     = "mgmt"
}

variable "cluster_vlan_id" {
  type        = number
  description = "VLAN tag ID for the bridge network."
  default     = 100
}

variable "rke2_version" {
  type        = string
  description = "RKE2 release to install, e.g. 'v1.34.7+rke2r1'."
  default     = "v1.34.7+rke2r1"
}

variable "disable_servicelb" {
  type        = bool
  description = "Disable RKE2's built-in ServiceLB (kube-vip). Required when using MetalLB."
  default     = true
}

variable "tls_san_extra" {
  type        = list(string)
  description = "Additional IPs or hostnames to include in the RKE2 kube-apiserver TLS SAN list (e.g. a future MetalLB VIP)."
  default     = []
}

variable "primary_dns" {
  type        = string
  description = "Primary DNS server IP configured via systemd-resolved before any package downloads."
  default     = ""
}

variable "vm_password" {
  type        = string
  description = "Password for the ubuntu user on every VM."
  sensitive   = true
}

variable "vm_disk_auto_delete" {
  type        = bool
  description = "Delete the root disk when the VM is deleted."
  default     = true
}

variable "enable_usb_tablet" {
  type        = bool
  description = "Attach a USB tablet input device (fixes cursor behaviour in the Harvester console)."
  default     = true
}

variable "harvester_kubeconfig_path" {
  type        = string
  description = "Path to the Harvester kubeconfig, used for storage class management and state extraction."
  default     = ""
}

variable "manage_storage_class" {
  type        = bool
  description = "Create a 2-replica Longhorn StorageClass and set it as the cluster default."
  default     = true
}

variable "storage_class_name" {
  type        = string
  description = "Name of the custom Longhorn StorageClass created when manage_storage_class=true."
  default     = "harvester-longhorn-2r"
}

variable "storage_class_replicas" {
  type        = number
  description = "Longhorn replica count for the custom StorageClass."
  default     = 2
}

variable "kubeconfig_output_path" {
  type        = string
  description = "Local file path where the extracted RKE2 kubeconfig is written after the cluster is ready."
  default     = "rke2.kubeconfig"
}

variable "manage_storage_network" {
  type        = bool
  description = "Patch the Harvester storage-network setting for dedicated Longhorn replication traffic."
  default     = false
}

variable "storage_network_vlan" {
  type        = number
  description = "VLAN ID for the storage network."
  default     = 0
}

variable "storage_network_cluster_network" {
  type        = string
  description = "Harvester cluster network name for storage traffic."
  default     = ""
}

variable "storage_network_range" {
  type        = string
  description = "IP CIDR range for storage NICs."
  default     = ""
}

variable "storage_network_exclude_ranges" {
  type        = list(string)
  description = "CIDR blocks to exclude from the storage range."
  default     = []
}
