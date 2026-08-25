"""
maven_wildcard_deps — Bzlmod module extension.

Reads a YAML dependency manifest, resolves wildcard versions against
Maven Central (or a configured mirror), and registers resolved artifacts
with rules_jvm_external's maven extension.

Usage in MODULE.bazel:

  bazel_dep(name = "rules_jvm_external", version = "6.1")
  bazel_dep(name = "maven_wildcard_deps", version = "0.1.0")

  wildcard_maven = use_extension(
      "@maven_wildcard_deps//extensions:defs.bzl",
      "maven_wildcard_deps",
  )
  wildcard_maven.config(
      manifest = "//:maven_deps.yaml",
  )

  # Re-export the maven hub so consumers can use @maven//... targets
  use_repo(wildcard_maven, "maven")

Then in BUILD files:

  java_library(
      name = "my_lib",
      deps = ["@maven//:com_fasterxml_jackson_core_jackson_databind"],
  )

──────────────────────────────────────────────────────────────────────────
Design notes
──────────────────────────────────────────────────────────────────────────
1. This extension is a WRAPPER around rules_jvm_external. It does NOT
   replace Coursier-based transitive resolution. It resolves wildcards
   to pinned GAVs, then delegates to maven_install.

2. Network calls happen in a repository_rule (ctx.execute), which Bazel
   allows. They do NOT happen in the module extension evaluation phase
   itself. This is the correct Bazel architecture.

3. The resolved GAVs are written to a generated file
   (bazel-out/.../resolved_maven_deps.bzl) and then loaded by a thin
   repository rule that calls maven_install programmatically.

4. Offline/JFrog: set `offline_repo` in settings to point
   maven.install()'s repositories at your Artifactory. The search/resolve
   step still hits Maven Central (or your configured search_base_url) at
   `bazel sync` time, but artifact downloads go through JFrog.
──────────────────────────────────────────────────────────────────────────
"""

load("//extensions:maven_search.bzl", "maven_search")
load("//extensions:versions.bzl", "versions")
load("//extensions:yaml_manifest.bzl", "yaml_manifest")

# ─── Tag classes ──────────────────────────────────────────────────────────────

_config_tag = tag_class(
    attrs = {
        "manifest": attr.label(
            mandatory = True,
            allow_single_file = [".yaml", ".yml"],
            doc = "Label of the YAML dependency manifest file.",
        ),
        "search_base_url": attr.string(
            default = "https://search.maven.org",
            doc = (
                "Base URL for Maven search API. Override with your Nexus/JFrog " +
                "search endpoint if mirroring Central. " +
                "Must expose the /solrsearch/select endpoint."
            ),
        ),
        "offline_repo_url": attr.string(
            default = "",
            doc = (
                "URL of the repository to use for artifact download " +
                "(maven.install repositories list). " +
                "If empty, falls back to settings.offline_repo in the YAML, " +
                "then to Maven Central."
            ),
        ),
        "fetch_sources": attr.bool(
            default = True,
            doc = "Fetch source JARs. Passed to maven.install().",
        ),
        "fetch_javadoc": attr.bool(
            default = False,
            doc = "Fetch Javadoc JARs. Passed to maven.install().",
        ),
        "fail_on_missing": attr.bool(
            default = True,
            doc = (
                "If True (default), fail the build if no version matches a " +
                "wildcard range. If False, skip silently with a warning."
            ),
        ),
        "max_search_rows": attr.int(
            default = 200,
            doc = (
                "Rows per page requested from the Maven search API " +
                "(hard ceiling is 200 per the API docs)."
            ),
        ),
    },
    doc = "Configure the wildcard Maven dependency resolver.",
)

# ─── Repository rule: resolver ────────────────────────────────────────────────

