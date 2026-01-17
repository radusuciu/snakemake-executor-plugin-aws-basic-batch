# Simple Workflow Infrastructure
#
# This module sets up workflow-specific AWS Batch resources that work with
# the coordinator infrastructure. It creates its own compute environment and
# job queue, allowing workflows to have different compute requirements than
# the lightweight coordinator.
#
# Resources created:
# - Batch compute environment (separate from coordinator)
# - Batch job queue (separate from coordinator)
# - Workflow job definition (for rule execution)
# - ECR repository for workflow container image
# - IAM policies for workflow job role
# - Security group (optional - can use coordinator's)
#
# Prerequisites:
# - Coordinator module must be deployed first
# - Provide coordinator outputs via variables (VPC, subnets, IAM roles)

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# =============================================================================
# Variables
# =============================================================================

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "snakemake-simple-workflow"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# Coordinator infrastructure references
variable "coordinator_job_queue_arn" {
  description = "ARN of the Batch job queue from coordinator module (for IAM permissions)"
  type        = string
}

variable "job_role_arn" {
  description = "ARN of the job role from coordinator module (shared by all jobs)"
  type        = string
}

variable "execution_role_arn" {
  description = "ARN of the ECS execution role from coordinator module"
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group name from coordinator module"
  type        = string
}

variable "log_group_arn" {
  description = "CloudWatch log group ARN from coordinator module"
  type        = string
}

variable "bucket_arn" {
  description = "S3 bucket ARN from coordinator module (for workflow storage)"
  type        = string
  default     = null
}

# VPC Configuration (from coordinator module)
variable "vpc_id" {
  description = "VPC ID from coordinator module"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs from coordinator module"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID from coordinator module (optional, creates new if not provided)"
  type        = string
  default     = null
}

# Batch Configuration
variable "compute_type" {
  description = "Batch compute type: FARGATE, FARGATE_SPOT, EC2, or SPOT"
  type        = string
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT", "EC2", "SPOT"], var.compute_type)
    error_message = "compute_type must be FARGATE, FARGATE_SPOT, EC2, or SPOT"
  }
}

variable "instance_types" {
  description = "EC2 instance types for compute environment (only used when compute_type is EC2 or SPOT)"
  type        = list(string)
  default     = ["optimal"]
}

variable "min_vcpus" {
  description = "Minimum vCPUs for compute environment (only used when compute_type is EC2 or SPOT)"
  type        = number
  default     = 0
}

variable "max_vcpus" {
  description = "Maximum vCPUs for compute environment"
  type        = number
  default     = 256
}

variable "workflow_image" {
  description = "Container image for workflow job definition. If null and create_ecr=true, uses the created ECR repository with :latest tag."
  type        = string
  default     = null
}

variable "workflow_vcpus" {
  description = "vCPUs for workflow job definition"
  type        = number
  default     = 1
}

variable "workflow_memory" {
  description = "Memory (MiB) for workflow job definition"
  type        = number
  default     = 2048
}

variable "coordinator_vcpus" {
  description = "vCPUs for coordinator job definition"
  type        = number
  default     = 1
}

variable "coordinator_memory" {
  description = "Memory (MiB) for coordinator job definition"
  type        = number
  default     = 2048
}

# ECR Configuration
variable "create_ecr" {
  description = "Whether to create an ECR repository for the workflow image"
  type        = bool
  default     = true
}

variable "ecr_repository_name" {
  description = "ECR repository name. If null, uses name_prefix."
  type        = string
  default     = null
}

# =============================================================================
# Locals
# =============================================================================

locals {
  is_fargate = var.compute_type == "FARGATE" || var.compute_type == "FARGATE_SPOT"
  is_ec2     = var.compute_type == "EC2" || var.compute_type == "SPOT"

  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Project   = "snakemake-aws-basic-batch"
    Component = "workflow"
    Workflow  = var.name_prefix
  })

  # Workflow image: use provided value, or ECR repo if created
  workflow_image = coalesce(
    var.workflow_image,
    var.create_ecr ? "${aws_ecr_repository.workflow[0].repository_url}:latest" : null,
  )

  # Coordinator image: from ECR repo if created
  coordinator_image = var.create_ecr ? "${aws_ecr_repository.coordinator[0].repository_url}:latest" : null

  # Use provided security group or we'll create one
  security_group_id = var.security_group_id != null ? var.security_group_id : aws_security_group.batch[0].id
}

# =============================================================================
# Security Group (optional - can use coordinator's)
# =============================================================================

