# AGENTS.md

Single-purpose bash repo: Epson network scan → PDF → Paperless-ngx upload. No build system, tests, or CI; `shellcheck` is the only static check.

## Verify

```bash
shellcheck scan.sh     # passes as of this writing
nix develop            # optional dev shell: epsonscan2, webhook, shellcheck
```

`./scan.sh` needs a live scanner and a configured `.env` — don't run it as a smoke test for a code edit.

## scan.sh behavior that isn't obvious

- `.env` is `source`d with `set -a` from the script's own directory. Required: `SCANNER_IP`, `OUTPUT_DIR`, `TMP_SCAN_PATH`, `EPSONSCAN2`; `RESOLUTION=300` and `BACKGROUND_COLOR=3` are defaults.
- `PaperlessScan.SF2` is generated at the repo root from `SF2.template` by replacing exactly three tokens: `RESOLUTION_VAR`, `TMP_SCAN_PATH_VAR`, `BACKGROUND_COLOR_VAR`. Gitignored (`*.SF2`), deleted only on success — a failed run leaves it behind. Edit the template, never the generated file.
- The scanner always writes `<TMP_SCAN_PATH>/Scan.pdf` (template `FileNamePrefix = "Scan"`); a stale one is removed first, then moved to `<OUTPUT_DIR>/scan_<timestamp>.pdf`. Changing the output name/location in the template breaks the `mv`.
- `EPSONSCAN2` is a command string, not a path: only its first word is PATH-checked (`${EPSONSCAN2%% *}`), the rest is word-split. It must match how Epson Scan is installed on the target host (apt vs Flatpak).
- Upload runs only if both `PAPERLESS_URL` and `API_TOKEN` are set. POSTs to `${PAPERLESS_URL}/api/documents/post_document/` with `Authorization: Token …` and `Accept: application/json; version=9`. `curl` has no `-L`, so a redirect counts as failure; any non-2xx exits 1.

## Secrets, paths, sync

- Gitignored: `.env`, `scan-hooks.json`, `*.SF2`. Tracked templates: `.env.example`, `scan-hooks.example.json` (placeholder `WEBHOOK_TOKEN_PLACEHOLDER`).
- The local `scan-hooks.json` and `scan-webhook.service` still point at a third checkout path `/home/robert/Documents/RobsDocuments/git/PaperlessScan` — fix both when editing.
- The host clone at `/root/PaperlessScan` is unmodified from GitHub; create its `.env` manually (gitignored) rather than syncing a local one.

## Deployment host: `paperlessscan`

- Fresh Ubuntu 24.04 LXC (rebuilt 2026-11-20), root-only (`ssh root@paperlessscan`; no `robert` user). LAN `192.168.4.156`, Tailscale `100.97.230.109`. Keep the root disk at least ~6 GB — 2 GB fails Nix builds with ENOSPC.
- Nix 2.36 is installed multi-user with `nix-command` + `flakes`, and **`sandbox = false`** in `/etc/nix/nix.conf`. The sandbox must be off in this unprivileged LXC, otherwise builds fail with `/dev/null: Permission denied`.
- Host `.env` uses `SCANNER_IP=192.168.4.152`, `EPSONSCAN2=epsonscan2`, `TMP_SCAN_PATH=/tmp/PaperlessScan`, `OUTPUT_DIR=/root/Documents/scans`. The first `nix develop` builds the non-free `epsonscan2` variant (not in the binary cache) and takes several minutes.
- Scanning is verified via Nix: `nix develop --command epsonscan2 --set-ip 192.168.4.152`, then `nix develop --command ./scan.sh`. On 2026-11-20 this produced a PDF in `/root/Documents/scans`, upload returned HTTP 200, and Paperless created document id 22. `--set-ip` is required even though `epsonscan2 --list` may still report `Device is not found...`.
- Scanner is `192.168.4.152` (old `192.168.4.34` is stale; Bonjour `EPSON099C8A.local`, model ES025A / WF-2930). Discover with `avahi-browse -art | grep -i epson` + `avahi-resolve -4 -n <name>.local`.
- Paperless-ngx is on a different host `paperless` (Debian 13, `192.168.4.82:8000`), reached at `https://paperless.dusky-paradise.ts.net`; the deployed token works.
- Webhook is not set up on the fresh host yet: no `scan-webhook.service`, nothing listening on port 9000. Scanning is headless CLI.
