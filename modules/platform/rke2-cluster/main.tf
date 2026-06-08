terraform {
  required_version = ">= 1.5"
  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 1.7"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# ── Namespace ─────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "ns" {
  count = var.harvester_namespace != "default" ? 1 : 0
  metadata {
    name = var.harvester_namespace
    labels = {
      "platform.wso2.com/role" = "infrastructure"
    }
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}

# ── OS Image ──────────────────────────────────────────────────────────────────
resource "harvester_image" "vm_image" {
  count        = var.image_url != "" ? 1 : 0
  name         = var.image_name
  namespace    = var.harvester_namespace
  display_name = var.image_display_name
  source_type  = "download"
  backend      = "backingimage"
  url          = var.image_url

  depends_on = [
    kubernetes_namespace.ns,
    kubernetes_storage_class_v1.default,
  ]
}

locals {
  image_id = var.image_url != "" ? harvester_image.vm_image[0].id : var.ubuntu_image_id

  # Flatten machine_pools into a map keyed by "<pool-name>-<index>".
  # The very first entry (pools[0], index 0) is the bootstrap node.
  all_vms = flatten([
    for pool_idx, pool in var.machine_pools : [
      for vm_idx in range(pool.quantity) : {
        key          = "${pool.name}-${vm_idx}"
        pool_idx     = pool_idx
        vm_idx       = vm_idx
        pool         = pool
        ip_address   = pool.ip_addresses[vm_idx]
        is_bootstrap = pool_idx == 0 && vm_idx == 0
        is_server    = pool.control_plane || pool.etcd
      }
    ]
  ])

  vms          = { for vm in local.all_vms : vm.key => vm }
  bootstrap_ip = [for vm in local.all_vms : vm.ip_address if vm.is_bootstrap][0]

  bridge_network_name = (
    var.create_bridge_network
    ? "${var.harvester_namespace}/${var.network_name}"
    : var.network_name
  )
}

check "image_source_required" {
  assert {
    condition     = var.image_url != "" || var.ubuntu_image_id != ""
    error_message = "Set either image_url (to download) or ubuntu_image_id (to reuse an existing image)."
  }
}

# ── RKE2 cluster token ────────────────────────────────────────────────────────
resource "random_password" "rke2_token" {
  length  = 64
  special = false
}

# ── SSH key pair ──────────────────────────────────────────────────────────────
resource "tls_private_key" "bootstrap_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "harvester_ssh_key" "bootstrap_key" {
  name       = "${var.vm_name_prefix}-ssh-key"
  namespace  = var.harvester_namespace
  public_key = tls_private_key.bootstrap_key.public_key_openssh
  depends_on = [kubernetes_namespace.ns]
}

# ── Bridge network (optional) ─────────────────────────────────────────────────
resource "harvester_network" "bridge" {
  count                = var.create_bridge_network ? 1 : 0
  name                 = var.network_name
  namespace            = var.harvester_namespace
  vlan_id              = var.cluster_vlan_id
  cluster_network_name = var.cluster_network_name
  depends_on           = [kubernetes_namespace.ns]
}

# ── Per-VM cloud-init secrets ─────────────────────────────────────────────────
resource "harvester_cloudinit_secret" "cloudinit" {
  for_each   = local.vms
  name       = "${var.vm_name_prefix}-${each.key}-ci"
  namespace  = var.harvester_namespace
  depends_on = [kubernetes_namespace.ns]

  user_data = templatefile("${path.module}/templates/user-data.yaml.tpl", {
    password          = var.vm_password
    ssh_public_key    = tls_private_key.bootstrap_key.public_key_openssh
    primary_dns       = var.primary_dns
    rke2_version      = var.rke2_version
    rke2_token        = random_password.rke2_token.result
    is_bootstrap      = each.value.is_bootstrap
    is_server         = each.value.is_server
    node_ip           = each.value.ip_address
    subnet_prefix     = each.value.pool.subnet_prefix
    gateway           = each.value.pool.gateway
    dns               = var.primary_dns != "" ? var.primary_dns : "8.8.8.8"
    bootstrap_ip      = local.bootstrap_ip
    disable_servicelb = var.disable_servicelb
    tls_san_extra     = var.tls_san_extra
  })
}

# ── VMs ───────────────────────────────────────────────────────────────────────
resource "harvester_virtualmachine" "vm" {
  for_each             = local.vms
  name                 = "${var.vm_name_prefix}-${each.key}"
  namespace            = var.harvester_namespace
  restart_after_update = true

  depends_on = [
    harvester_network.bridge,
    null_resource.storage_network,
  ]

  cpu    = each.value.pool.cpu_count
  memory = each.value.pool.memory_size

  run_strategy = "RerunOnFailure"
  machine_type = "q35"

  ssh_keys = [harvester_ssh_key.bootstrap_key.id]

  network_interface {
    name         = "default"
    type         = "bridge"
    network_name = local.bridge_network_name
  }

  disk {
    name        = "disk-0"
    type        = "disk"
    size        = each.value.pool.disk_size
    bus         = "virtio"
    boot_order  = 1
    image       = local.image_id
    auto_delete = var.vm_disk_auto_delete
  }

  dynamic "input" {
    for_each = var.enable_usb_tablet ? [1] : []
    content {
      name = "tablet"
      type = "tablet"
      bus  = "usb"
    }
  }

  cloudinit {
    user_data_secret_name = harvester_cloudinit_secret.cloudinit[each.key].name
  }
}

