#!/usr/bin/env python3
"""Validate source trees and generated OpenAI skills-only plugins."""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import yaml


PLUGIN_NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\."
    r"(0|[1-9]\d*)\."
    r"(0|[1-9]\d*)"
    r"(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\."
    r"(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
COLOR_RE = re.compile(r"^#[0-9A-F]{6}$", re.IGNORECASE)
MANIFEST_FIELDS = {
    "name",
    "version",
    "description",
    "author",
    "homepage",
    "repository",
    "license",
    "keywords",
    "skills",
    "interface",
}
INTERFACE_STRING_FIELDS = {
    "displayName",
    "shortDescription",
    "longDescription",
    "developerName",
    "category",
}
INTERFACE_URL_FIELDS = {
    "websiteURL",
    "privacyPolicyURL",
    "termsOfServiceURL",
}
INTERFACE_FIELDS = (
    INTERFACE_STRING_FIELDS
    | INTERFACE_URL_FIELDS
    | {"capabilities", "defaultPrompt", "brandColor"}
)


class ValidationError(Exception):
    """A source or plugin violates the portable exporter contract."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    source = subparsers.add_parser("source")
    source.add_argument("--root", required=True)
    source.add_argument("--skill", required=True)
    source.add_argument("--name", required=True)

    plugin = subparsers.add_parser("plugin")
    plugin.add_argument("root")
    return parser.parse_args()


def is_within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def validate_source(root_value: str, skill_value: str, name: str) -> None:
    lexical_root = Path(os.path.abspath(root_value))
    lexical_skill = Path(os.path.abspath(skill_value))
    if not is_within(lexical_skill, lexical_root):
        raise ValidationError(f"skill `{name}` is outside its declared source root")

    try:
        root = lexical_root.resolve(strict=True)
        skill = lexical_skill.resolve(strict=True)
    except (FileNotFoundError, RuntimeError, OSError) as error:
        raise ValidationError(f"skill `{name}` has a missing or cyclic root: {error}") from error

    if not is_within(skill, root):
        raise ValidationError(f"skill `{name}` resolves outside its declared source root")
    if not skill.is_dir():
        raise ValidationError(f"skill `{name}` is not a directory")
    if not (skill / "SKILL.md").is_file():
        raise ValidationError(f"skill `{name}` is missing SKILL.md")

    visited: set[tuple[int, int]] = set()

    def visit(directory: Path, active: set[tuple[int, int]]) -> None:
        stat = directory.stat()
        identity = (stat.st_dev, stat.st_ino)
        if identity in active:
            raise ValidationError(f"skill `{name}` contains a directory symlink cycle at {directory}")
        if identity in visited:
            return
        visited.add(identity)
        active.add(identity)
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
            for entry in entries:
                path = Path(entry.path)
                if path.is_symlink():
                    try:
                        target = path.resolve(strict=True)
                    except (FileNotFoundError, RuntimeError, OSError) as error:
                        raise ValidationError(
                            f"skill `{name}` contains a dangling or cyclic symlink at {path}"
                        ) from error
                    if not is_within(target, root):
                        raise ValidationError(
                            f"skill `{name}` symlink `{path}` resolves outside its declared source root"
                        )
                    if target.is_dir():
                        visit(target, active)
                    elif not target.is_file():
                        raise ValidationError(
                            f"skill `{name}` symlink `{path}` does not resolve to a regular file or directory"
                        )
                elif entry.is_dir(follow_symlinks=False):
                    visit(path, active)
                elif not entry.is_file(follow_symlinks=False):
                    raise ValidationError(
                        f"skill `{name}` contains unsupported filesystem entry `{path}`"
                    )
        finally:
            active.remove(identity)

    visit(skill, set())


def require_string(payload: dict[str, Any], field: str, prefix: str = "manifest") -> str:
    value = payload.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{prefix}.{field} must be a non-empty string")
    return value


def validate_string_list(value: Any, field: str) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item.strip() for item in value
    ):
        raise ValidationError(f"{field} must be a list of non-empty strings")
    return value


def validate_https_url(value: Any, field: str) -> None:
    parsed = urlparse(value) if isinstance(value, str) else None
    if parsed is None or parsed.scheme != "https" or not parsed.netloc:
        raise ValidationError(f"{field} must be an absolute https:// URL")


def reject_todo(value: Any, path: str = "manifest") -> None:
    if isinstance(value, str) and "[TODO:" in value:
        raise ValidationError(f"{path} contains a [TODO: ...] placeholder")
    if isinstance(value, list):
        for index, item in enumerate(value):
            reject_todo(item, f"{path}[{index}]")
    if isinstance(value, dict):
        for key, item in value.items():
            reject_todo(item, f"{path}.{key}")


def validate_manifest(manifest: Any) -> None:
    if not isinstance(manifest, dict):
        raise ValidationError(".codex-plugin/plugin.json must contain an object")
    unknown = sorted(set(manifest) - MANIFEST_FIELDS)
    if unknown:
        raise ValidationError(f"manifest contains unsupported fields: {', '.join(unknown)}")
    reject_todo(manifest)

    name = require_string(manifest, "name")
    if len(name) > 64 or PLUGIN_NAME_RE.fullmatch(name) is None:
        raise ValidationError("manifest.name must be lowercase kebab-case with at most 64 characters")
    version = require_string(manifest, "version")
    if SEMVER_RE.fullmatch(version) is None:
        raise ValidationError("manifest.version must be strict semantic versioning")
    require_string(manifest, "description")
    if manifest.get("skills") != "./skills/":
        raise ValidationError('manifest.skills must be exactly "./skills/"')

    for field in ("homepage", "repository", "license"):
        if field in manifest:
            require_string(manifest, field)
    if "keywords" in manifest:
        validate_string_list(manifest["keywords"], "manifest.keywords")

    if "author" in manifest:
        author = manifest["author"]
        if not isinstance(author, dict):
            raise ValidationError("manifest.author must be an object")
        unknown_author = sorted(set(author) - {"name", "email", "url"})
        if unknown_author:
            raise ValidationError(
                f"manifest.author contains unsupported fields: {', '.join(unknown_author)}"
            )
        require_string(author, "name", "manifest.author")
        if "email" in author:
            require_string(author, "email", "manifest.author")
        if "url" in author:
            validate_https_url(author["url"], "manifest.author.url")

    if "interface" in manifest:
        interface = manifest["interface"]
        if not isinstance(interface, dict):
            raise ValidationError("manifest.interface must be an object")
        unknown_interface = sorted(set(interface) - INTERFACE_FIELDS)
        if unknown_interface:
            raise ValidationError(
                "manifest.interface contains unsupported fields: "
                + ", ".join(unknown_interface)
            )
        for field in INTERFACE_STRING_FIELDS:
            if field in interface:
                require_string(interface, field, "manifest.interface")
        for field in INTERFACE_URL_FIELDS:
            if field in interface:
                validate_https_url(interface[field], f"manifest.interface.{field}")
        if "capabilities" in interface:
            validate_string_list(interface["capabilities"], "manifest.interface.capabilities")
        if "defaultPrompt" in interface:
            prompts = validate_string_list(
                interface["defaultPrompt"], "manifest.interface.defaultPrompt"
            )
            if len(prompts) > 3 or any(len(prompt) > 128 for prompt in prompts):
                raise ValidationError(
                    "manifest.interface.defaultPrompt must contain at most 3 strings "
                    "of at most 128 characters"
                )
        if "brandColor" in interface and (
            not isinstance(interface["brandColor"], str)
            or COLOR_RE.fullmatch(interface["brandColor"]) is None
        ):
            raise ValidationError("manifest.interface.brandColor must use #RRGGBB")


def parse_frontmatter(skill_path: Path, output_name: str) -> None:
    skill_md = skill_path / "SKILL.md"
    if not skill_md.is_file() or skill_md.is_symlink():
        raise ValidationError(f"skill `{output_name}` is missing a regular SKILL.md")
    try:
        lines = skill_md.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise ValidationError(f"skill `{output_name}` SKILL.md must be UTF-8") from error
    if not lines or lines[0] != "---":
        raise ValidationError(f"skill `{output_name}` must start with YAML frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError as error:
        raise ValidationError(f"skill `{output_name}` frontmatter is not closed") from error
    try:
        frontmatter = yaml.safe_load("\n".join(lines[1:end]))
    except yaml.YAMLError as error:
        raise ValidationError(f"skill `{output_name}` frontmatter must be valid YAML") from error
    if not isinstance(frontmatter, dict):
        raise ValidationError(f"skill `{output_name}` frontmatter must be an object")

    name = frontmatter.get("name")
    if not isinstance(name, str) or len(name) > 64 or PLUGIN_NAME_RE.fullmatch(name) is None:
        raise ValidationError(
            f"skill `{output_name}` frontmatter.name must be lowercase kebab-case "
            "with at most 64 characters"
        )
    if name != output_name:
        raise ValidationError(
            f"skill `{output_name}` frontmatter.name must match its output directory"
        )
    description = frontmatter.get("description")
    if not isinstance(description, str) or not description.strip() or len(description) > 1024:
        raise ValidationError(
            f"skill `{output_name}` frontmatter.description must contain 1-1024 characters"
        )
    disable_invocation = frontmatter.get(
        "disable-model-invocation", frontmatter.get("disable_model_invocation")
    )
    if disable_invocation is not None and disable_invocation is not False:
        raise ValidationError(
            f"skill `{output_name}` frontmatter.disable-model-invocation must be false"
        )


def validate_plugin(root_value: str) -> None:
    root = Path(root_value).resolve(strict=True)
    if not root.is_dir():
        raise ValidationError("plugin root must be a directory")

    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        for entry in [*dirnames, *filenames]:
            path = Path(directory) / entry
            if path.is_symlink():
                raise ValidationError(f"generated plugin must not contain symlink `{path}`")

    manifest_path = root / ".codex-plugin" / "plugin.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise ValidationError("plugin is missing regular .codex-plugin/plugin.json")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValidationError(".codex-plugin/plugin.json must be valid UTF-8 JSON") from error
    validate_manifest(manifest)

    codex_plugin_entries = sorted((root / ".codex-plugin").iterdir())
    if codex_plugin_entries != [manifest_path]:
        raise ValidationError("only plugin.json may be stored in .codex-plugin")

    skills_root = root / "skills"
    if not skills_root.is_dir():
        raise ValidationError("plugin is missing skills directory")
    skill_entries = sorted(skills_root.iterdir(), key=lambda path: path.name)
    if not skill_entries:
        raise ValidationError("skills-only plugin must contain at least one skill")
    for skill_path in skill_entries:
        if not skill_path.is_dir():
            raise ValidationError(f"skills entry `{skill_path.name}` must be a directory")
        parse_frontmatter(skill_path, skill_path.name)


def main() -> None:
    args = parse_args()
    try:
        if args.command == "source":
            validate_source(args.root, args.skill, args.name)
        else:
            validate_plugin(args.root)
    except ValidationError as error:
        print(f"agent-skills: mkAgentPlugin: {error}", file=os.sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
