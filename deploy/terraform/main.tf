# These "locals" help us manipulating string type variables,
# letting us sum the ip last bit and the vm counter.index 
# avoiding to spoil code readability inside resources section

locals {
  etcd_substring         = element(split(".", "${var.ci_ip0["etcd"]}"), 3)
  etcd_number            = tonumber(element(split(".", "${var.ci_ip0["etcd"]}"), 3))
  admin_substring        = element(split(".", "${var.ci_ip0["admin"]}"), 3)
  admin_number    = tonumber(element(split(".", "${var.ci_ip0["admin"]}"), 3))
  tenant-worker_substring = element(split(".", "${var.ci_ip0["tenant-worker"]}"), 3)
  tenant-worker_number    = tonumber(element(split(".", "${var.ci_ip0["tenant-worker"]}"), 3))
}

resource "proxmox_vm_qemu" "etcd_vm" {
  count                     = var.vms_number["etcd"]
  name                      = "${var.vm_prefix}-etcd-0${count.index}"
  desc                      = "${var.vm_prefix}-etcd"
  vmid                      = var.vms_id["etcd"] + count.index
  target_node               = "labs"
  pool                      = var.vm_pool
  clone                     = var.vms_template["etcd"]
  cores                     = 2
  sockets                   = 2
  cpu                       = "host"
  memory                    = 8192
  scsihw                    = "virtio-scsi-pci"
  qemu_os                   = "l26"
  agent                     = 1
  guest_agent_ready_timeout = 60
  boot                      = "order=scsi0"

  # CLOUD INIT PROVISIONING
  os_type      = "cloud-init"
  ciuser       = var.ci_user
  cipassword   = var.ci_password
  searchdomain = var.dns_domain
  nameserver   = var.dns_servers
  ipconfig0    = join("", [replace("ip=${var.ci_ip0["etcd"]}", local.etcd_substring, local.etcd_number + count.index), "/", var.ci_length0, ",gw=", var.ci_gateway0])
  sshkeys      = var.ssh_keys

  disk {
    size     = "16G"
    format   = "raw"
    type     = "scsi"
    storage  = var.disk_storage
    iothread = 0
  }

  disk {
    size     = "10G"
    format   = "raw"
    type     = "scsi"
    storage  = "local"
    ssd      = 1
    iothread = 0
  }

  network {
    model  = "virtio"
    bridge = var.network_bridge
  }

  lifecycle {
    ignore_changes = [
      network
    ]
  }
}

resource "proxmox_vm_qemu" "admin_vm" {
  count                     = var.vms_number["admin"]
  name                      = "${var.vm_prefix}-admin-0${count.index}"
  desc                      = "${var.vm_prefix}-admin"
  vmid                      = var.vms_id["admin"] + count.index
  target_node               = "labs"
  pool                      = var.vm_pool
  clone                     = var.vms_template["admin"]
  cores                     = 2
  sockets                   = 2
  cpu                       = "host"
  memory                    = 8192
  scsihw                    = "virtio-scsi-pci"
  qemu_os                   = "l26"
  agent                     = 1
  guest_agent_ready_timeout = 60
  boot                      = "order=scsi0"

  # CLOUD INIT PROVISIONING
  os_type      = "cloud-init"
  ciuser       = var.ci_user
  cipassword   = var.ci_password
  searchdomain = var.dns_domain
  nameserver   = var.dns_servers
  ipconfig0    = join("", [replace("ip=${var.ci_ip0["admin"]}", local.admin_substring, local.admin_number + count.index), "/", var.ci_length0, ",gw=", var.ci_gateway0])
  sshkeys      = var.ssh_keys

  disk {
    size     = "16G"
    format   = "raw"
    type     = "scsi"
    storage  = var.disk_storage
    iothread = 0
  }

  network {
    model  = "virtio"
    bridge = var.network_bridge
  }

  lifecycle {
    ignore_changes = [
      network
    ]
  }
}

resource "proxmox_vm_qemu" "tenant-worker_vm" {
  count                     = var.vms_number["tenant-worker"]
  name                      = "${var.vm_prefix}-tenant-worker-0${count.index}"
  desc                      = "${var.vm_prefix}-tenant-worker"
  vmid                      = var.vms_id["tenant-worker"] + count.index
  target_node               = "labs"
  pool                      = var.vm_pool
  clone                     = var.vms_template["tenant-worker"]
  cores                     = 2
  sockets                   = 1
  cpu                       = "host"
  memory                    = 4096
  scsihw                    = "virtio-scsi-pci"
  qemu_os                   = "l26"
  agent                     = 1
  guest_agent_ready_timeout = 60
  boot                      = "order=scsi0"

  # CLOUD INIT PROVISIONING
  os_type      = "cloud-init"
  ciuser       = var.ci_user
  cipassword   = var.ci_password
  searchdomain = var.dns_domain
  nameserver   = var.dns_servers
  ipconfig0    = join("", [replace("ip=${var.ci_ip0["tenant-worker"]}", local.tenant-worker_substring, local.tenant-worker_number + count.index), "/", var.ci_length0, ",gw=", var.ci_gateway0])
  sshkeys      = var.ssh_keys

  disk {
    size     = "16G"
    format   = "raw"
    type     = "scsi"
    storage  = var.disk_storage
    iothread = 0
  }

  network {
    model  = "virtio"
    bridge = var.network_bridge
  }

  lifecycle {
    ignore_changes = [
      network
    ]
  }
}