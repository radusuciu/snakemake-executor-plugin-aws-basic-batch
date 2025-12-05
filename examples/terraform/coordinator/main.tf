# Coordinator Infrastructure for snakemake-executor-plugin-aws-basic-batch
#
# This module sets up the base AWS Batch infrastructure needed to run the
# coordinator (the long-running Snakemake process that orchestrates jobs).
#
# Resources created:
# - VPC with public subnets (optional)
# - Batch compute environment
# - Batch job queue
# - Coordinator job definition
# - IAM roles (batch service, execution, coordinator job)
# - CloudWatch log group
# - ECR repository (optional)
#
# The coordinator needs permissions to:
# - Submit jobs to the queue
# - Describe/terminate jobs
# - Access S3 for workflow storage
# - Write logs

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# =============================================================================
# Variables
# =============================================================================

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "snakemake-coordinator"
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

# VPC Configuration
variable "create_vpc" {
  description = "Whether to create a new VPC or use existing"
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "Existing VPC ID (required if create_vpc = false)"
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Existing subnet IDs (required if create_vpc = false)"
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR block for new VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for subnets (defaults to first 2 in region)"
  type        = list(string)
  default     = []
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
  default     = 16
}

variable "coordinator_image" {
  description = "Container image for coordinator job definition"
  type        = string
  default     = "snakemake/snakemake:latest"
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

# Storage
variable "create_bucket" {
  description = "Whether to create an S3 bucket for workflow storage"
  type        = bool
  default     = true
}

variable "bucket_name" {
  description = "S3 bucket name (must be globally unique). If null, auto-generates a name."
  type        = string
  default     = null
}

variable "s3_bucket_arns" {
  description = "Additional S3 bucket ARNs that jobs can access (beyond the created bucket). Required if create_bucket = false."
  type        = list(string)
  default     = []
}

# ECR Configuration
variable "create_ecr" {
  description = "Whether to create an ECR repository for the coordinator image"
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
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)

  # Compute type helpers
  is_fargate = var.compute_type == "FARGATE" || var.compute_type == "FARGATE_SPOT"
  is_ec2     = var.compute_type == "EC2" || var.compute_type == "SPOT"

  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Project   = "snakemake-aws-basic-batch"
    Component = "coordinator"
  })

  vpc_id     = var.create_vpc ? aws_vpc.this[0].id : var.vpc_id
  subnet_ids = var.create_vpc ? aws_subnet.public[*].id : var.subnet_ids

  bucket_name = var.create_bucket ? (
    var.bucket_name != null ? var.bucket_name : "${var.name_prefix}-${random_id.bucket_suffix[0].hex}"
  ) : null

  has_s3_buckets = var.create_bucket || length(var.s3_bucket_arns) > 0

  all_bucket_arns = compact(concat(
    var.create_bucket ? [aws_s3_bucket.workflow[0].arn] : [],
    var.s3_bucket_arns
  ))

  ecr_repository_url = var.create_ecr ? aws_ecr_repository.coordinator[0].repository_url : null
}

# =============================================================================
# VPC
# =============================================================================

resource "aws_vpc" "this" {
  count = var.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  count = var.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  count = var.create_vpc ? length(local.azs) : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
  })
}

resource "aws_route_table" "public" {
  count = var.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = var.create_vpc ? length(local.azs) : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_security_group" "batch" {
  name_prefix = "${var.name_prefix}-batch-"
  description = "Security group for AWS Batch compute environment"
  vpc_id      = local.vpc_id

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

    precondition {
      condition     = var.create_vpc || var.vpc_id != null
      error_message = "vpc_id is required when create_vpc = false"
    }

    precondition {
      condition     = var.create_vpc || length(var.subnet_ids) > 0
      error_message = "subnet_ids is required when create_vpc = false"
    }
  }
}

# =============================================================================
# S3 Storage
# =============================================================================

resource "random_id" "bucket_suffix" {
  count       = var.create_bucket && var.bucket_name == null ? 1 : 0
  byte_length = 8
}

resource "aws_s3_bucket" "workflow" {
  count  = var.create_bucket ? 1 : 0
  bucket = local.bucket_name

  tags = merge(local.common_tags, {
    Name = local.bucket_name
  })
}