resource "aws_security_group" "batch" {
  count = var.security_group_id == null ? 1 : 0

  name_prefix = "${var.name_prefix}-batch-"
  description = "Security group for workflow Batch compute environment"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-batch-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# IAM Roles for Batch
# =============================================================================

# Batch Service Role
data "aws_iam_policy_document" "batch_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["batch.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "batch_service" {
  name_prefix        = "${var.name_prefix}-batch-svc-"
  assume_role_policy = data.aws_iam_policy_document.batch_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  role       = aws_iam_role.batch_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

# EC2 Instance Role (for EC2/SPOT compute environments)
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_instance" {
  count = local.is_ec2 ? 1 : 0

  name_prefix        = "${var.name_prefix}-ecs-inst-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  count = local.is_ec2 ? 1 : 0

  role       = aws_iam_role.ecs_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  count = local.is_ec2 ? 1 : 0

  name_prefix = "${var.name_prefix}-ecs-inst-"
  role        = aws_iam_role.ecs_instance[0].name
  tags        = local.common_tags
}

# =============================================================================
# AWS Batch Compute Environment and Job Queue
# =============================================================================

resource "aws_batch_compute_environment" "workflow" {
  compute_environment_name_prefix = "${var.name_prefix}-"
  type                            = "MANAGED"
  state                           = "ENABLED"
  service_role                    = aws_iam_role.batch_service.arn

  compute_resources {
    type      = var.compute_type
    max_vcpus = var.max_vcpus

    subnets            = var.subnet_ids
    security_group_ids = [local.security_group_id]

    # EC2/SPOT-specific settings
    min_vcpus     = local.is_ec2 ? var.min_vcpus : null
    instance_type = local.is_ec2 ? var.instance_types : null
    instance_role = local.is_ec2 ? aws_iam_instance_profile.ecs_instance[0].arn : null
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_job_queue" "workflow" {
  name     = "${var.name_prefix}-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.workflow.arn
  }

  tags = local.common_tags
}

# =============================================================================
# ECR Repositories
# =============================================================================

# Workflow image ECR (for rule execution)
resource "aws_ecr_repository" "workflow" {
  count = var.create_ecr ? 1 : 0

  name                 = var.ecr_repository_name != null ? var.ecr_repository_name : var.name_prefix
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name = var.ecr_repository_name != null ? var.ecr_repository_name : var.name_prefix
  })
}

resource "aws_ecr_lifecycle_policy" "workflow" {
  count = var.create_ecr ? 1 : 0

  repository = aws_ecr_repository.workflow[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Coordinator image ECR (Snakemake plugin + workflow files)
resource "aws_ecr_repository" "coordinator" {
  count = var.create_ecr ? 1 : 0

  name                 = "${var.ecr_repository_name != null ? var.ecr_repository_name : var.name_prefix}-coordinator"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.ecr_repository_name != null ? var.ecr_repository_name : var.name_prefix}-coordinator"
  })
}

resource "aws_ecr_lifecycle_policy" "coordinator" {
  count = var.create_ecr ? 1 : 0

  repository = aws_ecr_repository.coordinator[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# =============================================================================
# IAM - Add workflow queue and job definition to job role's SubmitJob permissions
# =============================================================================

# Add policy to job role allowing it to submit jobs to this workflow's queue
data "aws_iam_policy_document" "job_submit_workflow" {
  statement {
    sid    = "SubmitWorkflowJobs"
    effect = "Allow"
    actions = [
      "batch:SubmitJob",
    ]
    resources = [
      # Workflow queue
      aws_batch_job_queue.workflow.arn,
      # Note: Job definition ARNs need wildcard suffix to cover both versioned (:N) and unversioned forms
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.workflow.name}",
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.workflow.name}:*",
    ]
  }

  # List jobs in workflow queue
  statement {
    sid    = "ListJobsInWorkflowQueue"
    effect = "Allow"
    actions = [
      "batch:ListJobs",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "batch:JobQueue"
      values   = [aws_batch_job_queue.workflow.arn]
    }
  }
}

resource "aws_iam_role_policy" "job_submit_workflow" {
  name_prefix = "${var.name_prefix}-submit-"
  role        = element(split("/", var.job_role_arn), length(split("/", var.job_role_arn)) - 1)
  policy      = data.aws_iam_policy_document.job_submit_workflow.json
}

# =============================================================================
# AWS Batch Job Definition
# =============================================================================

