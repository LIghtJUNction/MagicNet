"""Validate active source pins in the recipe's canonical Markdown/YAML layout."""

import re
import tomllib


def single(pattern, text, label):
    matches = list(re.finditer(pattern, text, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError(f"{label} must occur exactly once in the canonical layout")
    return matches[0][1]


def active_markdown(text):
    """Exclude examples and comments before selecting canonical prose fields."""
    text = re.sub(r"<!--.*?(?:-->|\Z)", "", text, flags=re.S)
    lines, fence = [], None
    for line in text.splitlines(keepends=True):
        marker = re.match(r"^[ \t]*(`{3,}|~{3,})(.*)$", line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
        elif marker:
            fence = marker[1]
        else:
            lines.append(line)
    return "".join(lines)


def verify_source_pins(read_text, gitlink):
    """Read either working files or an immutable Git tree, never historical mentions."""
    prompt = active_markdown(read_text("recipes/magicnet/BUILD_PROMPT.md"))
    source = single(r"^- 当前维护实现为 ([^\r\n]+)$", prompt, "BUILD_PROMPT.md active source")
    match = re.match(r"`LIghtJUNction/magicnet-android@([0-9a-f]{40})`[；。]", source)
    if match is None or match[1] != gitlink:
        raise ValueError("BUILD_PROMPT.md does not record the current source gitlink")
    version = single(r"\A# 重建 MagicNet（配方 ([0-9]+\.[0-9]+\.[0-9]+)）[ \t]*$",
                     prompt, "BUILD_PROMPT.md title")
    recipe = read_text("recipes/magicnet/RECIPE.md")
    manifest = re.search(r"(?:~~~|```)toml\n(.*?)\n(?:~~~|```)", recipe, re.S)
    if manifest is None:
        raise ValueError("RECIPE.md does not contain a package identity")
    recipe_version = tomllib.loads(manifest[1])["package"]["version"]
    if version != recipe_version:
        raise ValueError("BUILD_PROMPT.md does not record the current recipe version")
    workflow = read_text(".github/workflows/release.yml")
    # Only direct uses fields of these reusable jobs count. Comments, step/run
    # examples and other jobs cannot satisfy the contract. Unsupported YAML
    # layouts fail closed; actionlint independently validates YAML semantics.
    jobs = single(r"^jobs:[ \t]*(?:#.*)?\n((?:[ \t].*\n|\n)*)", workflow, "release.yml jobs")
    for job, name in (("build", "exec.yml"), ("android", "android-kernelsu-acceptance.yml")):
        block = single(rf"^  {job}:[ \t]*(?:#.*)?\n((?: {{3,}}.*\n|[ \t]*\n)*)",
                       jobs, f"release.yml {job} job")
        value = single(r"^    uses:[ \t]*([^\r\n]+)$", block, f"release.yml {job}.uses")
        expected = f"LIghtJUNction/magicnet-android/.github/workflows/{name}@{gitlink}"
        literal = re.fullmatch(r"(?:'([^']*)'|\"([^\"]*)\"|([^\s'\"#]+))[ \t]*(?:#.*)?", value)
        if literal is None or next(group for group in literal.groups() if group is not None) != expected:
            raise ValueError(f"release.yml reusable {name} is not pinned to the current source gitlink")
