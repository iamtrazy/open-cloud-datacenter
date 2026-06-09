output "bootstrap_ip" {
  value       = local.bootstrap_ip
  description = "Static IP of the bootstrap node."
}

output "vm_ips" {
  value       = { for vm in local.all_vms : vm.key => vm.ip_address }
  description = "Map of <pool-name>-<index> to static IP for every cluster node."
}

output "vm_image_id" {
  value       = var.image_url != "" ? "${harvester_image.vm_image[0].namespace}/${harvester_image.vm_image[0].name}" : var.ubuntu_image_id
  description = "Harvester image reference (namespace/name). Pass downstream to avoid re-downloading."
}
