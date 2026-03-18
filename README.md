# maven_wildcard_deps

A Bazel Bzlmod module extension that resolves wildcard Maven version globs
from a YAML manifest and feeds resolved pinned GAVs into `rules_jvm_external`.

## What it does

```
maven_deps.yaml
  └─ version: "2.15.*"
        │
        ▼
  Maven search API  (search.maven.org/solrsearch/select)
        │
        ▼
  Version list: [2.15.0, 2.15.1, ..., 2.15.4, 2.15.4-SNAPSHOT, ...]
        │
        ▼ glob_to_range("2.15.*") → [2.15.0, 2.16.0)
          latest_in_range → "2.15.4"
        │
        ▼
  @resolved_maven_deps_*//:resolved.bzl
        │
        ▼
  rules_jvm_external maven_install()
        │
        ▼
  Coursier resolves full transitive graph
        │
        ▼
  @maven//:com_fasterxml_jackson_core_jackson_databind
```

## Architecture

Two-phase design, required by Bzlmod constraints:

**Phase 1 — wildcard resolution** (`maven_wildcard_deps` extension)
- Runs as a `repository_rule` (I/O allowed)
- Parses YAML, queries Maven search API via `python3 -c ...` inline script
- Writes `resolved.bzl` with pinned GAV list

**Phase 2 — Coursier resolution** (`maven_install_from_resolved` extension)
- Loads `resolved.bzl` from phase 1
- Calls `rules_jvm_external`'s `maven_install()` with pinned list
- Coursier handles full transitive dependency resolution and download

This split is necessary because `rules_jvm_external`'s Bzlmod extension
requires static `maven.artifact()` tags at module evaluation time; dynamic
lists can only be computed in `repository_rule` implementations.

## Requirements

- Bazel 6.x+ (Bzlmod stable)
- `rules_jvm_external` ≥ 6.0 (Bzlmod support)
- `python3` on the build host with `PyYAML` installed
- Network access to `search.maven.org` at `bazel sync` time
  (artifact downloads are redirected through `offline_repo` if configured)

Install PyYAML on build hosts:
```sh
pip3 install pyyaml
# or in your nix/docker image
```

## YAML manifest format

```yaml
settings:
  offline_repo: "https://artifactory.example.com/artifactory/libs-release"
  fetch_sources: true
  fetch_javadoc: false
  exclude_prerelease: true   # global default

dependencies:
  - name: jackson-databind
    search_url: https://search.maven.org/artifact/com.fasterxml.jackson.core/jackson-databind
    version: "2.15.*"        # resolves to latest in [2.15.0, 2.16.0)

  - name: slf4j-api
    search_url: https://search.maven.org/search?q=g:org.slf4j+AND+a:slf4j-api
    version: "2.*"           # resolves to latest in [2.0.0, 3.0.0)

  - name: logback-classic
    search_url: https://search.maven.org/artifact/ch.qos.logback/logback-classic
    version: "1.4.11"        # exact version, no resolution

  - name: guava
    search_url: https://search.maven.org/artifact/com.google.guava/guava
    version: "32.*"
    exclude_prerelease: false  # per-dep override
```

Supported `search_url` shapes:
- `https://search.maven.org/artifact/<group>/<artifact>`
- `https://search.maven.org/artifact/<group>/<artifact>/<version>/jar`
- `https://search.maven.org/search?q=g:<group>+AND+a:<artifact>`
- `https://search.maven.org/solrsearch/select?q=g:<group>+AND+a:<artifact>&...`
- URL-encoded variants (`g%3A`, `a%3A`)

## MODULE.bazel wiring

```starlark
bazel_dep(name = "rules_jvm_external", version = "6.1")
bazel_dep(name = "maven_wildcard_deps", version = "0.1.0")

# Phase 1: resolve wildcards
wildcard_maven = use_extension(
    "@maven_wildcard_deps//extensions:defs.bzl",
    "maven_wildcard_deps",
)
wildcard_maven.config(
    manifest         = "//:maven_deps.yaml",
    offline_repo_url = "https://artifactory.example.com/artifactory/libs-release",
    fetch_sources    = True,
)
use_repo(wildcard_maven, "resolved_maven_deps_maven_deps_yaml")

# Phase 2: feed into rules_jvm_external
maven_glue = use_extension(
    "@maven_wildcard_deps//extensions:maven_install_glue.bzl",
    "maven_install_from_resolved",
)
maven_glue.install(
    resolved_repo   = "@resolved_maven_deps_maven_deps_yaml",
    maven_repo_name = "maven",
)
use_repo(maven_glue, "maven")
```

## Using resolved deps in BUILD files

```starlark
java_library(
    name = "my_lib",
    srcs = glob(["src/main/java/**/*.java"]),
    deps = [
        "@maven//:com_fasterxml_jackson_core_jackson_databind",
        "@maven//:org_slf4j_slf4j_api",
    ],
)
```

Target name format (rules_jvm_external convention):
`group_dots_to_underscores:artifact_dashes_to_underscores`

## JFrog / offline-repo wiring

The `offline_repo_url` (or `settings.offline_repo` in YAML) is passed to
`maven_install(repositories = [...])`. This tells Coursier to download
artifacts from your Artifactory instead of Maven Central.

The **search/resolve step** still queries `search.maven.org` at sync time.
If your environment has no external internet access at all, you have two
options:

1. **Pre-resolve**: Run `python3 tests/integration_smoke.py` on a machine
   with internet access, commit `resolved.bzl` to your repo, and load it
   directly (bypassing phase 1).

2. **Mirror the search API**: Point `search_base_url` at a Nexus/JFrog
   instance that exposes a compatible `/solrsearch/select` endpoint.
   JFrog Artifactory Pro exposes this via its search REST API.

## Running the smoke test

Tests URL parsing and version resolution against live Maven Central:

```sh
pip3 install pyyaml
python3 tests/integration_smoke.py
```

## Running Bazel unit tests

Tests pure Starlark logic (no network, no I/O):

```sh
bazel test //tests:versions_tests
bazel test //tests:maven_search_url_tests
```

## Known limitations / honest caveats

1. **PyYAML host dependency**: The YAML parsing step requires PyYAML on the
   build host. There is no pure-Starlark YAML parser. If this is unacceptable,
   convert your manifest to JSON (which Starlark can decode natively).

2. **`ctx.execute` not hermetic**: The network call breaks Bazel's hermetic
   build guarantee. This is intentional and standard practice for dependency
   resolution (same trade-off as `maven_install` itself). Mitigate by:
   - Committing the generated `resolved.bzl` to VCS and only re-running
     on explicit `bazel sync`.
   - Using a fixed `search_base_url` pointing to your controlled Nexus.

3. **Pagination ceiling**: Maven search API returns max 200 rows per page.
   For artifacts with >200 versions (rare but possible), we paginate.
   If the API changes its pagination behaviour, bump `MAVEN_MAX_ROWS` env var.

4. **Version comparator is minimal**: The Starlark comparator handles
   numeric dotted versions and common pre-release markers. It does not
   implement the full Maven version ordering spec (e.g. `1.0-Final` vs
   `1.0.0`). If you need full Maven ordering, the comparison step should
   be delegated to a `python3 -c` call using `packaging.version`.

5. **rules_jvm_external strict_visibility**: Enabled by default. Remove
   `strict_visibility = True` from `maven_install_glue.bzl` if your
   dep graph has known version conflicts you need to force-resolve.
