# Simple Workflow Infrastructure
#
# This module sets up workflow-specific AWS Batch resources that work with
# the coordinator infrastructure. It creates:
# - Workflow-specific job definition (for rule execution)
# - ECR repository for workflow container image
# - IAM policies for workflow job role
#
# Prerequisites:
# - Coordinator module must be deployed first
# - Provide coordinator outputs via variables or data sources

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
variable "job_queue_arn" {
  description = "ARN of the Batch job queue from coordinator module"
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

# Batch Configuration
variable "compute_type" {
  description = "Batch compute type: FARGATE, FARGATE_SPOT, EC2, or SPOT (must match coordinator)"
  type        = string
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT", "EC2", "SPOT"], var.compute_type)
    error_message = "compute_type must be FARGATE, FARGATE_SPOT, EC2, or SPOT"
  }
}

variable "workflow_image" {
  description = "Container image for workflow job definition"
  type        = string
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

  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Project   = "snakemake-aws-basic-batch"
    Component = "workflow"
    Workflow  = var.name_prefix
  })
}

# =============================================================================
# ECR Repository
# =============================================================================

resource "aws_ecr_repository" "workflow" {
  count = var.create_ecr ? 1 : 0

  name                 = var.ecr_repository_name != null ? var.ecr_repository_name : "${var.name_prefix}-plugin"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name = var.ecr_repository_name != null ? var.ecr_repository_name : "${var.name_prefix}-plugin"
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

# =============================================================================
# IAM - Add workflow job definition to job role's SubmitJob permissions
# =============================================================================

# Add policy to job role allowing it to submit jobs using this workflow's job definition
data "aws_iam_policy_document" "job_submit_workflow" {
  statement {
    sid    = "SubmitWorkflowJobs"
    effect = "Allow"
    actions = [
      "batch:SubmitJob",
    ]
    resources = [
      # Note: Job definition ARNs need wildcard suffix to cover both versioned (:N) and unversioned forms
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.workflow.name}",
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.workflow.name}:*",
    ]
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

  container_properties = jsonencode({
    image = var.workflow_image

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

# =============================================================================
# Outputs
# =============================================================================

output "job_definition_name" {
  description = "Workflow job definition name"
  value       = aws_batch_job_definition.workflow.name
}

output "job_definition_arn" {
  description = "Workflow job definition ARN"
  value       = aws_batch_job_definition.workflow.arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for workflow image"
  value       = var.create_ecr ? aws_ecr_repository.workflow[0].repository_url : null
}

output "ecr_repository_arn" {
  description = "ECR repository ARN"
  value       = var.create_ecr ? aws_ecr_repository.workflow[0].arn : null
}

# Helper output: snakemake command
output "snakemake_command" {
  description = "Example snakemake command to run this workflow with coordinator"
  value       = <<-EOT
    snakemake --executor aws-basic-batch \
      --aws-basic-batch-region ${var.region} \
      --aws-basic-batch-job-queue ${element(split("/", var.job_queue_arn), length(split("/", var.job_queue_arn)) - 1)} \
      --aws-basic-batch-job-definition ${aws_batch_job_definition.workflow.name} \
      --aws-basic-batch-coordinator true \
      --aws-basic-batch-coordinator-job-definition <coordinator-job-definition> \
      --default-storage-provider s3 \
      --default-storage-prefix s3://<bucket-name>
    EOT
}
