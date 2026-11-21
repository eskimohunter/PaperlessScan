# AGENTS.md

Single-purpose bash repo: Epson network scan → PDF → Paperless-ngx upload. No build system, tests, or CI; `shellcheck` is the only static check.

## Verify

```bash
shellcheck scan.sh     # passes as of this writing
nix develop            # optional dev shell: epsonscan2, avahi, qpdf, webhook, shellcheck
```

`./scan.sh` needs a live scanner and a configured `.env` — don't run it as a smoke test for a code edit.

## scan.sh behavior that isn't obvious

- `.env` is `source`d with `set -a` from the script's own directory. Required: `SCANNER_MODEL`, `OUTPUT_DIR`, `TMP_SCAN_PATH`, `EPSONSCAN2`; `SCANNER_MAC` is optional, and `RESOLUTION=300` / `BACKGROUND_COLOR=3` are defaults.
- The scanner IP is discovered at runtime: `discover_scanner` parses `avahi-browse -r -p -t _scanner._tcp`, matching `SCANNER_MODEL` against the mDNS name/TXT or the driver `ModelID`, and `SCANNER_MAC` against the last 12 hex digits of the advertised UUID. No fixed IP is stored. Zero or multiple matches abort with the discovered-device list; `avahi-browse`/`avahi-daemon` must be available.
- The resolved address is cached at `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/paperlessscan/scanner` (model/mac/ip, fallback `/tmp`). `scan.sh resolve` forces a fresh discovery and writes the cache; the systemd unit runs it in `ExecStartPre` (failure ignored). Scans use the cache without a reachability probe. A scan error with exit 26 (unable to send data) or 34 (device not found) invalidates the cache, rediscovers, and retries the batch once. A model/MAC change in `.env` also invalidates it; there is no TTL.
- `PaperlessScan.SF2` is generated at the repo root from `SF2.template` by replacing exactly three tokens: `RESOLUTION_VAR`, `TMP_SCAN_PATH_VAR`, `BACKGROUND_COLOR_VAR`. Gitignored (`*.SF2`) and removed on exit by a trap, including failures. Edit the template, never the generated file.
- The scanner always writes `<TMP_SCAN_PATH>/Scan.pdf` (template `FileNamePrefix = "Scan"`); a stale one is removed first, then moved to `<OUTPUT_DIR>/scan_<timestamp>.pdf`. Changing the output name/location in the template breaks the `mv`.
- `EPSONSCAN2` is a command string, not a path: only its first word is PATH-checked (`${EPSONSCAN2%% *}`), the rest is word-split. It must match how Epson Scan is installed on the target host (apt vs Flatpak).
- Upload runs only if both `PAPERLESS_URL` and `API_TOKEN` are set. POSTs to `${PAPERLESS_URL}/api/documents/post_document/` with `Authorization: Token …` and `Accept: application/json; version=9`. `curl` has no `-L`, so a redirect counts as failure; any non-2xx exits 1.
- Modes: no argument (short press) = one-shot scan+upload, or scan the final batch and finalize an open session; `next` (long press) = start or append a session; `resolve` = force discovery and update the cache only. Sessions live in `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/paperlessscan-session` (fallback `/tmp`), expire after `SESSION_TIMEOUT` seconds (default 600) of inactivity, and are discarded on expiry, failed merge, or successful upload.
- Session merge: 1 batch as-is; 2 batches interleaved (fronts `1..N`, backs `N..1`, equal page counts required); 3+ concatenated in order. `qpdf` is required. An upload failure keeps the merged PDF in `OUTPUT_DIR` and discards the session.

## Secrets, paths, sync

- Gitignored: `.env`, `scan-hooks.json`, `*.SF2`. Tracked templates: `.env.example`, `scan-hooks.example.json` (placeholder `WEBHOOK_TOKEN_PLACEHOLDER`).
- The local `scan-hooks.json` and `scan-webhook.service` still point at a third checkout path `/home/robert/Documents/RobsDocuments/git/PaperlessScan` — fix both when editing.
- The host clone may temporarily differ from GitHub when `scan.sh`/`flake.nix` are deployed before a push. Create its `.env` manually (gitignored); versioned `deploy/` files are installed separately.

## Deployment host: `paperlessscan`

