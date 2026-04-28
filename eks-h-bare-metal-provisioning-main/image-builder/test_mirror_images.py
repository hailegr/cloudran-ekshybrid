#!/usr/bin/env python3
"""Tests for mirror-images.py"""
import os
import sys
import tempfile
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, os.path.dirname(__file__))
from importlib import import_module
mirror = import_module("mirror-images")


SAMPLE_CONFIG = """\
images:
  tinkerbell-actions/writefile:
    source: quay.io/tinkerbell-actions/writefile
    tags: ["v1.0.0"]
  disk-tools:
    source: alpine
    tags: ["3.20", "3.19"]
    packages:
      - sgdisk
      - wipefs
"""


class TestLoadConfig(unittest.TestCase):
    def test_loads_images(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(SAMPLE_CONFIG)
            f.flush()
            images = mirror.load_config(f.name)
        os.unlink(f.name)
        self.assertIn("tinkerbell-actions/writefile", images)
        self.assertIn("disk-tools", images)
        self.assertEqual(images["disk-tools"]["tags"], ["3.20", "3.19"])

    def test_missing_file_raises(self):
        with self.assertRaises(FileNotFoundError):
            mirror.load_config("/nonexistent.yaml")


class TestBuildCopyPlan(unittest.TestCase):
    def setUp(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(SAMPLE_CONFIG)
            f.flush()
            self.config_path = f.name
        self.images = mirror.load_config(self.config_path)

    def tearDown(self):
        os.unlink(self.config_path)

    def test_plan_count(self):
        plan = mirror.build_copy_plan(self.images, "123.dkr.ecr.us-west-2.amazonaws.com")
        # writefile has 1 tag, disk-tools has 2 tags = 3 total
        self.assertEqual(len(plan), 3)

    def test_plan_uris(self):
        registry = "123.dkr.ecr.us-west-2.amazonaws.com"
        plan = mirror.build_copy_plan(self.images, registry)
        names = [(t.name, t.tag) for t in plan]
        self.assertIn(("tinkerbell-actions/writefile", "v1.0.0"), names)
        self.assertIn(("disk-tools", "3.20"), names)
        self.assertIn(("disk-tools", "3.19"), names)

    def test_source_uri_format(self):
        plan = mirror.build_copy_plan(self.images, "r")
        task = next(t for t in plan if t.name == "tinkerbell-actions/writefile")
        self.assertEqual(task.src, "docker://quay.io/tinkerbell-actions/writefile:v1.0.0")

    def test_dest_uri_format(self):
        plan = mirror.build_copy_plan(self.images, "123.dkr.ecr.us-west-2.amazonaws.com")
        task = next(t for t in plan if t.name == "disk-tools" and t.tag == "3.20")
        self.assertEqual(task.dst, "docker://123.dkr.ecr.us-west-2.amazonaws.com/disk-tools:3.20")

    def test_dest_uri_with_prefix(self):
        plan = mirror.build_copy_plan(self.images, "123.dkr.ecr.us-west-2.amazonaws.com", prefix="my-cluster")
        task = next(t for t in plan if t.name == "disk-tools" and t.tag == "3.20")
        self.assertEqual(task.dst, "docker://123.dkr.ecr.us-west-2.amazonaws.com/my-cluster/disk-tools:3.20")


class TestMirrorImages(unittest.TestCase):
    def setUp(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(SAMPLE_CONFIG)
            f.flush()
            self.config_path = f.name

    def tearDown(self):
        os.unlink(self.config_path)

    def test_dry_run_succeeds(self):
        rc = mirror.mirror_images(self.config_path, "test-registry", dry_run=True)
        self.assertEqual(rc, 0)

    @patch("subprocess.run")
    def test_all_succeed(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)
        rc = mirror.mirror_images(self.config_path, "test-registry")
        self.assertEqual(rc, 0)

    @patch("subprocess.run")
    def test_failure_returns_nonzero(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1, stderr="auth error")
        rc = mirror.mirror_images(self.config_path, "test-registry")
        self.assertEqual(rc, 1)

    @patch("subprocess.run")
    def test_skopeo_called_with_correct_args(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)
        mirror.mirror_images(self.config_path, "ecr.example.com")
        # First call should be skopeo copy for writefile (no packages)
        first_call = mock_run.call_args_list[0]
        self.assertEqual(first_call[0][0][0], "skopeo")
        self.assertEqual(first_call[0][0][1], "copy")
        self.assertEqual(first_call[0][0][2], "--override-arch")
        self.assertEqual(first_call[0][0][3], "amd64")

    @patch("subprocess.run")
    def test_packages_trigger_docker_build(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)
        mirror.mirror_images(self.config_path, "ecr.example.com")
        # disk-tools has packages, so docker build should be called
        docker_calls = [c for c in mock_run.call_args_list if c[0][0][0] == "docker"]
        self.assertTrue(len(docker_calls) > 0)
        self.assertEqual(docker_calls[0][0][0][1], "build")


class TestGenerateDockerfile(unittest.TestCase):
    def test_basic(self):
        df = mirror.generate_dockerfile("alpine", "3.20", ["sgdisk", "wipefs"])
        self.assertIn("FROM alpine:3.20", df)
        self.assertIn("apk add --no-cache sgdisk wipefs", df)

    def test_empty_packages(self):
        df = mirror.generate_dockerfile("alpine", "3.20", [])
        self.assertIn("FROM alpine:3.20", df)


class TestBuildCopyPlanPackages(unittest.TestCase):
    def setUp(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(SAMPLE_CONFIG)
            f.flush()
        self.images = mirror.load_config(f.name)
        os.unlink(f.name)

    def test_packages_on_task(self):
        plan = mirror.build_copy_plan(self.images, "r")
        disk_task = next(t for t in plan if t.name == "disk-tools")
        self.assertEqual(disk_task.packages, ["sgdisk", "wipefs"])

    def test_no_packages_on_plain_image(self):
        plan = mirror.build_copy_plan(self.images, "r")
        wf_task = next(t for t in plan if t.name == "tinkerbell-actions/writefile")
        self.assertEqual(wf_task.packages, [])


if __name__ == "__main__":
    unittest.main()
