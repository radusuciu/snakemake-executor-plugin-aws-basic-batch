"""Tests for AWS Batch job resource extraction."""

from unittest.mock import MagicMock

import pytest

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
    ex.settings.task_timeout = None
    return ex


class TestGetJobResources:
    """Tests for _get_job_resources() method."""

    @pytest.mark.parametrize(
        "resource_name,bad_value,result_key",
        [
            ("aws_batch_vcpu", 0, "vcpu"),
            ("aws_batch_vcpu", -5, "vcpu"),
            ("aws_batch_mem_mb", 0, "mem_mb"),
            ("aws_batch_mem_mb", -1000, "mem_mb"),
        ],
    )
    def test_enforces_minimum_values(
        self, executor, resource_name, bad_value, result_key
    ):
        """Zero or negative values should be clamped to 1."""
        job = MockJob(resources={resource_name: bad_value})
        result = Executor._get_job_resources(executor, job)
        assert result[result_key] == 1

    def test_extracts_timeout_from_job_resources(self, executor):
        """Task timeout should be extracted from job resources."""
        job = MockJob(resources={"aws_batch_task_timeout": 300})
        result = Executor._get_job_resources(executor, job)
        assert result["task_timeout"] == 300

    def test_timeout_falls_back_to_settings(self, executor):
        """Task timeout should fall back to executor settings if not in job resources."""
        executor.settings.task_timeout = 600
        job = MockJob(resources={})
        result = Executor._get_job_resources(executor, job)
        assert result["task_timeout"] == 600

    def test_timeout_is_none_when_not_set(self, executor):
        """Task timeout should be None when not set anywhere."""
        job = MockJob(resources={})
        result = Executor._get_job_resources(executor, job)
        assert result["task_timeout"] is None


class TestRunJob:
    """Tests for run_job() AWS Batch integration."""

    def test_passes_resources_to_batch_client(self, executor):
        """Verify run_job correctly passes resource overrides to AWS Batch."""
        executor.format_job_exec = MagicMock(return_value="echo test")
        executor.envvars = MagicMock(return_value={})
        executor.report_job_submission = MagicMock()
        executor.logger = MagicMock()
        executor.batch_client.submit_job = MagicMock(return_value={"jobId": "job-123"})
        executor._get_job_resources = lambda job: Executor._get_job_resources(
            executor, job
        )

        job = MockJob(
            resources={
                "aws_batch_vcpu": 4,
                "aws_batch_mem_mb": 8192,
                "aws_batch_job_queue": "custom-queue",
                "aws_batch_job_definition": "custom-def",
            }
        )

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["jobQueue"] == "custom-queue"
        assert call_kwargs["jobDefinition"] == "custom-def"

        # AWS Batch expects VCPU/MEMORY as strings
        resource_reqs = call_kwargs["containerOverrides"]["resourceRequirements"]
        assert {"type": "VCPU", "value": "4"} in resource_reqs
        assert {"type": "MEMORY", "value": "8192"} in resource_reqs

    def test_passes_timeout_to_batch_client(self, executor):
        """Verify run_job correctly passes timeout to AWS Batch."""
        executor.format_job_exec = MagicMock(return_value="echo test")
        executor.envvars = MagicMock(return_value={})
        executor.report_job_submission = MagicMock()
        executor.logger = MagicMock()
        executor.batch_client.submit_job = MagicMock(return_value={"jobId": "job-123"})
        executor.settings.task_timeout = None
        executor._get_job_resources = lambda job: Executor._get_job_resources(
            executor, job
        )

        job = MockJob(resources={"aws_batch_task_timeout": 300})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["timeout"] == {"attemptDurationSeconds": 300}

    def test_no_timeout_when_not_set(self, executor):
        """Verify run_job does not add timeout when not set."""
        executor.format_job_exec = MagicMock(return_value="echo test")
        executor.envvars = MagicMock(return_value={})
        executor.report_job_submission = MagicMock()
        executor.logger = MagicMock()
        executor.batch_client.submit_job = MagicMock(return_value={"jobId": "job-123"})
        executor.settings.task_timeout = None
        executor._get_job_resources = lambda job: Executor._get_job_resources(
            executor, job
        )

        job = MockJob(resources={})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert "timeout" not in call_kwargs
