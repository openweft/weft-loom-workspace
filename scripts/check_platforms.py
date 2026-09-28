#!/usr/bin/env python3
"""Refuse a platform list the base image cannot supply.

This image's final stage is a real alpine userland, so every platform the
build claims has to exist in alpine's own manifest list. Claiming one that
does not is not caught by anything else here: buildx fails late, during a
tag-gated publish, long after the branch that introduced the claim merged.
linux/loong64 sat in this workflow that way.

It asks the registry rather than running docker, so it needs no daemon, no
qemu and no privileges -- which is what lets it run on a pull request.
"""

import json
import re
import sys
import urllib.request

ACCEPT = ",".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    ]
)


def claimed_platforms(workflow: str) -> list[str]:
    """The platforms: line of the buildx step, as written."""
    m = re.search(r"^\s*platforms:\s*(\S+)\s*$", workflow, re.M)
    if not m:
        raise SystemExit("check_platforms: no `platforms:` line in the build workflow")
    return [p.strip() for p in m.group(1).split(",") if p.strip()]


def base_image(dockerfile: str) -> tuple[str, str]:
    """The FROM the FINAL stage rests on, and the tag it is pinned to.

    A build stage pinned to --platform=$BUILDPLATFORM does not constrain the
    output, so only the shipped base matters. This image has one alpine base
    and it is the shipped one; a Dockerfile that grows a second would need
    this to look at the last FROM rather than the first.
    """
    name = re.search(r"^FROM\s+([a-z0-9._/-]+):\$\{?(\w+)\}?", dockerfile, re.M)
    if not name:
        raise SystemExit("check_platforms: no parameterised FROM in the Dockerfile")
    repo, argname = name.group(1), name.group(2)
    arg = re.search(rf"^ARG\s+{argname}=(\S+)", dockerfile, re.M)
    if not arg:
        raise SystemExit(f"check_platforms: {argname} has no ARG default")
    return repo, arg.group(1)


def published_platforms(repo: str, tag: str) -> set[str]:
    if "/" not in repo:
        repo = "library/" + repo
    tok = json.load(
        urllib.request.urlopen(
            "https://auth.docker.io/token?service=registry.docker.io"
            f"&scope=repository:{repo}:pull"
        )
    )["token"]
    req = urllib.request.Request(
        f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}",
        headers={"Authorization": f"Bearer {tok}", "Accept": ACCEPT},
    )
    index = json.load(urllib.request.urlopen(req))
    out = set()
    for m in index.get("manifests", []):
        p = m.get("platform") or {}
        if p.get("os") in (None, "unknown"):
            continue
        out.add(f"{p['os']}/{p['architecture']}")
    if not out:
        raise SystemExit(
            f"check_platforms: {repo}:{tag} returned no platforms at all -- "
            "treat that as a broken probe, not as an empty answer"
        )
    return out


def main() -> int:
    workflow = open(".github/workflows/build.yml", encoding="utf-8").read()
    dockerfile = open("Dockerfile", encoding="utf-8").read()

    claimed = claimed_platforms(workflow)
    repo, tag = base_image(dockerfile)
    have = published_platforms(repo, tag)

    print(f"base            {repo}:{tag}")
    print(f"base publishes  {' '.join(sorted(have))}")
    print(f"build claims    {' '.join(claimed)}")

    missing = [p for p in claimed if p not in have]
    if missing:
        print()
        print(f"::error::{repo}:{tag} publishes no manifest for: {', '.join(missing)}")
        print(
            "The final stage of this image IS that base, so a platform it does "
            "not publish cannot be built, whatever the workflow says."
        )
        return 1
    print(f"\nall {len(claimed)} claimed platforms exist in the base image")
    return 0


if __name__ == "__main__":
    sys.exit(main())
