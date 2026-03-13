"""
Snakemake executor plugin for AWS Batch using existing job definitions.

This "basic" plugin relies on pre-configured job definitions rather than
dynamically creating them. This simplifies the setup and allows all resource
configuration to be managed externally (e.g., via Terraform/CloudFormation).
"""

__author__ = "Radu Suciu"
__copyright__ = "Copyright 2025"
__email__ = "radusuciu@gmail.com"
__license__ = "MIT"

import os
import shlex
import sys
import uuid
from dataclasses import dataclass, field
from pprint import pformat
from typing import AsyncGenerator, List, Optional

from snakemake_interface_common.exceptions import WorkflowError
from snakemake_interface_executor_plugins.executors.base import SubmittedJobInfo
from snakemake_interface_executor_plugins.executors.remote import RemoteExecutor
from snakemake_interface_executor_plugins.jobs import JobExecutorInterface
from snakemake_interface_executor_plugins.settings import (
    CommonSettings,
    ExecutorSettingsBase,
)

from snakemake_executor_plugin_aws_basic_batch.batch_client import BatchClient


@dataclass
class ExecutorSettings(ExecutorSettingsBase):
    region: Optional[str] = field(
        default=None,
        metadata={
            "help": "AWS Region",
            "env_var": False,
            "required": True,
        },
    )
    job_queue: Optional[str] = field(
        default=None,
        metadata={
            "help": "The AWS Batch job queue ARN or name",
            "env_var": True,
            "required": True,
        },
    )
    job_definition: Optional[str] = field(
        default=None,
        metadata={
            "help": (
                "The AWS Batch job definition ARN or name to use for running jobs. "
                "This should be a pre-configured job definition with appropriate "
                "resources, IAM roles, and container settings."
            ),
            "env_var": True,
            "required": True,
        },
    )
    # Coordinator mode settings
    # TODO: do we even need this? if we're using this executor plugin, then maybe we always want coordinator mode?
    coordinator: Optional[bool] = field(
        default=False,
        metadata={
            "help": (
                "Run Snakemake as a coordinator job in AWS Batch. "
                "The workflow will be submitted and executed entirely in the cloud. "
                "Your terminal can disconnect after submission."
            ),
            "env_var": False,
            "required": False,
        },
    )
    coordinator_queue: Optional[str] = field(
        default=None,
        metadata={
            "help": (
                "Job queue for the coordinator job. Defaults to the main job_queue."
            ),
            "env_var": True,
            "required": False,
        },
    )
    coordinator_job_definition: Optional[str] = field(
        default=None,
        metadata={
            "help": (
                "Job definition for the coordinator job. Should have Snakemake, "
                "boto3, and snakemake-storage-plugin-s3 installed. "
                "Defaults to the main job_definition."
            ),
            "env_var": True,
            "required": False,
        },
    )
    coordinator_job_name_prefix: Optional[str] = field(
        default=None,
        metadata={
            "help": (
                "Custom prefix for coordinator job names. "
                "Defaults to 'snakemake-coordinator'."
            ),
            "env_var": True,
            "required": False,
        },
    )
    coordinator_job_uuid: Optional[str] = field(
        default=None,
        metadata={
            "help": (
                "Custom UUID/identifier for coordinator job names. "
                "Defaults to an auto-generated UUID."
            ),
            "env_var": True,
            "required": False,
        },
    )
    task_timeout: Optional[int] = field(
        default=None,
        metadata={
            "help": (
                "Job timeout in seconds. Jobs exceeding this duration will be terminated. "
                "Minimum value is 60 seconds. Can be overridden per-rule via aws_batch_task_timeout resource."
            ),
            "env_var": True,
            "required": False,
        },
    )
    tags: Optional[str] = field(
        default=None,
        metadata={
            "help": (
                "Tags to apply to submitted jobs as comma-separated key=value pairs "
                "(e.g. 'project=genomics,run=exp1'). Applied to both regular and coordinator jobs."
            ),
            "env_var": True,
            "required": False,
        },
    )


