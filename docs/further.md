## How This Plugin Works

Your local Snakemake process orchestrates the DAG and submits each rule as an individual AWS Batch job. Jobs read inputs and write outputs via S3 (the shared filesystem), and the plugin polls Batch for job status until completion.

The key design choice is that **job definitions must be pre-created** (e.g., via Terraform, CloudFormation, or the AWS Console). The plugin does not dynamically create or modify job definitions. Instead, it overrides CPU, memory, and GPU at submit time via `containerOverrides`.

### Comparison with the Standard aws-batch Plugin

| Feature | aws-basic-batch (this plugin) | aws-batch |
|---------|-------------------------------|-----------|
| Job definitions | Pre-configured, externally managed | Dynamically created |
| Container images | Workflow files bundled in image | Sources deployed at runtime |
| Infrastructure setup | Explicit (Terraform/CloudFormation) | Automatic |
| Coordinator mode | Built-in fire-and-forget mode | Not available |
| Resource overrides | Per-rule CPU, memory, GPU, queue, job definition, timeout, scheduling priority, job naming | Per-rule CPU, memory |

## Prerequisites

### AWS Credentials

The plugin uses standard AWS credential resolution: `~/.aws/credentials`, `AWS_PROFILE` environment variable, or IAM instance/task roles. Ensure the credentials have at minimum these permissions:

- `batch:SubmitJob`
- `batch:DescribeJobs`
- `batch:TerminateJob`

### S3 Storage

