"""
Minimal YAML parser for the Maven dependency manifest.

Starlark has no YAML library. We use ctx.execute(["python3", "-c", ...])
to parse YAML and emit JSON, then parse the JSON in Starlark using
json.decode() (available since Bazel 4.x).

Expected YAML schema:

  dependencies:
    - name: jackson-databind               # human label, used in error messages
      search_url: https://search.maven.org/artifact/com.fasterxml.jackson.core/jackson-databind
      version: "2.15.*"
      exclude_prerelease: true             # optional, default true

    - name: slf4j-api
      search_url: https://search.maven.org/search?q=g:org.slf4j+AND+a:slf4j-api
      version: "2.*"

    - name: commons-lang3
      search_url: https://search.maven.org/artifact/org.apache.commons/commons-lang3
      version: "3.12.0"                    # exact version also allowed

  settings:
    offline_repo: https://artifactory.example.com/artifactory/libs-release
    fetch_sources: true
    fetch_javadoc: false
    exclude_prerelease: true               # global default; per-dep overrides this

Notes:
  - Repository configuration is intentionally single-valued: `offline_repo`
    in settings is the only repository fed to maven.install(). There is no
    `repositories` list in this schema — Coursier resolution always uses
    either that one offline mirror or Maven Central, never a merged set.
  - `version` supports "X.Y.*" glob only. Exact versions pass through unchanged.
  - Per-dep `exclude_prerelease` overrides global setting.
"""

_YAML_TO_JSON_PY = """
import json
import sys

try:
    import yaml
except ImportError:
    # yaml not available — fall back to minimal hand-rolled parser
    # This handles only the subset of YAML we care about.
    # If this is insufficient, install PyYAML: pip3 install pyyaml
    print(json.dumps({"__error__": "PyYAML not available; install it: pip3 install pyyaml"}))
    sys.exit(0)

path = sys.argv[1]
with open(path) as f:
    data = yaml.safe_load(f)

print(json.dumps(data))
"""

def _parse_yaml(ctx, yaml_path):
    """
    Parse the YAML manifest via python3+yaml, return a Starlark dict.

    Requires PyYAML on the host. If absent, fails with actionable message.
    """
    result = ctx.execute(
        ["python3", "-c", _YAML_TO_JSON_PY, yaml_path],
        timeout = 30,
        quiet = True,
    )

    if result.return_code != 0:
        fail("Failed to parse YAML at '{}': {}".format(yaml_path, result.stderr))

    raw = result.stdout.strip()
    if not raw:
        fail("Empty output parsing YAML at '{}'".format(yaml_path))

    data = json.decode(raw)

    if "__error__" in data:
        fail(
            "YAML parsing failed: {}\n".format(data["__error__"]) +
            "Fix: run `pip3 install pyyaml` on your build host, or add it to your toolchain.",
        )

    return data

def _validate_dep(dep, idx):
    """Validate a single dependency entry, fail loudly with index for context."""
    if "search_url" not in dep:
        fail("dependencies[{}] missing required field 'search_url'".format(idx))
    if "version" not in dep:
        fail("dependencies[{}] missing required field 'version'".format(idx))

def parse_manifest(ctx, yaml_label):
    """
    Load and validate the dependency manifest YAML.

    Args:
      ctx        - repository rule context
      yaml_label - Label pointing to the YAML file (e.g. Label("//:deps.yaml"))

    Returns struct:
      .dependencies  - list of dep structs
      .settings      - settings struct
    """
    yaml_path = str(ctx.path(yaml_label))
    data = _parse_yaml(ctx, yaml_path)

    # --- settings ---
    raw_settings = data.get("settings", {})
    settings = struct(
        offline_repo = raw_settings.get("offline_repo", ""),
        fetch_sources = raw_settings.get("fetch_sources", True),
        fetch_javadoc = raw_settings.get("fetch_javadoc", False),
        exclude_prerelease = raw_settings.get("exclude_prerelease", True),
    )

    # --- dependencies ---
    deps = []
    raw_deps = data.get("dependencies", [])
    for idx, d in enumerate(raw_deps):
        _validate_dep(d, idx)
        deps.append(struct(
            name = d.get("name", "dep_{}".format(idx)),
            search_url = d["search_url"],
            version_glob = str(d["version"]),
            exclude_prerelease = d.get("exclude_prerelease", settings.exclude_prerelease),
        ))

    if not deps:
        fail("No dependencies found in manifest")

    return struct(
        dependencies = deps,
        settings = settings,
    )

# Public API
yaml_manifest = struct(
    parse = parse_manifest,
)
