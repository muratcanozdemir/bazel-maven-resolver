"""Golden tests for extensions/maven_search.bzl URL parsing — no network."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//extensions:maven_search.bzl", "maven_search")

# (url, expected_group, expected_artifact)
_PARSE_URL_CASES = [
    (
        "https://search.maven.org/artifact/com.fasterxml.jackson.core/jackson-databind",
        "com.fasterxml.jackson.core",
        "jackson-databind",
    ),
    (
        "https://search.maven.org/artifact/com.fasterxml.jackson.core/jackson-databind/2.15.4/jar",
        "com.fasterxml.jackson.core",
        "jackson-databind",
    ),
    (
        "https://search.maven.org/search?q=g:org.slf4j+AND+a:slf4j-api",
        "org.slf4j",
        "slf4j-api",
    ),
    (
        "https://search.maven.org/solrsearch/select?q=g:org.slf4j+AND+a:slf4j-api&core=gav&rows=200&wt=json",
        "org.slf4j",
        "slf4j-api",
    ),
    (
        "https://search.maven.org/search?q=g%3Aorg.slf4j+AND+a%3Aslf4j-api",
        "org.slf4j",
        "slf4j-api",
    ),
    (
        # Legacy hash-fragment router. Regression test: the data lives
        # after "#", and the group/artifact values are quote-wrapped.
        'https://search.maven.org/#search|ga|1|g:"org.apache.commons"+AND+a:"commons-lang3"',
        "org.apache.commons",
        "commons-lang3",
    ),
]

def _parse_url_test(ctx):
    env = unittest.begin(ctx)
    for url, expected_group, expected_artifact in _PARSE_URL_CASES:
        got = maven_search.parse_url(url)
        asserts.equals(env, expected_group, got.group, "group for %s" % url)
        asserts.equals(env, expected_artifact, got.artifact, "artifact for %s" % url)
    return unittest.end(env)

parse_url_test = unittest.make(_parse_url_test)

def maven_search_test_suite(name = "maven_search_url_tests"):
    unittest.suite(
        name,
        parse_url_test,
    )
