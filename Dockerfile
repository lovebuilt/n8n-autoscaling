# Multi-stage build to add tools to n8n image
# This works around apk being stripped from the official image
#
# These tools are for EXECUTE COMMAND nodes (raw shell commands).
# Code nodes (JS/Python) run in the task runner — see Dockerfile.runner.

# Stage 1: Build dependencies in Alpine
FROM alpine:3.23 AS builder

RUN apk add --no-cache \
    ffmpeg \
    git \
    openssh-client \
    graphicsmagick \
    imagemagick \
    jq \
    curl \
    ca-certificates \
    tzdata \
    # PDF processing (CLI tools for Execute Command nodes)
    poppler-utils \
    poppler-data \
    ghostscript \
    # OCR
    tesseract-ocr \
    tesseract-ocr-data-eng \
    # Fonts for proper PDF/image text rendering
    font-noto-cjk \
    font-dejavu \
    font-liberation

# Stage 2: Copy to n8n image
FROM n8nio/n8n:latest

USER root

# Copy all libraries from builder (avoids missing transitive dependencies)
# Selective copies like /usr/lib/libav*.so* miss deps — broad copy merges safely
COPY --from=builder /usr/lib/ /usr/lib/
COPY --from=builder /usr/share/fonts/ /usr/share/fonts/
COPY --from=builder /usr/share/ghostscript/ /usr/share/ghostscript/
COPY --from=builder /usr/share/tessdata/ /usr/share/tessdata/

# Copy binaries from builder
COPY --from=builder /usr/bin/ffmpeg /usr/bin/ffmpeg
COPY --from=builder /usr/bin/ffprobe /usr/bin/ffprobe
COPY --from=builder /usr/bin/git /usr/bin/git
COPY --from=builder /usr/bin/gm /usr/bin/gm
COPY --from=builder /usr/bin/jq /usr/bin/jq
COPY --from=builder /usr/bin/curl /usr/bin/curl
# ImageMagick
COPY --from=builder /usr/bin/magick /usr/bin/magick
COPY --from=builder /usr/bin/convert /usr/bin/convert
COPY --from=builder /usr/bin/identify /usr/bin/identify
COPY --from=builder /usr/bin/mogrify /usr/bin/mogrify
COPY --from=builder /usr/bin/composite /usr/bin/composite
# Poppler CLI tools
COPY --from=builder /usr/bin/pdftoppm /usr/bin/pdftoppm
COPY --from=builder /usr/bin/pdftotext /usr/bin/pdftotext
COPY --from=builder /usr/bin/pdfinfo /usr/bin/pdfinfo
COPY --from=builder /usr/bin/pdfimages /usr/bin/pdfimages
COPY --from=builder /usr/bin/pdfseparate /usr/bin/pdfseparate
COPY --from=builder /usr/bin/pdfunite /usr/bin/pdfunite
# Ghostscript
COPY --from=builder /usr/bin/gs /usr/bin/gs
# Tesseract OCR
COPY --from=builder /usr/bin/tesseract /usr/bin/tesseract

# Expose task broker port for external runners (n8n 2.0)
EXPOSE 5679

USER node
