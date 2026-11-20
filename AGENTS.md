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
- Deployed copies on `paperlessscan` are locally modified (apt `webhook` path, `/home/paperless/...` paths); preserve those edits when syncing from this repo.

## Deployment host: `paperlessscan`

- Separate clone at `/home/paperless/Documents/PaperlessScan`, user `paperless` (uid 1001), origin `eskimohunter/PaperlessScan.git`, branch `master`. Ubuntu 24.04 LXC, LAN `192.168.4.25`, Tailscale `100.83.71.86`. `ssh root@paperlessscan` works; `ssh paperlessscan` lands as robert (sudo needs a password).
- Host has apt `epsonscan2` 6.7.80, `webhook` 2.8.0, TigerVNC/XFCE — **no nix, flatpak, or shellcheck**. Working `.env` there: `EPSONSCAN2=epsonscan2`, `TMP_SCAN_PATH=/tmp/PaperlessScan`, `OUTPUT_DIR=/home/paperless/Documents/scans`. Never copy the local Flatpak paths to the host.
- Scanner IP is `192.168.4.152` (old `192.168.4.34` is stale); both local and host `.env` now use it. The device is Bonjour `EPSON099C8A.local` / IPv6 `fe80::fa25:51ff:fe09:9c8a` (model ES025A, WF-2930). Re-discover with `avahi-browse -art | grep -i epson` + `avahi-resolve -4 -n <name>.local`.
- On the host, `runuser -u paperless -- epsonscan2 --set-ip 192.168.4.152` makes scanning work, even if `epsonscan2 --list` still says `Device is not found...`. Verified 2026-11-20: `scan.sh` as user `paperless` produced a PDF in `~/Documents/scans` and upload returned HTTP 200 (Paperless consumed it as doc id 19, later 20/21).
- Local Nix scanning also works after fixing `flake.nix`: it must override `epsonscan2` with `withNonFreePlugins = true` (otherwise `es2netif` is missing, ENOENT) and export OpenSSL 1.1's `lib` dir via `shellHook` (otherwise `es2netif` cannot `dlopen libcrypto.so.1.1`, skips TLS, and fails with `Unable to send data`, exit 26). Both were verified; plain `nix develop && ./scan.sh` now produces a PDF.
- Paperless-ngx is on a different host `paperless` (Debian 13, `192.168.4.82:8000`), reached at `https://paperless.dusky-paradise.ts.net`; deployed token verified (200 on `/api/documents/`).
- Webhook is **not running**: user unit has no lingering manager, VNC is disabled, and the system `webhook.service` is dead (no `/etc/webhook.conf`); port 9000 unbound. Scanning is headless CLI — VNC is unrelated (see untracked `docs/vnc-setup.md`).
