"""
Maven Central search API client for Bazel repository rules.

Uses ctx.execute() with an inline Python 3 script.
No external Python packages required — urllib only.

The Maven search API endpoint:
  https://search.maven.org/solrsearch/select
  ?q=g:<group>+AND+a:<artifact>
  &core=gav
  &rows=200
  &wt=json

- `core=gav`   returns one row per version, not one per GA
- `rows=200`   pagination: if a library has >200 versions, we walk pages
- `wt=json`    JSON response

Rate limiting: search.maven.org has informal rate limiting.
We add a configurable delay between calls (default 0.5s).
"""

# Inline Python script executed via ctx.execute(["python3", "-c", SCRIPT]).
# Receives args via environment variables to avoid shell-quoting landmines.
# Outputs newline-separated version strings to stdout, errors to stderr.
#
# ENV vars consumed:
#   MAVEN_GROUP      - groupId
#   MAVEN_ARTIFACT   - artifactId
#   MAVEN_MAX_ROWS   - max rows per page (default 200, max 200 per API docs);
#                      set by fetch_versions()'s max_rows argument, not by the
#                      calling shell's environment.
#   MAVEN_BASE_URL   - override for internal Nexus/JFrog (default search.maven.org)

_FETCH_VERSIONS_PY = """
import json
import os
import sys
import time
import urllib.request
import urllib.error
import urllib.parse

group    = os.environ["MAVEN_GROUP"]
artifact = os.environ["MAVEN_ARTIFACT"]
max_rows = int(os.environ.get("MAVEN_MAX_ROWS", "200"))
base_url = os.environ.get("MAVEN_BASE_URL", "https://search.maven.org")

versions = []
start    = 0

while True:
    params = urllib.parse.urlencode({
        "q":    "g:{} AND a:{}".format(group, artifact),
        "core": "gav",
        "rows": max_rows,
        "wt":   "json",
        "start": start,
    })
    url = "{}/solrsearch/select?{}".format(base_url, params)

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "bazel-maven-wildcard/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print("HTTP {} fetching {}".format(e.code, url), file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print("Error fetching {}: {}".format(url, e), file=sys.stderr)
        sys.exit(1)

    docs = data.get("response", {}).get("docs", [])
    if not docs:
        break

    for doc in docs:
        v = doc.get("v") or doc.get("version")
        if v:
            versions.append(v)

    num_found = data.get("response", {}).get("numFound", 0)
    start    += len(docs)
    if start >= num_found:
        break

    # Be a polite client; avoid hammering the API on paginated requests
    time.sleep(0.3)

# One version per line — consumed by Starlark ctx.execute().stdout
print("\\n".join(versions))
"""

def _parse_search_url(url):
    """
    Extract groupId and artifactId from a search.maven.org URL.

    Supported URL shapes:
      https://search.maven.org/search?q=g:com.fasterxml.jackson.core+AND+a:jackson-databind
      https://search.maven.org/artifact/com.fasterxml.jackson.core/jackson-databind
      https://search.maven.org/#search|ga|1|g:"org.apache.commons"+AND+a:"commons-lang3"
      https://search.maven.org/solrsearch/select?q=g:org.slf4j+AND+a:slf4j-api&...

    Returns struct(group=..., artifact=...) or fails loudly.
    """
    if not url:
        fail("Empty Maven search URL")

    group = None
    artifact = None

    # Pattern 1: /artifact/<group>/<artifact> path. Only look at the part
    # before any query string or fragment — the path is what matters here,
    # and either suffix could coincidentally contain "/artifact/" text.
    path_part = url
    for sep in ["?", "#"]:
        if sep in path_part:
            path_part = path_part.split(sep)[0]

    if "/artifact/" in path_part:
        # e.g. /artifact/com.fasterxml.jackson.core/jackson-databind
        after = path_part.split("/artifact/", 1)[1]
        path_parts = after.split("/")
        if len(path_parts) >= 2:
            group = path_parts[0]
            artifact = path_parts[1]

    # Pattern 2: g:/a: params, either in a query string or in a legacy
    # hash-fragment URL (search.maven.org's old client-side router used
    # "#search|ga|1|g:...+AND+a:..."). Search the *whole* URL — for the
    # fragment form, the fragment is exactly where this data lives, so it
    # must not be stripped first.
    if not group and ("g:" in url or "g%3A" in url):
        # Normalise URL-encoded colons
        q_part = url.replace("g%3A", "g:").replace("a%3A", "a:")

        # Extract g:<value>. Quotes are NOT treated as a value terminator
        # here — an opening quote would otherwise truncate the value to
        # empty (e.g. g:"org.apache.commons" -> ""). Any wrapping quotes
        # are stripped afterwards instead.
        if "g:" in q_part:
            after_g = q_part.split("g:", 1)[1]

            # Value ends at space, +, or &
            for sep in ["+", "&", " "]:
                if sep in after_g:
                    after_g = after_g.split(sep)[0]
            group = after_g.strip().strip('"').strip("'")

        # Extract a:<value>
        if "a:" in q_part:
            after_a = q_part.split("a:", 1)[1]
            for sep in ["+", "&", " "]:
                if sep in after_a:
                    after_a = after_a.split(sep)[0]
            artifact = after_a.strip().strip('"').strip("'")

    if not group or not artifact:
        fail(
            "Cannot parse groupId/artifactId from URL: '{}'\n".format(url) +
            "Supported shapes:\n" +
            "  https://search.maven.org/artifact/<group>/<artifact>\n" +
            "  https://search.maven.org/search?q=g:<group>+AND+a:<artifact>\n",
        )

    return struct(group = group, artifact = artifact)

def fetch_versions(ctx, group, artifact, maven_base_url = "https://search.maven.org", max_rows = 200):
    """
    Fetch all available versions for a GA coordinate from Maven search API.

    Args:
      ctx           - Bazel repository rule context (needs ctx.execute)
      group         - Maven groupId
      artifact      - Maven artifactId
      maven_base_url - Base URL; override for JFrog/Nexus
      max_rows      - Rows per search API page (max 200 per API docs)

    Returns list of version strings, or fails.
    """
    env = {
        "MAVEN_GROUP": group,
        "MAVEN_ARTIFACT": artifact,
        "MAVEN_BASE_URL": maven_base_url,
        "MAVEN_MAX_ROWS": str(max_rows),
    }

    result = ctx.execute(
        ["python3", "-c", _FETCH_VERSIONS_PY],
        environment = env,
        timeout = 120,  # 2 min; large artifacts (e.g. jackson) have many versions
        quiet = True,
    )

    if result.return_code != 0:
        fail(
            "Failed to fetch versions for {}:{} from {}\n".format(group, artifact, maven_base_url) +
            "stderr: {}".format(result.stderr),
        )

    versions = [
        v.strip()
        for v in result.stdout.strip().split("\n")
        if v.strip()
    ]

    if not versions:
        fail("No versions found for {}:{} at {}".format(group, artifact, maven_base_url))

    return versions

# Public API
maven_search = struct(
    parse_url = _parse_search_url,
    fetch_versions = fetch_versions,
)
