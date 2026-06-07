# Consolidated Infrastructure for snakemake-executor-plugin-aws-basic-batch
#
# Single module containing all AWS Batch infrastructure needed to run Snakemake
# workflows with the aws-basic-batch executor plugin.
#
# Resources created:
# - VPC with public subnets (optional)
# - S3 bucket for workflow storage (optional)
# - Batch compute environments (coordinator: Fargate by default, workflow: EC2 by default)
# - Batch job queues (separate coordinator and workflow queues)
# - Coordinator job definition
# - Workflow job definition
# - IAM roles (batch service, execution, job)
# - CloudWatch log group
# - ECR repositories for coordinator and workflow images (optional)

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

# Core
variable "coordinator_name_prefix" {
  description = "Prefix for coordinator resource names (compute env, queue, job def)"
  type        = string
  default     = "snakemake-coordinator"
}

variable "workflow_name_prefix" {
  description = "Prefix for workflow resource names (compute env, queue, job def, ECR)"
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

# Batch Compute Configuration
variable "coordinator_compute_type" {
  description = "Batch compute type for coordinator: FARGATE, FARGATE_SPOT, EC2, or SPOT"
  type        = string
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT", "EC2", "SPOT"], var.coordinator_compute_type)
    error_message = "coordinator_compute_type must be FARGATE, FARGATE_SPOT, EC2, or SPOT"
  }
}

variable "workflow_compute_type" {
  description = "Batch compute type for workflow jobs: FARGATE, FARGATE_SPOT, EC2, or SPOT"
  type        = string
  default     = "EC2"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT", "EC2", "SPOT"], var.workflow_compute_type)
    error_message = "workflow_compute_type must be FARGATE, FARGATE_SPOT, EC2, or SPOT"
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
  description = "Maximum vCPUs for workflow compute environment"
  type        = number
  default     = 256
}

variable "coordinator_max_vcpus" {
  description = "Maximum vCPUs for coordinator compute environment"
  type        = number
  default     = 16
}

# Job Definition Configuration
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

variable "coordinator_image" {
  description = "Container image for coordinator job definition. If null and create_ecr=true, uses the created ECR repository."
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

variable "workflow_image" {
  description = "Container image for workflow job definition. If null and create_ecr=true, uses the created ECR repository."
  type        = string
  default     = null
}

# Storage Configuration
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
  description = "Whether to create ECR repositories for coordinator and workflow images"
  type        = bool
  default     = true
}

variable "ecr_repository_prefix" {
  description = "Prefix for ECR repository names. If null, uses name_prefix."
  type        = string
  default     = null
}

# =============================================================================
# Locals
# =============================================================================

