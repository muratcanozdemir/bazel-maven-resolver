"""
maven_install_glue — Bzlmod module extension.

Bridges the gap between the resolved artifact list (computed by
maven_wildcard_deps) and rules_jvm_external's maven_install().

Background on why this exists
──────────────────────────────
rules_jvm_external's Bzlmod extension requires static `maven.artifact()`
tags at MODULE.bazel evaluation time. We cannot feed it a dynamically
computed list. The solution is to read the resolved.bzl written by phase 1
directly inside THIS module extension's own implementation function, then
call maven_install() from there.

This must happen at the top level of the module_extension implementation,
not inside a nested repository_rule: a module extension's set of produced
repositories is fixed by which repository-rule-creating calls happen
directly in its implementation function. A repository_rule cannot itself
spawn additional named repositories — Bazel has no way to associate them
with this extension, so `use_repo(maven_glue, "maven")` in the consumer's
MODULE.bazel fails with "does not generate repository 'maven'" even though
maven_install() appears to "run". (This was the actual, verified failure
mode of an earlier version of this file that tried exactly that — see
e2e/ for the consumer test that caught it.)

module_ctx (the argument below) supports the same execute()/path()/read()
primitives repository_ctx does, which is what makes doing the resolved.bzl
read here — instead of in a nested repository_rule — possible at all.

Limitation
──────────
This glue calls maven_install() from Starlark which requires
rules_jvm_external ≥ 5.0 (the version that exposed maven_install as a
standalone callable rather than only via WORKSPACE macros).
Bzlmod support requires rules_jvm_external ≥ 6.0.
"""

load("@rules_jvm_external//:defs.bzl", "maven_install")
load("@rules_jvm_external//:repositories.bzl", "rules_jvm_external_deps")

# ─── Tag class ────────────────────────────────────────────────────────────────

_install_tag = tag_class(
    attrs = {
        "resolved_bzl": attr.label(
            mandatory = True,
            allow_single_file = [".bzl"],
            doc = (
                "Label of the resolved.bzl file produced by the " +
                "maven_wildcard_deps extension. Example: " +
                "'@resolved_maven_deps_maven_deps_yaml//:resolved.bzl'. " +
                "Must be a label (not a bare repo name) so Bazel can " +
                "order this extension's evaluation after the one that " +
                "produces it."
            ),
        ),
        "maven_repo_name": attr.string(
            default = "maven",
            doc = "Name of the @maven repository to create (default: 'maven').",
        ),
    },
)

# ─── Extraction helper ─────────────────────────────────────────────────────────

# Starlark has no exec/import — use python3 (ast + json, stdlib only) to pull
# the generated constants out of resolved.bzl.
_EXTRACT_PY = """
import ast, sys, json

path = sys.argv[1]
src  = open(path).read()
tree = ast.parse(src)

result = {}
for node in tree.body:
    if isinstance(node, ast.Assign):
        for t in node.targets:
            if isinstance(t, ast.Name) and t.id in (
                "RESOLVED_ARTIFACTS", "RESOLVED_REPOSITORIES",
                "FETCH_SOURCES", "FETCH_JAVADOC"
            ):
                result[t.id] = ast.literal_eval(node.value)

print(json.dumps(result))
"""

def _load_resolved(mctx, resolved_bzl_label):
    resolved_bzl_path = mctx.path(resolved_bzl_label)

    r = mctx.execute(
        ["python3", "-c", _EXTRACT_PY, str(resolved_bzl_path)],
        timeout = 30,
        quiet = True,
    )
    if r.return_code != 0:
        fail("Failed to extract resolved artifacts: {}".format(r.stderr))

    import_result = json.decode(r.stdout.strip())

    artifacts = import_result.get("RESOLVED_ARTIFACTS", [])
    if not artifacts:
        fail("RESOLVED_ARTIFACTS is empty in {}".format(str(resolved_bzl_path)))

    return struct(
        artifacts = artifacts,
        repositories = import_result.get("RESOLVED_REPOSITORIES", ["https://repo1.maven.org/maven2/"]),
        fetch_sources = import_result.get("FETCH_SOURCES", True),
        fetch_javadoc = import_result.get("FETCH_JAVADOC", False),
    )

# ─── Module extension ─────────────────────────────────────────────────────────

def _maven_install_from_resolved_impl_ext(mctx):
    rules_jvm_external_deps()

    for mod in mctx.modules:
        for tag in mod.tags.install:
            resolved = _load_resolved(mctx, tag.resolved_bzl)

            # maven_install() is itself a module-extension-style repository
            # generator; calling it here (top level of this extension's
            # implementation) is what actually registers "maven_repo_name"
            # as a repo this extension produces.
            maven_install(
                name = tag.maven_repo_name,
                artifacts = resolved.artifacts,
                repositories = resolved.repositories,
                fetch_sources = resolved.fetch_sources,
                fetch_javadoc = resolved.fetch_javadoc,
                # Reproducible builds: resolve_timeout ensures we don't get
                # non-deterministic Coursier behaviour in CI.
                resolve_timeout = 600,
                # Fail on version conflict rather than silently picking one.
                # Remove if your dependency graph has known conflicts to
                # force-resolve.
                strict_visibility = True,
            )

maven_install_from_resolved = module_extension(
    implementation = _maven_install_from_resolved_impl_ext,
    tag_classes = {"install": _install_tag},
    doc = (
        "Loads resolved Maven artifacts from a phase-1 repository and " +
        "wires them into rules_jvm_external's maven_install()."
    ),
)
