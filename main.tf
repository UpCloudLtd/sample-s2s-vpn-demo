
resource "upcloud_network" "backend_network" {
  name = "backend_network"
  zone = var.zone

  ip_network {
    address            = var.upcloud_network
    dhcp               = true
    dhcp_default_route = false
    family             = "IPv4"
  }
}
resource "upcloud_server" "s2s_vpn_vm" {
  hostname   = "s2s-vpn-vm-${var.zone}"
  zone       = var.zone
  plan       = var.server_plan
  metadata   = true
  depends_on = [upcloud_network.backend_network]
  template {
    storage = "Ubuntu Server 22.04 LTS (Jammy Jellyfish)"
    size    = 25
  }
  network_interface {
    type = "public"
  }
  network_interface {
    type = "utility"
  }
  network_interface {
    type    = "private"
    network = upcloud_network.backend_network.id
    source_ip_filtering = false
  }

  login {
    user = "root"
    keys = [
      var.ssh_key_public,
    ]
    create_password   = false
    password_delivery = "email"
  }

  connection {
    host  = self.network_interface[0].ip_address
    type  = "ssh"
    user  = "root"
    agent = true
  }

  provisioner "remote-exec" {
    inline = [
      "apt-get -o 'Dpkg::Options::=--force-confold' -q -y update",
      "echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf",
      "echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf",
      "echo 'net.ipv4.conf.all.accept_redirects = 0' >> /etc/sysctl.conf",
      "echo 'net.ipv4.conf.all.send_redirects = 0' >> /etc/sysctl.conf",
      "sysctl -p",
      "apt-get -o 'Dpkg::Options::=--force-confold' -q -y install strongswan strongswan-pki libcharon-extra-plugins libcharon-extauth-plugins libstrongswan-extra-plugins libtss2-tcti-tabrmd-dev",
      "ipsec pki --gen --size 4096 --type rsa --outform pem > /etc/ipsec.d/private/ca.key.pem",
      "ipsec pki --self --in /etc/ipsec.d/private/ca.key.pem --type rsa --dn 'CN=Upcloud VPN VM CA' --ca --lifetime 3650 --outform pem > /etc/ipsec.d/cacerts/ca.cert.pem",
      "ipsec pki --gen --size 4096 --type rsa --outform pem > /etc/ipsec.d/private/server.key.pem",
      "ipsec pki --pub --in /etc/ipsec.d/private/server.key.pem --type rsa | ipsec pki --issue --lifetime 2750 --cacert /etc/ipsec.d/cacerts/ca.cert.pem --cakey /etc/ipsec.d/private/ca.key.pem --dn \"CN=${self.network_interface[0].ip_address}\" --san=${self.network_interface[0].ip_address} --san=@${self.network_interface[0].ip_address}--flag serverAuth --flag ikeIntermediate --outform pem > /etc/ipsec.d/certs/server.cert.pem",
      "echo \"${self.network_interface[0].ip_address} ${var.remote_ip} : PSK \"${var.ipsec_psk}\"\" > /etc/ipsec.secrets"
    ]
  }
  provisioner "file" {
    content = templatefile("configs/ipsec.conf.tftpl", {
      UPCLOUD_VM      = self.network_interface[0].ip_address,
      REMOTE_VM       = var.remote_ip,
      UPCLOUD_NETWORK = var.upcloud_network,
    REMOTE_NETWORK = var.remote_network })
    destination = "/etc/ipsec.conf"
  }
  provisioner "remote-exec" {
    inline = [
      "systemctl enable strongswan-starter",
      "systemctl restart strongswan-starter"
    ]
  }
}