locals {
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)

  # Coordinator compute type helpers
  coordinator_is_fargate = var.coordinator_compute_type == "FARGATE" || var.coordinator_compute_type == "FARGATE_SPOT"
  coordinator_is_ec2     = var.coordinator_compute_type == "EC2" || var.coordinator_compute_type == "SPOT"

  # Workflow compute type helpers
  workflow_is_fargate = var.workflow_compute_type == "FARGATE" || var.workflow_compute_type == "FARGATE_SPOT"
  workflow_is_ec2     = var.workflow_compute_type == "EC2" || var.workflow_compute_type == "SPOT"

  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Project   = "snakemake-aws-basic-batch"
  })

  vpc_id     = var.create_vpc ? aws_vpc.this[0].id : var.vpc_id
  subnet_ids = var.create_vpc ? aws_subnet.public[*].id : var.subnet_ids

  bucket_name = var.create_bucket ? (
    var.bucket_name != null ? var.bucket_name : "${var.workflow_name_prefix}-${random_id.bucket_suffix[0].hex}"
  ) : null

  has_s3_buckets = var.create_bucket || length(var.s3_bucket_arns) > 0

  all_bucket_arns = compact(concat(
    var.create_bucket ? [aws_s3_bucket.workflow[0].arn] : [],
    var.s3_bucket_arns
  ))

  # ECR repository names - uses workflow prefix for state compatibility
  ecr_prefix = var.ecr_repository_prefix != null ? var.ecr_repository_prefix : var.workflow_name_prefix

  # Container images
  coordinator_image = coalesce(
    var.coordinator_image,
    var.create_ecr ? "${aws_ecr_repository.coordinator[0].repository_url}:latest" : "ghcr.io/radusuciu/snakemake-executor-plugin-aws-basic-batch:latest",
  )

  workflow_image = coalesce(
    var.workflow_image,
    var.create_ecr ? "${aws_ecr_repository.workflow[0].repository_url}:latest" : null,
  )
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
    Name = "${var.workflow_name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  count = var.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(local.common_tags, {
    Name = "${var.workflow_name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  count = var.create_vpc ? length(local.azs) : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.workflow_name_prefix}-public-${local.azs[count.index]}"
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
    Name = "${var.workflow_name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = var.create_vpc ? length(local.azs) : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_security_group" "batch" {
  name_prefix = "${var.workflow_name_prefix}-batch-"
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
    Name = "${var.workflow_name_prefix}-batch-sg"
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
# ECR Repositories
# =============================================================================

# Coordinator image ECR
resource "aws_ecr_repository" "coordinator" {
  count = var.create_ecr ? 1 : 0

  name                 = "${local.ecr_prefix}-coordinator"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.ecr_prefix}-coordinator"
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

# Workflow image ECR (uses ${workflow_name_prefix} for state compatibility)
resource "aws_ecr_repository" "workflow" {
  count = var.create_ecr ? 1 : 0

  name                 = local.ecr_prefix
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name = local.ecr_prefix
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
  name_prefix        = "${var.workflow_name_prefix}-batch-svc-"
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
  count = (local.coordinator_is_ec2 || local.workflow_is_ec2) ? 1 : 0

  name_prefix        = "${var.workflow_name_prefix}-ecs-inst-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  count = (local.coordinator_is_ec2 || local.workflow_is_ec2) ? 1 : 0

  role       = aws_iam_role.ecs_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  count = (local.coordinator_is_ec2 || local.workflow_is_ec2) ? 1 : 0

  name_prefix = "${var.workflow_name_prefix}-ecs-inst-"
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
  name_prefix        = "${var.workflow_name_prefix}-ecs-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow the ECS execution role to tag tasks on creation. Accounts that enforce
# ECS tagging authorization require this permission when propagating Batch job
# tags to ECS tasks; tags-on-create authorization does not support narrower
# resource scoping, so Resource "*" is required.
resource "aws_iam_role_policy" "ecs_execution_tag" {
  name_prefix = "${var.workflow_name_prefix}-ecs-exec-tag-"
  role        = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ecs:TagResource"]
      Resource = "*"
    }]
  })
}

# Job Role (shared by coordinator and workflow jobs)
resource "aws_iam_role" "job" {
  name_prefix        = "${var.workflow_name_prefix}-job-"
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

  name_prefix = "${var.workflow_name_prefix}-job-s3-"
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
  name_prefix = "${var.workflow_name_prefix}-job-logs-"
  role        = aws_iam_role.job.id
  policy      = data.aws_iam_policy_document.job_logs.json
}

# Batch access for job role to submit and manage jobs
# Includes BOTH queues and ALL job definitions
data "aws_iam_policy_document" "job_batch" {
  # Submit jobs to both queues using all job definitions
  statement {
    sid    = "SubmitJobs"
    effect = "Allow"
    actions = [
      "batch:SubmitJob",
      "batch:TagResource",
    ]
    resources = [
      # Both job queues
      aws_batch_job_queue.coordinator.arn,
      aws_batch_job_queue.workflow.arn,
      # Coordinator job definition (versioned and unversioned)
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.coordinator.name}",
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.coordinator.name}:*",
      # Workflow job definition (versioned and unversioned)
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.workflow.name}",
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.workflow.name}:*",
      # Workflow coordinator job definition (versioned and unversioned)
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.workflow_coordinator.name}",
      "arn:aws:batch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.workflow_coordinator.name}:*",
    ]
  }

  # List jobs in both queues
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
      values = [
        aws_batch_job_queue.coordinator.arn,
        aws_batch_job_queue.workflow.arn,
      ]
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
  name_prefix = "${var.workflow_name_prefix}-job-batch-"
  role        = aws_iam_role.job.id
  policy      = data.aws_iam_policy_document.job_batch.json
}

