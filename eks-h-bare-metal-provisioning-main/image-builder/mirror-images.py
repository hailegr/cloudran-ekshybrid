#!/usr/bin/env python3
"""Mirror container images to ECR using skopeo, with optional package builds.

Reads image-builder/mirror-images.yaml and for each image either:
- Copies it from the source registry (skopeo copy), or
- Builds a custom image with pre-installed packages (docker build + skopeo push)

Required env: AWS_ACCOUNT_ID, AWS_DEFAULT_REGION
Optional env: ECR_PREFIX
"""
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
import yaml


@dataclass
class CopyTask:
    name: str
    tag: str
    src: str
    dst: str
    arch: str
    packages: list = field(default_factory=list)


def load_config(config_path):
    with open(config_path) as f:
        return yaml.safe_load(f)["images"]


def build_copy_plan(images, registry, prefix=""):
    """Return list of CopyTask objects."""
    plan = []
    for name, img in images.items():
        source = img["source"]
        arch = img.get("arch", "amd64")
        packages = img.get("packages", [])
        repo_name = f"{prefix}/{name}" if prefix else name
        for tag in img["tags"]:
            plan.append(CopyTask(
                name=name,
                tag=tag,
                src=f"docker://{source}:{tag}",
                dst=f"docker://{registry}/{repo_name}:{tag}",
                arch=arch,
                packages=packages,
            ))
    return plan


def generate_dockerfile(source, tag, packages):
    """Generate a Dockerfile that installs packages on top of a base image."""
    pkgs = " ".join(packages)
    return f"FROM {source}:{tag}\nRUN apk add --no-cache {pkgs}\n"


def build_and_push(task, source, dry_run=False):
    """Build a custom image with packages and push via docker."""
    dockerfile = generate_dockerfile(source, task.tag, task.packages)
    if dry_run:
        print(f"  DRY RUN build: {task.name}:{task.tag} packages={task.packages}")
        return True

    with tempfile.TemporaryDirectory() as tmpdir:
        df_path = os.path.join(tmpdir, "Dockerfile")
        with open(df_path, "w") as f:
            f.write(dockerfile)

        # dst is "docker://registry/repo:tag", extract the registry URI
        remote_tag = task.dst.removeprefix("docker://")
        r = subprocess.run(
            ["docker", "build", "--platform", f"linux/{task.arch}",
             "-t", remote_tag, tmpdir],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            print(f"BUILD FAILED: {r.stderr}", file=sys.stderr)
            return False

        r = subprocess.run(
            ["docker", "push", remote_tag],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            print(f"PUSH FAILED: {r.stderr}", file=sys.stderr)
            return False
    return True


def copy_image(task, dry_run=False):
    """Copy an image via skopeo."""
    if dry_run:
        print(f"  DRY RUN copy: {task.name}:{task.tag}")
        return True

    cmd = ["skopeo", "copy"]
    if task.arch == "all":
        cmd.append("--all")
    else:
        cmd += ["--override-arch", task.arch]
    cmd += [task.src, task.dst]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"FAILED: {r.stderr}", file=sys.stderr)
        return False
    return True


def mirror_images(config_path, registry, prefix="", dry_run=False):
    images = load_config(config_path)
    plan = build_copy_plan(images, registry, prefix)
    failed = []

    for task in plan:
        source = images[task.name]["source"]
        if task.packages:
            print(f"Building {task.dst} (packages: {task.packages})")
            ok = build_and_push(task, source, dry_run)
        else:
            print(f"Copying {task.src} -> {task.dst} (arch={task.arch})")
            ok = copy_image(task, dry_run)

        if ok:
            print(f"OK: {task.name}:{task.tag}")
        else:
            failed.append(f"{task.name}:{task.tag}")

    if failed:
        print(f"Failed to mirror: {failed}", file=sys.stderr)
        return 1
    print(f"All {len(plan)} images mirrored to {registry}")
    return 0


if __name__ == "__main__":
    account = os.environ["AWS_ACCOUNT_ID"]
    region = os.environ["AWS_DEFAULT_REGION"]
    prefix = os.environ.get("ECR_PREFIX", "")
    registry = f"{account}.dkr.ecr.{region}.amazonaws.com"
    config_path = os.path.join(os.path.dirname(__file__), "mirror-images.yaml")
    sys.exit(mirror_images(config_path, registry, prefix))
