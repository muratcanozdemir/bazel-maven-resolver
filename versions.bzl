"""
Pure-Starlark version utilities for Maven wildcard resolution.

Supports glob notation only: "3.5.*"
Converts to half-open interval [3.5.0, 3.6.0) for comparison.

No external dependencies. No shell-out.
"""

def _parse_version(version_str):
    """
    Parse a dotted version string into a tuple of ints.
    Non-numeric qualifiers (e.g. -SNAPSHOT, -alpha) are stripped and
    cause the version to be marked as pre-release.

    Returns a struct:
      .parts   - list of ints, e.g. [3, 5, 2]
      .prerelease - bool, True if qualifier detected
      .raw    - original string
    """
    raw = version_str.strip()

    # Detect and strip common pre-release qualifiers.
    # Starlark has no regex; use explicit suffix checks.
    prerelease_markers = [
        "-SNAPSHOT", "-alpha", "-Alpha", "-ALPHA",
        "-beta", "-Beta", "-BETA",
        "-rc", "-RC", "-M", "-milestone",
        ".alpha", ".beta", ".rc",
    ]
    is_prerelease = False
    cleaned = raw
    for marker in prerelease_markers:
        if marker.lower() in cleaned.lower():
            is_prerelease = True
            # Strip from the marker onwards
            idx = cleaned.lower().find(marker.lower())
            cleaned = cleaned[:idx]
            break

    parts = []
    for segment in cleaned.split("."):
        if segment.isdigit():
            parts.append(int(segment))
        else:
            # Non-numeric segment at end (e.g. "2.Final") — treat as 0, mark prerelease
            is_prerelease = True

    if not parts:
        return struct(parts = [0], prerelease = True, raw = raw)

    return struct(parts = parts, prerelease = is_prerelease, raw = raw)

def _version_cmp(a_parts, b_parts):
    """
    Compare two version part lists.
    Pads shorter list with zeros.
    Returns -1, 0, or 1.
    """
    max_len = max(len(a_parts), len(b_parts))
    for i in range(max_len):
        a_val = a_parts[i] if i < len(a_parts) else 0
        b_val = b_parts[i] if i < len(b_parts) else 0
        if a_val < b_val:
            return -1
        if a_val > b_val:
            return 1
    return 0

def glob_to_range(glob_str):
    """
    Convert a glob version string to a half-open [low, high) range.

    "3.5.*"   -> low=[3,5,0], high=[3,6,0]
    "3.*"     -> low=[3,0,0], high=[4,0,0]
    "3.5.2.*" -> low=[3,5,2,0], high=[3,5,3,0]

    Non-glob strings (no "*") are returned as an exact match:
      low=parts, high=None (meaning exact)

    Fails loudly on malformed input.
    """
    parts = glob_str.split(".")

    if "*" not in parts:
        # Exact version — no range
        parsed = _parse_version(glob_str)
        return struct(
            low = parsed.parts,
            high = None,
            exact = True,
            raw = glob_str,
        )

    if parts[-1] != "*":
        fail("Wildcard '*' must be the final segment in version glob: '{}'".format(glob_str))

    # Parts before the wildcard are the base
    base = [int(p) for p in parts[:-1]]  # will fail on non-int — intentional

    # High bound: increment last base component
    high = list(base)
    high[-1] = high[-1] + 1

    # Low bound: pad with zero
    low = list(base) + [0]

    return struct(
        low = low,
        high = high,
        exact = False,
        raw = glob_str,
    )

def version_in_range(version_str, range_struct, exclude_prerelease = True):
    """
    Return True if version_str falls within range_struct [low, high).

    Args:
      version_str      - e.g. "3.5.2"
      range_struct     - result of glob_to_range()
      exclude_prerelease - if True, pre-release versions are rejected
    """
    parsed = _parse_version(version_str)

    if exclude_prerelease and parsed.prerelease:
        return False

    if range_struct.exact:
        return _version_cmp(parsed.parts, range_struct.low) == 0

    # >= low
    if _version_cmp(parsed.parts, range_struct.low) < 0:
        return False

    # < high
    if _version_cmp(parsed.parts, range_struct.high) >= 0:
        return False

    return True

def latest_in_range(versions_list, range_struct, exclude_prerelease = True):
    """
    From a list of version strings, return the highest that falls in range.
    Returns None if nothing matches.

    versions_list - list of raw version strings from Maven API
    """
    candidates = [
        v for v in versions_list
        if version_in_range(v, range_struct, exclude_prerelease)
    ]

    if not candidates:
        return None

    # Sort descending by parsed parts, return first
    # Starlark has no sort with key; implement selection sort on small lists.
    # Maven search API typically returns O(10-100) versions per artifact.
    best = candidates[0]
    best_parts = _parse_version(best).parts
    for v in candidates[1:]:
        v_parts = _parse_version(v).parts
        if _version_cmp(v_parts, best_parts) > 0:
            best = v
            best_parts = v_parts

    return best

# Public API
versions = struct(
    parse = _parse_version,
    cmp = _version_cmp,
    glob_to_range = glob_to_range,
    in_range = version_in_range,
    latest_in_range = latest_in_range,
)