# =============================================================================
# AWS Batch Resources
# =============================================================================

# Coordinator Compute Environment
resource "aws_batch_compute_environment" "coordinator" {
  compute_environment_name_prefix = "${var.coordinator_name_prefix}-"
  type                            = "MANAGED"
  state                           = "ENABLED"
  service_role                    = aws_iam_role.batch_service.arn

  compute_resources {
    type      = var.coordinator_compute_type
    max_vcpus = var.coordinator_max_vcpus

    subnets            = local.subnet_ids
    security_group_ids = [aws_security_group.batch.id]

    # EC2/SPOT-specific settings
    min_vcpus     = local.coordinator_is_ec2 ? var.min_vcpus : null
    instance_type = local.coordinator_is_ec2 ? var.instance_types : null
    instance_role = local.coordinator_is_ec2 ? aws_iam_instance_profile.ecs_instance[0].arn : null
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# Workflow Compute Environment
resource "aws_batch_compute_environment" "workflow" {
  compute_environment_name_prefix = "${var.workflow_name_prefix}-"
  type                            = "MANAGED"
  state                           = "ENABLED"
  service_role                    = aws_iam_role.batch_service.arn

  compute_resources {
    type      = var.workflow_compute_type
    max_vcpus = var.max_vcpus

    subnets            = local.subnet_ids
    security_group_ids = [aws_security_group.batch.id]

    # EC2/SPOT-specific settings
    min_vcpus     = local.workflow_is_ec2 ? var.min_vcpus : null
    instance_type = local.workflow_is_ec2 ? var.instance_types : null
    instance_role = local.workflow_is_ec2 ? aws_iam_instance_profile.ecs_instance[0].arn : null
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# Coordinator Job Queue
resource "aws_batch_job_queue" "coordinator" {
  name     = "${var.coordinator_name_prefix}-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.coordinator.arn
  }

  tags = local.common_tags
}

# Workflow Job Queue
resource "aws_batch_job_queue" "workflow" {
  name     = "${var.workflow_name_prefix}-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.workflow.arn
  }

  tags = local.common_tags
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "batch" {
  name              = "/aws/batch/${var.coordinator_name_prefix}"
  retention_in_days = 7
  tags              = local.common_tags
}

# =============================================================================
# AWS Batch Job Definitions
# =============================================================================

# Coordinator Job Definition (in coordinator module naming: ${coordinator_name_prefix}-coordinator)
resource "aws_batch_job_definition" "coordinator" {
  name                  = "${var.coordinator_name_prefix}-coordinator"
  type                  = "container"
  platform_capabilities = local.coordinator_is_fargate ? ["FARGATE"] : ["EC2"]
  propagate_tags        = true

  container_properties = jsonencode({
    image = local.coordinator_image

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

    networkConfiguration = local.coordinator_is_fargate ? {
      assignPublicIp = "ENABLED"
    } : null

    command = ["echo", "No command specified"]
  })

  tags = local.common_tags
}

# Workflow Job Definition (in workflow module naming: ${workflow_name_prefix}-job)
resource "aws_batch_job_definition" "workflow" {
  name                  = "${var.workflow_name_prefix}-job"
  type                  = "container"
  platform_capabilities = local.workflow_is_fargate ? ["FARGATE"] : ["EC2"]
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

    jobRoleArn       = aws_iam_role.job.arn
    executionRoleArn = aws_iam_role.ecs_execution.arn

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.batch.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "workflow"
      }
    }

    networkConfiguration = local.workflow_is_fargate ? {
      assignPublicIp = "ENABLED"
    } : null

    command = ["echo", "No command specified"]
  })

  tags = local.common_tags
}

