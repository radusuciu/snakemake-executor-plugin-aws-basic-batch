# Snakemake AWS Basic Batch Executor Plugin

# Configuration
base_image := "radusuciu/snakemake-executor-plugin-aws-basic-batch"
tf_coordinator := "examples/terraform/coordinator"

# Import example workflow module
mod example 'examples/simple-workflow'

# =============================================================================
# Base Plugin Image (for docker.io)
# =============================================================================

# Build the base plugin image
build-base:
    docker build -t {{base_image}}:latest .

# Push the base plugin image to Docker Hub
push-base:
    docker push {{base_image}}:latest

# Build and push base image
build-push-base: build-base push-base

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