S3 is required as the shared filesystem between Snakemake and the Batch jobs. Use `--default-storage-provider s3` and `--default-storage-prefix s3://your-bucket/prefix` when running workflows. The [snakemake-storage-plugin-s3](https://snakemake.github.io/snakemake-plugin-catalog/plugins/storage/s3.html) is automatically installed as a dependency.

### Container Images

Workflow files and their dependencies must be bundled into the container image. The plugin does **not** deploy sources to the container at runtime.

A recommended pattern uses a multi-stage Dockerfile with two images:

1. **Runtime image** -- contains the workflow files and any rule dependencies (Python packages, tools, etc.). This is what your rule jobs run in.
2. **Coordinator image** -- based on a pre-built image that includes Snakemake, this plugin, boto3, and snakemake-storage-plugin-s3. Workflow files are copied in so the coordinator can parse the DAG and submit jobs.

See [examples/simple-workflow/Dockerfile](https://github.com/radusuciu/snakemake-executor-plugin-aws-basic-batch/blob/main/examples/simple-workflow/Dockerfile) for a complete example:

```dockerfile
# Runtime stage: minimal image with workflow
FROM python:3.13-slim-bookworm AS runtime
COPY --from=builder --chown=snakemake:snakemake /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"
WORKDIR /workflow
COPY --chown=snakemake:snakemake Snakefile ./

# Coordinator stage: base plugin image with workflow files
FROM ghcr.io/radusuciu/snakemake-executor-plugin-aws-basic-batch:latest AS coordinator
COPY --chown=snakemake:snakemake Snakefile ./
```

### Job Definitions

Job definitions must be pre-created using Terraform, CloudFormation, the AWS Console, or the CLI. A job definition configures:

- The container image to use
- IAM roles (execution role and job role with S3/Batch access)
- Platform capabilities (Fargate or EC2)
- Default resource allocations (vCPUs, memory)

The plugin overrides CPU, memory, and GPU at submit time via `containerOverrides.resourceRequirements`, so the job definition provides sensible defaults while individual rules can request more resources as needed.

## Per-Rule Resource Customization

| Resource | Description | Default |
|----------|-------------|---------|
| `aws_batch_vcpu` | Number of vCPUs | 1 |
| `aws_batch_mem_mb` | Memory in MiB | 1024 |
| `aws_batch_gpu` | Number of GPUs (only included when > 0) | 0 |
| `aws_batch_job_queue` | Job queue ARN/name | `--aws-basic-batch-job-queue` |
| `aws_batch_job_definition` | Job definition ARN/name | `--aws-basic-batch-job-definition` |
| `aws_batch_task_timeout` | Job timeout in seconds (min: 60) | `--aws-basic-batch-task-timeout` |
| `aws_batch_job_name_prefix` | Custom prefix for job names | `snakejob` |
| `aws_batch_scheduling_priority` | Scheduling priority override for fair-share queues | None |
| `aws_batch_job_uuid` | Custom UUID/identifier for job names | auto-generated UUID |

### Compute Resources (vCPU, Memory, GPU)

Override compute resources on a per-rule basis:

```python
rule align:
    output: "aligned.bam"
    resources:
        aws_batch_vcpu=4,
        aws_batch_mem_mb=8192,
        aws_batch_gpu=1
    shell: "run_alignment > {output}"
```

- `aws_batch_vcpu` -- Number of vCPUs (default: 1, minimum: 1)
- `aws_batch_mem_mb` -- Memory in MiB (default: 1024, minimum: 1)
- `aws_batch_gpu` -- Number of GPUs (default: 0, only included in the request when > 0)

Values below the minimum are clamped automatically.

### Queue and Job Definition Overrides

Route specific rules to different queues or job definitions:

```python
rule gpu_task:
    output: "result.txt"
    resources:
        aws_batch_job_queue="gpu-queue",
        aws_batch_job_definition="gpu-job-def"
    shell: "python gpu_compute.py > {output}"
```

This is useful for routing rules to specialized compute environments (e.g., GPU instances, high-memory instances, or Spot capacity).

### Timeouts

Set job timeouts per-rule or globally:

```python
rule long_running:
    output: "result.txt"
    resources:
        aws_batch_task_timeout=7200  # 2 hours
    shell: "python long_task.py > {output}"
```

The global default can be set with `--aws-basic-batch-task-timeout`. The minimum timeout is 60 seconds (enforced by AWS Batch).

### Job Naming

Job names follow the pattern `{prefix}-{rule_name}-{uuid}`:

```python
rule my_rule:
    output: "out.txt"
    resources:
        aws_batch_job_name_prefix="myproject",
        aws_batch_job_uuid="run-42"
    shell: "echo done > {output}"
```

- `aws_batch_job_name_prefix` -- Prefix for job names (default: `snakejob`)
- `aws_batch_job_uuid` -- Custom identifier suffix (default: auto-generated UUID)

### Scheduling Priority

For [fair-share scheduling queues](https://docs.aws.amazon.com/batch/latest/userguide/scheduling-policies.html), set a priority per rule:

```python
rule urgent:
    output: "urgent.txt"
    resources:
        aws_batch_scheduling_priority=100
    shell: "echo urgent > {output}"
```

## Job Tagging

Apply tags to all submitted jobs for cost tracking, filtering, and organization:

```bash
--aws-basic-batch-tags "project=genomics,run=exp1,costcenter=research"
```

Tags are comma-separated `key=value` pairs and are applied to both regular rule jobs and coordinator jobs. Values may contain `=` characters (only the first `=` is used as the delimiter). Can also be set via the `SNAKEMAKE_AWS_BASIC_BATCH_TAGS` environment variable.

## Coordinator Mode

### Overview

Coordinator mode provides fire-and-forget workflow execution. When enabled, the plugin submits the entire Snakemake workflow as a single AWS Batch job. That coordinator job then runs Snakemake inside Batch, which in turn submits individual rule jobs. Your terminal can disconnect after submission -- the plugin prints the job ID and an AWS Console URL for monitoring.

```bash
snakemake --executor aws-basic-batch \
  --aws-basic-batch-coordinator true \
  --aws-basic-batch-region us-east-1 \
  --aws-basic-batch-job-queue my-workflow-queue \
  --aws-basic-batch-job-definition my-workflow-job \
  --aws-basic-batch-coordinator-queue my-coordinator-queue \
  --aws-basic-batch-coordinator-job-definition my-coordinator-job \
  --default-storage-provider s3 \
  --default-storage-prefix s3://my-bucket
```

### Settings

All coordinator settings fall back to the main job settings if not specified:

- `--aws-basic-batch-coordinator-queue` -- Job queue for the coordinator (defaults to `--aws-basic-batch-job-queue`). Env: `SNAKEMAKE_AWS_BASIC_BATCH_COORDINATOR_QUEUE`
- `--aws-basic-batch-coordinator-job-definition` -- Job definition for the coordinator (defaults to `--aws-basic-batch-job-definition`). Env: `SNAKEMAKE_AWS_BASIC_BATCH_COORDINATOR_JOB_DEFINITION`
- `--aws-basic-batch-coordinator-job-name-prefix` -- Prefix for coordinator job names (default: `snakemake-coordinator`). Env: `SNAKEMAKE_AWS_BASIC_BATCH_COORDINATOR_JOB_NAME_PREFIX`
- `--aws-basic-batch-coordinator-job-uuid` -- Custom UUID for coordinator job names (default: auto-generated). Env: `SNAKEMAKE_AWS_BASIC_BATCH_COORDINATOR_JOB_UUID`

### Container Requirements

The coordinator container image must have:

- Snakemake
- This plugin (`snakemake-executor-plugin-aws-basic-batch`)
- `boto3`
- `snakemake-storage-plugin-s3`
- Your workflow files (Snakefile, config, etc.)

The `coordinator` stage in [examples/simple-workflow/Dockerfile](https://github.com/radusuciu/snakemake-executor-plugin-aws-basic-batch/blob/main/examples/simple-workflow/Dockerfile) demonstrates this by building on top of the pre-built plugin image and copying in the workflow files.

## Infrastructure Setup with Terraform

The [examples/terraform/](https://github.com/radusuciu/snakemake-executor-plugin-aws-basic-batch/tree/main/examples/terraform) directory provides a complete Terraform module that deploys all required AWS infrastructure.

### Quick Start

```bash
cd examples/terraform
terraform init
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform apply
```

### What Gets Created

- **VPC** (optional) -- Public subnets with internet gateway
- **S3 Bucket** (optional) -- Versioned, private workflow storage
- **ECR Repositories** (optional) -- Container registries for coordinator and workflow images
- **IAM Roles** -- Batch service role, ECS execution role, job role with S3/Batch/Logs access
- **Batch Compute Environments** -- Separate coordinator and workflow environments
- **Batch Job Queues** -- Separate coordinator and workflow queues
- **Batch Job Definitions** -- Coordinator, workflow, and workflow-coordinator definitions
- **CloudWatch Log Group** -- For job logs

### Key Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `compute_type` | `FARGATE`, `FARGATE_SPOT`, `EC2`, or `SPOT` | `FARGATE` |
| `max_vcpus` | Max vCPUs for workflow compute environment | `256` |
| `create_vpc` | Create new VPC or use existing | `true` |
| `create_bucket` | Create S3 bucket for workflow storage | `true` |

See [examples/terraform/README.md](https://github.com/radusuciu/snakemake-executor-plugin-aws-basic-batch/blob/main/examples/terraform/README.md) for the full variable reference and outputs.

### Cleanup

```bash
terraform destroy
```

## Example Walkthrough

The [examples/simple-workflow/](https://github.com/radusuciu/snakemake-executor-plugin-aws-basic-batch/tree/main/examples/simple-workflow) directory contains a complete working example. The general steps are:

1. **Deploy infrastructure:**
   ```bash
   cd examples/terraform
   terraform init && terraform apply
   ```

2. **Build and push container images:**
   ```bash
   cd examples/simple-workflow
   just build-push
   ```

3. **Run the workflow** (coordinator mode):
   ```bash
   just run
   ```
   Or directly:
   ```bash
   snakemake --executor aws-basic-batch \
     --aws-basic-batch-coordinator true \
     --aws-basic-batch-region us-east-1 \
     --aws-basic-batch-job-queue my-workflow-queue \
     --aws-basic-batch-job-definition my-workflow-job \
     --aws-basic-batch-coordinator-job-definition my-coordinator-job \
     --aws-basic-batch-coordinator-queue my-coordinator-queue \
     --default-storage-provider s3 \
     --default-storage-prefix s3://my-bucket
   ```

4. **Monitor:**
   ```bash
   just status   # Check job status
   just logs     # View job logs
   just watch    # Watch until completion
   ```

5. **Cleanup:**
   ```bash
   cd examples/terraform
   terraform destroy
   ```

For standard (non-coordinator) mode, omit the `--aws-basic-batch-coordinator` flag and its related options:

```bash
snakemake --executor aws-basic-batch \
  --aws-basic-batch-region us-east-1 \
  --aws-basic-batch-job-queue my-queue \
  --aws-basic-batch-job-definition my-job-def \
  --default-storage-provider s3 \
  --default-storage-prefix s3://my-bucket/workdir
```
