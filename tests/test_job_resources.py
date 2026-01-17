"""Tests for AWS Batch job resource extraction."""
import pytest
from unittest.mock import MagicMock
from snakemake_executor_plugin_aws_basic_batch import Executor


class MockJob:
    """Minimal mock implementing JobExecutorInterface.resources as Mapping."""
    def __init__(self, name="test_job", resources=None):
        self.name = name
        self.resources = resources or {}


@pytest.fixture
def executor():
    """Mock executor with default settings."""
    ex = MagicMock()
    ex.settings.job_queue = "default-queue"
    ex.settings.job_definition = "default-job-def"
    return ex


class TestGetJobResources:
    """Tests for _get_job_resources() method."""

    @pytest.mark.parametrize("resource_name,bad_value,result_key", [
        ("aws_batch_vcpu", 0, "vcpu"),
        ("aws_batch_vcpu", -5, "vcpu"),
        ("aws_batch_mem_mb", 0, "mem_mb"),
        ("aws_batch_mem_mb", -1000, "mem_mb"),
    ])
    def test_enforces_minimum_values(self, executor, resource_name, bad_value, result_key):
        """Zero or negative values should be clamped to 1."""
        job = MockJob(resources={resource_name: bad_value})
        result = Executor._get_job_resources(executor, job)
        assert result[result_key] == 1


class TestRunJob:
    """Tests for run_job() AWS Batch integration."""

    def test_passes_resources_to_batch_client(self, executor):
        """Verify run_job correctly passes resource overrides to AWS Batch."""
        executor.format_job_exec = MagicMock(return_value="echo test")
        executor.envvars = MagicMock(return_value={})
        executor.report_job_submission = MagicMock()
        executor.logger = MagicMock()
        executor.batch_client.submit_job = MagicMock(return_value={"jobId": "job-123"})
        executor._get_job_resources = lambda job: Executor._get_job_resources(executor, job)

        job = MockJob(resources={
            "aws_batch_vcpu": 4,
            "aws_batch_mem_mb": 8192,
            "aws_batch_job_queue": "custom-queue",
            "aws_batch_job_definition": "custom-def",
        })

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["jobQueue"] == "custom-queue"
        assert call_kwargs["jobDefinition"] == "custom-def"

        # AWS Batch expects VCPU/MEMORY as strings
        resource_reqs = call_kwargs["containerOverrides"]["resourceRequirements"]
        assert {"type": "VCPU", "value": "4"} in resource_reqs
        assert {"type": "MEMORY", "value": "8192"} in resource_reqs
