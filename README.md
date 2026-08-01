# PaperlessScan

One-click scanning from an Epson network scanner to PDF, with automatic upload to [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx).

## Requirements

- An Epson network scanner accessible on your LAN
- `epsonscan2` (Epson Scan 2) — installed via Flatpak:
  ```bash
  flatpak install net.epson.epsonscan2
  ```
- `curl`
- A running [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) instance with an API token

## NixOS / Nix

A dev shell is provided via `flake.nix` with `epsonscan2` and `shellcheck`:

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
   | `SCANNER_IP` | IP address of your Epson scanner (e.g. `192.168.1.50`) |
   | `OUTPUT_DIR` | Directory where scanned PDFs are saved |
   | `TMP_SCAN_PATH` | Temporary directory for the scan output |
   | `RESOLUTION` | Scan resolution in DPI (default: `300`) |
   | `BACKGROUND_COLOR` | Scanner background colour (`0`=White, `3`=Black; default: `3`) |
   | `EPSONSCAN2` | Command to invoke `epsonscan2` (e.g. `flatpak run net.epson.epsonscan2`) |
   | `PAPERLESS_URL` | Paperless-ngx URL, no trailing slash |
   | `API_TOKEN` | API token from Paperless Web UI → Profile → circular arrow button |

## Usage

```bash
./scan.sh
```

The script will:

1. Load configuration from `.env`
2. Generate an Epson Scan 2 settings file from `SF2.template`
3. Trigger a scan on the network scanner
4. Save the PDF to `OUTPUT_DIR` with a timestamped filename
5. Upload the document to Paperless-ngx

## Scanner Settings

The `SF2.template` file configures the scanner with these defaults:
- **Resolution:** 300 DPI (configurable via `RESOLUTION`)
- **Colour:** Auto-detection
- **Format:** PDF
- **Document size:** A4
- **Feed:** Auto (flatbed or ADF)
- **Paper deskew:** Enabled
- **Double-feed detection:** Enabled
- **Duplex:** Disabled