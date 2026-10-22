# EarthAccessDownloader

A native macOS app for searching and downloading EMIT and AVIRIS (AVIRIS‑3, AVIRIS‑5, AVIRIS‑NG, AVIRIS‑Classic) imaging spectrometer data from NASA Earthdata, built on top of the [earthaccess](https://github.com/nsidc/earthaccess) Python library.

## Features

- Search by time window, location (point, bounding box, or a corner + offset), and product.
- Results are grouped by instrument, with AVIRIS split into its individual variants, and each group is color-coded for quick scanning.
- Granules from different products describing the same acquisition (e.g. EMIT L1B Radiance + L2A Reflectance for one overflight) are combined into a single row.
- AVIRIS flightline segments are grouped together, with a one-click action to fetch any remaining segments of a flightline.
- Per-file selection, with bulk select/deselect and select-by-file-type helpers.
- Download to a local folder, or to a remote machine over SSH (handy for downloading directly onto a server or cluster).

## How it works

The app is a SwiftUI frontend (`EarthAccessDownloader/`) that shells out to a small Python bridge script, `earthaccess_helper.py`, which wraps `earthaccess` for searching, authenticating, and downloading. Requests and results are passed as JSON over stdin/stdout, so the Swift side never needs to know anything about the earthaccess API directly.

For remote downloads, the same helper script is shipped inline over SSH and run with the remote machine's Python — nothing needs to be installed on the remote host beyond `earthaccess` itself.

## Requirements

- macOS, Xcode 16+
- Python 3 with [`earthaccess`](https://pypi.org/project/earthaccess/) installed (`pip install earthaccess`), for whichever Python interpreter the app is pointed at
- A [NASA Earthdata](https://urs.earthdata.nasa.gov/) account

## Setup

1. Open `EarthAccessDownloader.xcodeproj` in Xcode and run the app.
2. In the app's sidebar, point **Local Python** at a Python interpreter that has `earthaccess` installed (defaults to `python3` on your `PATH`).
3. Authenticate with Earthdata using any method `earthaccess.login()` supports — most commonly:
   - Environment variables: `EARTHDATA_USERNAME` and `EARTHDATA_PASSWORD`
   - A `~/.netrc` entry for `urs.earthdata.nasa.gov`

   Since the app launches its helper script via a login shell, make sure these are set somewhere a *login* shell picks up (e.g. `~/.zprofile`), not just an interactive one (e.g. `~/.zshrc` alone).

## Downloading to a remote machine

To download straight to a remote machine instead of your Mac, switch **Download on** to **Remote (ssh)** and fill in:

- **Host** — `user@host`, or an alias from your `~/.ssh/config`
- **Folder** — the destination folder on the remote machine
- **Python** — the remote `python3` (or full path) that has `earthaccess` installed

This requires key- or agent-based SSH auth (no password prompts), and Earthdata credentials available on the remote machine the same way as above.

## License

No license specified.
