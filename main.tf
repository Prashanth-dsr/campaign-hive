terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.30"
    }
  }
}

# -----------------------
# Variables
# -----------------------
variable "project_id"  { type = string defalut = "iron-portfolio-470506-p3"}
variable "region"      { type = string  default = "asia-south1" }
variable "app_name"    { type = string  default = "campaign-hive" }
variable "repo_id"     { type = string  default = "campaign-app-repo" } # Artifact Registry repo
variable "db_tier"     { type = string  default = "db-f1-micro" }
variable "db_version"  { type = string  default = "POSTGRES_15" }
variable "db_name"     { type = string  default = "appdb" }
variable "db_user"     { type = string  default = "appuser" }
variable "db_password" { type = string  sensitive = true }
variable "jwt_secret"  { type = string  sensitive = true }
variable "public_service" { type = bool default = true } # make Cloud Run public

# -----------------------
# Providers
# -----------------------
provider "google" {
  project = var.project_id
  region  = var.region
}
provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# -----------------------
# Enable Required APIs
# -----------------------
resource "google_project_service" "services" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
    "cloudbuild.googleapis.com"
  ])
  project = var.project_id
  service = each.key
  disable_on_destroy = false
}

# -----------------------
# Artifact Registry (Docker)
# -----------------------
resource "google_artifact_registry_repository" "repo" {
  location        = var.region
  repository_id   = var.repo_id
  description     = "Docker images for ${var.app_name}"
  format          = "DOCKER"
  depends_on      = [google_project_service.services]
}

# -----------------------
# Service Account for Cloud Run (least privilege)
# -----------------------
resource "google_service_account" "run_sa" {
  account_id   = "${var.app_name}-sa"
  display_name = "SA for ${var.app_name} (Cloud Run)"
}

# Allow pulling images from this repo
resource "google_artifact_registry_repository_iam_member" "repo_reader" {
  location   = google_artifact_registry_repository.repo.location
  repository = google_artifact_registry_repository.repo.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.run_sa.email}"
}

# Allow connecting to Cloud SQL
resource "google_project_iam_member" "cloudsql_client" {
  role   = "roles/cloudsql.client"
  member = "serviceAccount:${google_service_account.run_sa.email}"
}

# Secret access (we’ll bind per-secret below for least privilege)
# (No broad project-level secret accessor role given.)

# -----------------------
# Secret Manager
# -----------------------
resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.app_name}-db-password"
  replication { automatic = true }
}
resource "google_secret_manager_secret_version" "db_password_v1" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}

resource "google_secret_manager_secret" "jwt_secret" {
  secret_id = "${var.app_name}-jwt"
  replication { automatic = true }
}
resource "google_secret_manager_secret_version" "jwt_secret_v1" {
  secret      = google_secret_manager_secret.jwt_secret.id
  secret_data = var.jwt_secret
}

# Bind least-privilege access to only the needed secrets
resource "google_secret_manager_secret_iam_member" "db_password_accessor" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run_sa.email}"
}
resource "google_secret_manager_secret_iam_member" "jwt_accessor" {
  secret_id = google_secret_manager_secret.jwt_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run_sa.email}"
}

# -----------------------
# Cloud SQL (postgreSQL)
# - Public IP + Cloud SQL connector from Cloud Run (no VPC needed)
# -----------------------
resource "google_sql_database_instance" "db" {
  name             = "${var.app_name}-postgresql"
  database_version = var.db_version
  region           = var.region
  settings {
    tier = var.db_tier
    ip_configuration {
      ipv4_enabled = true
      # For personal projects, public IP + connector is simplest.
      # (For private IP you'd also set up VPC + Serverless VPC Access.)
    }
  }
  deletion_protection = false
  depends_on = [google_project_service.services]
}

resource "google_sql_user" "user" {
  instance = google_sql_database_instance.db.name
  name     = var.db_user
  password = var.db_password
}

resource "google_sql_database" "appdb" {
  name     = var.db_name
  instance = google_sql_database_instance.db.name
}

# -----------------------
# Cloud Run (v2) service
# -----------------------
resource "google_cloud_run_v2_service" "service" {
  name     = var.app_name
  location = var.region

  template {
    service_account = google_service_account.run_sa.email

    # Connect to Cloud SQL via connector (public IP)
    annotations = {
      "run.googleapis.com/cloudsql-instances" = google_sql_database_instance.db.connection_name
    }

    containers {
      # Update this image after your CI builds & pushes to Artifact Registry.
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo_id}/${var.app_name}:latest"

      # Example envs for your Next.js app
      env {
        name  = "DB_HOST"                # Unix socket path for Cloud SQL connector
        value = "/cloudsql/${google_sql_database_instance.db.connection_name}"
      }
      env { name = "DB_NAME"  value = var.db_name }
      env { name = "DB_USER"  value = var.db_user }

      # Secrets → mounted as env vars
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.name
            version = "latest"
          }
        }
      }
      env {
        name = "JWT_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.jwt_secret.name
            version = "latest"
          }
        }
      }

      # If you need port other than 8080, set container start options accordingly.
      # Cloud Run expects the app to listen on $PORT (provided at runtime).
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_service.services,
    google_artifact_registry_repository.repo,
    google_sql_database_instance.db,
    google_secret_manager_secret_version.db_password_v1,
    google_secret_manager_secret_version.jwt_secret_v1
  ]
}

# Make service public (optional)
resource "google_cloud_run_service_iam_member" "invoker" {
  location = google_cloud_run_v2_service.service.location
  service  = google_cloud_run_v2_service.service.name
  role     = "roles/run.invoker"
  member   = var.public_service ? "allUsers" : "serviceAccount:${google_service_account.run_sa.email}"
}

# -----------------------
# Outputs
# -----------------------
output "cloud_run_url" {
  value       = google_cloud_run_v2_service.service.uri
  description = "Public URL of the Cloud Run service"
}
output "cloud_sql_connection_name" {
  value       = google_sql_database_instance.db.connection_name
  description = "Cloud SQL connection name for connector/DB tools"
}
output "artifact_registry_repo" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo_id}"
  description = "Push images here: docker tag/push"
}
