resource "google_storage_bucket" "cnpg" {
    name = "cnpg-backups"
    location = "var.region"
    storage_class = "STANDARD"
    project = var.project
    force_destroy = true
    uniform_bucket_level_access = true
    versioning {
        enabled = false
    }
}