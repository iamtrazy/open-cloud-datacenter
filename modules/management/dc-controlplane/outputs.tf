output "cluster_id" {
  value       = module.cluster.cluster_id
  description = "Rancher cluster ID of the provisioned control-plane cluster."
}

output "cluster_name" {
  value       = var.cluster_name
  description = "Name of the RKE2 cluster."
}

output "project_id" {
  value       = module.project.project_id
  description = "Rancher project ID for the control-plane project."
}

output "mgmt_network_name" {
  value       = "${var.project_name}/${harvester_network.mgmt.name}"
  description = "Fully-qualified Harvester NAD name (namespace/name) for the management network."
}