- Fresh Ubuntu 24.04 LXC (rebuilt 2026-11-20), root-only (`ssh root@paperlessscan`; no `robert` user). LAN `192.168.4.156`, Tailscale `100.97.230.109`. Keep the root disk at least ~6 GB — 2 GB fails Nix builds with ENOSPC.
- Nix 2.36 is installed multi-user with `nix-command` + `flakes`, and **`sandbox = false`** in `/etc/nix/nix.conf`. The sandbox must be off in this unprivileged LXC, otherwise builds fail with `/dev/null: Permission denied`.
- Host `.env` uses `SCANNER_MODEL=WF-2930`, `EPSONSCAN2=epsonscan2`, `TMP_SCAN_PATH=/tmp/PaperlessScan`, `OUTPUT_DIR=/root/Documents/scans`; `SCANNER_MAC` is present but commented out. `avahi-daemon` and `avahi-utils` are installed and enabled. The first `nix develop` builds the non-free `epsonscan2` variant (not in the binary cache) and takes several minutes.
- Scanning is verified via Nix with no fixed IP config: `nix develop --command ./scan.sh` discovers the scanner and scans. On 2026-11-21 this produced `/root/Documents/scans/scan_2026-11-21_09-06-49.pdf`, upload HTTP 200, Paperless document id 26; the driver-ModelID (`ES025A`) + MAC path produced id 27.
- Scanner: Epson WF-2930 Series (driver ModelID `ES025A`), Bonjour `EPSON099C8A.local`, MAC `f8:25:51:09:9c:8a`. Its current IP (`192.168.4.152` at last check) is discovered dynamically; don't hardcode it in `.env`. Inspect with `avahi-browse -art | grep -i epson`.
- Paperless-ngx is on a different host `paperless` (Debian 13, `192.168.4.82:8000`), reached at `https://paperless.dusky-paradise.ts.net`; the deployed token works.
- Webhook is installed as the enabled system unit `/etc/systemd/system/scan-webhook.service`, bound to the Tailscale IP `100.97.230.109:9000` (after `tailscaled.service` and `avahi-daemon.service`). It runs `ExecStartPre=-/usr/local/bin/paperlessscan-scan resolve` to populate the scanner cache. Hook config: `/root/PaperlessScan/scan-hooks.json` (mode 600, holds the URL token); it calls `/usr/local/bin/paperlessscan-scan`, which prefers `/root/.nix-profile/bin/paperlessscan` (installed with `nix profile install .#`) and falls back to `nix develop --command ./scan.sh "$@"`. Hooks: `scan` (short press, no arg) and `scan-next` (long press, arg `next`). Read the token with `jq -r '.[0]["trigger-rule"].match.value' /root/PaperlessScan/scan-hooks.json` (bracket notation — `trigger-rule` is not a valid bare jq key).
- Webhook gotcha: an invalid token still returns HTTP 200 with body `Hook rules were not satisfied.` — validate the body, not the status code. The hook responds immediately and runs the scan asynchronously (~40 s).
- `/usr/local/bin/paperlessscan-scan` takes a non-blocking `flock` on `/run/paperlessscan-scan.lock` and forwards its argument to the profile wrapper (fallback: `./scan.sh` via `nix develop`); overlapping triggers exit 0 with `scan already in progress; trigger ignored`, so only one scan runs at a time. Versioned copies of the unit and wrapper are in `deploy/`.
- Session flows verified 2026-11-21: one-shot doc 31; long+short duplex doc 32 (2 pages); three batches then finish doc 33 (3 pages); an expired session fell back to one-shot doc 34; a re-test produced doc 35. qpdf merge tests: 2×2-page interleave → 4 pages, 1-vs-2-page mismatch rejected, 3-batch concat → 3 pages.
- Cache/profile verified 2026-11-21: startup `resolve` wrote the cache; cached one-shot doc 47; stale cache (`192.168.4.250`) failed 34, rediscovered, retried, doc 48; duplex with cache doc 49 (2 pages); a mismatched cache model forced rediscovery, doc 50. The profile package is installed, so scans no longer log the `nix develop` dirty-tree warning.
- Tailscale Serve also publishes the webhook tailnet-only at `https://paperlessscan.dusky-paradise.ts.net/` (Let's Encrypt HTTPS), proxying to `http://100.97.230.109:9000`. Home Assistant should use `http://100.97.230.109:9000/hooks/scan?token=...` — its Tailscale add-on does not reliably resolve MagicDNS names, which fails `rest_command` immediately. Check Serve with `tailscale serve status`.
