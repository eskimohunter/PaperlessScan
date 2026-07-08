# PaperlessScan

Scan a page from a network scanner, save it as a datetime-named PDF to a folder.

## Requirements

- Ubuntu (runner) or Linux with SANE
- Dependencies: `sane-utils` (scanimage), `img2pdf`

```bash
apt install sane-utils img2pdf
```

## Development (NixOS)

```bash
nix develop   # brings scanimage, img2pdf, shellcheck into PATH
```

## Setup

1. Find your scanner device:
   ```bash
   scanimage -L
   ```

2. Copy and edit the config:
   ```bash
   cp .env.example .env
   # Edit SCANNER_DEVICE and OUTPUT_DIR
   ```

3. Run:
   ```bash
   ./scan.sh
   ```

Output: `OUTPUT_DIR/scan_YYYY-MM-DD_HH-MM-SS.pdf`

## Configuration

| Variable | Default | Description |
|---|---|---|
| `SCANNER_DEVICE` | *(required)* | SANE device URI, e.g. `net:192.168.0.50:pixma:MX920` |
| `OUTPUT_DIR` | *(required)* | Directory to save PDFs (auto-created) |
| `RESOLUTION` | `300` | Scan DPI |
| `MODE` | `Color` | `Color` or `Gray` |