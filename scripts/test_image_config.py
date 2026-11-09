#!/usr/bin/env python3
"""Regression checks for public image destinations and Helm wiring.

Run from the repository root: python3 -m unittest discover -s scripts -p test_image_config.py
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def bash(program, **overrides):
    env = {key: value for key, value in os.environ.items() if not key.startswith("CENTAUR_")}
    env.update(overrides)
    return subprocess.run(
        ["bash", "-euc", "source contrib/scripts/image-config.sh; centaur_image_config; " + program],
        cwd=ROOT, env=env, text=True, capture_output=True,
    )


class ImageConfigTests(unittest.TestCase):
    def test_defaults_and_ghcr_keep_latest_and_chart_tags(self):
        self.assertEqual(bash("centaur_image_ref api-rs").stdout.strip(), "centaur-api-rs:latest")
        args = bash("centaur_image_values", CENTAUR_IMAGE_SOURCE="ghcr").stdout.splitlines()
        self.assertEqual(len(args), 24)
        self.assertIn("apiRs.image.repository=ghcr.io/paradigmxyz/centaur/centaur-api-rs", args)
        self.assertIn("sandbox.image.repository=ghcr.io/paradigmxyz/centaur/centaur-agent", args)
        self.assertFalse(any(".tag=" in arg for arg in args))

    def test_nested_namespace_port_and_tag_apply_to_every_image(self):
        result = bash(
            "centaur_image_values; centaur_image_ref api-rs",
            CENTAUR_IMAGE_SOURCE="registry", CENTAUR_REGISTRY="LOCALHOST:5001",
            CENTAUR_IMAGE_NAMESPACE="Example/Team", CENTAUR_IMAGE_TAG="sha-123",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        args = result.stdout.splitlines()
        self.assertEqual(len(args), 49)
        self.assertEqual(args[-1], "localhost:5001/example/team/centaur-api-rs:sha-123")
        self.assertEqual(sum(".tag=sha-123" in arg for arg in args), 12)
        self.assertEqual(sum(".image.repository=localhost:5001/example/team/" in arg for arg in args), 12)

    def test_agent_override_is_preserved(self):
        self.assertEqual(bash("centaur_image_ref agent", CENTAUR_AGENT_IMAGE="custom-agent:test").stdout.strip(), "custom-agent:test")

    def test_reject_invalid_image_paths(self):
        for key, value in [("CENTAUR_REGISTRY", "https://host"), ("CENTAUR_IMAGE_NAMESPACE", "team/../x"), ("CENTAUR_IMAGE_TAG", "bad\nvalue")]:
            with self.subTest(key=key):
                self.assertNotEqual(bash("centaur_image_values", **{key: value}).returncode, 0)

    def test_workflow_configuration_validation(self):
        for platforms, backend, profile, valid in [
            ('["linux/amd64","linux/arm64"]', "buildx", "release", True),
            ('["linux/amd64","linux/amd64"]', "depot", "debug", False),
            ('["linux/s390x"]', "buildx", "release", False),
            ('[]', "buildx", "release", False),
            ('', "unknown", "debug", False),
            ('', "depot", "unknown", False),
        ]:
            with self.subTest(platforms=platforms, backend=backend, profile=profile), tempfile.TemporaryDirectory() as directory:
                env = dict(os.environ, GITHUB_ENV=str(Path(directory) / "env"), BUILD_BACKEND=backend, RUST_BUILD_PROFILE=profile, CENTAUR_BUILD_PLATFORMS=platforms)
                result = subprocess.run(["bash", ".github/scripts/configure-images.sh"], cwd=ROOT, env=env, capture_output=True)
                self.assertEqual(result.returncode == 0, valid)


class JustImageTests(unittest.TestCase):
    def run_recipe(self, directory, recipe, **overrides):
        directory = Path(directory)
        recorder = directory / "recorder.py"
        recorder.write_text(
            "#!/usr/bin/env python3\nimport json, os, sys\n"
            "with open(os.environ['COMMAND_LOG'], 'a') as log:\n"
            "    log.write(json.dumps(sys.argv) + '\\n')\n"
        )
        recorder.chmod(0o700)
        for tool in ["docker", "helm"]:
            (directory / tool).symlink_to(recorder)
        log = directory / "commands"
        env = {key: value for key, value in os.environ.items() if not key.startswith("CENTAUR_")}
        env.update(overrides, PATH=f"{directory}:{os.environ['PATH']}", COMMAND_LOG=str(log))
        result = subprocess.run(["just", "--no-dotenv", *recipe], cwd=ROOT, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line)[1:] for line in log.read_text().splitlines()]

    def test_default_build_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = self.run_recipe(directory, ["_build-api-rs"])
            self.assertEqual(commands, [["build", "-t", "centaur-api-rs:latest", "-f", "services/api-rs/Dockerfile", "."]])

    def test_registry_source_propagates_through_nested_just(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = self.run_recipe(directory, ["source=registry", "build-one", "console"], CENTAUR_REGISTRY="localhost:5001", CENTAUR_IMAGE_NAMESPACE="example/nested", CENTAUR_IMAGE_TAG="123")
            self.assertEqual(commands, [["build", "-t", "localhost:5001/example/nested/centaur-console:123", "-f", "services/console/Dockerfile", "services/console"]])

    def test_agent_override_propagates_through_nested_build(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = self.run_recipe(directory, ["agent_image=custom-agent:test", "build-one", "agent"])
            self.assertEqual(commands, [["build", "-t", "custom-agent:test", "--target", "sandbox", "-f", "services/sandbox/Dockerfile", "."]])

    def test_helm_modes_preserve_precedence_and_tag_behavior(self):
        for source in ["local", "ghcr", "registry"]:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                commands = self.run_recipe(directory, [f"source={source}", "deploy"], CENTAUR_IMAGE_TAG="123", CENTAUR_EXTRA_VALUES="custom.yaml")
                upgrade = commands[-1]
                self.assertEqual(upgrade[:4], ["upgrade", "--install", "centaur", "contrib/chart"])
                self.assertEqual(upgrade[-2:], ["-f", "custom.yaml"])
                self.assertEqual(any(".image.repository=" in arg for arg in upgrade), source != "local")
                self.assertEqual(any(".image.tag=123" in arg for arg in upgrade), source == "registry")

    def test_nested_default_agent_keeps_k3s_mirror_source(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = self.run_recipe(directory, ["_push-registry"], CENTAUR_AGENT_IMAGE="")
            self.assertIn(["tag", "centaur-agent:latest", "localhost:5000/library/centaur-agent:latest"], commands)

    def test_push_honors_agent_source_override(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = self.run_recipe(directory, ["push"], CENTAUR_REGISTRY="localhost:5001", CENTAUR_IMAGE_NAMESPACE="example/nested", CENTAUR_AGENT_IMAGE="custom-agent:test")
            self.assertIn(["tag", "custom-agent:test", "localhost:5001/example/nested/centaur-agent:latest"], commands)
            self.assertEqual(sum(command[0] == "push" for command in commands), 12)


class HelmImageTests(unittest.TestCase):
    def test_public_repositories_reach_runtime_image_configuration(self):
        args = bash("centaur_image_values", CENTAUR_IMAGE_SOURCE="registry", CENTAUR_REGISTRY="localhost:5001", CENTAUR_IMAGE_NAMESPACE="example/nested", CENTAUR_IMAGE_TAG="test").stdout.splitlines()
        rendered = subprocess.check_output([
            "helm", "template", "image-test", "contrib/chart", "--namespace", "image-test",
            *args,
        ], cwd=ROOT, text=True)
        try:
            import yaml
        except ImportError:
            stream = subprocess.check_output(["yq", "-o=json", "-I=0", "."], input=rendered, text=True)
            objects = [json.loads(line) for line in stream.splitlines() if line]
        else:
            objects = list(yaml.safe_load_all(rendered))
        deployments = {obj["metadata"]["name"]: obj for obj in objects if obj and obj["kind"] == "Deployment"}
        api = deployments["image-test-centaur-api-rs"]["spec"]["template"]["spec"]
        self.assertNotIn("imagePullSecrets", api)
        env = {item["name"]: item.get("value") for item in api["containers"][0]["env"]}
        self.assertNotIn("SESSION_SANDBOX_IMAGE_PULL_SECRETS", env)
        for name, image in [("SESSION_SANDBOX_IMAGE", "agent"), ("KUBERNETES_IRON_PROXY_IMAGE", "iron-proxy"), ("KUBERNETES_TOOLS_RUNNER_IMAGE", "agent")]:
            self.assertEqual(env[name], f"localhost:5001/example/nested/centaur-{image}:test")


if __name__ == "__main__":
    unittest.main()
