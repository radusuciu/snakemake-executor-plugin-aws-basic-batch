"""Tests for AWS Batch job resource extraction and coordinator commands."""

import uuid
from unittest.mock import MagicMock, patch

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
    ex.settings.tags = None
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

    def test_extracts_gpu_from_job_resources(self, executor):
        """GPU count should be extracted from job resources."""
        job = MockJob(resources={"aws_batch_gpu": 2})
        result = Executor._get_job_resources(executor, job)
        assert result["gpu"] == 2

    def test_gpu_defaults_to_zero(self, executor):
        """GPU count should default to 0 when not specified."""
        job = MockJob(resources={})
        result = Executor._get_job_resources(executor, job)
        assert result["gpu"] == 0

    def test_extracts_job_name_prefix(self, executor):
        """Job name prefix should be extracted from job resources."""
        job = MockJob(resources={"aws_batch_job_name_prefix": "myproject"})
        result = Executor._get_job_resources(executor, job)
        assert result["job_name_prefix"] == "myproject"

    def test_job_name_prefix_defaults_to_snakejob(self, executor):
        """Job name prefix should default to 'snakejob'."""
        job = MockJob(resources={})
        result = Executor._get_job_resources(executor, job)
        assert result["job_name_prefix"] == "snakejob"

    def test_extracts_scheduling_priority(self, executor):
        """Scheduling priority should be extracted from job resources."""
        job = MockJob(resources={"aws_batch_scheduling_priority": 100})
        result = Executor._get_job_resources(executor, job)
        assert result["scheduling_priority"] == 100

    def test_scheduling_priority_defaults_to_none(self, executor):
        """Scheduling priority should default to None."""
        job = MockJob(resources={})
        result = Executor._get_job_resources(executor, job)
        assert result["scheduling_priority"] is None

    def test_extracts_job_uuid(self, executor):
        """Custom job UUID should be extracted from job resources."""
        job = MockJob(resources={"aws_batch_job_uuid": "my-custom-id"})
        result = Executor._get_job_resources(executor, job)
        assert result["job_uuid"] == "my-custom-id"

    def test_job_uuid_defaults_to_uuid4(self, executor):
        """Job UUID should default to a valid UUID string when not set."""
        job = MockJob(resources={})
        result = Executor._get_job_resources(executor, job)
        uuid.UUID(result["job_uuid"])  # raises ValueError if not valid


