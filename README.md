# layaair-ide

Repackage the official LayaAir IDE AppImage into an Arch Linux package and publish to AUR.

## How it works
- Fetches latest release metadata from:
  - `https://ldc-1251285021.file.myqcloud.com/layaair/log/3.0/navConfig.json`
- Picks the newest entry by `date`
- Downloads the Linux AppImage
- Updates `PKGBUILD` and `.SRCINFO`

The package extracts the AppImage and installs the unpacked app into `/opt/layaair-ide`, with desktop entry and icon configured for a normal Electron app.

## Local update
```bash
./scripts/update.sh
```

## GitHub Actions (nightly)
The workflow runs every night and pushes updates to GitHub and AUR.

Required secrets:
- `AUR_SSH_PRIVATE_KEY` (private key with access to `aur.archlinux.org`)
- `AUR_USERNAME` (your AUR username)

Optional:
- If you change the AUR package name, update it in `.github/workflows/auto-update.yml`.
