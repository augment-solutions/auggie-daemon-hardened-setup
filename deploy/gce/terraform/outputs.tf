output "instance_template_id" {
  description = "Created regional instance template ID."
  value       = google_compute_instance_template.auggie.id
}

output "regional_mig_id" {
  description = "Created regional managed instance group ID."
  value       = google_compute_region_instance_group_manager.auggie.id
}