resource "aws_s3_bucket_public_access_block" "workflow" {
  count  = var.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.workflow[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "workflow" {
  count  = var.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.workflow[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# =============================================================================
# ECR Repository
# =============================================================================

resource "aws_ecr_repository" "coordinator" {
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
# IAM Roles
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
  name_prefix        = "${var.name_prefix}-batch-service-"
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

  name_prefix        = "${var.name_prefix}-ecs-instance-"
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

  name_prefix = "${var.name_prefix}-ecs-instance-"
  role        = aws_iam_role.ecs_instance[0].name
  tags        = local.common_tags
}

# ECS Task Execution Role
data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name_prefix        = "${var.name_prefix}-ecs-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Job Role (shared by coordinator and workflow jobs)
resource "aws_iam_role" "job" {
  name_prefix        = "${var.name_prefix}-job-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = local.common_tags
}

# S3 access policy for job role
data "aws_iam_policy_document" "job_s3" {
  count = local.has_s3_buckets ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [for arn in local.all_bucket_arns : "${arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = local.all_bucket_arns
  }
}

resource "aws_iam_role_policy" "job_s3" {
  count = local.has_s3_buckets ? 1 : 0

  name_prefix = "${var.name_prefix}-job-s3-"
  role        = aws_iam_role.job.id
  policy      = data.aws_iam_policy_document.job_s3[0].json
}

# CloudWatch Logs access for job role
data "aws_iam_policy_document" "job_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.batch.arn}:*"]
  }
}

resource "aws_iam_role_policy" "job_logs" {
  name_prefix = "${var.name_prefix}-job-logs-"
  role        = aws_iam_role.job.id
  policy      = data.aws_iam_policy_document.job_logs.json
}

# Batch access for job role to submit and manage child jobs
data "aws_iam_policy_document" "job_batch" {
  # Submit jobs to our queue using the coordinator job definition
  # Note: Job definition ARNs need wildcard suffix to cover both versioned (:N) and unversioned forms
  # Workflow modules will add their own job definitions to this role
  statement {
    sid    = "SubmitJobs"
    effect = "Allow"
    actions = [
      "batch:SubmitJob",
    ]
    resources = [
      aws_batch_job_queue.this.arn,
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.coordinator.name}",
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.coordinator.name}:*",
    ]
  }

  # List jobs in our queue
  statement {
    sid    = "ListJobsInQueue"
    effect = "Allow"
    actions = [
      "batch:ListJobs",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "batch:JobQueue"
      values   = [aws_batch_job_queue.this.arn]
    }
  }

  # Describe jobs (no resource-level permissions supported)
  statement {
    sid       = "DescribeJobs"
    effect    = "Allow"
    actions   = ["batch:DescribeJobs"]
    resources = ["*"]
  }

  # Terminate jobs with our project tag
  statement {
    sid    = "TerminateTaggedJobs"
    effect = "Allow"
    actions = [
      "batch:TerminateJob",
    ]
    resources = [
      "arn:aws:batch:${data.aws_region.current.name}:*:job/*"
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["snakemake-aws-basic-batch"]
    }
  }
}

resource "aws_iam_role_policy" "job_batch" {
  name_prefix = "${var.name_prefix}-job-batch-"
  role        = aws_iam_role.job.id
  policy      = data.aws_iam_policy_document.job_batch.json
}

# =============================================================================
# AWS Batch Resources
# =============================================================================

# Compute Environment
resource "aws_batch_compute_environment" "this" {
  compute_environment_name_prefix = "${var.name_prefix}-"
  type                            = "MANAGED"
  state                           = "ENABLED"
  service_role                    = aws_iam_role.batch_service.arn

  compute_resources {
    type      = var.compute_type
    max_vcpus = var.max_vcpus

    subnets            = local.subnet_ids
    security_group_ids = [aws_security_group.batch.id]

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

# Job Queue
resource "aws_batch_job_queue" "this" {
  name     = "${var.name_prefix}-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.this.arn
  }

  tags = local.common_tags
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "batch" {
  name              = "/aws/batch/${var.name_prefix}"
  retention_in_days = 7
  tags              = local.common_tags
}

# Coordinator Job Definition
resource "aws_batch_job_definition" "coordinator" {
  name                  = "${var.name_prefix}-coordinator"
  type                  = "container"
  platform_capabilities = local.is_fargate ? ["FARGATE"] : ["EC2"]
  propagate_tags        = true

  container_properties = jsonencode({
    image = var.coordinator_image

    resourceRequirements = [
      { type = "VCPU", value = tostring(var.coordinator_vcpus) },
      { type = "MEMORY", value = tostring(var.coordinator_memory) },
    ]

    jobRoleArn       = aws_iam_role.job.arn
    executionRoleArn = aws_iam_role.ecs_execution.arn

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.batch.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "coordinator"
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

output "region" {
  description = "AWS region"
  value       = var.region
}

output "job_queue_name" {
  description = "Batch job queue name"
  value       = aws_batch_job_queue.this.name
}

output "job_queue_arn" {
  description = "Batch job queue ARN"
  value       = aws_batch_job_queue.this.arn
}

output "coordinator_job_definition_name" {
  description = "Coordinator job definition name"
  value       = aws_batch_job_definition.coordinator.name
}

output "coordinator_job_definition_arn" {
  description = "Coordinator job definition ARN"
  value       = aws_batch_job_definition.coordinator.arn
}

output "job_role_arn" {
  description = "IAM role ARN for jobs (shared by coordinator and workflows)"
  value       = aws_iam_role.job.arn
}

output "execution_role_arn" {
  description = "IAM execution role ARN for ECS tasks"
  value       = aws_iam_role.ecs_execution.arn
}

# VPC outputs (for workflow modules to use)
output "vpc_id" {
  description = "VPC ID"
  value       = local.vpc_id
}

output "subnet_ids" {
  description = "Subnet IDs"
  value       = local.subnet_ids
}

output "security_group_id" {
  description = "Security group ID for Batch compute environment"
  value       = aws_security_group.batch.id
}

# Storage outputs
output "bucket_name" {
  description = "S3 bucket name for workflow storage"
  value       = var.create_bucket ? aws_s3_bucket.workflow[0].id : null
}

output "bucket_arn" {
  description = "S3 bucket ARN for workflow storage"
  value       = var.create_bucket ? aws_s3_bucket.workflow[0].arn : null
}

output "log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.batch.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN"
  value       = aws_cloudwatch_log_group.batch.arn
}

# ECR outputs
output "ecr_repository_url" {
  description = "ECR repository URL for coordinator image"
  value       = var.create_ecr ? aws_ecr_repository.coordinator[0].repository_url : null
}

output "ecr_repository_arn" {
  description = "ECR repository ARN"
  value       = var.create_ecr ? aws_ecr_repository.coordinator[0].arn : null
}
