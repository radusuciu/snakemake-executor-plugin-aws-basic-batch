# syntax=docker/dockerfile:1

# Example workflow image using multi-stage build with uv
# This serves as a template for building your own workflow images

ARG PYTHON_VERSION=3.13
ARG COORDINATOR_IMAGE=ghcr.io/radusuciu/snakemake-executor-plugin-aws-basic-batch:latest

# =============================================================================
# Builder stage: install dependencies with uv
# =============================================================================
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

WORKDIR /app

# Copy dependency files first (better layer caching)
COPY pyproject.toml uv.lock ./

# Sync dependencies
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# =============================================================================
# Runtime stage: minimal image with workflow
# =============================================================================
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

# Create non-root user
RUN groupadd --gid 1000 snakemake && \
    useradd --uid 1000 --gid 1000 --create-home snakemake

# Copy virtual environment from builder
COPY --from=builder --chown=snakemake:snakemake /app/.venv /app/.venv

ENV PATH="/app/.venv/bin:$PATH"

USER snakemake
WORKDIR /workflow

# Copy workflow files
COPY --chown=snakemake:snakemake Snakefile ./

CMD ["snakemake", "--help"]

# =============================================================================
# Coordinator stage: base plugin image with workflow files
# =============================================================================
FROM ${COORDINATOR_IMAGE} AS coordinator

# Copy workflow files
COPY --chown=snakemake:snakemake Snakefile ./