def _resolve_wildcard_deps_impl(ctx):
    """
    Repository rule implementation.

    This is where all I/O happens:
      1. Parse the YAML manifest.
      2. For each dep with a wildcard version, scrape Maven search API.
      3. Select the best matching version.
      4. Write resolved GAVs to a .bzl file that maven_install consumes.
    """
    manifest = yaml_manifest.parse(ctx, ctx.attr.manifest)

    # Effective settings: tag attrs override YAML settings
    offline_repo = ctx.attr.offline_repo_url or manifest.settings.offline_repo
    fetch_sources = ctx.attr.fetch_sources
    fetch_javadoc = ctx.attr.fetch_javadoc
    fail_on_missing = ctx.attr.fail_on_missing
    search_base = ctx.attr.search_base_url
    max_search_rows = ctx.attr.max_search_rows

    resolved = []  # list of "group:artifact:version" strings

    for dep in manifest.dependencies:
        ga = maven_search.parse_url(dep.search_url)
        group = ga.group
        artifact = ga.artifact
        version_glob = dep.version_glob

        # Exact version — no resolution needed
        if "*" not in version_glob:
            resolved.append("{}:{}:{}".format(group, artifact, version_glob))
            continue

        # Wildcard — fetch all versions and pick best
        range_struct = versions.glob_to_range(version_glob)

        all_versions = maven_search.fetch_versions(
            ctx,
            group = group,
            artifact = artifact,
            maven_base_url = search_base,
            max_rows = max_search_rows,
        )

        best = versions.latest_in_range(
            all_versions,
            range_struct,
            exclude_prerelease = dep.exclude_prerelease,
        )

        if best == None:
            msg = (
                "No version of {}:{} matched glob '{}' (exclude_prerelease={}). ".format(
                    group,
                    artifact,
                    version_glob,
                    dep.exclude_prerelease,
                ) +
                "Available versions (first 10): {}".format(all_versions[:10])
            )
            if fail_on_missing:
                fail(msg)
            else:
                # buildifier: disable=print
                print("WARNING: " + msg)
                continue

        resolved.append("{}:{}:{}".format(group, artifact, best))

    # ── Write resolved deps as a loadable .bzl file ──────────────────────────
    # This file is loaded by the companion maven_install_from_resolved rule.
    #
    # Format: a simple Starlark list literal so it can be loaded with
    #   load("@resolved_maven_deps//:resolved.bzl", "RESOLVED_ARTIFACTS")

    artifacts_literal = "[\n" + "".join([
        '    "{}",\n'.format(gav)
        for gav in resolved
    ]) + "]"

    repos_list = [offline_repo] if offline_repo else ["https://repo1.maven.org/maven2/"]

    repos_literal = "[\n" + "".join([
        '    "{}",\n'.format(r)
        for r in repos_list
    ]) + "]"

    resolved_bzl = """# AUTO-GENERATED by maven_wildcard_deps — DO NOT EDIT
# Re-run `bazel sync` to refresh.

RESOLVED_ARTIFACTS = {artifacts}

RESOLVED_REPOSITORIES = {repos}

FETCH_SOURCES = {sources}

FETCH_JAVADOC = {javadoc}
""".format(
        artifacts = artifacts_literal,
        repos = repos_literal,
        sources = "True" if fetch_sources else "False",
        javadoc = "True" if fetch_javadoc else "False",
    )

    ctx.file("resolved.bzl", resolved_bzl)

    # Minimal BUILD to make this a valid repository
    ctx.file("BUILD.bazel", """# AUTO-GENERATED
exports_files(["resolved.bzl"])
""")

_resolve_wildcard_deps = repository_rule(
    implementation = _resolve_wildcard_deps_impl,
    attrs = {
        "manifest": attr.label(
            mandatory = True,
            allow_single_file = [".yaml", ".yml"],
        ),
        "search_base_url": attr.string(default = "https://search.maven.org"),
        "offline_repo_url": attr.string(default = ""),
        "fetch_sources": attr.bool(default = True),
        "fetch_javadoc": attr.bool(default = False),
        "fail_on_missing": attr.bool(default = True),
        "max_search_rows": attr.int(default = 200),
    },
    # Mark non-hermetic: this rule intentionally makes network calls.
    # Bazel will re-run it on `bazel sync` or when manifest changes.
    local = False,
    doc = "Resolves wildcard Maven versions by querying Maven search API.",
)

# ─── Module extension implementation ─────────────────────────────────────────

def _maven_wildcard_deps_impl(mctx):
    """
    Module extension entry point.

    Iterates over all `config` tags (one per module that uses this extension),
    creates the resolver repository rule, then calls into rules_jvm_external's
    maven extension to register the resolved artifacts.

    NOTE: rules_jvm_external's Bzlmod extension (maven) must also be loaded
    in the root MODULE.bazel. This extension generates the artifact list;
    rules_jvm_external does the actual Coursier resolution + download.
    See the example MODULE.bazel for the correct wiring.
    """

    for mod in mctx.modules:
        for tag in mod.tags.config:
            repo_name = "resolved_maven_deps_{}".format(
                tag.manifest.name.replace(".", "_").replace("-", "_").replace("/", "_"),
            )

            _resolve_wildcard_deps(
                name = repo_name,
                manifest = tag.manifest,
                search_base_url = tag.search_base_url,
                offline_repo_url = tag.offline_repo_url,
                fetch_sources = tag.fetch_sources,
                fetch_javadoc = tag.fetch_javadoc,
                fail_on_missing = tag.fail_on_missing,
                max_search_rows = tag.max_search_rows,
            )

    # The resolved.bzl files are now available as
    # @resolved_maven_deps_<name>//:resolved.bzl
    # They must be consumed by the root module's MODULE.bazel to wire
    # into rules_jvm_external. See docs/wiring.md for the pattern.

maven_wildcard_deps = module_extension(
    implementation = _maven_wildcard_deps_impl,
    tag_classes = {"config": _config_tag},
    doc = (
        "Resolves wildcard Maven versions from a YAML manifest and registers " +
        "them for use with rules_jvm_external."
    ),
)
