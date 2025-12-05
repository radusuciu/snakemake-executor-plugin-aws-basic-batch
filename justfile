# Snakemake AWS Basic Batch Executor Plugin

# Configuration
ghcr_image := "ghcr.io/radusuciu/snakemake-executor-plugin-aws-basic-batch"
tf_coordinator := "examples/terraform/coordinator"

# Import example workflow module
mod example 'examples/simple-workflow'

# =============================================================================
# Base Plugin Image
# =============================================================================

# Build the base plugin image
build-base:
    docker build -t {{ghcr_image}}:latest .

# Push the base plugin image to GHCR
push-ghcr: build-base
    docker push {{ghcr_image}}:latest

# Get ECR repository URL from terraform output
[private]
ecr-url:
    @terraform -chdir={{tf_coordinator}} output -raw ecr_repository_url

# Tag and push to ECR (requires: aws ecr get-login-password | docker login)
push-ecr: build-base
    #!/usr/bin/env bash
    set -euo pipefail
    ecr_url=$(just ecr-url)
    docker tag {{ghcr_image}}:latest "${ecr_url}:latest"
    docker push "${ecr_url}:latest"

# Push to both GHCR and ECR
push-all: push-ghcr push-ecr

# Login to ECR (run before push-ecr)
ecr-login:
    #!/usr/bin/env bash
    set -euo pipefail
    region=$(terraform -chdir={{tf_coordinator}} output -raw region)
    ecr_url=$(just ecr-url)
    ecr_host="${ecr_url%%/*}"
    aws ecr get-login-password --region "${region}" | docker login --username AWS --password-stdin "${ecr_host}"

# =============================================================================
# Terraform - Coordinator Infrastructure
# =============================================================================

# Initialize coordinator terraform
tf-coordinator-init:
    terraform -chdir={{tf_coordinator}} init

# Plan coordinator infrastructure
tf-coordinator-plan *args:
    terraform -chdir={{tf_coordinator}} plan {{args}}

# Apply coordinator infrastructure
tf-coordinator-apply *args:
    terraform -chdir={{tf_coordinator}} apply {{args}}

# Destroy coordinator infrastructure
tf-coordinator-destroy *args:
    terraform -chdir={{tf_coordinator}} destroy {{args}}

# Show coordinator outputs
tf-coordinator-output *args:
    terraform -chdir={{tf_coordinator}} output {{args}}
