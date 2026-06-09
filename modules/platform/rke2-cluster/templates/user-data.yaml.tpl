#cloud-config
ssh_pwauth: true
chpasswd:
  list:
    - "ubuntu:${password}"
  expire: False

bootcmd:
  - mkdir -p /etc/rancher/rancherd
%{~ if is_bootstrap }
  - mkdir -p /var/lib/rancher/rke2/server/manifests
%{~ endif }
%{~ if primary_dns != "" }
  - mkdir -p /etc/systemd/resolved.conf.d
  - "echo '[Resolve]' > /etc/systemd/resolved.conf.d/primary-dns.conf"
  - "echo 'DNS=${primary_dns}' >> /etc/systemd/resolved.conf.d/primary-dns.conf"
  - systemctl restart systemd-resolved
%{~ endif }

packages:
  - qemu-guest-agent
  - curl

write_files:
  - path: /etc/rancher/rancherd/config.yaml
    permissions: '0600'
    encoding: b64
    content: ${base64encode(rancherd_config)}

%{~ if is_bootstrap }
  - path: /var/lib/rancher/rke2/server/manifests/01-metallb-ns.yaml
    encoding: b64
    content: ${base64encode(manifest_metallb_ns)}

  - path: /var/lib/rancher/rke2/server/manifests/02-metallb-helmchart.yaml
    encoding: b64
    content: ${base64encode(manifest_metallb_helmchart)}

  - path: /var/lib/rancher/rke2/server/manifests/03-metallb-config.yaml
    encoding: b64
    content: ${base64encode(manifest_metallb_config)}

  - path: /var/lib/rancher/rke2/server/manifests/04-network-services.yaml
    encoding: b64
    content: ${base64encode(manifest_network_services)}

%{~ if tls_source == "secret" }
  - path: /var/lib/rancher/rke2/server/manifests/05-rancher-tls.yaml
    permissions: '0600'
    encoding: b64
    content: ${base64encode(manifest_rancher_tls)}
%{~ endif }
%{~ endif }

runcmd:
  - systemctl enable --now qemu-guest-agent
  - |
    (
      until curl -s --connect-timeout 5 http://1.1.1.1 >/dev/null; do sleep 5; done
      curl -sfL https://raw.githubusercontent.com/harvester/rancherd/harvester-dev/install.sh | sh -
      systemctl enable rancherd
      systemctl start rancherd
    ) >> /var/log/rancherd-install.log 2>&1 &
