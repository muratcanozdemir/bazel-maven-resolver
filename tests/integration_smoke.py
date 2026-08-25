#!/usr/bin/env python3
"""
Standalone integration smoke test.

Does NOT require Bazel. Simulates what the Starlark code does:
  1. Parses each search_url from the example YAML.
  2. Fetches versions from Maven search API.
  3. Applies version range filtering.
  4. Prints the resolved GAV.

Run: python3 tests/integration_smoke.py

Requires: PyYAML, Python 3.8+
No other dependencies.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ── Inline Python equivalents of the Starlark logic ──────────────────────────

def parse_url(url: str) -> tuple[str, str]:
    """Mirrors maven_search._parse_search_url in Starlark (extensions/maven_search.bzl).

    Keep this in sync with that function — see tests/versions_test.bzl and
    tests/test_version_logic.py for the shared golden-vector convention.
    """
    path_part = url
    for sep in ["?", "#"]:
        path_part = path_part.split(sep)[0]

    group = artifact = None

    if "/artifact/" in path_part:
        after = path_part.split("/artifact/", 1)[1]
        parts = after.split("/")
        if len(parts) >= 2:
            group = parts[0]
            artifact = parts[1]

    if not group:
        # Search the whole URL (not path_part) — the legacy hash-fragment
        # form encodes g:/a: after the "#", which path_part just stripped.
        q = url.replace("g%3A", "g:").replace("a%3A", "a:")
        if "g:" in q:
            after_g = q.split("g:", 1)[1]
            for sep in ["+", "&", " "]:
                after_g = after_g.split(sep)[0]
            group = after_g.strip().strip('"').strip("'")
        if "a:" in q:
            after_a = q.split("a:", 1)[1]
            for sep in ["+", "&", " "]:
                after_a = after_a.split(sep)[0]
            artifact = after_a.strip().strip('"').strip("'")

    if not group or not artifact:
        raise ValueError(f"Cannot parse group/artifact from: {url}")

    return group, artifact


def parse_version(v: str) -> tuple[list[int], bool]:
    prerelease_markers = ["-snapshot", "-alpha", "-beta", "-rc", "-m", ".alpha", ".beta", ".rc"]
    cleaned = v.strip()
    is_pre = any(m in cleaned.lower() for m in prerelease_markers)
    if is_pre:
        for m in prerelease_markers:
            idx = cleaned.lower().find(m)
            if idx != -1:
                cleaned = cleaned[:idx]
                break
    parts = []
    for seg in cleaned.split("."):
        if seg.isdigit():
            parts.append(int(seg))
        else:
            is_pre = True
    return parts or [0], is_pre


def glob_to_range(glob: str):
    parts = glob.split(".")
    if "*" not in parts:
        p, _ = parse_version(glob)
        return dict(low=p, high=None, exact=True)
    base = [int(p) for p in parts[:-1]]
    high = base[:-1] + [base[-1] + 1]
    low  = base + [0]
    return dict(low=low, high=high, exact=False)


def version_cmp(a, b):
    ml = max(len(a), len(b))
    for i in range(ml):
        av = a[i] if i < len(a) else 0
        bv = b[i] if i < len(b) else 0
        if av < bv: return -1
        if av > bv: return 1
    return 0


def in_range(v: str, rng: dict, exclude_pre: bool = True) -> bool:
    parts, is_pre = parse_version(v)
    if exclude_pre and is_pre:
        return False
    if rng["exact"]:
        return version_cmp(parts, rng["low"]) == 0
    if version_cmp(parts, rng["low"]) < 0:
        return False
    if version_cmp(parts, rng["high"]) >= 0:
        return False
    return True


def latest_in_range(versions: list[str], rng: dict, exclude_pre: bool = True) -> str | None:
    candidates = [v for v in versions if in_range(v, rng, exclude_pre)]
    if not candidates:
        return None
    best = candidates[0]
    best_p, _ = parse_version(best)
    for v in candidates[1:]:
        vp, _ = parse_version(v)
        if version_cmp(vp, best_p) > 0:
            best, best_p = v, vp
    return best


def fetch_versions(group: str, artifact: str, base_url: str = "https://search.maven.org") -> list[str]:
    versions = []
    start = 0
    while True:
        params = urllib.parse.urlencode({
            "q": f"g:{group} AND a:{artifact}",
            "core": "gav",
            "rows": 200,
            "wt": "json",
            "start": start,
        })
        url = f"{base_url}/solrsearch/select?{params}"
        req = urllib.request.Request(url, headers={"User-Agent": "bazel-maven-wildcard-smoke/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
        docs = data["response"]["docs"]
        if not docs:
            break
        for d in docs:
            v = d.get("v") or d.get("version")
            if v:
                versions.append(v)
        start += len(docs)
        if start >= data["response"]["numFound"]:
            break
        time.sleep(0.3)
    return versions


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    try:
        import yaml
    except ImportError:
        print("ERROR: PyYAML required. Run: pip3 install pyyaml", file=sys.stderr)
        sys.exit(1)

    yaml_path = os.path.join(os.path.dirname(__file__), "..", "maven_deps.yaml")
    with open(yaml_path) as f:
        manifest = yaml.safe_load(f)

    global_exclude_pre = manifest.get("settings", {}).get("exclude_prerelease", True)

    print(f"{'DEP':<30} {'GLOB':<12} {'RESOLVED':<20}")
    print("-" * 65)

    failures = []
    for dep in manifest["dependencies"]:
        name        = dep.get("name", "?")
        search_url  = dep["search_url"]
        version_str = str(dep["version"])
        exclude_pre = dep.get("exclude_prerelease", global_exclude_pre)

        try:
            group, artifact = parse_url(search_url)
        except ValueError as e:
            failures.append((name, str(e)))
            print(f"{'  ' + name:<30} {'ERROR':<12} URL parse failed")
            continue

        rng = glob_to_range(version_str)

        if rng["exact"]:
            print(f"  {name:<28} {version_str:<12} {version_str:<20}  (exact)")
            continue

        try:
            all_versions = fetch_versions(group, artifact)
        except Exception as e:
            failures.append((name, str(e)))
            print(f"  {name:<28} {version_str:<12} FETCH ERROR: {e}")
            continue

        best = latest_in_range(all_versions, rng, exclude_pre)
        if best is None:
            failures.append((name, f"No match in {len(all_versions)} versions"))
            print(f"  {name:<28} {version_str:<12} NO MATCH (exclude_pre={exclude_pre})")
        else:
            print(f"  {name:<28} {version_str:<12} {best:<20}  ({group}:{artifact})")

        time.sleep(0.5)  # polite rate limiting

    print()
    if failures:
        print(f"FAILURES ({len(failures)}):")
        for name, msg in failures:
            print(f"  {name}: {msg}")
        sys.exit(1)
    else:
        print("All deps resolved successfully.")


if __name__ == "__main__":
    main()
