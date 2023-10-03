resource "google_project_iam_member" "cnpg" {
    project = var.project
    role = "roles/storage.admin"
    member = "serviceAccount:${google_service_account.cnpg.email}"
}

resource "google_service_account_iam_member" "cnpg" {
    service_account_id = google_service_account.cnpg.id
    role = "roles/iam.workloadIdentityUser"
    member = "serviceAccount:${var.project}.svc.id.goog[cnpg/cluster-cnpg]"
}