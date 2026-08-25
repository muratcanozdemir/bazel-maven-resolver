"""Golden tests for extensions/versions.bzl — pure Starlark, no network."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//extensions:versions.bzl", "versions")

# ─── Golden vectors ────────────────────────────────────────────────────────
# (input, expected_output) pairs. Keep in sync with tests/test_version_logic.py
# if that Python mirror's behaviour is meant to match — see that file's header.

_PARSE_VERSION_CASES = [
    ("3.5.2", struct(parts = [3, 5, 2], prerelease = False)),
    ("2.15.0", struct(parts = [2, 15, 0], prerelease = False)),
    ("2.15.4-SNAPSHOT", struct(parts = [2, 15, 4], prerelease = True)),
    ("5.0.0-alpha", struct(parts = [5, 0, 0], prerelease = True)),
    ("5.0.0.RC1", struct(parts = [5, 0, 0], prerelease = True)),
    # "Final" isn't a marker this parser knows about; the non-numeric
    # segment is dropped (not zero-filled) but still flips prerelease=True.
    ("1.0-Final", struct(parts = [1], prerelease = True)),
    ("32.1.3-jre", struct(parts = [32, 1], prerelease = True)),
]

# NOTE: `high` intentionally has fewer components than `low` in some cases
# (e.g. [3, 6] rather than [3, 6, 0]) — see the comment on glob_to_range().
# _version_cmp zero-pads, so this is not a bug; these golden values pin the
# actual (correct) output shape rather than the more "obvious" padded one.
_GLOB_TO_RANGE_CASES = [
    ("3.5.*", [3, 5, 0], [3, 6], False),
    ("3.*", [3, 0], [4], False),
    ("3.5.2.*", [3, 5, 2, 0], [3, 5, 3], False),
    ("1.4.11", [1, 4, 11], None, True),
]

_VERSION_IN_RANGE_CASES = [
    # (version, glob, exclude_prerelease, expected)
    ("2.15.3", "2.15.*", True, True),
    ("2.16.0", "2.15.*", True, False),
    ("2.14.99", "2.15.*", True, False),
    ("2.15.4-SNAPSHOT", "2.15.*", True, False),
    ("2.15.4-SNAPSHOT", "2.15.*", False, True),
    ("1.4.11", "1.4.11", True, True),
    ("1.4.12", "1.4.11", True, False),
]

_LATEST_IN_RANGE_CASES = [
    (
        ["2.15.0", "2.15.1", "2.15.4", "2.15.4-SNAPSHOT", "2.16.0"],
        "2.15.*",
        True,
        "2.15.4",
    ),
    (
        ["32.1.1-jre", "32.1.2-jre", "32.1.3-android"],
        "32.*",
        True,
        None,
    ),
    (
        ["1.0.0"],
        "9.*",
        True,
        None,
    ),
]

# ─── Tests ─────────────────────────────────────────────────────────────────

def _parse_version_test(ctx):
    env = unittest.begin(ctx)
    for raw, expected in _PARSE_VERSION_CASES:
        got = versions.parse(raw)
        asserts.equals(env, expected.parts, got.parts, "parts for %s" % raw)
        asserts.equals(env, expected.prerelease, got.prerelease, "prerelease for %s" % raw)
    return unittest.end(env)

parse_version_test = unittest.make(_parse_version_test)

def _glob_to_range_test(ctx):
    env = unittest.begin(ctx)
    for glob_str, low, high, exact in _GLOB_TO_RANGE_CASES:
        got = versions.glob_to_range(glob_str)
        asserts.equals(env, low, got.low, "low for %s" % glob_str)
        asserts.equals(env, exact, got.exact, "exact for %s" % glob_str)
        if not exact:
            asserts.equals(env, high, got.high, "high for %s" % glob_str)
    return unittest.end(env)

glob_to_range_test = unittest.make(_glob_to_range_test)

def _version_in_range_test(ctx):
    env = unittest.begin(ctx)
    for version_str, glob_str, exclude_pre, expected in _VERSION_IN_RANGE_CASES:
        rng = versions.glob_to_range(glob_str)
        got = versions.in_range(version_str, rng, exclude_prerelease = exclude_pre)
        asserts.equals(
            env,
            expected,
            got,
            "in_range(%s, %s, exclude_prerelease=%s)" % (version_str, glob_str, exclude_pre),
        )
    return unittest.end(env)

version_in_range_test = unittest.make(_version_in_range_test)

def _latest_in_range_test(ctx):
    env = unittest.begin(ctx)
    for candidates, glob_str, exclude_pre, expected in _LATEST_IN_RANGE_CASES:
        rng = versions.glob_to_range(glob_str)
        got = versions.latest_in_range(candidates, rng, exclude_prerelease = exclude_pre)
        asserts.equals(env, expected, got, "latest_in_range for glob %s" % glob_str)
    return unittest.end(env)

latest_in_range_test = unittest.make(_latest_in_range_test)

def versions_test_suite(name = "versions_tests"):
    unittest.suite(
        name,
        parse_version_test,
        glob_to_range_test,
        version_in_range_test,
        latest_in_range_test,
    )