class TestRunJob:
    """Tests for run_job() AWS Batch integration."""

    def _setup_executor(self, executor):
        """Wire up common mocks for run_job tests."""
        executor.format_job_exec = MagicMock(return_value="echo test")
        executor.envvars = MagicMock(return_value={})
        executor.report_job_submission = MagicMock()
        executor.logger = MagicMock()
        executor.batch_client.submit_job = MagicMock(return_value={"jobId": "job-123"})
        executor._get_job_resources = lambda job: Executor._get_job_resources(
            executor, job
        )
        executor._parse_tags = lambda: Executor._parse_tags(executor)

    def test_passes_resources_to_batch_client(self, executor):
        """Verify run_job correctly passes resource overrides to AWS Batch."""
        self._setup_executor(executor)

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
        self._setup_executor(executor)

        job = MockJob(resources={"aws_batch_task_timeout": 300})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["timeout"] == {"attemptDurationSeconds": 300}

    def test_no_timeout_when_not_set(self, executor):
        """Verify run_job does not add timeout when not set."""
        self._setup_executor(executor)

        job = MockJob(resources={})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert "timeout" not in call_kwargs

    def test_gpu_included_in_resource_requirements(self, executor):
        """GPU resource requirement should be included when gpu > 0."""
        self._setup_executor(executor)

        job = MockJob(resources={"aws_batch_gpu": 2})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        resource_reqs = call_kwargs["containerOverrides"]["resourceRequirements"]
        assert {"type": "GPU", "value": "2"} in resource_reqs

    def test_no_gpu_when_zero(self, executor):
        """No GPU entry in resourceRequirements when gpu is not set."""
        self._setup_executor(executor)

        job = MockJob(resources={})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        resource_reqs = call_kwargs["containerOverrides"]["resourceRequirements"]
        gpu_entries = [r for r in resource_reqs if r["type"] == "GPU"]
        assert gpu_entries == []

    def test_custom_job_name_prefix(self, executor):
        """Job name should use custom prefix from resources."""
        self._setup_executor(executor)

        job = MockJob(resources={"aws_batch_job_name_prefix": "myexp"})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["jobName"].startswith("myexp-")

    def test_default_job_name_prefix(self, executor):
        """Job name should default to 'snakejob-' prefix."""
        self._setup_executor(executor)

        job = MockJob(resources={})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["jobName"].startswith("snakejob-")

    def test_scheduling_priority_passed(self, executor):
        """Scheduling priority should be passed to submit_job."""
        self._setup_executor(executor)

        job = MockJob(resources={"aws_batch_scheduling_priority": 50})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["schedulingPriorityOverride"] == 50

    def test_no_scheduling_priority_when_not_set(self, executor):
        """No schedulingPriorityOverride when priority is not set."""
        self._setup_executor(executor)

        job = MockJob(resources={})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert "schedulingPriorityOverride" not in call_kwargs

    def test_tags_included_in_submit(self, executor):
        """Tags should be included in submit_job when configured."""
        self._setup_executor(executor)
        executor.settings.tags = "project=genomics,run=exp1"

        job = MockJob(resources={})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["tags"] == {"project": "genomics", "run": "exp1"}

    def test_no_tags_when_not_set(self, executor):
        """No tags key in submit_job when tags not configured."""
        self._setup_executor(executor)

        job = MockJob(resources={})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert "tags" not in call_kwargs

    def test_custom_job_uuid_in_job_name(self, executor):
        """Job name should contain custom UUID from resources."""
        self._setup_executor(executor)

        job = MockJob(resources={"aws_batch_job_uuid": "fixed-id"})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert "fixed-id" in call_kwargs["jobName"]

    def test_default_job_uuid_in_job_name(self, executor):
        """Job name should contain a valid UUID when not set."""
        self._setup_executor(executor)

        job = MockJob(resources={})

        Executor.run_job(executor, job)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        # Extract UUID portion from job name (format: prefix-rulename-uuid)
        job_name = call_kwargs["jobName"]
        uuid_part = job_name.rsplit("-", 5)[-5:]  # UUID has 5 groups
        uuid_str = "-".join(uuid_part)
        uuid.UUID(uuid_str)  # raises ValueError if not valid


class TestParseTags:
    """Tests for _parse_tags() method."""

    def test_parses_simple_tags(self):
        """Simple comma-separated key=value pairs should be parsed."""
        ex = MagicMock()
        ex.settings.tags = "a=1,b=2"
        assert Executor._parse_tags(ex) == {"a": "1", "b": "2"}

    def test_returns_empty_for_none(self):
        """None tags should return empty dict."""
        ex = MagicMock()
        ex.settings.tags = None
        assert Executor._parse_tags(ex) == {}

    def test_returns_empty_for_empty_string(self):
        """Empty string tags should return empty dict."""
        ex = MagicMock()
        ex.settings.tags = ""
        assert Executor._parse_tags(ex) == {}

    def test_handles_whitespace(self):
        """Whitespace around keys and values should be stripped."""
        ex = MagicMock()
        ex.settings.tags = " a = 1 , b = 2 "
        assert Executor._parse_tags(ex) == {"a": "1", "b": "2"}

    def test_handles_equals_in_value(self):
        """Values containing '=' should be preserved."""
        ex = MagicMock()
        ex.settings.tags = "arn=arn:aws:foo:bar"
        assert Executor._parse_tags(ex) == {"arn": "arn:aws:foo:bar"}


class TestBuildCoordinatorCommand:
    """Tests for _build_coordinator_command() method."""

    def _call(self, argv):
        """Call _build_coordinator_command with a mocked sys.argv."""
        ex = MagicMock()
        with patch("sys.argv", ["snakemake"] + argv):
            return Executor._build_coordinator_command(ex)

    def test_preserves_snakefile_flag(self):
        """--snakefile should be forwarded to the coordinator command."""
        cmd = self._call(["--snakefile", "workflow/Snakefile", "--cores", "4"])
        assert cmd == "snakemake --snakefile workflow/Snakefile --cores 4"

    def test_preserves_snakefile_short_flag(self):
        """-s should be forwarded to the coordinator command."""
        cmd = self._call(["-s", "alt/Snakefile", "--cores", "1"])
        assert cmd == "snakemake -s alt/Snakefile --cores 1"

    def test_preserves_snakefile_equals_form(self):
        """--snakefile=path form should be forwarded."""
        cmd = self._call(["--snakefile=workflow/Snakefile", "--cores", "2"])
        assert cmd == "snakemake --snakefile=workflow/Snakefile --cores 2"

    def test_no_snakefile_flag(self):
        """Command without --snakefile should work normally."""
        cmd = self._call(["--cores", "4", "--executor", "aws-basic-batch"])
        assert cmd == "snakemake --cores 4 --executor aws-basic-batch"

    def test_empty_args(self):
        """Empty arguments should produce a bare snakemake command."""
        cmd = self._call([])
        assert cmd == "snakemake "

    def test_special_characters_are_quoted(self):
        """Arguments with special characters should be properly shell-quoted."""
        cmd = self._call(["--config", "key=value with spaces"])
        assert "'key=value with spaces'" in cmd


