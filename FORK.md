# FORK.md — how this fork stays mergeable

`lovebuilt/n8n-autoscaling`, forked from `conor-is-my-name/n8n-autoscaling`.

**The whole strategy in one line:** customizations live in files upstream does not have, so a
3-way merge never has to reconcile them.

## The three layers

| Layer | Where customizations live | Conflict surface |
|---|---|---|
| **Dockerfiles** | `custom/config.json` → `custom/build.py` generates `Dockerfile.build`, `Dockerfile.runner.build`, `n8n-task-runners.build.json` | **none** — `Dockerfile` + `Dockerfile.runner` are byte-identical to upstream |
| **Compose** | `docker-compose.override.yml` (fork-only file) | **small** — only the residuals listed below |
| **Tooling** | `*.sh` at repo root, `custom/` | **none** — upstream has no such files |

`build.py` reads the upstream file straight out of git (`git show upstream/main:<file>`), applies
declarative injections from `config.json`, writes the `.build` artifacts, and **verifies** —
exiting 1 if anything present in your current setup is missing from the generated output. It never
edits an upstream file in place, which is why the Dockerfile conflict surface is exactly zero.

## Why the override file is safe again (2026-08-06)

It was NOT safe between ~June and 2026-08-06. The autoscaler scaled workers with a single explicit
`-f`, which makes Compose skip its automatic merge of `docker-compose.override.yml` — so anything
defined only in the override was silently absent from every autoscaler-created worker. We reported
this as [issue #28](https://github.com/conor-is-my-name/n8n-autoscaling/issues/28); Conor fixed it
in **2.1.2** (`6bbe366`), which resolves the ordered compose-file list from the autoscaler
container's own `com.docker.compose.project.config_files` label and passes each with its own `-f`.

**Verified live on this stack 2026-08-06**: a worker created by a real autoscaler scale event
carries `config_files=<base>,<override>` and all six host mounts.

> Historical note: the workaround before 2.1.2 was to duplicate worker config into the base
> compose file (HO-N8N-ENVGAP, 2026-08-01). That duplication has been **removed** — the override
> is the single source again.

## Residual base-file edits (the remaining conflict surface)

These genuinely cannot move to an override:

- **`ai-env-n8n-link`** external network — top-level definition + 4 service references
- **`x-n8n` anchor additions** — YAML anchors are file-local, so anchor-level environment
  additions can't be extended from another file
- **`cloudflared` service deleted** — an override can add or modify a service, never delete one
- **Autoscaler `./docker-compose.yml:/app/docker-compose.yml:ro`** — guards the legacy
  single-file fallback against the stale copy baked into the autoscaler image

If this list starts growing, see "Future option" below.

## Merging upstream

```bash
./upstream-sync.sh check    # read-only: what's new upstream
./upstream-sync.sh merge    # DRY RUN -- stages the merge, never commits
# inspect: git diff --cached <file>
./upstream-sync.sh done     # commit it
./upstream-sync.sh abort    # or back out entirely
```

`merge` is **dry-run-first by design** and will not commit on your behalf. It tags a rollback
point, then hard-aborts by itself if the merge would delete anything under `custom/`, any `*.sh`,
or `docker-compose.override.yml`.

### Two things that will lie to you

1. **The Upstream Monitor email.** n8n workflow `QPjdLz451cfHOize` (daily 11PM CT) compares
   GitHub's `origin/main` to upstream and has Groq analyze the diff against `custom/manifest.md`.
   Its AI only sees the new upstream commits — it cannot see merge mechanics. "SAFE TO MERGE" is a
   hint, not a verdict. Note it reads the manifest from **GitHub raw**, so a manifest that hasn't
   been pushed doesn't inform it, and it compares the pushed fork, not the VPS working copy.
2. **`git diff main upstream`.** A *tree* comparison, not a merge preview. Files the fork ADDED
   show as "deleted by upstream" even though a 3-way merge never touches them. On 2026-07-10 this
   produced a terrifying and completely false "would delete 1,535 lines" warning.

**Only a staged dry-run merge tells the truth.** That is what `merge` now does.

## After a merge

- `./update.sh` — full: backup → `build.py` → rebuild → recreate → health gate → API-key check
- `./quick-update.sh` — same without the backup and health gate
- Both now run `custom/build.py` first and include `n8n-autoscaler` in the rebuild set.

## Ground rules

- `/opt/n8n-autoscaling` is a **shared, root-owned production repo**: every git command needs
  `sudo -n`, and history moves **forward only** — no amend, rebase, reset-to-earlier, or
  force-push (`~/.claude/rules/git-history-safety.md`).
- Workers keep **`$env` BLOCKED**. Do not re-add `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`.
  Secrets → stored credentials; non-secret config → workflow literals; host-script values →
  `/home/dev/.env` (`~/.claude/rules/n8n-env-vars.md`).
- Never print `.env` contents. Use `get-secret` / `set-secret --target n8n-stack`.

## Future option (deliberately NOT built)

`custom/config.json` carries a **dead `compose_overrides` key** — nothing reads it. It stubs the
idea of extending `build.py` to generate `docker-compose.build.yml` from upstream + declarative
overlays, the same trick that took the Dockerfile conflict surface to zero.

**Not built, on purpose.** Compose layering already solves this natively now that 2.1.2 honors it,
and generation would cost: a YAML-aware merge (the existing injectors are anchor-based line
splicers, too fragile for YAML), plus repointing every script *and* the autoscaler at a generated
file. **Revisit only if** the residual list above grows enough that merges start conflicting again.

---

*Written 2026-08-06 alongside the 2.1.2 merge. Companion: `custom/manifest.md` (what the
customizations ARE); this file is how they SURVIVE.*