# ── SSH private key (written to disk so the null_resource can use it) ─────────
resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.bootstrap_key.private_key_pem
  filename        = "${dirname(var.kubeconfig_output_path)}/${var.vm_name_prefix}.pem"
  file_permission = "0600"
}

# ── Extract kubeconfig from bootstrap node ───────────────────────────────────
# Waits for the bootstrap VM to be SSHable and for RKE2 to finish initializing,
# then copies /etc/rancher/rke2/rke2.yaml with 127.0.0.1 replaced by the
# bootstrap IP so downstream consumers can connect from outside the VM.
resource "null_resource" "kubeconfig" {
  triggers = {
    bootstrap_vm_id = harvester_virtualmachine.vm["${var.machine_pools[0].name}-0"].id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      KEY="${local_sensitive_file.ssh_private_key.filename}"
      HOST="${local.bootstrap_ip}"
      OUT="${var.kubeconfig_output_path}"

      echo "Waiting for SSH on $HOST..."
      until ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
          ubuntu@$HOST exit 2>/dev/null; do
        sleep 20
      done

      echo "Waiting for RKE2 kubeconfig on $HOST..."
      until ssh -i "$KEY" -o StrictHostKeyChecking=no ubuntu@$HOST \
          "sudo test -f /etc/rancher/rke2/rke2.yaml" 2>/dev/null; do
        sleep 30
      done

      # Give the API server a moment to be fully ready after the file appears.
      sleep 15

      echo "Copying kubeconfig..."
      ssh -i "$KEY" -o StrictHostKeyChecking=no ubuntu@$HOST \
          "sudo cat /etc/rancher/rke2/rke2.yaml" \
        | sed "s/127\.0\.0\.1/$HOST/g" > "$OUT"
      echo "Kubeconfig written to $OUT"
    EOT
  }

  depends_on = [
    harvester_virtualmachine.vm,
    local_sensitive_file.ssh_private_key,
  ]
}

# ── Storage class (optional) ──────────────────────────────────────────────────
resource "kubernetes_storage_class_v1" "default" {
  count      = var.manage_storage_class ? 1 : 0
  depends_on = [kubernetes_annotations.harvester_longhorn_not_default]

  metadata {
    name = var.storage_class_name
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "driver.longhorn.io"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"

  parameters = {
    numberOfReplicas    = tostring(var.storage_class_replicas)
    staleReplicaTimeout = "30"
    fromBackup          = ""
    fsType              = "ext4"
    migratable          = "true"
  }
}

resource "kubernetes_annotations" "harvester_longhorn_not_default" {
  count       = var.manage_storage_class ? 1 : 0
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata { name = "harvester-longhorn" }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true
}

resource "kubernetes_storage_class_v1" "longhorn_rwx" {
  count      = var.manage_storage_class ? 1 : 0
  depends_on = [kubernetes_annotations.harvester_longhorn_not_default]

  metadata { name = "longhorn-rwx" }

  storage_provisioner    = "driver.longhorn.io"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"

  parameters = {
    numberOfReplicas    = "1"
    staleReplicaTimeout = "2880"
    fromBackup          = ""
    fsType              = "ext4"
    nfsOptions          = "vers=4.2,noresvport,softerr,timeo=600,retrans=5"
  }
}

# ── Storage network (optional) ────────────────────────────────────────────────
resource "null_resource" "storage_network" {
  count = var.manage_storage_network ? 1 : 0

  triggers = {
    config = jsonencode({
      vlan           = var.storage_network_vlan
      clusterNetwork = var.storage_network_cluster_network
      range          = var.storage_network_range
      exclude        = var.storage_network_exclude_ranges
    })
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = var.harvester_kubeconfig_path
      STORAGE_CONFIG = jsonencode({
        vlan           = var.storage_network_vlan
        clusterNetwork = var.storage_network_cluster_network
        range          = var.storage_network_range
        exclude        = var.storage_network_exclude_ranges
      })
    }
    command = <<-EOT
      python3 -c "
import subprocess, json, os
config = json.loads(os.environ['STORAGE_CONFIG'])
patch = json.dumps({'value': json.dumps(config)})
subprocess.run(
  ['kubectl', 'patch', 'setting', 'storage-network', '--type=merge', '-p', patch],
  env={**os.environ}, check=True)
print('storage-network patched:', patch)
"
    EOT
  }
}
