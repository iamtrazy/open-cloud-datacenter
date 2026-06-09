terraform {
  required_version = ">= 1.5"
  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 1.7"
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
  }
}

# ── Cluster join token ────────────────────────────────────────────────────────
resource "random_password" "rke2_token" {
  length  = 64
  special = false
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

# ── Bridge network ────────────────────────────────────────────────────────────
resource "harvester_network" "bridge" {
  count                = var.create_bridge_network ? 1 : 0
  name                 = var.network_name
  namespace            = var.harvester_namespace
  vlan_id              = var.cluster_vlan_id
  cluster_network_name = var.cluster_network_name
  depends_on           = [kubernetes_namespace.ns]
}

# ── Flatten machine_pools → per-VM map ───────────────────────────────────────
locals {
  image_id = var.image_url != "" ? harvester_image.vm_image[0].id : var.ubuntu_image_id

  all_vms = flatten([
    for pool_idx, pool in var.machine_pools : [
      for vm_idx in range(pool.quantity) : {
        key          = "${pool.name}-${vm_idx}"
        pool         = pool
        ip_address   = pool.ip_addresses[vm_idx]
        is_bootstrap = pool_idx == 0 && vm_idx == 0
        is_server    = pool.control_plane || pool.etcd
      }
    ]
  ])

  vms               = { for vm in local.all_vms : vm.key => vm }
  bootstrap_ip      = [for vm in local.all_vms : vm.ip_address if vm.is_bootstrap][0]
  control_plane_ips = sort([for vm in local.all_vms : vm.ip_address if vm.is_server])

  network_name_full = (
    var.create_bridge_network
    ? "${var.harvester_namespace}/${var.network_name}"
    : var.network_name
  )

  # ── RKE2 manifests (bootstrap node only) ────────────────────────────────────
  # Written to /var/lib/rancher/rke2/server/manifests/ via cloud-init.
  # RKE2's built-in manifest controller applies these with automatic retries:
  #   - MetalLB CRs retry until the HelmChart installs the CRDs (~2 min)
  #   - rancher TLS secret retries until cattle-system namespace exists

  manifest_metallb_ns = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "metallb-system"
      labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
        "pod-security.kubernetes.io/audit"   = "privileged"
        "pod-security.kubernetes.io/warn"    = "privileged"
      }
    }
  })

  manifest_metallb_helmchart = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChart"
    metadata = {
      name      = "metallb"
      namespace = "kube-system"
    }
    spec = {
      repo            = "https://metallb.github.io/metallb"
      chart           = "metallb"
      version         = var.metallb_version
      targetNamespace = "metallb-system"
      createNamespace = false
    }
  })

  manifest_metallb_config = join("\n---\n", [
    yamlencode({
      apiVersion = "metallb.io/v1beta1"
      kind       = "IPAddressPool"
      metadata   = { name = "kube-api-pool", namespace = "metallb-system" }
      spec = {
        addresses = ["${var.metallb_api_vip}/32"]
        serviceAllocation = {
          priority   = 100
          namespaces = ["default"]
        }
      }
    }),
    yamlencode({
      apiVersion = "metallb.io/v1beta1"
      kind       = "IPAddressPool"
      metadata   = { name = "ingress-pool", namespace = "metallb-system" }
      spec       = { addresses = ["${var.metallb_ingress_vip}/32"] }
    }),
    yamlencode({
      apiVersion = "metallb.io/v1beta1"
      kind       = "L2Advertisement"
      metadata   = { name = "l2-adv", namespace = "metallb-system" }
      spec       = { ipAddressPools = ["kube-api-pool", "ingress-pool"] }
    }),
  ])

  manifest_network_services = join("\n---\n", [
    yamlencode({
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "kubernetes-vip"
        namespace = "default"
        annotations = { "metallb.io/loadBalancerIPs" = var.metallb_api_vip }
      }
      spec = {
        type = "LoadBalancer"
        ports = [
          { name = "k8s-api", port = 6443, targetPort = 6443, protocol = "TCP" },
          { name = "rke2-api", port = 9345, targetPort = 9345, protocol = "TCP" },
        ]
      }
    }),
    yamlencode({
      apiVersion = "v1"
      kind       = "Endpoints"
      metadata   = { name = "kubernetes-vip", namespace = "default" }
      subsets = [{
        addresses = [for ip in local.control_plane_ips : { ip = ip }]
        ports = [
          { name = "k8s-api", port = 6443, protocol = "TCP" },
          { name = "rke2-api", port = 9345, protocol = "TCP" },
        ]
      }]
    }),
    yamlencode({
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "rke2-ingress-lb"
        namespace = "kube-system"
        annotations = { "metallb.io/loadBalancerIPs" = var.metallb_ingress_vip }
      }
      spec = {
        type     = "LoadBalancer"
        selector = { "app.kubernetes.io/name" = "rke2-ingress-nginx" }
        ports = [
          { name = "http", port = 80, targetPort = 80, protocol = "TCP" },
          { name = "https", port = 443, targetPort = 443, protocol = "TCP" },
        ]
      }
    }),
  ])

  manifest_rancher_tls = var.tls_source == "secret" ? yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "tls-rancher-ingress", namespace = "cattle-system" }
    type       = "kubernetes.io/tls"
    data = {
      "tls.crt" = base64encode(var.tls_cert)
      "tls.key" = base64encode(var.tls_key)
    }
  }) : ""

  # ── Per-VM rancherd configs ──────────────────────────────────────────────────
  rancherd_configs = {
    for key, vm in local.vms : key => yamlencode(
      vm.is_bootstrap
      ? {
          role              = "cluster-init"
          kubernetesVersion = var.rke2_version
          rancherVersion    = var.rancher_version
          token             = random_password.rke2_token.result
          tlsSans           = var.tls_san_extra
          extraConfig = {
            disable   = ["servicelb"]
            "node-ip" = vm.ip_address
          }
          rancherValues = {
            hostname          = var.rancher_hostname
            bootstrapPassword = var.bootstrap_password
            replicas          = var.rancher_replicas
            hostPort          = 8443
            ingress = {
              enabled = true
              tls     = { source = var.tls_source }
            }
          }
        }
      : (vm.is_server ? {
          role        = "server"
          server      = "https://${local.bootstrap_ip}:8443"
          token       = random_password.rke2_token.result
          extraConfig = { disable = ["servicelb"], "node-ip" = vm.ip_address }
        } : {
          role        = "agent"
          server      = "https://${local.bootstrap_ip}:8443"
          token       = random_password.rke2_token.result
          extraConfig = { "node-ip" = vm.ip_address }
        })
    )
  }
}

