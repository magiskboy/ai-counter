FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/bin:/opt/ai-counter/.venv/bin:${PATH}"

# Container runtime user (match host sandbox ownership: chown -R 1000:1000 $SANDBOX)
ARG COUNTER_UID=1000
ARG COUNTER_GID=1000

# SpecStory CLI release tag (https://github.com/specstoryai/getspecstory/releases)
ARG SPECSTORY_VERSION=v1.12.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    cron \
    git \
    gosu \
    nodejs \
    npm \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

# z8l — vendored in repo (see bin/z8l, scripts/vendor-z8l.sh to refresh)
COPY bin/z8l /usr/local/bin/z8l
RUN chmod 755 /usr/local/bin/z8l && z8l version || z8l --version || true

COPY docker/install-tools.sh /tmp/install-tools.sh
RUN chmod +x /tmp/install-tools.sh \
    && HOME=/root SPECSTORY_VERSION="${SPECSTORY_VERSION}" /tmp/install-tools.sh \
    && rm -f /tmp/install-tools.sh

# uv + Python 3.12 — install interpreters under /opt (readable by user `counter`)
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python
RUN HOME=/root curl -LsSf https://astral.sh/uv/install.sh | sh \
    && install -m 755 /root/.local/bin/uv /usr/local/bin/uv \
    && install -m 755 /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv python install 3.12 \
    && chmod -R a+rX /opt/uv-python

WORKDIR /opt/ai-counter

COPY pyproject.toml README.md ./
COPY src ./src
COPY prompts ./prompts
COPY docker ./docker

RUN chmod 755 /opt/ai-counter/docker/*.sh \
    && uv venv /opt/ai-counter/.venv --python 3.12 \
    && uv pip install --python /opt/ai-counter/.venv/bin/python -e .

ENV Z8L_BINARY=/usr/local/bin/z8l
ENV SPECSTORY_BINARY=/usr/local/bin/specstory
ENV CURSOR_AGENT_BINARY=/usr/local/bin/cursor-agent

# Linux user `counter` — sandbox mounts at /home/counter (its HOME)
# Ubuntu base may ship `ubuntu` at uid 1000; remove so `counter` can use that uid.
RUN set -eux; \
    if id ubuntu >/dev/null 2>&1 && [ "$(id -u ubuntu)" = "${COUNTER_UID}" ]; then userdel -r ubuntu; fi; \
    if ! getent group counter >/dev/null 2>&1; then \
      if getent group "${COUNTER_GID}" >/dev/null 2>&1; then \
        groupadd -o -g "${COUNTER_GID}" counter; \
      else \
        groupadd -g "${COUNTER_GID}" counter; \
      fi; \
    fi; \
    if ! id counter >/dev/null 2>&1; then \
      useradd -m -u "${COUNTER_UID}" -g counter -s /bin/bash counter; \
    fi; \
    chown -R counter:counter /opt/ai-counter /home/counter

ENV HOME=/home/counter
ENV USER=counter

VOLUME ["/home/counter"]

RUN chmod +x /opt/ai-counter/docker/entrypoint.sh

# cron daemon needs root; jobs and exec should use user `counter`
USER root

ENTRYPOINT ["/opt/ai-counter/docker/entrypoint.sh"]
