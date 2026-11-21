# PaperlessScan

One-click scanning from an Epson network scanner to PDF, with automatic upload to [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx).

## Requirements

- An Epson network scanner reachable over mDNS
- `avahi-daemon` and `avahi-utils` for scanner discovery
- `epsonscan2` (Epson Scan 2) — provided by the Nix dev shell below, or install it via apt/Flatpak
- `qpdf` for multi-page session merges (provided by the Nix dev shell)
- `curl`
- A running [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) instance with an API token

## NixOS / Nix

A dev shell is provided via `flake.nix` with `epsonscan2` (including the non-free network plugins), `avahi`, `qpdf`, `webhook`, and `shellcheck`:

```bash
nix develop
```

## Setup

1. Copy the environment template and fill in your values:

   ```bash
   cp .env.example .env
   ```

2. Edit `.env` with your details:

   | Variable | Description |
   |---|---|
   | `SCANNER_MODEL` | Model name/number advertised via mDNS, case-insensitive substring (e.g. `WF-2930`) |
   | `SCANNER_MAC` | Optional MAC address to select one of several same-model scanners |
   | `RESOLUTION` | Scan resolution in DPI (default: `300`) |
   | `BACKGROUND_COLOR` | Scanner background colour (`0`=White, `3`=Black; default: `3`) |
   | `OUTPUT_DIR` | Directory where scanned PDFs are saved |
   | `TMP_SCAN_PATH` | Temporary directory for the scan output |
   | `EPSONSCAN2` | Command to invoke `epsonscan2` (e.g. `epsonscan2` from the dev shell, or `flatpak run net.epson.epsonscan2`) |
   | `PAPERLESS_URL` | Paperless-ngx URL, no trailing slash |
   | `API_TOKEN` | API token from Paperless Web UI → Profile → circular arrow button |

## Usage

`./scan.sh` scans one batch. `./scan.sh next` starts or extends a scan session.

### One-shot

```bash
./scan.sh
```

The script discovers the scanner by model/MAC over mDNS, scans one batch, saves it to `OUTPUT_DIR`, and uploads it to Paperless.

### Scan sessions

Use `next` for a long press (start or continue a session), and a normal run for a short press (scan the final batch and finish):

```bash
./scan.sh next   # start session, scan batch 1
./scan.sh next   # append batch 2
./scan.sh        # scan final batch, merge, upload
```

Merging rules:

- **1 batch** → uploaded as-is
- **2 batches** → interleaved as duplex (long-edge flip: fronts `1..N`, backs `N..1`)
- **3+ batches** → concatenated in order

This supports manual duplex on a simplex ADF (long press for fronts, flip, short press for backs), single-sheet front/back on the flatbed, and multi-load simplex documents. Sessions expire after 10 minutes of inactivity (`SESSION_TIMEOUT`).

## Webhook

A scan can also be triggered remotely via HTTP using [webhook](https://github.com/adnanh/webhook).

**Setup:**

1. Copy the hooks template and set a secret token:

   ```bash
   cp scan-hooks.example.json scan-hooks.json
   ```

2. Edit `scan-hooks.json` — replace `WEBHOOK_TOKEN_PLACEHOLDER` with your own secret and update paths to match your system.

3. Run the webhook server:

   ```bash
   webhook -hooks scan-hooks.json -ip 127.0.0.1 -port 9000 -verbose
   ```

   Or install as a systemd user service:

   ```bash
   cp scan-webhook.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now scan-webhook
   ```

   For a headless host, `deploy/` contains a root system unit and a wrapper that serializes overlapping triggers. Adjust the paths and Tailscale IP in the unit first:

   ```bash
   install -m755 deploy/paperlessscan-scan /usr/local/bin/
   install -m644 deploy/scan-webhook.service /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now scan-webhook
   ```

   The unit resolves the scanner and caches its address at startup. Install the preloaded runtime to avoid `nix develop` on every scan (the wrapper uses it automatically when present):

   ```bash
   nix profile install /root/PaperlessScan#
   ```

   If the cached address goes stale, a scan failure (exit 26/34) triggers rediscovery and one retry.

**Trigger a scan:**

The `scan` hook is the short-press action (one-shot, or finish a session); `scan-next` is the long-press action (start or extend a session):

```bash
curl "http://127.0.0.1:9000/hooks/scan?token=YOUR_SECRET"
curl "http://127.0.0.1:9000/hooks/scan-next?token=YOUR_SECRET"
```

For a ZHA button, bind its short-press event to `scan` and its long-press event to `scan-next`.

## Scanner Settings

The `SF2.template` file configures the scanner with these defaults:
- **Resolution:** 300 DPI (configurable via `RESOLUTION`)
- **Colour:** Auto-detection
- **Format:** PDF
- **Document size:** A4
- **Feed:** Auto (flatbed or ADF)
- **Paper deskew:** Enabled
- **Double-feed detection:** Enabled
- **Background color:** Black (configurable via `BACKGROUND_COLOR`)
- **Duplex:** Disabled