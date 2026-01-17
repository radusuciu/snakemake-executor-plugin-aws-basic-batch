# Snakemake AWS Basic Batch Executor Plugin

# Configuration
ghcr_image := "ghcr.io/radusuciu/snakemake-executor-plugin-aws-basic-batch"
tf_dir := "examples/terraform"

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

# =============================================================================
# Terraform - Infrastructure
# =============================================================================

# Initialize terraform
tf-init:
    terraform -chdir={{tf_dir}} init

# Plan infrastructure
tf-plan *args:
    terraform -chdir={{tf_dir}} plan {{args}}

# Apply infrastructure
tf-apply *args:
    terraform -chdir={{tf_dir}} apply {{args}}

# Destroy infrastructure
tf-destroy *args:
    terraform -chdir={{tf_dir}} destroy {{args}}

# Show terraform outputs
tf-output *args:
    terraform -chdir={{tf_dir}} output {{args}}
