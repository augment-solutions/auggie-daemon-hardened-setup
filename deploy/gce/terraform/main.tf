locals {
  common_metadata = {
    "startup-script"                 = file("${path.module}/../startup-${var.deployment_mode}.sh")
    "augment-common-script"          = file("${path.module}/../lib/gce-common.sh")
    "augment-pool-id"                = var.pool_id
    "augment-secret-project-id"      = var.secret_project_id
    "augment-session-secret-id"      = var.session_secret_id
    "augment-session-secret-version" = var.session_secret_version
    "augment-max-agents"             = tostring(var.max_agents)
    "disable-legacy-endpoints"       = "true"
  }
  mode_metadata = var.deployment_mode == "direct" ? {
    "augment-linux-installer" = file("${path.module}/../../../setup-auggie-daemon-linux.sh")
    "augment-auggie-version"  = var.auggie_version
    } : {
    "augment-runtime-image"   = var.runtime_image
    "augment-bootstrap-image" = var.bootstrap_image
    "augment-memory-limit"    = var.container_memory_limit
    "augment-cpu-limit"       = var.container_cpu_limit
    "augment-pids-limit"      = tostring(var.container_pids_limit)
  }
}

resource "google_secret_manager_secret_iam_member" "session_accessor" {
  project   = var.secret_project_id
  secret_id = var.session_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.service_account_email}"
}

resource "google_project_iam_member" "artifact_reader" {
  count   = var.deployment_mode == "container" ? 1 : 0
  project = coalesce(var.artifact_registry_project_id, var.project_id)
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${var.service_account_email}"
}

resource "google_compute_instance_template" "auggie" {
  project      = var.project_id
  region       = var.region
  name_prefix  = "auggie-${var.deployment_mode}-"
  machine_type = var.machine_type
  labels       = merge(var.labels, { workload = "auggie-daemon" })
  metadata     = merge(local.common_metadata, local.mode_metadata)

  disk {
    source_image = var.source_image
    boot         = true
    auto_delete  = true
    disk_type    = "pd-balanced"
    disk_size_gb = var.boot_disk_size_gb
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
  }

  service_account {
    email  = var.service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = var.deployment_mode != "container" || (var.runtime_image != null && var.bootstrap_image != null && var.artifact_registry_project_id != null)
      error_message = "Container mode requires runtime_image, bootstrap_image, and artifact_registry_project_id."
    }
    precondition {
      condition     = var.deployment_mode != "container" || try(regex("^([a-z0-9-]+\\.)?(pkg\\.dev|gcr\\.io)/[^[:space:]]+@sha256:[0-9a-f]{64}$", var.bootstrap_image), null) != null
      error_message = "bootstrap_image must be an Artifact Registry or gcr.io URI pinned by sha256 digest."
    }
    precondition {
      condition     = var.deployment_mode != "container" || try(regex("^([a-z0-9-]+\\.)?(pkg\\.dev|gcr\\.io)/[^[:space:]]+@sha256:[0-9a-f]{64}$", var.runtime_image), null) != null
      error_message = "runtime_image must be an Artifact Registry or gcr.io URI pinned by sha256 digest."
    }
    precondition {
      condition     = var.deployment_mode != "direct" || (var.runtime_image == null && var.bootstrap_image == null)
      error_message = "Direct mode must leave runtime_image and bootstrap_image null."
    }
    precondition {
      condition     = alltrue([for zone in var.zones : startswith(zone, "${var.region}-")])
      error_message = "Every zone must belong to region."
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.session_accessor,
    google_project_iam_member.artifact_reader,
  ]
}

resource "google_compute_region_instance_group_manager" "auggie" {
  project            = var.project_id
  region             = var.region
  name               = "auggie-${var.deployment_mode}"
  base_instance_name = "auggie-${var.deployment_mode}"
  target_size        = var.target_size

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.auggie.id
  }

  distribution_policy_zones = var.zones

  update_policy {
    type                           = "PROACTIVE"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    replacement_method             = "SUBSTITUTE"
    max_surge_fixed                = length(var.zones)
    max_unavailable_fixed          = 0
  }
}