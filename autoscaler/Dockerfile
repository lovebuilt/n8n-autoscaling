# Use an official Python runtime as a parent image
FROM python:3.12-slim as builder

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    jq \
    docker.io \
    docker-cli \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set the working directory in the container
WORKDIR /app

# Install Docker Compose v2 (multi-architecture support)
RUN mkdir -p ~/.docker/cli-plugins/ && \
    ARCH=$(dpkg --print-architecture) && \
    case ${ARCH} in \
        amd64) COMPOSE_ARCH='x86_64' ;; \
        arm64) COMPOSE_ARCH='aarch64' ;; \
        armhf) COMPOSE_ARCH='armv7' ;; \
        *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}" -o ~/.docker/cli-plugins/docker-compose && \
    chmod +x ~/.docker/cli-plugins/docker-compose

# Copy requirements first to leverage Docker cache
COPY autoscaler/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Final stage
FROM python:3.12-slim
WORKDIR /app

# Install Docker CLI and dependencies in the final stage
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y docker-ce-cli && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy from builder
COPY --from=builder /root/.docker/cli-plugins/ /usr/local/lib/docker/cli-plugins/
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages

# Ensure docker compose plugin is in PATH
ENV PATH="/usr/local/lib/docker/cli-plugins:${PATH}"

# Copy application files
COPY autoscaler/autoscaler.py .
COPY docker-compose.yml .
COPY Dockerfile .

# Specify the command to run on container start
CMD ["python", "-u", "autoscaler.py"]
