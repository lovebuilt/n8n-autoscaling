#!/usr/bin/env python3
"""
custom/build.py — Generate final Dockerfiles from upstream + your customizations.

WHAT THIS DOES:
  1. Reads upstream's clean Dockerfiles (from git)
  2. Reads your package lists (from custom/config.json)
  3. Injects your packages into the right places
  4. Writes .build files that docker-compose.override.yml uses
  5. VERIFIES nothing from your current setup is missing

Upstream's files stay untouched → git merges never conflict.
Your additions live in config.json → easy to update.

SAFETY: If verification fails, the script exits with error and tells you what's missing.
"""
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

CUSTOM_DIR = Path(__file__).parent
ROOT_DIR = CUSTOM_DIR.parent
BACKUP_DIR = ROOT_DIR / '.build-backups'


def load_config():
    with open(CUSTOM_DIR / 'config.json') as f:
        return json.load(f)


def get_upstream_file(filename):
    """Get file from upstream/main. Falls back to current file if no upstream."""
    try:
        r = subprocess.run(
            ['git', 'show', f'upstream/main:{filename}'],
            capture_output=True, text=True, cwd=ROOT_DIR
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout, 'upstream'
    except Exception:
        pass
    p = ROOT_DIR / filename
    if p.exists():
        return p.read_text(), 'local'
    print(f"  FATAL: Cannot find {filename}")
    sys.exit(1)


def backup_current():
    """Backup current working Dockerfiles before generating new ones."""
    BACKUP_DIR.mkdir(exist_ok=True)
    ts = datetime.now().strftime('%Y%m%d-%H%M%S')
    backup = BACKUP_DIR / ts
    backup.mkdir()
    for f in ['Dockerfile', 'Dockerfile.runner', 'n8n-task-runners.json']:
        src = ROOT_DIR / f
        if src.exists():
            shutil.copy2(src, backup / f)
    # Keep only last 5 backups
    backups = sorted(BACKUP_DIR.iterdir())
    while len(backups) > 5:
        shutil.rmtree(backups.pop(0))
    return backup


def inject_apk(content, packages):
    """Add custom packages to the RUN apk add block."""
    if not packages:
        return content
    lines = content.split('\n')
    result = []
    in_apk = False
    for line in lines:
        if 'apk add' in line:
            in_apk = True
        if in_apk and not line.rstrip().endswith('\\'):
            result.append(line.rstrip() + ' \\')
            result.append('    # === YOUR CUSTOM PACKAGES (from custom/config.json) ===')
            for i, pkg in enumerate(packages):
                suffix = ' \\' if i < len(packages) - 1 else ''
                result.append(f'    {pkg}{suffix}')
            in_apk = False
            continue
        result.append(line)
    return '\n'.join(result)


def set_broad_lib_copy(content):
    """Replace selective /usr/lib/lib*.so* copies with one broad /usr/lib/ copy."""
    lines = content.split('\n')
    result = []
    inserted_broad = False
    for line in lines:
        if re.match(r'COPY --from=builder /usr/lib/lib\S+', line):
            if not inserted_broad:
                result.append('# Broad library copy (avoids missing transitive deps)')
                result.append('COPY --from=builder /usr/lib/ /usr/lib/')
                inserted_broad = True
            continue
        result.append(line)
    return '\n'.join(result)


def inject_copies(content, share_copies, bin_copies):
    """Add custom COPY --from=builder lines after existing ones."""
    if not share_copies and not bin_copies:
        return content
    lines = content.split('\n')
    last_copy_idx = max(
        (i for i, l in enumerate(lines) if 'COPY --from=builder' in l),
        default=-1
    )
    if last_copy_idx == -1:
        return content
    result = lines[:last_copy_idx + 1]
    result.append('# === YOUR CUSTOM COPIES (from custom/config.json) ===')
    for src in share_copies:
        result.append(f'COPY --from=builder {src} {src}')
    for b in bin_copies:
        result.append(f'COPY --from=builder {b} {b}')
    result.extend(lines[last_copy_idx + 1:])
    return '\n'.join(result)


def inject_npm(content, packages):
    """Add custom npm packages to the pnpm add block."""
    if not packages:
        return content
    lines = content.split('\n')
    result = []
    in_pnpm = False
    for line in lines:
        if 'pnpm add' in line:
            in_pnpm = True
        if in_pnpm and not line.rstrip().endswith('\\'):
            result.append(line.rstrip() + ' \\')
            result.append('    # NOTE: pdf-poppler excluded — calls process.exit(1), kills runner')
            result.append('    # === YOUR CUSTOM NPM PACKAGES ===')
            for i, pkg in enumerate(packages):
                suffix = ' \\' if i < len(packages) - 1 else ''
                result.append(f'    {pkg}{suffix}')
            in_pnpm = False
            continue
        result.append(line)
    return '\n'.join(result)


def inject_pip(content, packages):
    """Add custom pip packages to the uv pip install block."""
    if not packages:
        return content
    lines = content.split('\n')
    result = []
    in_pip = False
    for line in lines:
        if 'uv pip install' in line:
            in_pip = True
        if in_pip and not line.rstrip().endswith('\\'):
            result.append(line.rstrip() + ' \\')
            result.append('    # === YOUR CUSTOM PYTHON PACKAGES ===')
            for i, pkg in enumerate(packages):
                suffix = ' \\' if i < len(packages) - 1 else ''
                result.append(f'    {pkg}{suffix}')
            in_pip = False
            continue
        result.append(line)
    return '\n'.join(result)


def fix_runner_config_path(content):
    """Point COPY to .build.json instead of original."""
    return content.replace(
        'COPY n8n-task-runners.json /etc/n8n-task-runners.json',
        'COPY n8n-task-runners.build.json /etc/n8n-task-runners.json'
    )


def generate_task_runners(config):
    """Merge custom allowlist entries into upstream task-runners config."""
    content, source = get_upstream_file('n8n-task-runners.json')
    data = json.loads(content)
    runner_cfg = config['runner']
    js_adds = runner_cfg.get('js_allowlist_additions', [])
    py_adds = runner_cfg.get('py_allowlist_additions', [])

    for runner in data.get('task-runners', []):
        env = runner.get('env-overrides', {})
        if 'NODE_FUNCTION_ALLOW_EXTERNAL' in env and js_adds:
            current = [x for x in env['NODE_FUNCTION_ALLOW_EXTERNAL'].split(',') if x]
            for pkg in js_adds:
                if pkg not in current:
                    current.append(pkg)
            env['NODE_FUNCTION_ALLOW_EXTERNAL'] = ','.join(current)
        if 'N8N_RUNNERS_EXTERNAL_ALLOW' in env and py_adds:
            current = [x for x in env['N8N_RUNNERS_EXTERNAL_ALLOW'].split(',') if x]
            for pkg in py_adds:
                if pkg not in current:
                    current.append(pkg)
            env['N8N_RUNNERS_EXTERNAL_ALLOW'] = ','.join(current)

    return json.dumps(data, indent='\t') + '\n'


def verify(config):
    """
    SAFETY CHECK: Compare generated .build files against current working files.
    Ensures nothing from the current setup is lost.
    """
    print("  === SAFETY VERIFICATION ===")
    issues = []

    for label, current_name, built_name in [
        ('Dockerfile', 'Dockerfile', 'Dockerfile.build'),
        ('Dockerfile.runner', 'Dockerfile.runner', 'Dockerfile.runner.build'),
    ]:
        current_path = ROOT_DIR / current_name
        built_path = ROOT_DIR / built_name
        if not current_path.exists() or not built_path.exists():
            continue

        current = current_path.read_text()
        built = built_path.read_text()

        # Check apk packages
        cur_apk = set(re.findall(r'^\s+([\w][\w.-]*)\s*\\?\s*$', current, re.MULTILINE))
        blt_apk = set(re.findall(r'^\s+([\w][\w.-]*)\s*\\?\s*$', built, re.MULTILINE))
        # Filter to real package names (not comments, not flags)
        cur_apk = {p for p in cur_apk if not p.startswith('#') and len(p) > 1}
        blt_apk = {p for p in blt_apk if not p.startswith('#') and len(p) > 1}
        missing = cur_apk - blt_apk
        if missing:
            issues.append(f"  ✗ {label} MISSING packages: {missing}")
        else:
            print(f"    ✓ {label}: all packages present")

        # Check binary copies
        cur_bins = set(re.findall(r'COPY --from=builder (/usr/bin/\S+)', current))
        blt_bins = set(re.findall(r'COPY --from=builder (/usr/bin/\S+)', built))
        missing_bins = cur_bins - blt_bins
        if missing_bins:
            issues.append(f"  ✗ {label} MISSING binaries: {missing_bins}")
        else:
            print(f"    ✓ {label}: all binary copies present")

    # Check task runner allowlists
    tr_current_path = ROOT_DIR / 'n8n-task-runners.json'
    tr_built_path = ROOT_DIR / 'n8n-task-runners.build.json'
    if tr_current_path.exists() and tr_built_path.exists():
        cur_tr = json.loads(tr_current_path.read_text())
        blt_tr = json.loads(tr_built_path.read_text())
        for cur_r in cur_tr['task-runners']:
            rt = cur_r['runner-type']
            for blt_r in blt_tr['task-runners']:
                if blt_r['runner-type'] != rt:
                    continue
                for key in ['NODE_FUNCTION_ALLOW_EXTERNAL', 'N8N_RUNNERS_EXTERNAL_ALLOW']:
                    cur_val = cur_r.get('env-overrides', {}).get(key, '')
                    blt_val = blt_r.get('env-overrides', {}).get(key, '')
                    cur_set = set(x for x in cur_val.split(',') if x)
                    blt_set = set(x for x in blt_val.split(',') if x)
                    missing = cur_set - blt_set
                    if missing:
                        issues.append(f"  ✗ {rt} allowlist MISSING: {missing}")
                    else:
                        print(f"    ✓ {rt} allowlist: complete")

    if issues:
        print()
        print("  ⛔ VERIFICATION FAILED")
        for i in issues:
            print(i)
        print()
        print("  Generated files are MISSING items from your current setup.")
        print("  Update custom/config.json to include the missing items.")
        print("  Your current Dockerfiles are UNCHANGED and still working.")
        print(f"  Backup saved to: {BACKUP_DIR}")
        sys.exit(1)
    else:
        print()
        print("  ✅ ALL VERIFIED — generated files match or exceed your current setup.")


def main():
    config = load_config()
    main_cfg = config['main']
    runner_cfg = config['runner']

    print()
    print("=== custom/build.py — Generating build files ===")
    print()

    # Safety: backup current files first
    backup = backup_current()
    print(f"  Backed up current files to {backup}")
    print()

    # --- Dockerfile.build ---
    print("  Generating Dockerfile.build ...")
    df, src = get_upstream_file('Dockerfile')
    print(f"    Source: {src}")
    df = inject_apk(df, main_cfg['apk_packages'])
    if main_cfg.get('lib_strategy') == 'broad':
        df = set_broad_lib_copy(df)
    df = inject_copies(df, main_cfg['share_copies'], main_cfg['bin_copies'])
    (ROOT_DIR / 'Dockerfile.build').write_text(df)
    print("    ✓ Written")

    # --- Dockerfile.runner.build ---
    print("  Generating Dockerfile.runner.build ...")
    rf, src = get_upstream_file('Dockerfile.runner')
    print(f"    Source: {src}")
    rf = inject_apk(rf, runner_cfg['apk_packages'])
    rf = inject_copies(rf, runner_cfg['share_copies'], runner_cfg['bin_copies'])
    rf = inject_npm(rf, runner_cfg['npm_packages'])
    rf = inject_pip(rf, runner_cfg['pip_packages'])
    rf = fix_runner_config_path(rf)
    (ROOT_DIR / 'Dockerfile.runner.build').write_text(rf)
    print("    ✓ Written")

    # --- n8n-task-runners.build.json ---
    print("  Generating n8n-task-runners.build.json ...")
    tr = generate_task_runners(config)
    (ROOT_DIR / 'n8n-task-runners.build.json').write_text(tr)
    print("    ✓ Written")

    print()

    # --- Verify ---
    verify(config)

    print()
    print("  Generated files ready for: docker compose build")
    print()


if __name__ == '__main__':
    main()
