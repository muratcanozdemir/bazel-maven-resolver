#!/usr/bin/env python3
"""
Golden tests for the Python mirror of the Starlark version/URL logic in
tests/integration_smoke.py (which itself mirrors extensions/versions.bzl
and extensions/maven_search.bzl).

Pure logic only — no network, no PyYAML dependency. Keep the cases here in
sync with tests/versions_test.bzl and tests/maven_search_test.bzl; a
divergence between the two implementations is exactly the bug class this
file exists to catch.

Run: python3 tests/test_version_logic.py
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from integration_smoke import glob_to_range, in_range, latest_in_range, parse_url


class ParseUrlTest(unittest.TestCase):
    def test_artifact_path(self):
        self.assertEqual(
            parse_url("https://search.maven.org/artifact/com.fasterxml.jackson.core/jackson-databind"),
            ("com.fasterxml.jackson.core", "jackson-databind"),
        )

    def test_artifact_path_with_version_suffix(self):
        self.assertEqual(
            parse_url("https://search.maven.org/artifact/com.fasterxml.jackson.core/jackson-databind/2.15.4/jar"),
            ("com.fasterxml.jackson.core", "jackson-databind"),
        )

    def test_search_query(self):
        self.assertEqual(
            parse_url("https://search.maven.org/search?q=g:org.slf4j+AND+a:slf4j-api"),
            ("org.slf4j", "slf4j-api"),
        )

    def test_solrsearch_query(self):
        self.assertEqual(
            parse_url(
                "https://search.maven.org/solrsearch/select?q=g:org.slf4j+AND+a:slf4j-api&core=gav&rows=200&wt=json"
            ),
            ("org.slf4j", "slf4j-api"),
        )

    def test_url_encoded_query(self):
        self.assertEqual(
            parse_url("https://search.maven.org/search?q=g%3Aorg.slf4j+AND+a%3Aslf4j-api"),
            ("org.slf4j", "slf4j-api"),
        )

    def test_legacy_hash_fragment_with_quotes(self):
        # Regression test: the fragment used to be stripped before parsing,
        # and quoted values used to be truncated to "" by the quote char
        # being treated as a value terminator.
        self.assertEqual(
            parse_url(
                'https://search.maven.org/#search|ga|1|g:"org.apache.commons"+AND+a:"commons-lang3"'
            ),
            ("org.apache.commons", "commons-lang3"),
        )

    def test_unparseable_raises(self):
        with self.assertRaises(ValueError):
            parse_url("https://search.maven.org/")


class VersionRangeTest(unittest.TestCase):
    def test_glob_to_range_minor(self):
        rng = glob_to_range("3.5.*")
        self.assertEqual(rng["low"], [3, 5, 0])
        self.assertEqual(rng["high"], [3, 6])

    def test_glob_to_range_major(self):
        rng = glob_to_range("3.*")
        self.assertEqual(rng["low"], [3, 0])
        self.assertEqual(rng["high"], [4])

    def test_glob_to_range_exact(self):
        rng = glob_to_range("1.4.11")
        self.assertTrue(rng["exact"])
        self.assertEqual(rng["low"], [1, 4, 11])

    def test_in_range_excludes_prerelease_by_default(self):
        rng = glob_to_range("2.15.*")
        self.assertTrue(in_range("2.15.3", rng))
        self.assertFalse(in_range("2.15.4-SNAPSHOT", rng))
        self.assertTrue(in_range("2.15.4-SNAPSHOT", rng, exclude_pre=False))
        self.assertFalse(in_range("2.16.0", rng))
        self.assertFalse(in_range("2.14.99", rng))

    def test_latest_in_range(self):
        rng = glob_to_range("2.15.*")
        candidates = ["2.15.0", "2.15.1", "2.15.4", "2.15.4-SNAPSHOT", "2.16.0"]
        self.assertEqual(latest_in_range(candidates, rng), "2.15.4")

    def test_latest_in_range_no_match(self):
        rng = glob_to_range("9.*")
        self.assertIsNone(latest_in_range(["1.0.0"], rng))


if __name__ == "__main__":
    unittest.main()
