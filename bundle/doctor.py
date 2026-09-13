#!/usr/bin/env python3
"""Inspect declared project capabilities without executing or authenticating tools."""

import argparse
import json
import re
import shutil
import sys
from pathlib import Path


def validate(config):
    if (
        not isinstance(config, dict)
        or type(config.get("schema")) is not int
        or config["schema"] != 1
    ):
        raise ValueError("project configuration must use schema 1")
    for key in ("required_tools", "optional_tools", "required_files"):
        values = config.get(key, [])
        if not isinstance(values, list) or not all(
            isinstance(value, str) for value in values
        ):
            raise ValueError(f"{key} must be a list of strings")
        for value in values:
            if key.endswith("tools"):
                if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", value):
                    raise ValueError(f"invalid executable name: {value}")
            elif (
                not value
                or not value.isascii()
                or re.search(r"[\\:\x00-\x1f]", value)
                or any(
                    part in ("", ".", "..") or part.casefold() == ".git"
                    for part in value.split("/")
                )
            ):
                raise ValueError(f"invalid project path: {value}")


def inspect(root, config):
    validate(config)
    results = []
    for key, required in (("required_tools", True), ("optional_tools", False)):
        for name in config.get(key, []):
            results.append(
                {
                    "name": name,
                    "status": "available" if shutil.which(name) else "missing",
                    "required": required,
                    "authentication": "not checked",
                }
            )
    for name in config.get("required_files", []):
        path = root / name
        present = path.is_file() and path.resolve().is_relative_to(root.resolve())
        results.append(
            {
                "name": name,
                "status": "present" if present else "missing",
                "required": True,
            }
        )
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        root = args.project.resolve()
        results = inspect(
            root, json.loads((root / ".workflow/project.json").read_text())
        )
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    if args.json:
        print(
            json.dumps(
                {
                    "capabilities": results,
                    "credentials": "not checked",
                    "verification": "not run",
                    "independent_review": "not run",
                },
                indent=2,
            )
        )
    else:
        for result in results:
            requirement = "required" if result["required"] else "optional"
            print(f"{result['status']:9} {result['name']} ({requirement})")
        print(
            "Tool presence does not verify credentials, daemon health, tests, or independent review."
        )
    return int(any(r["required"] and r["status"] == "missing" for r in results))


if __name__ == "__main__":
    sys.exit(main())
