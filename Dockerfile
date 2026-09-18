# Golden-Image-Pipeline toolbox image.
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
# Runs the Flask web app (gunicorn) AND contains the full local build toolchain
# (AWS CLI v2, Packer, Ansible, git, ssh, jq) so the pipeline can be driven
# entirely from this container. Typed as multi-arch (amd64/aarch64).

FROM python:3.12-slim

ARG TARGETARCH

# --- build toolchain --------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc libffi-dev curl unzip git openssh-client jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 (arch-aware)
ARG AWS_CLI_VERSION=2.22.35
RUN case "$TARGETARCH" in \
      arm64|aarch64) ARCH=aarch64;; \
      amd64|x86_64) ARCH=x86_64;; \
      *) echo "Unsupported arch: $TARGETARCH"; exit 1;; \
    esac && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}-${AWS_CLI_VERSION}.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp/aws && /tmp/aws/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip

# HashiCorp Packer (arch-aware)
ARG PACKER_VERSION=1.10.0
RUN case "$TARGETARCH" in \
      arm64|aarch64) A=arm64;; \
      amd64|x86_64) A=amd64;; \
    esac && \
    curl -fsSL "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${A}.zip" -o /tmp/packer.zip && \
    unzip -q /tmp/packer.zip -d /usr/local/bin && rm /tmp/packer.zip

# Ansible + app deps
WORKDIR /app

COPY web/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt ansible

# --- application ------------------------------------------------------------
COPY web/ /app/web/
COPY config/ /app/config/
COPY NOTICE /app/NOTICE
COPY LICENSE /app/LICENSE
COPY VERSION /app/VERSION
COPY scripts/docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

WORKDIR /app/web

ENV DATABASE_PATH=/app/data/golden_image.db
ENV SECRET_KEY_FILE=/app/data/app.key
ENV FLASK_DEBUG=false
ENV PORT=8080

VOLUME /app/data

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD python -c "import os, ssl, urllib.request; \
scheme='https' if os.path.exists('/app/certs/tls.crt') else 'http'; \
ctx=ssl._create_unverified_context() if scheme=='https' else None; \
urllib.request.urlopen(f'{scheme}://127.0.0.1:{os.environ.get(\"PORT\",8080)}/api/health', context=ctx) or exit(0)" || exit 1

CMD ["/app/docker-entrypoint.sh"]