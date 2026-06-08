#cloud-config
ssh_pwauth: true
chpasswd:
  list:
    - "ubuntu:${password}"
  expire: False

ssh_authorized_keys:
  - ${ssh_public_key}
%{~ if primary_dns != "" }

bootcmd:
  - mkdir -p /etc/systemd/resolved.conf.d
  - "echo '[Resolve]' > /etc/systemd/resolved.conf.d/primary-dns.conf"
  - "echo 'DNS=${primary_dns}' >> /etc/systemd/resolved.conf.d/primary-dns.conf"
  - systemctl restart systemd-resolved
%{~ endif }

packages:
  - qemu-guest-agent
  - curl

runcmd:
  - systemctl enable --now qemu-guest-agent
  - |
    (
      # Configure static IP on the primary non-loopback interface.
      # Done first so subsequent internet checks use the correct IP and gateway.
      IFACE=$(ip -o link show | awk -F': ' '$2 !~ /^lo$/ {print $2; exit}')
      mkdir -p /etc/netplan
      cat > /etc/netplan/60-rke2-static.yaml <<NETCFG
      network:
        version: 2
        ethernets:
          $IFACE:
            dhcp4: false
            addresses:
              - ${node_ip}/${subnet_prefix}
            routes:
              - to: default
                via: ${gateway}
            nameservers:
              addresses:
                - ${dns}
    NETCFG
      netplan apply --timeout 10 || true

      until curl -s --connect-timeout 5 http://1.1.1.1 > /dev/null; do
        sleep 5
      done

%{~ if is_server }
      curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${rke2_version} INSTALL_RKE2_TYPE=server sh -
%{~ else }
      curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${rke2_version} INSTALL_RKE2_TYPE=agent sh -
%{~ endif }

      mkdir -p /etc/rancher/rke2
%{~ if is_bootstrap }

      cat > /etc/rancher/rke2/config.yaml <<'RKCFG'
      token: ${rke2_token}
      cluster-init: true
      node-ip: ${node_ip}
      tls-san:
        - ${node_ip}
%{~ for san in tls_san_extra }
        - ${san}
%{~ endfor }
%{~ if disable_servicelb }
      disable:
        - servicelb
%{~ endif }
    RKCFG

      systemctl enable rke2-server
      systemctl start rke2-server

      ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
      until [ -f /etc/rancher/rke2/rke2.yaml ]; do sleep 5; done
      mkdir -p /home/ubuntu/.kube
      cp /etc/rancher/rke2/rke2.yaml /home/ubuntu/.kube/config
      chown -R ubuntu:ubuntu /home/ubuntu/.kube
      chmod 600 /home/ubuntu/.kube/config
%{~ else }

      # Wait for bootstrap node (${bootstrap_ip}) to accept joins on port 9345.
      until timeout 5 bash -c "</dev/tcp/${bootstrap_ip}/9345" 2>/dev/null; do
        sleep 15
      done

      cat > /etc/rancher/rke2/config.yaml <<'RKCFG'
      token: ${rke2_token}
      server: https://${bootstrap_ip}:9345
      node-ip: ${node_ip}
      tls-san:
        - ${node_ip}
%{~ for san in tls_san_extra }
        - ${san}
%{~ endfor }
%{~ if disable_servicelb }
      disable:
        - servicelb
%{~ endif }
    RKCFG

%{~ if is_server }
      systemctl enable rke2-server
      systemctl start rke2-server
%{~ else }
      systemctl enable rke2-agent
      systemctl start rke2-agent
%{~ endif }
%{~ endif }
    ) >> /var/log/rke2-install.log 2>&1 &
