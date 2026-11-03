#!/usr/bin/env python3
import re
import sys


def brand_version_tag(lines, brand):
    needle = '$(KSU_VERSION_TAG)\\"'
    branded = '$(KSU_VERSION_TAG)-' + brand + '\\"'
    changed = False
    for i, line in enumerate(lines):
        if "-DKSU_VERSION_TAG=" not in line or needle not in line:
            continue
        if branded in line:
            continue
        lines[i] = line.replace(needle, branded, 1)
        changed = True
    return changed


def brand_version_full(lines, brand):
    last = -1
    has_tag_name = False
    has_version_tag = False
    for i, line in enumerate(lines):
        if re.match(r"^KSU_VERSION_FULL\s*:=", line):
            last = i
        if re.match(r"^KSU_TAG_NAME\s*:?=", line):
            has_tag_name = True
        if re.match(r"^VERSION_TAG\s*:?=", line):
            has_version_tag = True
    if last < 0:
        return False
    if has_tag_name:
        expr = "$(KSU_TAG_NAME)"
    elif has_version_tag:
        expr = "v$(VERSION_TAG)"
    else:
        return False
    line = "KSU_VERSION_FULL := " + expr + "-" + brand
    if line in lines:
        return False
    lines.insert(last + 1, line)
    return True


def main():
    if len(sys.argv) != 3:
        print("Usage: branding.py <path> <brand>")
        sys.exit(0)

    path, brand = sys.argv[1], sys.argv[2]
    try:
        with open(path) as f:
            lines = f.read().split("\n")
    except OSError:
        print("[branding] " + path + " not readable, skipping.")
        sys.exit(0)

    a = brand_version_tag(lines, brand)
    b = brand_version_full(lines, brand)

    if not (a or b):
        print("[branding] nothing to inject in " + path)
        sys.exit(0)

    with open(path, "w") as f:
        f.write("\n".join(lines))
    print("[branding] injected '" + brand + "' into " + path)


if __name__ == "__main__":
    main()
