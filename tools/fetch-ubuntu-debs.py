#!/usr/bin/env python3
"""
Resolve and download Ubuntu noble amd64 .deb closure for seed packages.
Uses Packages.gz from main, updates, and security (like apt).
"""
from __future__ import annotations

import gzip
import hashlib
import os
import re
import sys
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

ARCH = "amd64"
SUITE = "noble"
MIRROR = "http://archive.ubuntu.com/ubuntu"

COMPONENTS = ("main", "universe", "restricted", "multiverse")
RELEASES = (
    ("noble", COMPONENTS),
    ("noble-updates", COMPONENTS),
    ("noble-security", COMPONENTS),
)

SEED_PACKAGES = (
    "mdadm",
    "parted",
    "gdisk",
    "xfsprogs",
    "e2fsprogs",
)

# mdadm recommends (explicit per user request)
MDADM_RECOMMENDS = ("finalrd", "kmod")

DEP_FIELDS = ("Pre-Depends", "Depends")
OPTIONAL_FIELDS = ("Recommends",)  # only for mdadm seeds via MDADM_RECOMMENDS


@dataclass(frozen=True)
class PkgVersion:
    name: str
    version: str
    filename: str
    source: str  # release/component path key

    def deb_url(self) -> str:
        # filename is like pool/main/m/mdadm/mdadm_4.3-1ubuntu2.1_amd64.deb
        return f"{MIRROR}/{self.filename}"


def parse_depends(value: str) -> list[tuple[str, str | None]]:
    """Return list of (pkgname, arch_qualifier|None). Ignores version constraints."""
    if not value or value.strip() == "-":
        return []
    parts: list[str] = []
    current: list[str] = []
    depth = 0
    for ch in value:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
            continue
        current.append(ch)
    if current:
        parts.append("".join(current).strip())

    result: list[tuple[str, str | None]] = []
    for part in parts:
        part = part.strip()
        if not part or part.startswith("|"):
            continue
        # strip alternatives — take first alternative
        if "|" in part:
            part = part.split("|")[0].strip()
        # remove version constraint
        part = re.split(r"\s*[<(=]", part)[0].strip()
        if not part or part.startswith("<"):
            continue
        arch: str | None = None
        m = re.search(r"\[([^\]]+)\]", part)
        if m:
            arch = m.group(1).strip()
            part = part[: m.start()].strip()
        # Ubuntu multiarch qualifiers on package name: python3:any
        if ":" in part and not part.startswith("http"):
            base, qual = part.rsplit(":", 1)
            if qual in ("any", "amd64", "native"):
                part = base
            elif qual.isalpha() or qual.startswith("linux-"):
                arch = qual if arch is None else arch
                part = base
        if part:
            result.append((part, arch))
    return result


def arch_ok(qualifier: str | None) -> bool:
    if qualifier is None:
        return True
    q = qualifier.lower()
    if q == "any":
        return True
    if q == ARCH:
        return True
    if q.startswith("linux-"):
        return True
    if q == "linux-any":
        return True
    return False


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    if dest.exists():
        return
    req = urllib.request.Request(url, headers={"User-Agent": "raid6-kit-fetch/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = resp.read()
    part.write_bytes(data)
    part.rename(dest)


def fetch_packages_index() -> dict[str, list[PkgVersion]]:
    """pkgname -> list of versions (newest first after sort)."""
    by_name: dict[str, list[PkgVersion]] = defaultdict(list)
    seen_file: set[str] = set()

    for release, components in RELEASES:
        for component in components:
            url = f"{MIRROR}/dists/{release}/{component}/binary-{ARCH}/Packages.gz"
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "raid6-kit-fetch/1.0"})
                with urllib.request.urlopen(req, timeout=120) as resp:
                    raw = gzip.decompress(resp.read()).decode("utf-8", errors="replace")
            except Exception as e:
                print(f"WARN: skip {url}: {e}", file=sys.stderr)
                continue

            stanza: dict[str, str] = {}
            for line in raw.splitlines():
                if line.strip() == "":
                    if stanza.get("Package") and stanza.get("Filename"):
                        fn = stanza["Filename"]
                        if fn in seen_file:
                            stanza = {}
                            continue
                        seen_file.add(fn)
                        pv = PkgVersion(
                            name=stanza["Package"],
                            version=stanza.get("Version", "0"),
                            filename=fn,
                            source=f"{release}/{component}",
                        )
                        by_name[pv.name].append(pv)
                    stanza = {}
                    continue
                if line.startswith(" "):
                    continue
                if ":" in line:
                    k, v = line.split(":", 1)
                    stanza[k.strip()] = v.strip()

    # sort each name by dpkg version compare (rough: split numeric)
    def ver_key(v: str) -> tuple:
        return tuple(re.findall(r"\d+|\D+", v))

    for name in by_name:
        by_name[name].sort(key=lambda p: ver_key(p.version))

    return by_name


