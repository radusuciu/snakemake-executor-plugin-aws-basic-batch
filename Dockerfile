# syntax=docker/dockerfile:1

# Minimal Snakemake executor image for AWS Batch
# Uses uv for fast, reproducible dependency installation

ARG PYTHON_VERSION=3.13

# =============================================================================
# Builder stage: install dependencies with uv
# =============================================================================
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

# Copy uv from the official image
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Set uv environment variables for reproducible builds
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

WORKDIR /app

# Install dependencies first (better layer caching)
# Only copy files needed for dependency resolution
COPY pyproject.toml uv.lock* ./

# Sync dependencies without installing the project itself
# This layer is cached unless pyproject.toml or uv.lock changes
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# Copy source code and install the project in non-editable mode
COPY src/ ./src/
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-editable --no-dev

# =============================================================================
# Runtime stage: minimal image with just the virtual environment
# =============================================================================
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

LABEL org.opencontainers.image.title="snakemake-executor-plugin-aws-basic-batch" \
      org.opencontainers.image.description="Minimal Snakemake image with AWS Batch executor plugin" \
      org.opencontainers.image.source="https://github.com/radusuciu/snakemake-executor-plugin-aws-basic-batch" \
      org.opencontainers.image.authors="Radu Suciu <radusuciu@gmail.com>"

# Create non-root user for security
RUN groupadd --gid 1000 snakemake && \
    useradd --uid 1000 --gid 1000 --create-home snakemake

# Copy the prepared virtual environment from builder
COPY --from=builder --chown=snakemake:snakemake /app/.venv /app/.venv

# Add virtual environment to PATH
ENV PATH="/app/.venv/bin:$PATH"

# Switch to non-root user
USER snakemake

WORKDIR /workflow

# Default command shows help
CMD ["snakemake", "--help"]
