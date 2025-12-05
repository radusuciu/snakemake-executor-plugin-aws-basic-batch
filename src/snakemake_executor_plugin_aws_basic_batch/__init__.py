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
import shutil
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


common_settings = CommonSettings(
    non_local_exec=True,
    implies_no_shared_fs=True,
    # We require the workflow to be included in the container image
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

    def _is_coordinator_context(self) -> bool:
        """Check if we're running inside a coordinator job."""
        return os.environ.get(COORDINATOR_CONTEXT_ENV_VAR) == "1"

    def _build_coordinator_command(self) -> str:
        """Build the coordinator command.

        The workflow is expected to be included in the container image.
        We forward all original arguments - the COORDINATOR_CONTEXT_ENV_VAR
        prevents recursion even if --coordinator is passed again.
        """
        return f"snakemake {shlex.join(sys.argv[1:])}"

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
        job_uuid = str(uuid.uuid4())
        job_name = f"snakemake-coordinator-{job_uuid}"

        coordinator_queue = self.settings.coordinator_queue or self.settings.job_queue
        coordinator_job_def = (
            self.settings.coordinator_job_definition or self.settings.job_definition
        )

        command = self._build_coordinator_command()
        self.logger.debug(f"Coordinator command: {command}")

        try:
            job_info = self.batch_client.submit_job(
                jobName=job_name,
                jobQueue=coordinator_queue,
                jobDefinition=coordinator_job_def,
                containerOverrides={
                    "command": ["/bin/bash", "-c", command],
                    "environment": self._get_coordinator_environment(),
                },
            )
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

        # Clean up workflow lock before exiting - os._exit() bypasses normal cleanup
        lock_dir = self.workflow.persistence.path / "locks"
        if lock_dir.exists():
            shutil.rmtree(lock_dir)

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

    def run_job(self, job: JobExecutorInterface):
        """Submit a job to AWS Batch using the pre-configured job definition."""
        job_uuid = str(uuid.uuid4())
        job_name = f"snakejob-{job.name}-{job_uuid}"

        # Get the command to execute
        job_command = self.format_job_exec(job)

        # Build environment from envvars
        environment = [{"name": k, "value": v} for k, v in self.envvars().items()]

        try:
            job_info = self.batch_client.submit_job(
                jobName=job_name,
                jobQueue=self.settings.job_queue,
                jobDefinition=self.settings.job_definition,
                containerOverrides={
                    "command": ["/bin/bash", "-c", job_command],
                    "environment": environment,
                },
            )

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
