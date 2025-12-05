# snakemake-executor-plugin-aws-basic-batch

A Snakemake executor plugin for AWS Batch that uses pre-configured job definitions.

Unlike the [standard AWS Batch plugin](https://github.com/snakemake/snakemake-executor-plugin-aws-batch) which dynamically creates job definitions, this "basic" plugin relies on existing job definitions. This allows all resource configuration to be managed externally (e.g., via Terraform/CloudFormation). Additionally, workflow files and dependencies must bundled in the container image.

## Usage

```bash
snakemake --executor aws-basic-batch \
  --aws-basic-batch-region us-east-1 \
  --aws-basic-batch-job-queue my-queue \
  --aws-basic-batch-job-definition my-job-def \
  --default-storage-provider s3 \
  --default-storage-prefix s3://my-bucket/workdir
```

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

## Requirements

- Workflow and dependencies must be included in the container image
- Job definitions should have appropriate IAM roles for S3 access and Batch job submission (for coordinator mode)