# ── Per-VM cloud-init secrets ─────────────────────────────────────────────────
resource "harvester_cloudinit_secret" "cloudinit" {
  for_each   = local.vms
  name       = "${var.vm_name_prefix}-${each.key}-ci"
  namespace  = var.harvester_namespace
  depends_on = [kubernetes_namespace.ns]

  user_data = templatefile("${path.module}/templates/user-data.yaml.tpl", {
    password     = var.vm_password
    primary_dns  = var.primary_dns
    is_bootstrap = each.value.is_bootstrap
    bootstrap_ip = local.bootstrap_ip
    tls_source   = var.tls_source

    rancherd_config = local.rancherd_configs[each.key]

    manifest_metallb_ns        = each.value.is_bootstrap ? local.manifest_metallb_ns : ""
    manifest_metallb_helmchart = each.value.is_bootstrap ? local.manifest_metallb_helmchart : ""
    manifest_metallb_config    = each.value.is_bootstrap ? local.manifest_metallb_config : ""
    manifest_network_services  = each.value.is_bootstrap ? local.manifest_network_services : ""
    manifest_rancher_tls       = each.value.is_bootstrap ? local.manifest_rancher_tls : ""
  })

  network_data = templatefile("${path.module}/templates/network-data.yaml.tpl", {
    node_ip       = each.value.ip_address
    subnet_prefix = each.value.pool.subnet_prefix
    gateway       = each.value.pool.gateway
    dns           = var.primary_dns != "" ? var.primary_dns : "8.8.8.8"
  })
}

# ── VMs ───────────────────────────────────────────────────────────────────────
resource "harvester_virtualmachine" "vm" {
  for_each             = local.vms
  name                 = "${var.vm_name_prefix}-${each.key}"
  namespace            = var.harvester_namespace
  restart_after_update = true
  depends_on           = [harvester_network.bridge]

  cpu          = each.value.pool.cpu_count
  memory       = each.value.pool.memory_size
  run_strategy = "RerunOnFailure"
  machine_type = "q35"

  network_interface {
    name         = "default"
    type         = "bridge"
    network_name = local.network_name_full
  }

  disk {
    name        = "disk-0"
    type        = "disk"
    size        = each.value.pool.disk_size
    bus         = "virtio"
    boot_order  = 1
    image       = local.image_id
    auto_delete = true
  }

  input {
    name = "tablet"
    type = "tablet"
    bus  = "usb"
  }

  cloudinit {
    user_data_secret_name    = harvester_cloudinit_secret.cloudinit[each.key].name
    network_data_secret_name = harvester_cloudinit_secret.cloudinit[each.key].name
  }
}

# ── Storage class (optional) ──────────────────────────────────────────────────
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
