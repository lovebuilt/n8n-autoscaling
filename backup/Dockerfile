# Stage 1: Builder - install rclone, pg_dump client, gpg
FROM alpine:3.21 AS builder

RUN apk add --no-cache \
    rclone \
    postgresql17-client \
    gnupg \
    tar \
    gzip

# Stage 2: Final image with Python runtime
FROM python:3.9-slim

WORKDIR /app

# Install runtime dependencies (pg_dump needs libpq, rclone/gpg are standalone binaries)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    libpq5 \
    gnupg \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy binaries from builder
COPY --from=builder /usr/bin/rclone /usr/bin/rclone
COPY --from=builder /usr/bin/pg_dump /usr/bin/pg_dump
COPY --from=builder /usr/lib/libpq* /usr/lib/
COPY --from=builder /usr/lib/libssl* /usr/lib/
COPY --from=builder /usr/lib/libcrypto* /usr/lib/
COPY --from=builder /usr/lib/libldap* /usr/lib/
COPY --from=builder /usr/lib/liblber* /usr/lib/
COPY --from=builder /usr/lib/libsasl* /usr/lib/

# Install Python dependencies
COPY backup/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Create backup working directory and empty default rclone config
RUN mkdir -p /backups /config/rclone && \
    touch /config/rclone/rclone.conf

# Copy application
COPY backup/backup.py .

CMD ["python", "-u", "backup.py"]