# Workflow Coordinator Job Definition (in workflow module naming: ${workflow_name_prefix}-coordinator)
resource "aws_batch_job_definition" "workflow_coordinator" {
  name                  = "${var.workflow_name_prefix}-coordinator"
  type                  = "container"
  platform_capabilities = local.workflow_is_fargate ? ["FARGATE"] : ["EC2"]
  propagate_tags        = true

  container_properties = jsonencode({
    image = local.coordinator_image

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

    networkConfiguration = local.workflow_is_fargate ? {
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

# Coordinator Job Queue
output "coordinator_job_queue_name" {
  description = "Coordinator Batch job queue name"
  value       = aws_batch_job_queue.coordinator.name
}

output "coordinator_job_queue_arn" {
  description = "Coordinator Batch job queue ARN"
  value       = aws_batch_job_queue.coordinator.arn
}

# Workflow Job Queue
output "workflow_job_queue_name" {
  description = "Workflow Batch job queue name"
  value       = aws_batch_job_queue.workflow.name
}

output "workflow_job_queue_arn" {
  description = "Workflow Batch job queue ARN"
  value       = aws_batch_job_queue.workflow.arn
}

# Coordinator Job Definition
output "coordinator_job_definition_name" {
  description = "Coordinator job definition name"
  value       = aws_batch_job_definition.coordinator.name
}

output "coordinator_job_definition_arn" {
  description = "Coordinator job definition ARN"
  value       = aws_batch_job_definition.coordinator.arn
}

# Workflow Job Definition
output "workflow_job_definition_name" {
  description = "Workflow job definition name"
  value       = aws_batch_job_definition.workflow.name
}

output "workflow_job_definition_arn" {
  description = "Workflow job definition ARN"
  value       = aws_batch_job_definition.workflow.arn
}

# Workflow Coordinator Job Definition
output "workflow_coordinator_job_definition_name" {
  description = "Workflow coordinator job definition name"
  value       = aws_batch_job_definition.workflow_coordinator.name
}

output "workflow_coordinator_job_definition_arn" {
  description = "Workflow coordinator job definition ARN"
  value       = aws_batch_job_definition.workflow_coordinator.arn
}

# IAM Roles
output "job_role_arn" {
  description = "IAM role ARN for jobs (shared by coordinator and workflows)"
  value       = aws_iam_role.job.arn
}

output "execution_role_arn" {
  description = "IAM execution role ARN for ECS tasks"
  value       = aws_iam_role.ecs_execution.arn
}

# VPC
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

# Storage
output "bucket_name" {
  description = "S3 bucket name for workflow storage"
  value       = var.create_bucket ? aws_s3_bucket.workflow[0].id : var.bucket_name
}

output "bucket_arn" {
  description = "S3 bucket ARN for workflow storage"
  value       = var.create_bucket ? aws_s3_bucket.workflow[0].arn : (var.bucket_name != null ? "arn:aws:s3:::${var.bucket_name}" : null)
}

# CloudWatch
output "log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.batch.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN"
  value       = aws_cloudwatch_log_group.batch.arn
}

# ECR
output "coordinator_ecr_repository_url" {
  description = "ECR repository URL for coordinator image"
  value       = var.create_ecr ? aws_ecr_repository.coordinator[0].repository_url : null
}

output "workflow_ecr_repository_url" {
  description = "ECR repository URL for workflow image"
  value       = var.create_ecr ? aws_ecr_repository.workflow[0].repository_url : null
}

# Container Images
output "coordinator_image" {
  description = "Resolved coordinator container image"
  value       = local.coordinator_image
}

output "workflow_image" {
  description = "Resolved workflow container image"
  value       = local.workflow_image
}

# Helper output: snakemake command
output "snakemake_command" {
  description = "Example snakemake command to run a workflow"
  value       = <<-EOT
    snakemake --executor aws-basic-batch \
      --aws-basic-batch-region ${var.region} \
      --aws-basic-batch-job-queue ${aws_batch_job_queue.workflow.name} \
      --aws-basic-batch-job-definition ${aws_batch_job_definition.workflow.name} \
      --aws-basic-batch-coordinator true \
      --aws-basic-batch-coordinator-job-definition ${aws_batch_job_definition.coordinator.name} \
      --aws-basic-batch-coordinator-queue ${aws_batch_job_queue.coordinator.name} \
      --default-storage-provider s3 \
      --default-storage-prefix s3://${var.create_bucket ? aws_s3_bucket.workflow[0].id : "<bucket-name>"}
    EOT
}
