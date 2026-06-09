version: 2
ethernets:
  enp1s0:
    dhcp4: false
    dhcp6: false
    addresses:
      - ${node_ip}/${subnet_prefix}
    routes:
      - to: default
        via: ${gateway}
    nameservers:
      addresses: [${dns}]
