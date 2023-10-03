# Provisioning a PostgreSQL database cluster in Kubernetes using GKE and GCS

## Why should you use this and not?

Provisioning a PostgreSQL database in Kubernetes can provide benefits such as containerization for easy management, resource efficiency, isolation, automatic failover, scalability, and infrastructure agnosticism. However, it comes with complexity, resource overhead, data persistence challenges, potential performance trade-offs, and operational demands. Before choosing this approach, carefully consider your specific use case, expertise, and operational resources to determine whether the advantages outweigh the drawbacks. In some cases, a combination of traditional database hosting and Kubernetes for other application components may be a more suitable solution.

## What we we'll be using

In this article we explore the use of the new CNPG PostgreSQL Operator in kubernetes in order to provision a cluster.
We will be following a simple script:

1. [Setup a GCS bucket for backups](#setup-a-gcs-bucket-for-backups)
2. [Create a GKE cluster](#create-a-gke-cluster)
3. [Install the CNPG PostgreSQL Operator](#install-the-cnpg-postgresql-operator)
4. [Create an IAM role for the operator, enabling it to access the GCS bucket with Workload Identity.](#create-an-iam-role-for-the-operator)
5. [Create a PostgreSQL cluster](#create-a-postgresql-cluster)
6. [Connect to the database](#connect-to-the-database)
7. [Create a backup](#create-a-backup)
8. [Restore from backup](#restore-from-backup)

This explanaition assumes you already have a functional kubernetes cluster, and that you have the necessary permissions to create the resources mentioned above. If not, please refer to the [GKE quickstart](https://cloud.google.com/kubernetes-engine/docs/quickstart) and [GCS quickstart](https://cloud.google.com/storage/docs/quickstart-console) to get started.

Although it's not accessed in this article, there are other ways of backing up you Postgres data into object store, please follow the [official documentation](https://cloudnative-pg.io/documentation/1.20/) for more information.

All the code used in this article can be found in [this GitHub repository](https://github.com/zesilva15/cnpg-article).

## Setup a GCS bucket for backups

First, login in GCP and create a new project. Having done that install gcloud and run 
```bash
gcloud auth application-default login
```
logging in with the same account you used to create the project.

In order to store our backups, we will be using a GCS bucket. To create one, apply the terraform code, filling in the variables with your project id and the region you want to use. 

```terraform
provider "google" {
  project     = var.project
  region      = var.region
}
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}
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
```

## Create a GKE cluster

In order to create a GKE, simply run the following command, replacing the variables with your project id and the region you want to use.

```bash
gcloud container clusters create cnpg-cluster --zone=var.region --project=var.project
```

## Install the CNPG PostgreSQL Operator

To install the operator, run the command below having your context set to the cluster you just created.

```bash
kubectl apply -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.20/releases/cnpg-1.20.2.yaml
```

## Create an IAM role for the operator

In order to allow the operator to access the GCS bucket, we will be using Workload Identity. To do so, we need to create a service account for the operator, and then create a role binding between the service account and the IAM role we will create.

First, create a service account with the following terraform code, replacing the variables with your project id and the region you want to use.

```terraform
resource "google_service_account" "cnpg" {
    account_id = "cnpg"
}
```

And then create the IAM role with the following terraform code, replacing the variables with your project id and the region you want to use.

```terraform
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
```

## Create a PostgreSQL cluster

Now that we have everything set up, we can create our PostgreSQL cluster. To do so, we will be using the following yaml file, replacing the variables with your project id and the region you want to use.

This will create a 3 instance HA cluster, with a 1Gi volume, and a GCS bucket for backups.
The backups will go to the bucket we created earlier, and will be encrypted with a KMS key managed by GCP.


```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg
---
apiVersion: v1
data:
  password: VHhWZVE0bk44MlNTaVlIb3N3cU9VUlp2UURhTDRLcE5FbHNDRUVlOWJ3RHhNZDczS2NrSWVYelM1Y1U2TGlDMg==
  username: YXBw
kind: Secret
metadata:
  name: cluster-cnpg-app-user
  namespace: cnpg
type: kubernetes.io/basic-auth
---
apiVersion: v1
data:
  password: dU4zaTFIaDBiWWJDYzRUeVZBYWNCaG1TemdxdHpxeG1PVmpBbjBRSUNoc0pyU211OVBZMmZ3MnE4RUtLTHBaOQ==
  username: cG9zdGdyZXM=
kind: Secret
metadata:
  name: cluster-cnpg-superuser
  namespace: cnpg
type: kubernetes.io/basic-auth
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-cnpg
  namespace: cnpg
spec:
  description: "This is an example cluster"
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgis:15-3.3
  bootstrap:
    initdb:
      database: postgres
      owner: postgres
      secret:
        name: cluster-cnpg-app-user
      postInitTemplateSQL:
        - CREATE EXTENSION postgis;
        - CREATE EXTENSION postgis_topology;
        - CREATE EXTENSION fuzzystrmatch;
        - CREATE EXTENSION postgis_tiger_geocoder;
  storage:
    size: 1Gi
    storageClass: standard
  backup:
    barmanObjectStore:
      destinationPath: "gs://cnpg-backups/cluster-cnpg"
      googleCredentials:
        gkeEnvironment: true
  serviceAccountTemplate:
    metadata:
      annotations:
        iam.gke.io/gcp-service-account: cnpg@<project>.iam.gserviceaccount.com
  monitoring:
    enablePodMonitor: true
```

## Connect to the database

In order to connect to the database, we will be portforwarding the service to our local machine. To do so, run the following command, replacing the variables with your project id and the region you want to use.

```bash
kubectl port-forward svc/cluster-cnpg-rw 5432:5432 --namespace=cnpg
```

You can expose permanently the service by installing the [Nginx Ingress Controller](https://kubernetes.github.io/ingress-nginx/deploy/#gce-gke) and exposing the ClusterIP service as a TCP service in the ingress controller, redirecting it as <LB-IP>:5432.

## Create a backup

In order to create a backup instantly we can suimply apply a backup resource into the cluster, such as:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: backup-on-demand
spec:
  cluster:
    name: cluster-cnpg
    namespace: cnpg
```
If we want to schedule backups, we can use the following:

```yaml
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: cluster-cnpg-scheduled-backup
  namespace: cnpg
spec:
  schedule: "0 0 * * *" # every day at midnight
  backupOwnerReference: self
  cluster:
    name: cluster-cnpg
  immediate: true
  ```

## Restore from backup

As CNPG clusters do not support In cluster restores, we will be bootstrapping a new cluster with the backup data from the GCS bucket.

```yaml
---
apiVersion: v1
data:
  password: VHhWZVE0bk44MlNTaVlIb3N3cU9VUlp2UURhTDRLcE5FbHNDRUVlOWJ3RHhNZDczS2NrSWVYelM1Y1U2TGlDMg==
  username: YXBw
kind: Secret
metadata:
  name: cluster-cnpg-restore-app-user
  namespace: cnpg
type: kubernetes.io/basic-auth
---
apiVersion: v1
data:
  password: dU4zaTFIaDBiWWJDYzRUeVZBYWNCaG1TemdxdHpxeG1PVmpBbjBRSUNoc0pyU211OVBZMmZ3MnE4RUtLTHBaOQ==
  username: cG9zdGdyZXM=
kind: Secret
metadata:
  name: cluster-cnpg-restore-superuser
  namespace: cnpg
type: kubernetes.io/basic-auth
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-cnpg-restore
  namespace: cnpg
spec:
  description: "This is a restore cluster"
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgis:15-3.3
  superuserSecret:
    name: cluster-cnpg-restore-superuser
  bootstrap:
    recovery:
      backup:
        name: backup-on-demand
  storage:
    size: 1Gi
    storageClass: standard
  backup:
    barmanObjectStore:
      destinationPath: "gs://cnpg-backups/cluster-cnpg-restore"
      googleCredentials:
        gkeEnvironment: true
  serviceAccountTemplate:
    metadata:
      annotations:
        iam.gke.io/gcp-service-account: cnpg@<project>.iam.gserviceaccount.com
  monitoring:
    enablePodMonitor: true
```

The restore process will take a while, as it needs to download the backup from the GCS bucket, and then restore it into the cluster.

## Cleanup

To cleanup the work area, simply delete the created project in GCP.

In short, this is how you create a PostgreSQL cluster with HA, backups, and restores in GKE using CNPG. You can simulate more of the real world scenarios by changing the number of instances, the storage class, the backup schedule, and the backup retention policy.

If you want to learn more about CNPG, please refer to the [official documentation](https://cloudnative-pg.io/documentation/1.20/).

Happy kubernetting! :)