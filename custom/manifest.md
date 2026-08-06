# Custom Fork Manifest

> **What is this?** A human+AI readable description of every customization
> in this fork. When upstream changes, AI reads this to decide what's safe
> to adopt and what conflicts with your setup.
>
> **When to update:** Whenever you add/remove packages or change configuration.
> Tell Claude "I added X to my setup" and it will update this file + config.json.

**Last verified**: 2026-08-06 (against custom/config.json + live compose)

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
- **Packages**: `ca-certificates`, `tzdata`, `python3`, `py3-pip`, `openssl`
- **Binaries**: python3, pip3, openssl
- **Why**: HTTPS reliability and timezone support for Execute Command nodes; `python3`/`py3-pip`
  back the system-pip install below; `openssl` is used by Execute Command scripts

### Media Download (yt-dlp — NIGHTLY channel, not the apk build)
- **Packages**: `yt-dlp` (apk) — then **overwritten** by a system-pip install of
  `yt-dlp[default]` (nightly, `--pre`) + `curl_cffi`, via `pip_globals_pre` in `config.json`
- **Binary**: `/usr/bin/yt-dlp` (the pip script replaces the apk one)
- **Why**: the apk build is stale (2026.03.17) and the latest STABLE (2026.07.04) has Vimeo
  extractor rot (OAuth 401). Nightly 2026.07.23+ fixes it and keeps YouTube byte-identical.
  Prebuilt musllinux wheels, so no build toolchain is needed.
- **Kept fresh between rebuilds** by `custom/ytdlp-refresh.sh` (host cron, parity-guarded)
- **Origin**: HO-TRANSCRIBE-PROCESSOR 2026-07-24

### REMOVED: in-container AI CLIs (npm globals)
- **Status**: deliberately **not installed** — `npm_globals` was dropped from `config.json`
  on 2026-07-20 specifically to stop `build.py` re-adding them
- **Why**: E3 2026-06-27 — the `ai-env` bridge owns AI calls now. The containers reach the
  host CLIs through the `./config/{gemini,claude,codex}` mounts + `ai-env-n8n-link` network
  instead of bundling `claude`/`gemini`/`codex` into the image
- **Do not re-add** without revisiting that decision

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

> **Layering contract (2026-08-06).** Customizations belong in `docker-compose.override.yml`,
> which upstream does not have and therefore never conflicts. Since upstream **2.1.2** (our
> issue #28) the autoscaler passes EVERY compose file to its scale commands, so override
> content reaches autoscaler-created workers too. See `FORK.md`.

### In `docker-compose.override.yml` (fork-only — zero conflict surface)
- `build.dockerfile: Dockerfile.build` / `Dockerfile.runner.build` — points Docker at the
  generated files produced by `custom/build.py`
- `env_file: .env` on n8n, webhook and worker
- Host mounts on the worker (and main): `/backups:/backups:ro`, `/home/dev/lab:/home/dev/lab`,
  `/home/dev/.env:/home/dev/.env:ro`, and `./config/{gemini,claude,codex}` → `/root/.{gemini,claude,codex}`
  (the AI CLIs read their config from these)

### Residual edits that MUST stay in the base `docker-compose.yml`
These cannot live in an override, and are the fork's remaining conflict surface:
- **`ai-env-n8n-link`** external network — top-level definition + references on 4 services
- **`x-n8n` anchor additions** — YAML anchors are file-local, so anchor-level environment
  additions cannot be extended from another file: `NODES_EXCLUDE`,
  `N8N_RESTRICT_FILE_ACCESS_TO`, `NODE_FUNCTION_ALLOW_BUILTIN`,
  `N8N_BINARY_DATA_DATABASE_MAX_FILE_SIZE`, `EXECUTIONS_DATA_PRUNE`, `EXECUTIONS_DATA_MAX_AGE`
- **`cloudflared` service deleted** — a Compose override can add or modify a service, never
  delete one (a `profiles:` tag could neutralize it instead if base parity is ever wanted)
- **Autoscaler `./docker-compose.yml:/app/docker-compose.yml:ro`** — guards the LEGACY
  single-file fallback against the stale copy baked into the autoscaler image

### `$env` posture (deliberate — do not "fix")
Workers keep `$env` **BLOCKED**. `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` must NOT be re-added to
the worker. Secrets belong in stored credentials, non-secret config in workflow literals, and
host-script values in `/home/dev/.env`. See `~/.claude/rules/n8n-env-vars.md`.

### Shell Scripts (additions, not modifications)
These are YOUR scripts, not in upstream. They never conflict:
- `sync.sh` — push/pull to GitHub (origin/fork remote only)
- `update.sh` — full update (backup + build.py + rebuild + restart + health gate)
- `quick-update.sh` — fast update (build.py + rebuild + restart)
- `restart-all.sh` — full stack restart
- `backup.sh` — Postgres core dump (also runs daily 08:00 via cron)
- `health-check.sh` — color-coded container status table
- `upstream-sync.sh` — **dry-run-first** upstream merge (never auto-commits; see FORK.md)
- `post-update-hook.sh` — fires the TypeVersion Health Check workflow
- `restore-drill.sh` — weekly restore drill (Mon 09:00 cron)
- `check-api-keys.sh` — validates stored n8n API keys after a version bump
- `custom/ytdlp-refresh.sh` — host cron, keeps the yt-dlp nightly fresh between rebuilds

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
