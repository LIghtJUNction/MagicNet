"""Validate active source pins in the recipe's canonical Markdown/YAML layout."""

import re
import tomllib

SOFTWARE_VERSION = r"v[0-9]+\.[0-9]+\.[0-9]+"
RELEASE_TAG = (
    re.escape("https://github.com/LIghtJUNction/MagicNet/releases/tag/")
    + rf"(?P<tag>{SOFTWARE_VERSION})"
)
RELEASE_PAIR = (
    rf"\[`?(?P<version>{SOFTWARE_VERSION})[ \t]*/[ \t]*"
    rf"(?P<code>[1-9][0-9]*)`?\]\({RELEASE_TAG}\)"
)
RELEASE_NOTES = rf"docs/releases/(?P<notes>{SOFTWARE_VERSION})\.md"
README_GITLINK_FIELDS = {
    "README.md": (
        r"^[ \t]*\|[ \t]*Fixed implementation commit[ \t]*\|[ \t]*"
        r"`(?P<gitlink>[0-9a-f]{40})`[ \t]*\|"
    ),
    "README.en.md": r"current gitlink:[ \t]*`(?P<gitlink>[0-9a-f]{40})`",
    "README.ru.md": r"текущий gitlink:[ \t]*`(?P<gitlink>[0-9a-f]{40})`",
}
README_RELEASE_FIELDS = {
    "README.md": (
        ("Android release badge",
         rf"\[!\[Android release\]\(https://img\.shields\.io/badge/Android-"
         rf"(?P<version>{SOFTWARE_VERSION})%20%2[Ff]%20(?P<code>[1-9][0-9]*)"
         rf"-[^)\r\n]+\)\]\({RELEASE_TAG}\)"),
        ("published package",
         rf"^[ \t]*\|[ \t]*Published Android package[ \t]*\|[ \t]*{RELEASE_PAIR}"),
        ("installation notes",
         rf"^[ \t]*\|[ \t]*Install and use MagicNet[ \t]*\|[^\r\n]*?"
         rf"\[(?P<version>{SOFTWARE_VERSION})[ \t]+installation notes\]\({RELEASE_NOTES}\)"),
    ),
    "README.en.md": (("current Android release",
                      rf"current Android release:[ \t]*{RELEASE_PAIR}\.[ \t\r\n]*"
                      rf"\[Release and installation notes\]\({RELEASE_NOTES}\)"),),
    "README.ru.md": (("current Android release",
                      rf"текущий выпуск Android:[ \t]*{RELEASE_PAIR}\.[ \t\r\n]*"
                      rf"\[Установка и изменения\]\({RELEASE_NOTES}\)"),),
}


def single(pattern, text, label):
    matches = list(re.finditer(pattern, text, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError(f"{label} must occur exactly once in the canonical layout")
    return matches[0]


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


def verify_readme_pins(read_text, gitlink, version, code):
    """Refuse stale active README pins even when history still mentions the live values."""
    expected_code = str(code)
    for path, gitlink_pattern in README_GITLINK_FIELDS.items():
        text = active_markdown(read_text(path))
        recorded = single(gitlink_pattern, text, f"{path} active gitlink")["gitlink"]
        if recorded != gitlink:
            raise ValueError(f"{path} does not record the current source gitlink")
        for label, pattern in README_RELEASE_FIELDS[path]:
            groups = single(pattern, text, f"{path} current {label} field").groupdict()
            if any(groups.get(key) not in (None, version) for key in ("version", "tag", "notes")):
                raise ValueError(f"{path} does not record the published updater version")
            if groups.get("code") not in (None, expected_code):
                raise ValueError(f"{path} does not record the published updater version")


def verify_source_pins(read_text, gitlink):
    """Read either working files or an immutable Git tree, never historical mentions."""
    prompt = active_markdown(read_text("recipes/magicnet/BUILD_PROMPT.md"))
    source = single(r"^- 当前维护实现为 ([^\r\n]+)$", prompt, "BUILD_PROMPT.md active source")[1]
    match = re.match(r"`LIghtJUNction/magicnet-android@([0-9a-f]{40})`[；。]", source)
    if match is None or match[1] != gitlink:
        raise ValueError("BUILD_PROMPT.md does not record the current source gitlink")
    version = single(r"\A# 重建 MagicNet（配方 ([0-9]+\.[0-9]+\.[0-9]+)）[ \t]*$",
                     prompt, "BUILD_PROMPT.md title")[1]
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
    jobs = single(r"^jobs:[ \t]*(?:#.*)?\n((?:[ \t].*\n|\n)*)", workflow, "release.yml jobs")[1]
    for job, name in (("build", "exec.yml"), ("android", "android-kernelsu-acceptance.yml")):
        block = single(rf"^  {job}:[ \t]*(?:#.*)?\n((?: {{3,}}.*\n|[ \t]*\n)*)",
                       jobs, f"release.yml {job} job")[1]
        value = single(r"^    uses:[ \t]*([^\r\n]+)$", block, f"release.yml {job}.uses")[1]
        expected = f"LIghtJUNction/magicnet-android/.github/workflows/{name}@{gitlink}"
        literal = re.fullmatch(r"(?:'([^']*)'|\"([^\"]*)\"|([^\s'\"#]+))[ \t]*(?:#.*)?", value)
        if literal is None or next(group for group in literal.groups() if group is not None) != expected:
            raise ValueError(f"release.yml reusable {name} is not pinned to the current source gitlink")
