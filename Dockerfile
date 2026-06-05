# =====================================================================
# Dockerfile — event segmentation pipeline
#
# Base: rocker/r-ver pinned to your dev R version (4.5.1).
# Installs R packages from renv.lock and Python deps from requirements.txt,
# then runs the full pipeline via scripts/run_pipeline.sh.
#
# Build:  docker build -t eventseg-pipeline .
# Run:    docker run --rm eventseg-pipeline
# =====================================================================

FROM rocker/r-ver:4.5.1

# --- System libraries ---
# python3 + venv for the toy data generator; build-essential and a few
# common -dev libs cover what CRAN source packages typically need to compile.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        build-essential \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
	zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /pipeline

# --- R packages via renv (layer-cached: only re-runs if renv.lock changes) ---
# Copy ONLY the lockfile first so Docker caches the (slow) package install
# layer and doesn't redo it every time your scripts change.
COPY renv.lock renv.lock
RUN R -e "install.packages('renv', repos='https://cloud.r-project.org')" \
    && R -e "renv::restore(lockfile='renv.lock', prompt=FALSE)"

# --- Python packages (also cached on requirements.txt alone) ---
COPY requirements.txt requirements.txt
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt
ENV PATH="/opt/venv/bin:${PATH}"

# --- Now copy the rest of the repo ---
COPY . .

# The runner calls `python3` and `Rscript`; the venv is on PATH so `python3`
# resolves to the venv interpreter that has the deps.
RUN chmod +x scripts/run_pipeline.sh

ENTRYPOINT ["bash", "scripts/run_pipeline.sh"]