resource "aws_batch_job_definition" "workflow" {
  name                  = "${var.name_prefix}-job"
  type                  = "container"
  platform_capabilities = local.is_fargate ? ["FARGATE"] : ["EC2"]
  propagate_tags        = true

  lifecycle {
    precondition {
      condition     = var.workflow_image != null || var.create_ecr
      error_message = "Either workflow_image must be provided or create_ecr must be true"
    }
  }

  container_properties = jsonencode({
    image = local.workflow_image

    resourceRequirements = [
      { type = "VCPU", value = tostring(var.workflow_vcpus) },
      { type = "MEMORY", value = tostring(var.workflow_memory) },
    ]

    jobRoleArn       = var.job_role_arn
    executionRoleArn = var.execution_role_arn

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = var.name_prefix
      }
    }

    networkConfiguration = local.is_fargate ? {
      assignPublicIp = "ENABLED"
    } : null

    command = ["echo", "No command specified"]
  })

  tags = local.common_tags
}

# Coordinator Job Definition (workflow-specific, includes Snakefile in image)
resource "aws_batch_job_definition" "coordinator" {
  count = var.create_ecr ? 1 : 0

  name                  = "${var.name_prefix}-coordinator"
  type                  = "container"
  platform_capabilities = local.is_fargate ? ["FARGATE"] : ["EC2"]
  propagate_tags        = true

  container_properties = jsonencode({
    image = local.coordinator_image

    resourceRequirements = [
      { type = "VCPU", value = tostring(var.coordinator_vcpus) },
      { type = "MEMORY", value = tostring(var.coordinator_memory) },
    ]

    jobRoleArn       = var.job_role_arn
    executionRoleArn = var.execution_role_arn

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "${var.name_prefix}-coordinator"
      }
    }

    networkConfiguration = local.is_fargate ? {
      assignPublicIp = "ENABLED"
    } : null

    command = ["echo", "No command specified"]
  })

  tags = local.common_tags
}

# =============================================================================
# Outputs
# =============================================================================

output "job_queue_name" {
  description = "Workflow Batch job queue name"
  value       = aws_batch_job_queue.workflow.name
}

output "job_queue_arn" {
  description = "Workflow Batch job queue ARN"
  value       = aws_batch_job_queue.workflow.arn
}

output "job_definition_name" {
  description = "Workflow job definition name"
  value       = aws_batch_job_definition.workflow.name
}

output "job_definition_arn" {
  description = "Workflow job definition ARN"
  value       = aws_batch_job_definition.workflow.arn
}

output "coordinator_job_definition_name" {
  description = "Coordinator job definition name"
  value       = var.create_ecr ? aws_batch_job_definition.coordinator[0].name : null
}

output "coordinator_job_definition_arn" {
  description = "Coordinator job definition ARN"
  value       = var.create_ecr ? aws_batch_job_definition.coordinator[0].arn : null
}

output "ecr_repository_url" {
  description = "ECR repository URL for workflow image"
  value       = var.create_ecr ? aws_ecr_repository.workflow[0].repository_url : null
}

output "ecr_repository_arn" {
  description = "ECR repository ARN"
  value       = var.create_ecr ? aws_ecr_repository.workflow[0].arn : null
}

output "coordinator_ecr_repository_url" {
  description = "ECR repository URL for coordinator image"
  value       = var.create_ecr ? aws_ecr_repository.coordinator[0].repository_url : null
}

output "coordinator_ecr_repository_arn" {
  description = "Coordinator ECR repository ARN"
  value       = var.create_ecr ? aws_ecr_repository.coordinator[0].arn : null
}

output "workflow_image" {
  description = "Resolved workflow container image"
  value       = local.workflow_image
}

output "coordinator_image" {
  description = "Resolved coordinator container image"
  value       = var.create_ecr ? "${aws_ecr_repository.coordinator[0].repository_url}:latest" : null
}

# Helper output: snakemake command
output "snakemake_command" {
  description = "Example snakemake command to run this workflow with coordinator"
  value       = <<-EOT
    snakemake --executor aws-basic-batch \
      --aws-basic-batch-region ${var.region} \
      --aws-basic-batch-job-queue ${aws_batch_job_queue.workflow.name} \
      --aws-basic-batch-job-definition ${aws_batch_job_definition.workflow.name} \
      --aws-basic-batch-coordinator true \
      --aws-basic-batch-coordinator-job-definition <coordinator-job-definition> \
      --default-storage-provider s3 \
      --default-storage-prefix s3://<bucket-name>
    EOT
}
