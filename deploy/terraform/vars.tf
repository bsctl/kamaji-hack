# Provider vars

variable "pm_api_url" {
  type        = string
  description = "URL for Proxmox endpoint"
  default     = "https://labs.clastix.io:8006/api2/json"
}

variable "pm_user" {
  type        = string
  description = "User for Proxmox"
}

variable "pm_password" {
  type        = string
  description = "Password for Proxmox user"
  sensitive   = true
}

variable "pm_parallel" {
  type        = number
  description = "Total parallel running tasks for Proxmox"
  default     = 3
}

# VMs vars

variable "vm_prefix" {
  type        = string
  description = "Prefix placed before vm name and description"
}

variable "vm_pool" {
  type        = string
  description = "Resource pool in which to place the vm"
}

variable "vms_number" {
  type        = map(number)
  description = "Cluster VMs desired number"
  default = {
    "etcd"                = 3
    "admin"               = 6
    "tenant-worker"       = 4
  }
}

variable "vms_id" {
  type        = map(number)
  description = "Cluster VMs desired ID"
}

variable "vms_template" {
  type        = map(string)
  description = "Cluster VMs desired template"
  default = {
    "etcd"          = "ubuntu-vanilla"
    "admin"         = "ubuntu-vanilla"
    "tenant-worker" = "ubuntu-vanilla"
  }
}

## VMs vars - cloud-init

variable "ci_user" {
  type        = string
  description = "Cloud-init user"
  default     = "clastix"
}

variable "ci_password" {
  type        = string
  description = "Cloud-init user password"
  default     = "password"
  sensitive   = true
}

variable "dns_domain" {
  type        = string
  description = "Cloud-init dns domain"
  default     = "clastix.labs"
}

variable "dns_servers" {
  type        = string
  description = "Cloud-init dns servers"
  default     = "192.168.1.100"
}

variable "ssh_keys" {
  type        = string
  description = "Cloud-init user authorized public keys"
}

variable "ci_ip0" {
  type        = map(string)
  description = "Cloud-init IP network config; CIDR last bit will be automatically placed"
}

variable "ci_length0" {
  type        = number
  description = "Cloud-init CIDR length"
  default     = 24
}

variable "ci_gateway0" {
  type        = string
  description = "Cloud-init GW network config"
}

## VMs vars - disks

variable "disk_storage" {
  type        = string
  description = "Disk storage in which to place the vm"
  default     = "local"
}

## VMs vars - network

variable "network_bridge" {
  type        = string
  description = "Network of clastix user"
}