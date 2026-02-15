# Custom Fork Manifest

> **What is this?** A human+AI readable description of every customization
> in this fork. When upstream changes, AI reads this to decide what's safe
> to adopt and what conflicts with your setup.
>
> **When to update:** Whenever you add/remove packages or change configuration.
> Tell Claude "I added X to my setup" and it will update this file + config.json.

## Owner Setup

- **Timezone**: America/Chicago
- **Domain**: configured via Cloudflare Tunnel (not in repo — secrets)
- **Container architecture**: Main (Execute Command) + Runner (Code nodes)

## Main Container (Dockerfile) Customizations

### PDF Processing
- **Packages**: `poppler-utils`, `poppler-data`, `ghostscript`
- **Binaries**: pdftoppm, pdftotext, pdfinfo, pdfimages, pdfseparate, pdfunite, gs
- **Why**: Execute Command nodes convert PDFs to images, extract text, merge/split PDFs
- **Used by**: KDP keyword research workflows, document processing

### Image Processing
- **Packages**: `imagemagick` (upstream only has graphicsmagick)
- **Binaries**: magick, convert, identify, mogrify, composite
- **Why**: Full ImageMagick for advanced image manipulation (resize, watermark, format conversion)
- **Note**: GraphicsMagick (from upstream) is kept too — they serve different use cases

### OCR (Optical Character Recognition)
- **Packages**: `tesseract-ocr`, `tesseract-ocr-data-eng`
- **Binaries**: tesseract
- **Why**: Extract text from scanned documents and images

### Fonts
- **Packages**: `font-noto-cjk`, `font-dejavu`, `font-liberation`
- **Why**: PDF rendering and image text need fonts. Without them, text appears as boxes.
- **font-noto-cjk**: Asian language support
- **font-dejavu**: Western language fallback
- **font-liberation**: Microsoft font alternatives (Arial → Liberation Sans, etc.)

### System Utilities
- **Packages**: `ca-certificates`, `tzdata`
- **Why**: HTTPS reliability and timezone support for Execute Command nodes

### Library Copy Strategy
- **Strategy**: Broad `/usr/lib/` copy (instead of upstream's selective `libav*.so*` pattern)
- **Why**: With 11+ packages, tracking individual shared library dependencies is impractical.
  Broad copy merges safely (doesn't overwrite existing files) and guarantees no missing transitive deps.
- **Trade-off**: Slightly larger image (~50MB more), but zero runtime "library not found" errors.

## Runner Container (Dockerfile.runner) Customizations

### Same as Main (subset)
- PDF Processing: poppler-utils, poppler-data, ghostscript (for Python pdf2image)
- OCR: tesseract-ocr, tesseract-ocr-data-eng (for Python/JS OCR workflows)
- Fonts: font-noto-cjk, font-dejavu, font-liberation

### JavaScript Packages (npm)
- **`sharp`**: High-performance image processing (resize, crop, format conversion)
- **Why**: Much faster than ImageMagick for batch image operations in Code nodes

### Python Packages (pip)
- **`pdf2image`**: Convert PDF pages to PIL images (requires poppler-utils)
- **`PyPDF2`**: Extract text, merge/split PDFs programmatically

### EXCLUDED Packages
- **`pdf-poppler` (npm)**: NEVER install. Calls `process.exit(1)` on Linux which
  kills the entire JS task runner process. Use native `poppler-utils` CLI via
  `subprocess` in Python or `child_process` workarounds instead.

## Task Runner Config (n8n-task-runners.json)

### JS Allowlist Additions
- `sharp` (matches npm install above)

### Python Allowlist Additions
- `pdf2image`, `PyPDF2` (matches pip install above)

## Docker Compose Customizations

### Extra Volumes
- `/backups:/backups:ro` on n8n and worker services — for backup access from workflows

### Shell Scripts (additions, not modifications)
These are YOUR scripts, not in upstream. They never conflict:
- `sync.sh` — push/pull to GitHub
- `update.sh` — full update (backup + pull + rebuild + restart)
- `quick-update.sh` — fast update (pull + rebuild + restart)
- `restart-all.sh` — full stack restart
- `backup.sh` — manual backup (also runs daily via cron)
- `health-check.sh` — color-coded container status table
- `upstream-sync.sh` — merge upstream changes safely
- `post-update-hook.sh` — runs after n8n updates

## What NOT to Override from Upstream

These upstream features are GOOD and should be adopted when merging:
- Redis password authentication (security improvement)
- Redis 8 upgrade (performance)
- Centralized log rotation (prevents disk fill)
- Port binding defaults to 127.0.0.1 (security)
- Execution data pruning env vars (DB management)
- N8N_MIGRATE_FS_STORAGE_PATH=true (upgrade support)
- Removal of n8n-task-runner service (saves RAM, redundant with worker offloading)
- .dockerignore (build optimization)
- Faster health check intervals
