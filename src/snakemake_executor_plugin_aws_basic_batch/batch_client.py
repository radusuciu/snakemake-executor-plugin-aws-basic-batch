import boto3


class BatchClient:
    """Minimal wrapper around boto3 Batch client."""

    def __init__(self, region_name=None):
        self.client = boto3.client("batch", region_name=region_name)

    def submit_job(self, **kwargs):
        """Submit a job to AWS Batch."""
        return self.client.submit_job(**kwargs)

    def describe_jobs(self, **kwargs):
        """Describe jobs in AWS Batch."""
        return self.client.describe_jobs(**kwargs)

    def terminate_job(self, **kwargs):
        """Terminate a job in AWS Batch."""
        return self.client.terminate_job(**kwargs)
