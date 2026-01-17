# Terraform Infrastructure for snakemake-executor-plugin-aws-basic-batch

Single-module AWS Batch infrastructure for the Snakemake executor plugin. Deploy all resources with one `terraform apply`.

## Resources Created

- **VPC** (optional): Public subnets with internet gateway
- **S3 Bucket** (optional): Workflow storage (versioned, private)
- **ECR Repositories** (optional): Container registries for coordinator and workflow images
- **IAM Roles**: Batch service role, ECS execution role, job role with S3/Batch/Logs access
- **Batch Compute Environments**: Separate coordinator and workflow compute environments (Fargate or EC2)
- **Batch Job Queues**: Separate coordinator and workflow job queues
- **Batch Job Definitions**: Coordinator, workflow, and workflow-coordinator job definitions
- **CloudWatch Log Group**: For job logs

## Usage

### Quick Start

```bash
# 1. Initialize terraform
cd examples/terraform
terraform init

# 2. Configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# 3. Deploy infrastructure
terraform apply

# 4. Build and push images (from examples/simple-workflow)
cd ../simple-workflow
just build-push
```

Or using the justfile from the repository root:

```bash
just example::tf-init
just example::tf-apply
just example::build-push
```

### Running a Workflow

After deployment, use the snakemake command with coordinator mode:

```bash
snakemake --executor aws-basic-batch \
  --aws-basic-batch-region us-east-1 \
  --aws-basic-batch-job-queue snakemake-simple-workflow-queue \
  --aws-basic-batch-job-definition snakemake-simple-workflow-job \
  --aws-basic-batch-coordinator true \
  --aws-basic-batch-coordinator-job-definition snakemake-coordinator-coordinator \
  --aws-basic-batch-coordinator-queue snakemake-coordinator-queue \
  --default-storage-provider s3 \
  --default-storage-prefix s3://your-bucket-name
```

Or use the justfile helper:

```bash
# From examples/simple-workflow
just run
```

## Variables

| Name | Description | Default |
|------|-------------|---------|
| **Core** | | |
| `coordinator_name_prefix` | Prefix for coordinator resource names | `snakemake-coordinator` |
| `workflow_name_prefix` | Prefix for workflow resource names | `snakemake-simple-workflow` |
| `region` | AWS region | `us-east-1` |
| `tags` | Tags to apply to all resources | `{}` |
| **VPC** | | |
| `create_vpc` | Create new VPC or use existing | `true` |
| `vpc_id` | Existing VPC ID (required if `create_vpc=false`) | `null` |
| `subnet_ids` | Existing subnet IDs (required if `create_vpc=false`) | `[]` |
| `vpc_cidr` | CIDR block for new VPC | `10.0.0.0/16` |
| `availability_zones` | AZs for subnets (defaults to first 2 in region) | `[]` |
| **Batch Compute** | | |
| `compute_type` | `FARGATE`, `FARGATE_SPOT`, `EC2`, or `SPOT` | `FARGATE` |
| `instance_types` | EC2 instance types (only for EC2/SPOT) | `["optimal"]` |
| `min_vcpus` | Min vCPUs for compute env (only for EC2/SPOT) | `0` |
| `max_vcpus` | Max vCPUs for workflow compute environment | `256` |
| `coordinator_max_vcpus` | Max vCPUs for coordinator compute environment | `16` |
| **Coordinator Job** | | |
| `coordinator_vcpus` | vCPUs for coordinator job | `1` |
| `coordinator_memory` | Memory (MiB) for coordinator job | `2048` |
| `coordinator_image` | Coordinator container image (uses ECR if null) | `null` |
| **Workflow Job** | | |
| `workflow_vcpus` | vCPUs for workflow jobs | `1` |
| `workflow_memory` | Memory (MiB) for workflow jobs | `2048` |
| `workflow_image` | Workflow container image (uses ECR if null) | `null` |
| **Storage** | | |
| `create_bucket` | Create S3 bucket for workflow storage | `true` |
| `bucket_name` | S3 bucket name (auto-generated if null) | `null` |
| `s3_bucket_arns` | Additional S3 bucket ARNs for job access | `[]` |
| **ECR** | | |
| `create_ecr` | Create ECR repositories | `true` |
| `ecr_repository_prefix` | Prefix for ECR repo names (uses `workflow_name_prefix` if null) | `null` |

## Outputs

| Name | Description |
|------|-------------|
| `region` | AWS region |
| `coordinator_job_queue_name` | Coordinator Batch job queue name |
| `coordinator_job_queue_arn` | Coordinator Batch job queue ARN |
| `workflow_job_queue_name` | Workflow Batch job queue name |
| `workflow_job_queue_arn` | Workflow Batch job queue ARN |
| `coordinator_job_definition_name` | Coordinator job definition name |
| `coordinator_job_definition_arn` | Coordinator job definition ARN |
| `workflow_job_definition_name` | Workflow job definition name |
| `workflow_job_definition_arn` | Workflow job definition ARN |
| `workflow_coordinator_job_definition_name` | Workflow coordinator job definition name |
| `workflow_coordinator_job_definition_arn` | Workflow coordinator job definition ARN |
| `job_role_arn` | IAM role ARN for jobs |
| `execution_role_arn` | ECS execution role ARN |
| `vpc_id` | VPC ID |
| `subnet_ids` | Subnet IDs |
| `security_group_id` | Security group ID |
| `bucket_name` | S3 bucket name |
| `bucket_arn` | S3 bucket ARN |
| `log_group_name` | CloudWatch log group name |
| `log_group_arn` | CloudWatch log group ARN |
| `coordinator_ecr_repository_url` | Coordinator ECR repository URL |
| `workflow_ecr_repository_url` | Workflow ECR repository URL |
| `coordinator_image` | Resolved coordinator container image |
| `workflow_image` | Resolved workflow container image |
| `snakemake_command` | Example snakemake command |

## Cleanup

```bash
terraform destroy
```

## Legacy Modules

The `coordinator/` and `simple-workflow/` subdirectories contain the previous two-module architecture kept for reference. New deployments should use the consolidated `main.tf`.
