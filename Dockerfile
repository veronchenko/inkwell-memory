# Inkwell — Knowledge Base MCP Server
# Persistent knowledge base with hybrid SQLite FTS5 + semantic search
#
# Production image only — this is the sole stage, so a plain
# `docker build -t <tag> .` (no --target) always builds production.
# The test image lives in tests/Dockerfile and builds FROM this image.
#
# No venv: the container itself is already the isolation boundary, so
# packages install straight into the system interpreter (`uv pip install
# --system`). Dependencies still come from pyproject.toml/uv.lock (single
# source of truth) via `uv export`, which is exported *without* the project
# itself (--no-emit-project) so this layer only needs pyproject.toml/uv.lock,
# not the source tree — keeping the cache-across-code-edits property the
# previous requirements.txt-based layer had.

FROM ghcr.io/astral-sh/uv:python3.13-alpine

WORKDIR /app

# Non-root user, created up front so the model cache below can be written
# with correct ownership directly instead of via a later `chown -R`, which
# would force the overlay filesystem to duplicate the ~1GB cache layer.
RUN addgroup -S inkwell && adduser -S inkwell -G inkwell

# Install runtime dependencies only (no dev/test groups, no project itself
# — added later via --no-deps once the source is present).
ENV UV_LINK_MODE=copy
COPY src/pyproject.toml src/uv.lock ./
RUN uv export --locked --no-default-groups --no-emit-project --no-hashes -o /tmp/requirements.txt \
    && uv pip install --system --no-cache -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

# Pre-download the embedding model into the image so runtime and tests
# never need network access for it. Done before COPY src/ so editing app
# code doesn't invalidate this layer and force a re-download. Runs as
# inkwell so the cache lands with correct ownership from the start.
ENV HF_HOME=/app/.cache/huggingface
RUN mkdir -p "$HF_HOME" && chown -R inkwell:inkwell /app/.cache
USER inkwell
RUN python -c "from model2vec import StaticModel; StaticModel.from_pretrained('minishlab/potion-multilingual-128M')"
USER root

# Copy application
COPY src/ ./
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Add just the project itself (--no-deps: dependencies are already
# satisfied from the export above — reinstalling them here would double
# their size in this layer, the way a second unrestricted `uv sync` did).
# Editable so the `inkwell` console script (admin CLI) is on PATH, without
# moving the flat module layout server.py/config.py/... already rely on
# (schema.py resolves schema.json relative to its own file, not via package
# resources — an editable install keeps that path valid).
RUN uv pip install --system --no-cache --no-deps -e .

RUN mkdir -p /knowledge && chown inkwell:inkwell /knowledge
USER inkwell

# Default configuration (override via docker run -e or --arg)
ENV INKWELL_DATA_PATH=/knowledge
ENV INKWELL_TRANSPORT=stdio
ENV INKWELL_HOST=0.0.0.0
# INKWELL_PORT/INKWELL_DASHBOARD_PORT are starting ports: the first free port
# at or above them is used, so the actual bound port can differ.
ENV INKWELL_PORT=8192
ENV INKWELL_DASHBOARD_HOST=0.0.0.0
ENV INKWELL_DASHBOARD_PORT=8193
ENV INKWELL_EMBEDDING_MODEL=minishlab/potion-multilingual-128M
# Dashboard (API + frontend) runs as a second process alongside the MCP
# backend by default. Set to 0/false/no to run the backend only.
ENV INKWELL_ENABLE_DASHBOARD=1
# Multi-tenant (VPS, several teams) mode is off by default — single-tenant
# stdio/local usage is unaffected either way. Turning it on requires also
# setting INKWELL_TRANSPORT=streamable-http (or sse), INKWELL_PUBLIC_URL, and
# INKWELL_ADMIN_API_KEY via `docker run -e` — none have a safe default.
ENV INKWELL_MULTI_TENANT=0
ENV INKWELL_ADMIN_API_HOST=127.0.0.1
ENV INKWELL_ADMIN_API_PORT=8194

# Data volume
VOLUME /knowledge

EXPOSE 8192 8193

ENTRYPOINT ["docker-entrypoint.sh"]
CMD []
