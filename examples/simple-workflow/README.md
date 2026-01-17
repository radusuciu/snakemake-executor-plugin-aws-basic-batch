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

The workflow module creates workflow-specific resources (compute environment, job queue, job definition, ECR repositories for both workflow and coordinator images). It requires outputs from the coordinator:

```bash
just example::tf-init
just example::tf-apply-new
```

### 3. Build and Push Images

Build and push both the coordinator and workflow images to ECR:

```bash
just example::ecr-login
just example::build-push
```

This builds two images from the same Dockerfile:
- **Coordinator image**: Base plugin image with workflow files (Snakefile)
- **Workflow image**: Minimal image with workflow dependencies

## Running the Workflow

### Using Justfile (Recommended)

The justfile provides shortcuts for common operations:

```bash
# Submit coordinator job
just example::run

# Monitor job status
just example::watch

# View logs
just example::logs

# Check status
just example::status
```

Generate a snakemake command with your deployed infrastructure values:

```bash
just example::tf-snakemake-cmd
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
  --aws-basic-batch-coordinator true \
  --aws-basic-batch-coordinator-job-definition <coordinator-job-def-name> \
  --aws-basic-batch-coordinator-queue <coordinator-queue-name> \
  --aws-basic-batch-coordinator-image <coordinator-image-uri> \
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
