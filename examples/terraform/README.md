# Terraform Infrastructure for snakemake-executor-plugin-aws-basic-batch

Modular AWS Batch infrastructure for the Snakemake executor plugin. Split into two modules:

- **coordinator/** - Base infrastructure shared by all workflows (VPC, Batch compute, IAM, S3, coordinator job definition)
- **simple-workflow/** - Example workflow-specific resources (job definition, ECR repository)

## Resources Created

### Coordinator Module

- **VPC** (optional): Public subnets with internet gateway
- **S3 Bucket**: Workflow storage (versioned, private)
- **ECR Repository**: Container image registry for coordinator
- **IAM Roles**: Batch service role, ECS execution role, job role with S3/Batch/Logs access
- **Batch Compute Environment**: Fargate (default) or EC2
- **Batch Job Queue**: Single queue for all jobs
- **Batch Job Definition**: Coordinator job definition
- **CloudWatch Log Group**: For job logs

### Workflow Module

- **Batch Job Definition**: Workflow-specific job definition
- **ECR Repository**: Container image registry for workflow
- **IAM Policy**: Adds workflow job definition to coordinator's job role

## Usage

### Quick Start

```bash
# 1. Deploy coordinator infrastructure
cd coordinator
terraform init
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform apply

# 2. Deploy workflow infrastructure (from examples/simple-workflow directory)
cd ../../simple-workflow
just tf-init
just tf-apply-new
```

### Configuration

Both modules use `terraform.tfvars` for auto-loading configuration. Copy the example files and edit:

```bash
# Coordinator
cd coordinator
cp terraform.tfvars.example terraform.tfvars

# Workflow
cd simple-workflow
cp terraform.tfvars.example terraform.tfvars
```

The workflow module receives coordinator outputs via CLI variables (handled by the justfile).

## Coordinator Variables

| Name | Description | Default |
|------|-------------|---------|
| `name_prefix` | Prefix for resource names | `snakemake-coordinator` |
| `region` | AWS region | `us-east-1` |
| `tags` | Tags to apply to all resources | `{}` |
| **VPC** | | |
| `create_vpc` | Create new VPC or use existing | `true` |
| `vpc_id` | Existing VPC ID (required if `create_vpc=false`) | `null` |
| `subnet_ids` | Existing subnet IDs (required if `create_vpc=false`) | `[]` |
| `vpc_cidr` | CIDR block for new VPC | `10.0.0.0/16` |
| `availability_zones` | AZs for subnets (defaults to first 2 in region) | `[]` |
| **Batch** | | |
| `compute_type` | `FARGATE`, `FARGATE_SPOT`, `EC2`, or `SPOT` | `FARGATE` |
| `instance_types` | EC2 instance types (only for EC2/SPOT) | `["optimal"]` |
| `min_vcpus` | Min vCPUs for compute env (only for EC2/SPOT) | `0` |
| `max_vcpus` | Max vCPUs for compute environment | `16` |
| `coordinator_image` | Coordinator container image | `snakemake/snakemake:latest` |
| `coordinator_vcpus` | vCPUs for coordinator job | `1` |
| `coordinator_memory` | Memory (MiB) for coordinator job | `2048` |
| **Storage** | | |
| `create_bucket` | Create S3 bucket for workflow storage | `true` |
| `bucket_name` | S3 bucket name (auto-generated if null) | `null` |
| `s3_bucket_arns` | Additional S3 bucket ARNs for job access | `[]` |
| **ECR** | | |
| `create_ecr` | Create ECR repository for coordinator image | `true` |
| `ecr_repository_name` | ECR repository name (auto-generated if null) | `null` |

## Workflow Variables

| Name | Description | Default |
|------|-------------|---------|
| `name_prefix` | Prefix for resource names | `snakemake-simple-workflow` |
| `region` | AWS region | `us-east-1` |
| `tags` | Tags to apply to all resources | `{}` |
| **Coordinator References** (passed via CLI) | | |
| `job_queue_arn` | ARN of Batch job queue from coordinator | (required) |
| `job_role_arn` | ARN of job role from coordinator | (required) |
| `execution_role_arn` | ARN of ECS execution role from coordinator | (required) |
| `log_group_name` | CloudWatch log group name from coordinator | (required) |
| `log_group_arn` | CloudWatch log group ARN from coordinator | (required) |
| `bucket_arn` | S3 bucket ARN from coordinator | `null` |
| **Batch** | | |
| `compute_type` | Must match coordinator | `FARGATE` |
| `workflow_image` | Workflow container image | (required) |
| `workflow_vcpus` | vCPUs for workflow jobs | `1` |
| `workflow_memory` | Memory (MiB) for workflow jobs | `2048` |
| **ECR** | | |
| `create_ecr` | Create ECR repository for workflow image | `true` |
| `ecr_repository_name` | ECR repository name (auto-generated if null) | `null` |

## Running Snakemake

After deploying both modules, use coordinator mode:

```bash
snakemake --executor aws-basic-batch \
  --aws-basic-batch-region us-east-1 \
  --aws-basic-batch-job-queue snakemake-test-queue \
  --aws-basic-batch-job-definition snakemake-simple-workflow-job \
  --aws-basic-batch-coordinator true \
  --aws-basic-batch-coordinator-job-definition snakemake-test-coordinator \
  --default-storage-provider s3 \
  --default-storage-prefix s3://your-bucket-name
```

Or use the justfile helper from `examples/simple-workflow`:

```bash
just tf-snakemake-cmd  # Generates the command with deployed values
```

## Cleanup

```bash
# Destroy workflow first
cd examples/simple-workflow
just tf-destroy

# Then destroy coordinator
cd examples/terraform/coordinator
terraform destroy
```