common_settings = CommonSettings(
    non_local_exec=True,
    implies_no_shared_fs=True,
    job_deploy_sources=False,
    pass_default_storage_provider_args=True,
    pass_default_resources_args=True,
    pass_envvar_declarations_to_cmd=False,
    auto_deploy_default_storage_provider=False,
    init_seconds_before_status_checks=0,
)


# Environment variable to detect if we're running inside a coordinator job
COORDINATOR_CONTEXT_ENV_VAR = "SNAKEMAKE_AWS_BASIC_BATCH_COORDINATOR_CONTEXT"


class Executor(RemoteExecutor):
    def __post_init__(self):
        self.container_image = self.workflow.remote_execution_settings.container_image
        self.next_seconds_between_status_checks = 5

        self.settings = self.workflow.executor_settings
        self.logger.debug(f"ExecutorSettings: {pformat(self.settings, indent=2)}")

        try:
            self.batch_client = BatchClient(region_name=self.settings.region)
        except Exception as e:
            raise WorkflowError(f"Failed to initialize AWS Batch client: {e}") from e

        # Check if coordinator mode is enabled and we're not inside a coordinator job
        if self.settings.coordinator and not self._is_coordinator_context():
            self._coordinator_pending = True
        else:
            self._coordinator_pending = False

    def _parse_tags(self) -> dict:
        """Parse tags setting into a dict for submit_job().

        Format: "key1=value1,key2=value2"
        Returns empty dict if no tags configured.
        """
        if not self.settings.tags:
            return {}
        tags = {}
        for pair in self.settings.tags.split(","):
            pair = pair.strip()
            if "=" in pair:
                key, value = pair.split("=", 1)
                tags[key.strip()] = value.strip()
        return tags

    def _is_coordinator_context(self) -> bool:
        """Check if we're running inside a coordinator job."""
        return os.environ.get(COORDINATOR_CONTEXT_ENV_VAR) == "1"

    def _build_coordinator_command(self) -> str:
        """Build the coordinator command.

        The workflow is expected to be included in the container image.
        All original arguments are forwarded, including --snakefile.
        Relative snakefile paths work because the container's WORKDIR
        mirrors the source tree structure.
        The COORDINATOR_CONTEXT_ENV_VAR prevents recursion.
        """
        args = sys.argv[1:]
        return f"snakemake {shlex.join(args)}"

    def _get_coordinator_environment(self) -> list:
        """Build environment variables for coordinator job."""
        env = [
            {"name": COORDINATOR_CONTEXT_ENV_VAR, "value": "1"},
            {"name": "SNAKEMAKE_AWS_BASIC_BATCH_REGION", "value": self.settings.region},
            {
                "name": "SNAKEMAKE_AWS_BASIC_BATCH_JOB_QUEUE",
                "value": self.settings.job_queue,
            },
            {
                "name": "SNAKEMAKE_AWS_BASIC_BATCH_JOB_DEFINITION",
                "value": self.settings.job_definition,
            },
        ]

        return env

    def _submit_coordinator_job(self):
        """Submit a coordinator job that runs the entire Snakemake workflow.

        After successful submission, exits with code 0. The coordinator job
        will handle the actual workflow execution in AWS Batch.
        """
        job_uuid = self.settings.coordinator_job_uuid or str(uuid.uuid4())
        prefix = self.settings.coordinator_job_name_prefix or "snakemake-coordinator"
        job_name = f"{prefix}-{job_uuid}"

        coordinator_queue = self.settings.coordinator_queue or self.settings.job_queue
        coordinator_job_def = (
            self.settings.coordinator_job_definition or self.settings.job_definition
        )

        command = self._build_coordinator_command()
        self.logger.debug(f"Coordinator command: {command}")

        submit_kwargs = {
            "jobName": job_name,
            "jobQueue": coordinator_queue,
            "jobDefinition": coordinator_job_def,
            "containerOverrides": {
                "command": ["/bin/bash", "-c", command],
                "environment": self._get_coordinator_environment(),
            },
        }

        tags = self._parse_tags()
        if tags:
            submit_kwargs["tags"] = tags

        try:
            job_info = self.batch_client.submit_job(**submit_kwargs)
        except Exception as e:
            raise WorkflowError(f"Failed to submit coordinator job: {e}") from e

        job_id = job_info["jobId"]
        console_url = (
            f"https://console.aws.amazon.com/batch/home?"
            f"region={self.settings.region}#jobs/detail/{job_id}"
        )

        self.logger.info(
            f"Coordinator job submitted: {job_id}\n"
            f"Monitor at: {console_url}\n"
            f"You can now safely disconnect."
        )

        # Clean up this process's lock files before exiting.
        # os._exit() bypasses the finally block in persistence.lock(),
        # so we call unlock() manually. Unlike shutil.rmtree(), this only
        # removes lock files created by this process, not the entire directory.
        self.workflow.persistence.unlock()

        # Use os._exit(0) to terminate immediately without raising SystemExit.
        # sys.exit(0) raises SystemExit which Snakemake's scheduler catches
        # (alongside KeyboardInterrupt) and treats as a cancellation request.
        os._exit(0)

    def run_jobs(self, jobs: List[JobExecutorInterface]):
        """Override to submit coordinator job when sources are ready."""
        if self._coordinator_pending:
            self._coordinator_pending = False
            self._submit_coordinator_job()

        return super().run_jobs(jobs)

    def _get_job_resources(self, job: JobExecutorInterface) -> dict:
        """Extract AWS Batch resource overrides from Snakemake job resources.

        Supported resources:
        - aws_batch_vcpu: Number of vCPUs (default: 1)
        - aws_batch_mem_mb: Memory in MiB (default: 1024)
        - aws_batch_gpu: Number of GPUs (default: 0, only included when > 0)
        - aws_batch_job_queue: Job queue ARN/name (default: settings.job_queue)
        - aws_batch_job_definition: Job definition ARN/name (default: settings.job_definition)
        - aws_batch_job_name_prefix: Custom job name prefix (default: "snakejob")
        - aws_batch_scheduling_priority: Scheduling priority override (default: None)
        - aws_batch_job_uuid: Custom UUID/identifier for job names (default: auto-generated UUID)
        """
        return {
            "vcpu": max(1, int(job.resources.get("aws_batch_vcpu", 1))),
            "mem_mb": max(1, int(job.resources.get("aws_batch_mem_mb", 1024))),
            "gpu": int(job.resources.get("aws_batch_gpu", 0)),
            "job_queue": job.resources.get(
                "aws_batch_job_queue", self.settings.job_queue
            ),
            "job_definition": job.resources.get(
                "aws_batch_job_definition", self.settings.job_definition
            ),
            "task_timeout": job.resources.get(
                "aws_batch_task_timeout", self.settings.task_timeout
            ),
            "job_name_prefix": job.resources.get(
                "aws_batch_job_name_prefix", "snakejob"
            ),
            "scheduling_priority": job.resources.get(
                "aws_batch_scheduling_priority", None
            ),
            "job_uuid": job.resources.get("aws_batch_job_uuid", str(uuid.uuid4())),
        }

    def run_job(self, job: JobExecutorInterface):
        """Submit a job to AWS Batch using the pre-configured job definition."""
        # Extract per-rule resource overrides
        resources = self._get_job_resources(job)

        job_uuid = resources["job_uuid"]
        prefix = resources["job_name_prefix"]
        job_name = f"{prefix}-{job.name}-{job_uuid}"

        # Get the command to execute
        job_command = self.format_job_exec(job)

        # Build environment from envvars
        environment = [{"name": k, "value": v} for k, v in self.envvars().items()]

        self.logger.debug(
            f"Job resources: vcpu={resources['vcpu']}, mem={resources['mem_mb']}MB, "
            f"gpu={resources['gpu']}, timeout={resources.get('task_timeout')}s, "
            f"queue={resources['job_queue']}, definition={resources['job_definition']}"
        )

        resource_requirements = [
            {"type": "VCPU", "value": str(resources["vcpu"])},
            {"type": "MEMORY", "value": str(resources["mem_mb"])},
        ]

        if resources["gpu"] > 0:
            resource_requirements.append(
                {"type": "GPU", "value": str(resources["gpu"])}
            )

        submit_kwargs = {
            "jobName": job_name,
            "jobQueue": resources["job_queue"],
            "jobDefinition": resources["job_definition"],
            "containerOverrides": {
                "command": ["/bin/bash", "-c", job_command],
                "environment": environment,
                "resourceRequirements": resource_requirements,
            },
        }

        if resources.get("task_timeout"):
            submit_kwargs["timeout"] = {
                "attemptDurationSeconds": int(resources["task_timeout"])
            }

        if resources.get("scheduling_priority") is not None:
            submit_kwargs["schedulingPriorityOverride"] = int(
                resources["scheduling_priority"]
            )

        tags = self._parse_tags()
        if tags:
            submit_kwargs["tags"] = tags

        try:
            job_info = self.batch_client.submit_job(**submit_kwargs)

            self.logger.debug(
                f"AWS Batch job submitted: name={job_name}, id={job_info['jobId']}"
            )
        except Exception as e:
            raise WorkflowError(f"Failed to submit AWS Batch job: {e}") from e

        self.report_job_submission(
            SubmittedJobInfo(
                job=job,
                external_jobid=job_info["jobId"],
                aux={"job_name": job_name},
            )
        )

    async def check_active_jobs(
        self, active_jobs: List[SubmittedJobInfo]
    ) -> AsyncGenerator[SubmittedJobInfo, None]:
        """Check the status of active jobs."""
        self.logger.debug(f"Monitoring {len(active_jobs)} active Batch jobs")

        for job in active_jobs:
            async with self.status_rate_limiter:
                status_code, msg = self._get_job_status(job)

            if status_code is not None:
                if status_code == 0:
                    self.report_job_success(job)
                else:
                    message = f"AWS Batch job failed. Code: {status_code}, Msg: {msg}."
                    self.report_job_error(job, msg=message)
            else:
                yield job

    def _get_job_status(self, job: SubmittedJobInfo) -> tuple[int, Optional[str]]:
        """Poll for Batch job status and return exit code if complete."""
        try:
            response = self.batch_client.describe_jobs(jobs=[job.external_jobid])
            jobs = response.get("jobs", [])

            if not jobs:
                return None, f"No job found with ID {job.external_jobid}"

            job_info = jobs[0]
            job_status = job_info.get("status", "UNKNOWN")
            exit_code = job_info.get("container", {}).get("exitCode", None)

            if job_status == "SUCCEEDED":
                return 0, None
            elif job_status == "FAILED":
                reason = job_info.get("statusReason", "Unknown reason")
                return exit_code or 1, reason
            else:
                self.logger.debug(f"Job {job.external_jobid} status: {job_status}")
                return None, None
        except Exception as e:
            self.logger.error(f"Error getting job status: {e}")
            return None, str(e)

    def cancel_jobs(self, active_jobs: List[SubmittedJobInfo]):
        """Cancel all active jobs."""
        self.logger.info("Shutting down, cancelling active jobs...")
        for job in active_jobs:
            try:
                self.logger.debug(f"Terminating job {job.external_jobid}")
                self.batch_client.terminate_job(
                    jobId=job.external_jobid,
                    reason="Terminated by Snakemake",
                )
            except Exception as e:
                self.logger.warning(
                    f"Failed to terminate job {job.external_jobid}: {e}"
                )