class TestSubmitCoordinatorJob:
    """Tests for coordinator job name customization."""

    def _setup_executor(self, executor):
        """Wire up common mocks for coordinator job tests."""
        executor.settings.coordinator_queue = None
        executor.settings.coordinator_job_definition = None
        executor.settings.coordinator_job_name_prefix = None
        executor.settings.coordinator_job_uuid = None
        executor.logger = MagicMock()
        executor.batch_client.submit_job = MagicMock(
            return_value={"jobId": "coord-123"}
        )
        executor.workflow.persistence.path = MagicMock()
        executor.workflow.persistence.path.__truediv__ = MagicMock(
            return_value=MagicMock(exists=MagicMock(return_value=False))
        )
        executor._build_coordinator_command = (
            lambda: Executor._build_coordinator_command(executor)
        )
        executor._get_coordinator_environment = (
            lambda: Executor._get_coordinator_environment(executor)
        )
        executor._parse_tags = lambda: Executor._parse_tags(executor)

    def test_custom_prefix(self, executor):
        """Custom prefix should be used in coordinator job name."""
        self._setup_executor(executor)
        executor.settings.coordinator_job_name_prefix = "my-workflow"

        with patch("os._exit"):
            Executor._submit_coordinator_job(executor)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["jobName"].startswith("my-workflow-")

    def test_default_prefix(self, executor):
        """Default prefix should be 'snakemake-coordinator' when not set."""
        self._setup_executor(executor)

        with patch("os._exit"):
            Executor._submit_coordinator_job(executor)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["jobName"].startswith("snakemake-coordinator-")

    def test_custom_uuid(self, executor):
        """Custom UUID should be used in coordinator job name."""
        self._setup_executor(executor)
        executor.settings.coordinator_job_uuid = "fixed-run-id"

        with patch("os._exit"):
            Executor._submit_coordinator_job(executor)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        assert call_kwargs["jobName"].endswith("-fixed-run-id")

    def test_default_uuid_is_valid(self, executor):
        """Default UUID should be a valid auto-generated UUID when not set."""
        self._setup_executor(executor)

        with patch("os._exit"):
            Executor._submit_coordinator_job(executor)

        call_kwargs = executor.batch_client.submit_job.call_args.kwargs
        job_name = call_kwargs["jobName"]
        # Format: snakemake-coordinator-<uuid>
        uuid_part = job_name.removeprefix("snakemake-coordinator-")
        uuid.UUID(uuid_part)  # raises ValueError if not valid

    def test_does_not_delete_locks_directory(self, executor, tmp_path):
        """Lock cleanup should not delete the locks directory itself.

        When concurrent Snakemake processes share .snakemake/locks/,
        deleting the directory (shutil.rmtree) races with other processes
        that expect the directory to exist for lock file creation.
        The cleanup should only remove this process's lock files.
        """
        self._setup_executor(executor)

        # Set up a real locks directory with another process's lock file
        lock_dir = tmp_path / "locks"
        lock_dir.mkdir()
        other_process_lock = lock_dir / "1.input.lock"
        other_process_lock.write_text("some/output/file.txt\n")

        executor.workflow.persistence.path = tmp_path
        executor.workflow.persistence.unlock = MagicMock()

        with patch("os._exit"):
            Executor._submit_coordinator_job(executor)

        assert lock_dir.exists(), (
            "locks directory was deleted — concurrent processes will get "
            "FileNotFoundError when creating lock files"
        )
        assert other_process_lock.exists(), "another process's lock file was deleted"
