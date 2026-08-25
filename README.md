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

## Repository layout

```
MODULE.bazel              this module's own identity (name/version) + test-only deps
extensions/                the module extension itself — what consumers load via @maven_wildcard_deps//extensions:...
  defs.bzl                   phase 1: maven_wildcard_deps extension
  maven_install_glue.bzl     phase 2: maven_install_from_resolved extension
  maven_search.bzl           Maven search API client + search_url parsing
  versions.bzl               glob -> range -> latest-match version logic
  yaml_manifest.bzl          YAML manifest parsing
tests/                     golden tests — no network (bazel test //tests/...)
  versions_test.bzl, maven_search_test.bzl   Starlark (bazel_skylib unittest)
  test_version_logic.py                      Python mirror of the same cases
  integration_smoke.py                       live Maven Central smoke test (network)
e2e/                       nested Bazel workspace; consumes this module the way a
                           real project would (local_path_override), exercising the
                           full pipeline against live Maven Central + real Coursier
```

## Architecture

Two-phase design, required by Bzlmod constraints:

**Phase 1 — wildcard resolution** (`maven_wildcard_deps` extension)
- Runs as a `repository_rule` (I/O allowed)
- Parses YAML, queries Maven search API via `python3 -c ...` inline script
- Writes `resolved.bzl` with pinned GAV list

**Phase 2 — Coursier resolution** (`maven_install_from_resolved` extension)
- Reads `resolved.bzl` from phase 1 directly inside its own module
  extension implementation (`module_ctx` supports the same
  `execute()`/`path()` primitives a `repository_rule`'s `ctx` does)
- Calls `rules_jvm_external`'s `maven_install()` with the pinned list —
  from that same top-level call site, not from a nested `repository_rule`
- Coursier handles full transitive dependency resolution and download

This split is necessary because `rules_jvm_external`'s Bzlmod extension
requires static `maven.artifact()` tags at module evaluation time, and our
list is only known after phase 1's network call. Calling `maven_install()`
from *inside* a nested `repository_rule` (an earlier, broken version of
this glue did that) doesn't work: a module extension's set of produced
repositories is fixed by which repository-generating calls happen directly
in its own implementation function, so `use_repo(maven_glue, "maven")`
fails with "does not generate repository 'maven'" even though
`maven_install()` appears to run. See `e2e/` for a live consumer test that
exercises this end to end.

## Requirements

- Bazel 6.x–7.x with Bzlmod (verified against 7.4.1; Bazel 8/9's
  `rules_java` currently breaks generated `@maven//...` targets for
  unrelated reasons — see `e2e/.bazelversion`)
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
    exclude_prerelease: false  # required — see gotcha below
```

> **Gotcha:** every published Guava version ends in a `-jre` or `-android`
> flavor suffix (e.g. `32.1.3-jre`). This resolver treats *any* non-numeric
> version segment as a prerelease marker (not just recognized ones like
> `-SNAPSHOT`/`-rc`), so with the default `exclude_prerelease: true`, a
> wildcard glob against Guava will never match anything and `bazel sync`
> will fail with "No version ... matched glob". Set
> `exclude_prerelease: false` for Guava (or any artifact whose releases
> always carry a flavor/classifier suffix).

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
    resolved_bzl     = "@resolved_maven_deps_maven_deps_yaml//:resolved.bzl",
    maven_repo_name  = "maven",
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

The same cases are mirrored in Python against `tests/integration_smoke.py`'s
helper functions, to catch the two implementations drifting apart:

```sh
python3 tests/test_version_logic.py -v
```

## Running the full pipeline end-to-end

`e2e/` is a separate, nested Bazel workspace (its own `MODULE.bazel`) that
depends on this module via `local_path_override`, the same way a real
consumer would via `bazel_dep`. It runs phase 1 (live search), phase 2
(`maven_install`/Coursier), and compiles a trivial `java_library` against
the resolved artifacts — the only way to actually validate the module
extensions work, since `bazel test //tests/...` above never loads
`defs.bzl` or `maven_install_glue.bzl`.

```sh
cd e2e
bazel build //:smoke
bazel query "@maven//..."   # inspect what got resolved
```

Requires network access; not run as part of `bazel test //...` at the repo
root (see `.github/workflows/ci.yml`'s `live-integration` job, which runs
it as a separate, non-blocking job).

## CI

`.github/workflows/ci.yml` runs three jobs on every push/PR:
- `format` — `buildifier -mode=check` over all `.bzl`/`BUILD.bazel`/`MODULE.bazel` files
- `unit-tests` — the offline golden tests above (required to pass)
- `live-integration` — the live smoke test + `e2e/` build (`continue-on-error`,
  since it depends on Maven Central being up)

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
   If the API changes its pagination behaviour, pass `max_search_rows` to
   `wildcard_maven.config()` (it's a Starlark/tag attribute, not an actual
   shell environment variable — it gets threaded into the search script's
   `MAVEN_MAX_ROWS` env var internally).

4. **Version comparator is minimal**: The Starlark comparator handles
   numeric dotted versions and common pre-release markers. It does not
   implement the full Maven version ordering spec (e.g. `1.0-Final` vs
   `1.0.0`). If you need full Maven ordering, the comparison step should
   be delegated to a `python3 -c` call using `packaging.version`.

5. **rules_jvm_external strict_visibility**: Enabled by default. Remove
   `strict_visibility = True` from `maven_install_glue.bzl` if your
   dep graph has known version conflicts you need to force-resolve.
