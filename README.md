# snakemake-executor-plugin-aws-basic-batch

A Snakemake executor plugin for AWS Batch that uses pre-configured job definitions.

For full documentation, see the [Snakemake Plugin Catalog](https://snakemake.github.io/snakemake-plugin-catalog/plugins/executor/aws-basic-batch.html).

Unlike the [standard AWS Batch plugin](https://github.com/snakemake/snakemake-executor-plugin-aws-batch) which dynamically creates job definitions, this "basic" plugin relies on existing job definitions. This allows all resource configuration to be managed externally (e.g., via Terraform/CloudFormation). Additionally, workflow files and dependencies must bundled in the container image.

## Usage

```bash
snakemake --executor aws-basic-batch \
  --aws-basic-batch-region us-east-1 \
  --aws-basic-batch-job-queue my-queue \
  --aws-basic-batch-job-definition my-job-def \
  --aws-basic-batch-tags "project=genomics,user=alice" \
  --default-storage-provider s3 \
  --default-storage-prefix s3://my-bucket/workdir
```

### Workflow-Level Tags

Apply tags to all submitted jobs (both regular and coordinator) for cost tracking, filtering, etc.:

```bash
--aws-basic-batch-tags "project=genomics,run=exp1,costcenter=research"
```

Tags are comma-separated `key=value` pairs. Can also be set via the `SNAKEMAKE_AWS_BASIC_BATCH_TAGS` environment variable. Tags are propagated to the underlying ECS tasks for cost allocation. If your account enforces ECS tagging authorization, the ECS task execution role may additionally need `ecs:TagResource`.

## Coordinator Mode

Run the entire workflow as a fire-and-forget AWS Batch job:

```bash
snakemake --executor aws-basic-batch \
  --aws-basic-batch-coordinator true \
  ...
```

The coordinator job runs Snakemake itself on AWS Batch, submitting and monitoring rule jobs. Your terminal can disconnect after submission.

Optional coordinator-specific settings:
- `--aws-basic-batch-coordinator-queue` - Job queue for the coordinator (defaults to main queue)
- `--aws-basic-batch-coordinator-job-definition` - Job definition for the coordinator (defaults to main job definition)
- `--aws-basic-batch-coordinator-job-name-prefix` - Custom prefix for coordinator job names (defaults to `snakemake-coordinator`)
- `--aws-basic-batch-coordinator-job-uuid` - Custom UUID/identifier for coordinator job names (defaults to auto-generated UUID)

## Per-Job Resource Customization

Override CPU, memory, queue, or job definition on a per-rule basis using Snakemake's resource system:

```python
rule compute_heavy:
    output: "result.txt"
    resources:
        aws_batch_vcpu=4,
        aws_batch_mem_mb=8192,
        aws_batch_gpu=1,
        aws_batch_job_queue="high-memory-queue",
        aws_batch_job_name_prefix="myproject",
        aws_batch_scheduling_priority=100,
        aws_batch_job_uuid="my-run-id"
    shell: "python compute.py > {output}"
```

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

These values override the base job definition's resource configuration at submission time via AWS Batch's `containerOverrides.resourceRequirements`.

## Requirements

- Workflow and dependencies must be included in the container image
- Job definitions should have appropriate IAM roles for S3 access and Batch job submission (for coordinator mode)