def load_stanza_fields(by_name: dict[str, list[PkgVersion]]) -> dict[str, dict[str, str]]:
    """Re-fetch or cache — build name -> fields from best package."""
    # We need full stanza for depends; re-parse indexes into name->best stanza
    best_stanza: dict[str, dict[str, str]] = {}

    for release, components in RELEASES:
        for component in components:
            url = f"{MIRROR}/dists/{release}/{component}/binary-{ARCH}/Packages.gz"
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "raid6-kit-fetch/1.0"})
                with urllib.request.urlopen(req, timeout=120) as resp:
                    raw = gzip.decompress(resp.read()).decode("utf-8", errors="replace")
            except Exception:
                continue

            stanza: dict[str, str] = {}
            for line in raw.splitlines():
                if line.strip() == "":
                    if stanza.get("Package"):
                        pkg = stanza["Package"]
                        cur = best_stanza.get(pkg)
                        if cur is None or _ver_gt(stanza.get("Version", "0"), cur.get("Version", "0")):
                            best_stanza[pkg] = dict(stanza)
                    stanza = {}
                    continue
                if line.startswith(" "):
                    continue
                if ":" in line:
                    k, v = line.split(":", 1)
                    stanza[k.strip()] = v.strip()

    return best_stanza


def _ver_gt(a: str, b: str) -> bool:
    def key(v: str) -> tuple:
        return tuple(re.findall(r"\d+|\D+", v))

    return key(a) > key(b)


def resolve_closure(stanzas: dict[str, dict[str, str]], seeds: Iterable[str]) -> set[str]:
    needed: set[str] = set()
    queue = list(seeds)

    while queue:
        name = queue.pop()
        if name in needed:
            continue
        st = stanzas.get(name)
        if not st:
            print(f"WARN: package not in index: {name}", file=sys.stderr)
            needed.add(name)
            continue
        needed.add(name)
        for field in DEP_FIELDS:
            for dep, arch_q in parse_depends(st.get(field, "")):
                if arch_ok(arch_q):
                    if dep not in needed:
                        queue.append(dep)
        if name == "mdadm":
            for rec in MDADM_RECOMMENDS:
                if rec not in needed:
                    queue.append(rec)
            for dep, arch_q in parse_depends(st.get("Recommends", "")):
                if arch_ok(arch_q) and dep in MDADM_RECOMMENDS:
                    if dep not in needed:
                        queue.append(dep)

    return needed


def pick_best_deb(by_name: dict[str, list[PkgVersion]], name: str) -> PkgVersion | None:
    versions = by_name.get(name)
    if not versions:
        return None
    return versions[-1]  # sorted ascending, last is newest


def main() -> int:
    out_dir = Path(os.environ.get("OUT_DIR", "/workspace/raid6-kit/packages"))
    out_dir.mkdir(parents=True, exist_ok=True)

    print("Fetching package indexes...", file=sys.stderr)
    by_name = fetch_packages_index()
    stanzas = load_stanza_fields(by_name)

    seeds = list(SEED_PACKAGES)
    closure = resolve_closure(stanzas, seeds)
    print(f"Resolved {len(closure)} packages", file=sys.stderr)

    manifest_lines: list[str] = []
    downloaded = 0

    for name in sorted(closure):
        pv = pick_best_deb(by_name, name)
        if not pv:
            print(f"ERROR: no .deb for {name}", file=sys.stderr)
            return 1
        deb_name = Path(pv.filename).name
        dest = out_dir / deb_name
        url = pv.deb_url()
        print(f"GET {deb_name} ({pv.version}) from {pv.source}", file=sys.stderr)
        try:
            download(url, dest)
            downloaded += 1
        except Exception as e:
            print(f"ERROR downloading {url}: {e}", file=sys.stderr)
            return 1
        manifest_lines.append(f"{deb_name}\t{pv.version}\t{name}\t{pv.source}")

    manifest_path = out_dir / "MANIFEST.txt"
    manifest_path.write_text(
        "# raid6-kit offline packages — Ubuntu 24.04 noble amd64\n"
        f"# Seeds: {', '.join(SEED_PACKAGES)} + mdadm recommends {', '.join(MDADM_RECOMMENDS)}\n"
        f"# Total: {len(manifest_lines)} .deb files\n"
        "# filename\tversion\tpackage\torigin\n"
        + "\n".join(manifest_lines)
        + "\n",
        encoding="utf-8",
    )
    print(f"Done. {len(manifest_lines)} packages in {out_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
