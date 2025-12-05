# Example workflow image based on the snakemake-executor-plugin-aws-basic-batch base
FROM radusuciu/snakemake-executor-plugin-aws-basic-batch:latest

# Copy the example workflow
COPY --chown=snakemake:snakemake Snakefile /workflow/Snakefile

WORKDIR /workflow
