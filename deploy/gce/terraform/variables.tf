variable "project_id" {
  description = "Project that owns the GCE regional MIG."
  type        = string
}

variable "region" {
  description = "GCE region for the instance template and MIG."
  type        = string
}

variable "zones" {
  description = "Two or more zones in region used by the regional MIG."
  type        = list(string)
  validation {
    condition     = length(var.zones) >= 2 && length(toset(var.zones)) == length(var.zones)
    error_message = "Provide at least two distinct zones from the selected region."
  }
}

variable "deployment_mode" {
  description = "Either direct or container."
  type        = string
  validation {
    condition     = contains(["direct", "container"], var.deployment_mode)
    error_message = "deployment_mode must be direct or container."
  }
}

variable "source_image" {
  description = "Full self_link of the customer-owned Rocky Linux 8 VM image."
  type        = string
}

variable "bootstrap_image" {
  description = "Container mode image URI pinned by @sha256; null for direct mode."
  type        = string
  default     = null
}

variable "runtime_image" {
  description = "Container mode customer private Rocky 8 image URI pinned by @sha256; null for direct mode."
  type        = string
  default     = null
}

variable "machine_type" {
  description = "Customer-selected GCE machine type."
  type        = string
}

variable "target_size" {
  description = "Number of daemon VMs in the regional MIG."
  type        = number
  validation {
    condition     = var.target_size >= 1 && floor(var.target_size) == var.target_size
    error_message = "target_size must be a positive integer."
  }
}

variable "network" {
  description = "Full self_link of the VPC network."
  type        = string
}

variable "subnetwork" {
  description = "Full self_link of the regional subnetwork."
  type        = string
}

variable "service_account_email" {
  description = "Existing user-managed VM service account email."
  type        = string
}

variable "secret_project_id" {
  description = "Project containing the Augment session Secret Manager secret."
  type        = string
}

variable "session_secret_id" {
  description = "Secret Manager secret ID containing session.json."
  type        = string
}

variable "session_secret_version" {
  description = "Numeric secret version or latest."
  type        = string
  default     = "latest"
  validation {
    condition     = var.session_secret_version == "latest" || can(regex("^[1-9][0-9]*$", var.session_secret_version))
    error_message = "session_secret_version must be latest or a positive integer."
  }
}

variable "artifact_registry_project_id" {
  description = "Project hosting the bootstrap image; required in container mode."
  type        = string
  default     = null
}

variable "pool_id" {
  description = "Augment daemon pool ID in pool-UUID form."
  type        = string
  sensitive   = false
  validation {
    condition     = can(regex("^pool-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.pool_id))
    error_message = "pool_id must be pool- followed by a UUID."
  }
}

variable "auggie_version" {
  description = "Exact Auggie CLI version for direct mode."
  type        = string
  default     = "0.32.0"
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?$", var.auggie_version))
    error_message = "auggie_version must be an exact version."
  }
}

variable "max_agents" {
  description = "Maximum concurrent Auggie agents per VM."
  type        = number
  default     = 4
  validation {
    condition     = var.max_agents >= 1 && floor(var.max_agents) == var.max_agents
    error_message = "max_agents must be a positive integer."
  }
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GiB."
  type        = number
  default     = 50
  validation {
    condition     = var.boot_disk_size_gb >= 20 && floor(var.boot_disk_size_gb) == var.boot_disk_size_gb
    error_message = "boot_disk_size_gb must be an integer of at least 20."
  }
}

variable "container_memory_limit" {
  description = "Podman memory limit in container mode."
  type        = string
  default     = "6g"
}

variable "container_cpu_limit" {
  description = "Podman CPU limit in container mode."
  type        = string
  default     = "2"
}

variable "container_pids_limit" {
  description = "Podman process limit in container mode."
  type        = number
  default     = 512
  validation {
    condition     = var.container_pids_limit >= 1 && floor(var.container_pids_limit) == var.container_pids_limit
    error_message = "container_pids_limit must be a positive integer."
  }
}

variable "labels" {
  description = "Additional labels for the instance template."
  type        = map(string)
  default     = {}
}