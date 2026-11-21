# AGENTS.md

Single-purpose bash repo: Epson network scan → PDF → Paperless-ngx upload. No build system, tests, or CI; `shellcheck` is the only static check.

## Verify

```bash
shellcheck scan.sh     # passes as of this writing
nix develop            # optional dev shell: epsonscan2, avahi, webhook, shellcheck
```

`./scan.sh` needs a live scanner and a configured `.env` — don't run it as a smoke test for a code edit.

## scan.sh behavior that isn't obvious

- `.env` is `source`d with `set -a` from the script's own directory. Required: `SCANNER_MODEL`, `OUTPUT_DIR`, `TMP_SCAN_PATH`, `EPSONSCAN2`; `SCANNER_MAC` is optional, and `RESOLUTION=300` / `BACKGROUND_COLOR=3` are defaults.
- The scanner IP is discovered at runtime: `discover_scanner` parses `avahi-browse -r -p -t _scanner._tcp`, matching `SCANNER_MODEL` against the mDNS name/TXT or the driver `ModelID`, and `SCANNER_MAC` against the last 12 hex digits of the advertised UUID. No fixed IP is stored. Zero or multiple matches abort with the discovered-device list; `avahi-browse`/`avahi-daemon` must be available.
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
- Host `.env` uses `SCANNER_MODEL=WF-2930`, `EPSONSCAN2=epsonscan2`, `TMP_SCAN_PATH=/tmp/PaperlessScan`, `OUTPUT_DIR=/root/Documents/scans`; `SCANNER_MAC` is present but commented out. `avahi-daemon` and `avahi-utils` are installed and enabled. The first `nix develop` builds the non-free `epsonscan2` variant (not in the binary cache) and takes several minutes.
- Scanning is verified via Nix with no fixed IP config: `nix develop --command ./scan.sh` discovers the scanner and scans. On 2026-11-21 this produced `/root/Documents/scans/scan_2026-11-21_09-06-49.pdf`, upload HTTP 200, Paperless document id 26; the driver-ModelID (`ES025A`) + MAC path produced id 27.
- Scanner: Epson WF-2930 Series (driver ModelID `ES025A`), Bonjour `EPSON099C8A.local`, MAC `f8:25:51:09:9c:8a`. Its current IP (`192.168.4.152` at last check) is discovered dynamically; don't hardcode it in `.env`. Inspect with `avahi-browse -art | grep -i epson`.
- Paperless-ngx is on a different host `paperless` (Debian 13, `192.168.4.82:8000`), reached at `https://paperless.dusky-paradise.ts.net`; the deployed token works.
- Webhook is installed as the enabled system unit `/etc/systemd/system/scan-webhook.service`, bound to the Tailscale IP `100.97.230.109:9000` (after `tailscaled.service`). Hook config: `/root/PaperlessScan/scan-hooks.json` (mode 600, holds the URL token); it calls `/usr/local/bin/paperlessscan-scan`, which runs `nix develop --command ./scan.sh`. Read the token with `jq -r '.[0]["trigger-rule"].match.value' /root/PaperlessScan/scan-hooks.json` (bracket notation — `trigger-rule` is not a valid bare jq key). Trigger with `curl "http://100.97.230.109:9000/hooks/scan?token=<token>"` — verified 2026-11-20, produced Paperless document id 23.
- Webhook gotcha: an invalid token still returns HTTP 200 with body `Hook rules were not satisfied.` — validate the body, not the status code. The hook responds immediately and runs the scan asynchronously (~40 s).
- `/usr/local/bin/paperlessscan-scan` takes a non-blocking `flock` on `/run/paperlessscan-scan.lock`; overlapping triggers exit 0 with `scan already in progress; trigger ignored`, so only one scan runs at a time. Verified by firing two requests: both returned 200, one PDF, Paperless document id 25. Versioned copies of the unit and wrapper are in `deploy/`.
- Tailscale Serve also publishes the webhook tailnet-only at `https://paperlessscan.dusky-paradise.ts.net/` (Let's Encrypt HTTPS), proxying to `http://100.97.230.109:9000`. Home Assistant should use `http://100.97.230.109:9000/hooks/scan?token=...` — its Tailscale add-on does not reliably resolve MagicDNS names, which fails `rest_command` immediately. Check Serve with `tailscale serve status`.
