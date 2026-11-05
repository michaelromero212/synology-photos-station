# The FrameStation analyzer: what the NAS sees in photos and videos.
#
# Build context is the REPOSITORY ROOT, as for the server, because the self-test
# reads a fixture from Scripts/fixtures:
#
#   docker build -f Analyzer/Dockerfile .
#
# linux/amd64, for the DS920+'s Celeron J4125. That CPU has no AVX, so check
# a change of package versions on it before shipping one (NAS-ANALYSIS.md §8).
# Runs with no network at all; see docker-compose.yml and NAS-ANALYSIS.md.

ARG PYTHON_VERSION=3.12.16

# ==============================================================================
# Models: downloaded at pinned commits and checked by SHA-256, or the build stops
# ==============================================================================
FROM python:${PYTHON_VERSION}-slim-bookworm AS models
COPY Analyzer/models.json Analyzer/fetch_models.py /build/
RUN python /build/fetch_models.py /build/models.json /models

# ==============================================================================
# Run
# ==============================================================================
FROM python:${PYTHON_VERSION}-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Every package pinned and checked by hash, and nothing pip would pull in on
# its own: the lock is the whole closure, so `--no-deps` loses nothing.
COPY Analyzer/requirements.lock /tmp/requirements.lock
RUN pip install --no-deps --require-hashes --only-binary=:all: -r /tmp/requirements.lock \
    && rm /tmp/requirements.lock

WORKDIR /opt/analyzer
COPY --from=models /models ./models
COPY Analyzer/models.json ./models.json
COPY Analyzer/LICENSES ./LICENSES
COPY Analyzer/analyzer ./analyzer
COPY Scripts/fixtures/hdr-gain-map.heic ./fixtures/hdr-gain-map.heic

# Fail the build rather than ship an image that can't do its job: models,
# HEIC with a gain map, rotation, video, determinism, path rules. CI runs it
# again under --network none.
RUN SELFTEST_REQUIRE_FIXTURE=1 python -m analyzer.selftest

# The socket's directory, owned by the unprivileged user so the image also
# runs without root. A fresh volume mounted here takes this ownership.
RUN useradd --system --no-create-home --uid 10001 --user-group analyzer \
    && mkdir -p /run/framestation-analyzer \
    && chown analyzer:analyzer /run/framestation-analyzer

ENV ANALYZER_MODELS=/opt/analyzer/models \
    ANALYZER_MANIFEST=/opt/analyzer/models.json \
    ANALYZER_SOCKET=/run/framestation-analyzer/analyzer.sock \
    ANALYZER_THREADS=2

# The commit this image was built from. Declared last so a new commit only
# changes this one tiny layer.
ARG FRAMESTATION_REVISION=unknown
ENV FRAMESTATION_REVISION=${FRAMESTATION_REVISION}

# Unprivileged by default. docker-compose.yml runs it as root with every
# capability dropped except reading, because DSM's homes are private to each
# person. Lowest CPU priority: the app, thumbnails and the stream ladder come
# first.
USER analyzer:analyzer
ENTRYPOINT ["nice", "-n", "19", "python", "-m", "analyzer.server"]
