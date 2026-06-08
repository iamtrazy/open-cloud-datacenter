output "bootstrap_ip" {
  value       = local.bootstrap_ip
  description = "Static IP of the bootstrap (cluster-init) node. Use this to reach the kube-apiserver from outside the cluster."
}

output "kubeconfig_path" {
  value       = var.kubeconfig_output_path
  description = "Local path where the RKE2 kubeconfig was written after the cluster became ready."
  depends_on  = [null_resource.kubeconfig]
}

output "vm_ids" {
  value       = { for k, v in harvester_virtualmachine.vm : k => v.id }
  description = "Map of <pool-name>-<index> → Harvester VM resource ID."
}

output "vm_ips" {
  value       = { for vm in local.all_vms : vm.key => vm.ip_address }
  description = "Map of <pool-name>-<index> → static IP address of that VM."
}

output "ssh_private_key_path" {
  value       = local_sensitive_file.ssh_private_key.filename
  description = "Path to the PEM-encoded SSH private key for all VMs in the cluster."
}

output "vm_image_id" {
  value       = var.image_url != "" ? "${harvester_image.vm_image[0].namespace}/${harvester_image.vm_image[0].name}" : var.ubuntu_image_id
  description = "Harvester image reference (namespace/name). Pass to the 01-rancher layer as ubuntu_image_id to skip re-downloading."
}
