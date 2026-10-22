#!/usr/bin/env python3
"""Bridge between the SwiftUI app and the earthaccess library.

Usage: earthaccess_helper.py <search|download|check>
A JSON request is read from stdin. Results are written to stdout as JSON
lines: one `{"type": ...}` object per line.
"""
import json
import os
import re
import sys


def emit(**obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


_TIMESTAMP = re.compile(r"^\d{8}[Tt]\d{6}$")
_FLIGHT_ID = re.compile(r"^(?:AV\d|ang|prm|f)\d{6,8}[tT]\d{2,6}(?:p\d{2}r\d+)?$")
_HASH = re.compile(r"^[0-9a-f]{8}$")
_VERSION = re.compile(r"^\d{3}$")


def file_kind(name):
    """Name of a file with granule-specific tokens (ids, timestamps, hashes)
    removed, so the same kind of file in different granules compares equal."""
    stem, dot, ext = name.partition(".")
    tokens = [
        t for t in stem.split("_")
        if not (_TIMESTAMP.match(t) or _FLIGHT_ID.match(t)
                or _HASH.match(t) or _VERSION.match(t))
    ]
    return "_".join(tokens) + dot + ext if tokens else name


def parse_granule(g, product):
    umm = g["umm"]
    sizes = {
        a.get("Name"): a.get("SizeInBytes")
        for a in (umm.get("DataGranule") or {}).get("ArchiveAndDistributionInformation", [])
    }
    files = []
    for url in g.data_links(access="external"):
        if url.endswith(".sha256") or url.endswith(".md5"):
            continue
        name = url.rsplit("/", 1)[-1]
        files.append({"url": url, "name": name, "kind": file_kind(name),
                      "bytes": sizes.get(name)})
    rng = (umm.get("TemporalExtent") or {}).get("RangeDateTime") or {}
    return {
        "id": g["meta"]["concept-id"],
        "name": umm["GranuleUR"],
        "product": product,
        "start": rng.get("BeginningDateTime"),
        "end": rng.get("EndingDateTime"),
        "files": files,
    }


def cmd_search(req):
    import earthaccess

    limit = req.get("limit", 500)
    loc = req.get("location") or {}
    for product in req["products"]:
        query = earthaccess.DataGranules() \
            .short_name(product["short_name"]).version(product["version"])
        if req.get("start") and req.get("end"):
            query = query.temporal(req["start"], req["end"])
        if "point" in loc:
            query = query.point(*loc["point"])
        elif "bbox" in loc:
            query = query.bounding_box(*loc["bbox"])
        try:
            results = query.get(limit)
        except IndexError:  # earthaccess raises this on an empty result set
            results = []
        emit(type="granules",
             granules=[parse_granule(g, product["label"]) for g in results],
             truncated=len(results) >= limit)


def cmd_extend(req):
    """Find every granule of the given flightlines (granule names sharing a prefix)."""
    import earthaccess

    for line in req["lines"]:
        query = earthaccess.DataGranules() \
            .short_name(line["short_name"]).version(line["version"]) \
            .readable_granule_name(line["prefix"] + "_*")
        try:
            results = query.get(200)
        except IndexError:  # earthaccess raises this on an empty result set
            results = []
        emit(type="granules",
             granules=[parse_granule(g, line["label"]) for g in results],
             truncated=False)


def login():
    import earthaccess

    for strategy in ("environment", "netrc"):
        try:
            auth = earthaccess.login(strategy=strategy)
        except Exception:
            continue
        if auth.authenticated:
            return True
    return False


def cmd_download(req):
    import earthaccess

    if not login():
        emit(type="error", message="Not logged in to Earthdata. Run earthaccess.login(persist=True) "
             "or set EARTHDATA_USERNAME/EARTHDATA_PASSWORD (or EARTHDATA_TOKEN), then try again.")
        return
    dest = req["dest"]
    os.makedirs(dest, exist_ok=True)
    urls = req["urls"]
    for i, url in enumerate(urls):
        name = url.rsplit("/", 1)[-1]
        emit(type="progress", index=i, total=len(urls), name=name)
        try:
            paths = earthaccess.download([url], dest)
            if not paths or isinstance(paths[0], Exception):
                raise RuntimeError(str(paths[0]) if paths else "no file returned")
        except Exception as e:
            emit(type="file_error", name=name, message=str(e))
    emit(type="done", total=len(urls))


def cmd_check(_req):
    import earthaccess  # noqa: F401
    emit(type="ok", version=earthaccess.__version__)


def main():
    cmd = sys.argv[1]
    req = json.loads(sys.stdin.read() or "{}")
    try:
        {"search": cmd_search, "download": cmd_download, "check": cmd_check,
         "extend": cmd_extend}[cmd](req)
    except ImportError:
        emit(type="error", message="The earthaccess Python package is not installed for this "
             "interpreter. Run: pip install earthaccess")
    except Exception as e:
        emit(type="error", message=f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
