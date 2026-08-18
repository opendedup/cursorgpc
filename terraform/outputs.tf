output "project_id" {
  description = "Project hosting the worker fleet."
  value       = var.project_id
}

output "region" {
  description = "Region hosting the worker fleet."
  value       = var.region
}

output "zones" {
  description = "Zones the fleet is distributed across."
  value       = local.zones
}

output "instance_group_manager" {
  description = "Name of the regional managed instance group that runs the workers."
  value       = google_compute_region_instance_group_manager.worker.name
}

output "instance_template" {
  description = "Name of the current worker instance template."
  value       = google_compute_instance_template.worker.name
}

output "machine_type" {
  description = "Machine type each worker runs on."
  value       = var.machine_type
}

output "worker_count" {
  description = "Configured number of workers."
  value       = var.worker_count
}

output "service_account_email" {
  description = "Service account attached to the workers."
  value       = google_service_account.worker.email
}

output "api_key_secret_id" {
  description = "Secret Manager secret the workers read the Cursor service account API key from."
  value       = var.cursor_api_key_secret_id
}

output "network" {
  description = "VPC network the workers attach to."
  value       = local.network_name
}

output "subnetwork" {
  description = "Subnetwork the workers attach to."
  value       = local.subnetwork_name
}

output "worker_mode" {
  description = "Whether workers register for pool assignment or as My Machines workers."
  value       = var.worker_mode
}

output "cursor_pool_name" {
  description = "Cursor pool name workers register with. Target it from a trigger with pool=<name>."
  value       = var.worker_pool_name
}

output "set_api_key_command" {
  description = "Command that stores the Cursor service account API key so workers can read it."
  value       = "printf %s \"$CURSOR_API_KEY\" | gcloud secrets versions add ${var.cursor_api_key_secret_id} --project=${var.project_id} --data-file=-"
}

output "list_workers_command" {
  description = "Command that lists the VMs currently in the fleet."
  value       = "gcloud compute instance-groups managed list-instances ${google_compute_region_instance_group_manager.worker.name} --project=${var.project_id} --region=${var.region}"
}

output "worker_logs_command" {
  description = "Command that tails worker service logs from Cloud Logging."
  value       = "gcloud logging read 'logName:\"cursor-worker\" OR jsonPayload.SYSLOG_IDENTIFIER=\"cursor-worker\"' --project=${var.project_id} --limit=100 --freshness=1h"
}
