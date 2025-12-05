# Simple Workflow Example

A minimal Snakemake workflow to test the AWS Batch executor plugin.

## What It Does

1. **create_input**: Generates sample text files
2. **process**: Processes each sample in parallel (one Batch job per sample)
3. **aggregate**: Combines all processed results into a summary

## Prerequisites

Deploy the terraform infrastructure in two steps:

### 1. Deploy Coordinator Infrastructure

The coordinator module creates shared resources (VPC, job queue, IAM roles, S3 bucket, coordinator job definition):

```bash
cd examples/terraform/coordinator
terraform init
terraform apply
```

### 2. Deploy Workflow Infrastructure

The workflow module creates workflow-specific resources (job definition, ECR repository). It requires outputs from the coordinator:

```bash
# From the simple-workflow example directory:
just tf-init
just tf-apply-new

# Or manually:
cd examples/terraform/simple-workflow
terraform init
terraform apply \
  -var="job_queue_arn=$(terraform -chdir=../coordinator output -raw job_queue_arn)" \
  -var="job_role_arn=$(terraform -chdir=../coordinator output -raw job_role_arn)" \
  -var="execution_role_arn=$(terraform -chdir=../coordinator output -raw execution_role_arn)" \
  -var="log_group_name=$(terraform -chdir=../coordinator output -raw log_group_name)" \
  -var="log_group_arn=$(terraform -chdir=../coordinator output -raw log_group_arn)" \
  -var="bucket_arn=$(terraform -chdir=../coordinator output -raw bucket_arn)"
```

### 3. Note the Outputs

After deployment, get the values needed for snakemake:

```bash
# From examples/terraform/coordinator:
terraform output  # region, job_queue_name, coordinator_job_definition_name, bucket_name

# From examples/terraform/simple-workflow:
terraform output  # job_definition_name
```

## Running the Workflow

### Using Justfile (Recommended)

The justfile provides shortcuts for common operations:

```bash
cd examples/simple-workflow

# Submit coordinator job
just run

# Monitor job status
just watch

# View logs
just logs

# Check status
just status
```

Generate a snakemake command with your deployed infrastructure values:

```bash
just tf-snakemake-cmd
```

### Option 1: Standard Mode (local orchestration)

Your machine runs Snakemake and submits jobs to AWS Batch:

```bash
snakemake --executor aws-basic-batch \
  --aws-basic-batch-region <region> \
  --aws-basic-batch-job-queue <queue-name> \
  --aws-basic-batch-job-definition <job-def-name> \
  --default-storage-provider s3 \
  --default-storage-prefix s3://<bucket-name>
```

### Option 2: Coordinator Mode (fire-and-forget)

Submit a coordinator job that runs the entire workflow on Batch:

```bash
snakemake --executor aws-basic-batch \
  --aws-basic-batch-region <region> \
  --aws-basic-batch-job-queue <queue-name> \
  --aws-basic-batch-job-definition <job-def-name> \
  --aws-basic-batch-coordinator \
  --aws-basic-batch-coordinator-job-definition <coordinator-job-def-name> \
  --default-storage-provider s3 \
  --default-storage-prefix s3://<bucket-name>
```

### Local Test (no AWS)

```bash
snakemake --cores 1
```

## Expected Output

After completion, you'll have:
- `data/sample_A.txt`, `data/sample_B.txt`, `data/sample_C.txt`
- `results/sample_A.processed.txt`, etc.
- `results/summary.txt` - aggregated output showing all processed samples
