import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).parents[1]
BASE_FILE = "docker-compose.yml"
INSTANCE_AI_FILE = "docker-compose.instance-ai.yml"
SELF_HOSTED_FILE = "docker-compose.ai-sandbox.yml"
SYSBOX_FILE = "docker-compose.ai-sandbox.sysbox.yml"
PRIVILEGED_FILE = "docker-compose.ai-sandbox.privileged.yml"
DAYTONA_FILE = "docker-compose.ai-daytona.yml"
PODMAN_FILE = "docker-compose.podman.yml"


def docker_compose_available():
    if shutil.which("docker") is None:
        return False
    return subprocess.run(
        ["docker", "compose", "version"],
        cwd=PROJECT_DIR,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0


@unittest.skipUnless(docker_compose_available(), "Docker Compose v2 is required")
class InstanceAiComposeTests(unittest.TestCase):
    self_hosted_environment = {
        "ENABLE_AI_ASSISTANT": "true",
        "N8N_DISABLED_MODULES": "",
        "N8N_INSTANCE_AI_SANDBOX_ENABLED": "true",
        "N8N_INSTANCE_AI_SANDBOX_PROVIDER": "n8n-sandbox",
        "SANDBOX_API_KEYS": "n8n-to-api-secret",
        "N8N_SANDBOX_SERVICE_API_KEY": "n8n-to-api-secret",
        "SANDBOX_API_RUNNER_REGISTRATION_TOKEN": "registration-secret",
        "SANDBOX_RUNNER_REGISTRATION_TOKEN": "registration-secret",
        "SANDBOX_API_RUNNER_API_KEY": "api-to-runner-secret",
        "SANDBOX_RUNNER_API_KEYS": "api-to-runner-secret",
        "SEARXNG_SECRET": "searxng-secret",
    }

    def render(self, *files, environment=None, env_file=".env.example", unset_environment=()):
        command = ["docker", "compose", "--env-file", str(env_file)]
        for compose_file in files:
            command.extend(["-f", compose_file])
        command.extend(["config", "--format", "json"])

        process_environment = os.environ.copy()
        for name in unset_environment:
            process_environment.pop(name, None)
        process_environment.update(environment or {})
        result = subprocess.run(
            command,
            cwd=PROJECT_DIR,
            env=process_environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_self_hosted_stack_is_internal_and_uses_sysbox(self):
        config = self.render(
            BASE_FILE,
            INSTANCE_AI_FILE,
            SELF_HOSTED_FILE,
            SYSBOX_FILE,
            environment=self.self_hosted_environment,
        )
        services = config["services"]

        for service in ("sandbox-certs", "sandbox-api", "sandbox-runner-1", "searxng"):
            self.assertIn(service, services)
            self.assertNotIn("ports", services[service])

        self.assertEqual(services["sandbox-certs"]["network_mode"], "none")
        self.assertEqual(
            services["sandbox-certs"]["image"],
            "n8nio/n8n-sandbox-service-api:1.1.1",
        )
        self.assertEqual(
            services["sandbox-api"]["image"],
            "n8nio/n8n-sandbox-service-api:1.1.1",
        )
        self.assertEqual(
            services["sandbox-runner-1"]["image"],
            "n8nio/n8n-sandbox-service-runner-dind:1.1.1",
        )
        self.assertEqual(
            services["searxng"]["image"],
            "ghcr.io/searxng/searxng:2026.8.28-a30b2d474",
        )
        self.assertIn("/tls-work", services["sandbox-certs"]["tmpfs"])
        certificate_command = " ".join(services["sandbox-certs"]["command"])
        self.assertNotIn("--world-readable", certificate_command)
        self.assertIn("Existing role-specific mTLS material is complete", certificate_command)
        self.assertIn("refusing an uncoordinated CA rotation", certificate_command)
        self.assertIn("/tls-work/api/. /api-tls/", certificate_command)
        self.assertIn("/tls-work/runner/. /runner-tls/", certificate_command)

        api_tls_mount = next(
            volume for volume in services["sandbox-api"]["volumes"] if volume["target"] == "/tls"
        )
        runner_tls_mount = next(
            volume for volume in services["sandbox-runner-1"]["volumes"] if volume["target"] == "/tls"
        )
        self.assertEqual(api_tls_mount["source"], "sandbox_api_tls")
        self.assertEqual(runner_tls_mount["source"], "sandbox_runner_tls")
        self.assertNotEqual(api_tls_mount["source"], runner_tls_mount["source"])
        self.assertTrue(api_tls_mount["read_only"])
        self.assertTrue(runner_tls_mount["read_only"])

        self.assertEqual(services["sandbox-runner-1"]["runtime"], "sysbox-runc")
        self.assertNotIn("privileged", services["sandbox-runner-1"])
        self.assertIn("healthcheck", services["sandbox-api"])
        self.assertIn("healthcheck", services["sandbox-runner-1"])

        n8n_environment = services["n8n"]["environment"]
        self.assertEqual(services["n8n"]["build"]["args"]["N8N_VERSION"], "2.36.8")
        self.assertEqual(
            services["n8n-worker-runner"]["build"]["args"]["N8N_VERSION"],
            "2.36.8",
        )
        self.assertIn(
            "FROM n8nio/runners:${N8N_VERSION}",
            (PROJECT_DIR / "Dockerfile.runner").read_text(),
        )
        self.assertIn("instance-ai", n8n_environment["N8N_ENABLED_MODULES"].split(","))
        self.assertNotIn("instance-ai", n8n_environment["N8N_DISABLED_MODULES"].split(","))
        # Compose represents an unresolved passthrough as null in config and
        # omits it from the container environment at create time.
        self.assertIsNone(n8n_environment["N8N_INSTANCE_AI_MODEL"])
        self.assertIsNone(n8n_environment["N8N_INSTANCE_AI_MODEL_API_KEY"])
        self.assertEqual(n8n_environment["N8N_INSTANCE_AI_SANDBOX_PROVIDER"], "n8n-sandbox")
        self.assertEqual(n8n_environment["N8N_SANDBOX_SERVICE_URL"], "http://sandbox-api:8080")
        self.assertEqual(n8n_environment["N8N_SANDBOX_SERVICE_API_KEY"], "n8n-to-api-secret")
        self.assertEqual(n8n_environment["N8N_INSTANCE_AI_SEARXNG_URL"], "http://searxng:8080")

        api_environment = services["sandbox-api"]["environment"]
        runner_environment = services["sandbox-runner-1"]["environment"]
        self.assertEqual(
            runner_environment["SANDBOX_RUNNER_DOCKER_SANDBOX_IMAGE"],
            "n8nio/n8n-sandbox-service-sandbox:1.1.0",
        )
        self.assertEqual(runner_environment["SANDBOX_RUNNER_REGISTRATION_GRPC_CA_FILE"], "/tls/ca.crt")
        self.assertEqual(runner_environment["SANDBOX_RUNNER_REGISTRATION_GRPC_CERT_FILE"], "/tls/grpc-client.crt")
        self.assertEqual(runner_environment["SANDBOX_RUNNER_CONTROL_GRPC_TLS_CERT_FILE"], "/tls/control-grpc-server.crt")
        self.assertEqual(api_environment["SANDBOX_API_KEYS"], n8n_environment["N8N_SANDBOX_SERVICE_API_KEY"])
        self.assertEqual(
            api_environment["SANDBOX_API_RUNNER_REGISTRATION_TOKEN"],
            runner_environment["SANDBOX_RUNNER_REGISTRATION_TOKEN"],
        )
        self.assertEqual(api_environment["SANDBOX_API_RUNNER_API_KEY"], runner_environment["SANDBOX_RUNNER_API_KEYS"])

    def test_privileged_mode_is_explicit_and_separate(self):
        config = self.render(
            BASE_FILE,
            INSTANCE_AI_FILE,
            SELF_HOSTED_FILE,
            PRIVILEGED_FILE,
            environment=self.self_hosted_environment,
        )
        runner = config["services"]["sandbox-runner-1"]
        self.assertTrue(runner["privileged"])
        self.assertNotIn("runtime", runner)

    def test_ai_secrets_do_not_leak_to_workers_or_webhooks(self):
        config = self.render(
            BASE_FILE,
            INSTANCE_AI_FILE,
            SELF_HOSTED_FILE,
            SYSBOX_FILE,
            environment=self.self_hosted_environment,
        )
        services = config["services"]
        forbidden_prefixes = (
            "N8N_INSTANCE_AI_",
            "N8N_SANDBOX_",
            "DAYTONA_",
            "INSTANCE_AI_",
            "SANDBOX_API_",
            "SANDBOX_RUNNER_",
            "SEARXNG_",
        )
        for service_name in ("n8n-webhook", "n8n-worker", "n8n-worker-runner"):
            environment = services[service_name].get("environment", {})
            leaked = [key for key in environment if key.startswith(forbidden_prefixes)]
            self.assertEqual(leaked, [], f"{service_name} received {leaked}")
            self.assertNotIn("N8N_ENABLED_MODULES", environment)

        api_environment = services["sandbox-api"]["environment"]
        self.assertFalse(any(key.startswith("N8N_INSTANCE_AI_") for key in api_environment))
        self.assertFalse(any(key.startswith("DB_") for key in api_environment))

        all_environment_keys = {
            key
            for service in services.values()
            for key in service.get("environment", {})
        }
        self.assertNotIn("N8N_INSTANCE_AI_SANDBOX_API_URL", all_environment_keys)
        self.assertNotIn("N8N_INSTANCE_AI_SANDBOX_API_KEY", all_environment_keys)

    def test_daytona_has_no_local_sandbox_services(self):
        environment = {
            "ENABLE_AI_ASSISTANT": "true",
            "N8N_DISABLED_MODULES": "",
            "N8N_INSTANCE_AI_SANDBOX_ENABLED": "true",
            "N8N_INSTANCE_AI_SANDBOX_PROVIDER": "daytona",
            "N8N_INSTANCE_AI_MODEL": "anthropic/claude-opus-4-8",
            "N8N_INSTANCE_AI_MODEL_API_KEY": "model-secret",
            "DAYTONA_API_URL": "https://app.daytona.io/api",
            "DAYTONA_API_KEY": "daytona-secret",
        }
        config = self.render(
            BASE_FILE,
            INSTANCE_AI_FILE,
            DAYTONA_FILE,
            environment=environment,
        )
        services = config["services"]

        for service in ("sandbox-certs", "sandbox-api", "sandbox-runner-1", "searxng"):
            self.assertNotIn(service, services)

        n8n_environment = services["n8n"]["environment"]
        self.assertEqual(n8n_environment["N8N_INSTANCE_AI_SANDBOX_PROVIDER"], "daytona")
        self.assertEqual(n8n_environment["N8N_INSTANCE_AI_MODEL"], "anthropic/claude-opus-4-8")
        self.assertEqual(n8n_environment["DAYTONA_API_KEY"], "daytona-secret")
        self.assertNotIn("N8N_SANDBOX_SERVICE_API_KEY", n8n_environment)

        for service_name in ("n8n-webhook", "n8n-worker"):
            self.assertNotIn("DAYTONA_API_KEY", services[service_name].get("environment", {}))

    def test_searxng_json_format_is_enabled(self):
        settings = (PROJECT_DIR / "searxng-settings.yml").read_text()
        self.assertIn("formats:", settings)
        self.assertIn("- json", settings)

    def test_default_stack_hard_disables_instance_ai(self):
        config = self.render(BASE_FILE)
        for service_name in ("n8n", "n8n-webhook", "n8n-worker"):
            disabled_modules = config["services"][service_name]["environment"]["N8N_DISABLED_MODULES"]
            self.assertIn("instance-ai", disabled_modules.split(","))

    def test_env_example_supports_plain_compose_commands(self):
        config = self.render(unset_environment=("COMPOSE_FILE",))
        self.assertIn("n8n", config["services"])
        self.assertNotIn("sandbox-api", config["services"])

    def test_legacy_env_without_disabled_modules_is_safe(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".env") as legacy_env:
            legacy_env.write(
                "\n".join(
                    line
                    for line in (PROJECT_DIR / ".env.example").read_text().splitlines()
                    if not line.startswith("N8N_DISABLED_MODULES=")
                )
            )
            legacy_env.flush()
            config = self.render(
                BASE_FILE,
                env_file=legacy_env.name,
                unset_environment=("N8N_DISABLED_MODULES",),
            )

        for service_name in ("n8n", "n8n-webhook", "n8n-worker"):
            disabled_modules = config["services"][service_name]["environment"]["N8N_DISABLED_MODULES"]
            self.assertIn("instance-ai", disabled_modules.split(","))

    def test_podman_override_uses_wizard_socket_without_relabeling_it(self):
        config = self.render(BASE_FILE, PODMAN_FILE, environment={"DOCKER_SOCK": "/run/user/1234/podman/podman.sock"})
        autoscaler = config["services"]["n8n-autoscaler"]
        socket_mount = next(volume for volume in autoscaler["volumes"] if volume["target"] == "/var/run/docker.sock")
        self.assertEqual(socket_mount["source"], "/run/user/1234/podman/podman.sock")
        self.assertNotIn("Z", socket_mount.get("bind", {}).get("selinux", ""))
        self.assertIn("label=disable", autoscaler["security_opt"])


class SetupWizardHelperTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp_directory.name)
        self.env_file = self.directory / ".env"
        old_secret = "a" * 64
        new_secret = "b" * 64
        old_runner_secret = "c" * 64
        new_runner_secret = "d" * 64
        self.env_file.write_text(
            "\n".join(
                (
                    "COMPOSE_FILE=docker-compose.yml:custom.yml",
                    "ENABLE_AI_ASSISTANT=true",
                    "N8N_ENABLED_MODULES=insights",
                    "N8N_DISABLED_MODULES=insights,instance-ai",
                    "N8N_INSTANCE_AI_SANDBOX_PROVIDER=n8n-sandbox",
                    "N8N_SANDBOX_ISOLATION=sysbox",
                    f"SANDBOX_API_KEYS={old_secret},{new_secret}",
                    f"N8N_SANDBOX_SERVICE_API_KEY={old_secret},{new_secret}",
                    f"SANDBOX_RUNNER_API_KEYS={old_runner_secret},{new_runner_secret}",
                    f"SANDBOX_API_RUNNER_API_KEY={old_runner_secret}",
                    "",
                )
            )
        )

    def tearDown(self):
        self.temp_directory.cleanup()

    def run_helpers(self):
        script = PROJECT_DIR / "n8n-setup.sh"
        shell = r'''
source "$1"
cd "$2"
set_env_value "ENABLE_AI_ASSISTANT" "true"
ensure_csv_value "N8N_ENABLED_MODULES" "instance-ai"
remove_csv_value "N8N_DISABLED_MODULES" "instance-ai"
set_env_value "NEW_WIZARD_KEY" "new-value"
ensure_client_key_in_list "SANDBOX_API_KEYS" "N8N_SANDBOX_SERVICE_API_KEY"
ensure_secret_pair "SANDBOX_API_RUNNER_REGISTRATION_TOKEN" "SANDBOX_RUNNER_REGISTRATION_TOKEN"
ensure_client_key_in_list "SANDBOX_RUNNER_API_KEYS" "SANDBOX_API_RUNNER_API_KEY"
ensure_default_value "N8N_VERSION" "2.36.8"
ensure_default_value "N8N_SANDBOX_SERVICE_VERSION" "1.1.1"
ensure_default_value "N8N_SANDBOX_IMAGE_VERSION" "1.1.0"
ensure_default_value "SEARXNG_VERSION" "2026.8.28-a30b2d474"
printf '%s\n' "$(compose_file_list docker)"
'''
        environment = os.environ.copy()
        environment["TERM"] = "xterm"
        return subprocess.run(
            ["bash", "-c", shell, "wizard-test", str(script), str(self.directory)],
            env=environment,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()

    def parse_env(self):
        values = {}
        for line in self.env_file.read_text().splitlines():
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
        return values

    def test_old_env_is_upgraded_idempotently_and_preserves_secrets(self):
        first_list = self.run_helpers()
        first_values = self.parse_env()
        second_list = self.run_helpers()
        second_values = self.parse_env()

        expected_files = ":".join(
            (
                "docker-compose.yml",
                "docker-compose.instance-ai.yml",
                "docker-compose.ai-sandbox.yml",
                "docker-compose.ai-sandbox.sysbox.yml",
                "custom.yml",
            )
        )
        self.assertEqual(first_list, expected_files)
        self.assertEqual(second_list, expected_files)
        self.assertEqual(first_values, second_values)
        self.assertEqual(first_values["SANDBOX_API_KEYS"], f"{'a' * 64},{'b' * 64}")
        self.assertEqual(first_values["N8N_ENABLED_MODULES"], "insights,instance-ai")
        self.assertEqual(first_values["N8N_DISABLED_MODULES"], "insights")
        self.assertEqual(first_values["N8N_SANDBOX_SERVICE_API_KEY"], "b" * 64)
        self.assertEqual(first_values["N8N_VERSION"], "2.36.8")
        self.assertEqual(first_values["N8N_SANDBOX_SERVICE_VERSION"], "1.1.1")
        self.assertEqual(first_values["N8N_SANDBOX_IMAGE_VERSION"], "1.1.0")
        self.assertEqual(first_values["SEARXNG_VERSION"], "2026.8.28-a30b2d474")
        self.assertEqual(first_values["SANDBOX_RUNNER_API_KEYS"], f"{'c' * 64},{'d' * 64}")
        self.assertEqual(first_values["SANDBOX_API_RUNNER_API_KEY"], "c" * 64)
        self.assertEqual(
            first_values["SANDBOX_API_RUNNER_REGISTRATION_TOKEN"],
            first_values["SANDBOX_RUNNER_REGISTRATION_TOKEN"],
        )
        self.assertEqual(self.env_file.read_text().count("NEW_WIZARD_KEY="), 1)

    def test_runtime_identity_includes_engine_mode_and_socket(self):
        script = PROJECT_DIR / "n8n-setup.sh"
        shell = r'''
source "$1"
runtime_identity_changed docker rootless /run/user/1000/docker.sock docker rootless /run/user/1000/docker.sock && exit 10
runtime_identity_changed docker rootless /run/user/1000/docker.sock docker rootful /var/run/docker.sock || exit 11
runtime_identity_changed docker rootful /var/run/docker.sock docker rootful /run/docker.sock || exit 12
runtime_identity_changed docker rootful /var/run/docker.sock podman rootful /run/podman/podman.sock || exit 13
'''
        environment = os.environ.copy()
        environment["TERM"] = "xterm"
        result = subprocess.run(
            ["bash", "-c", shell, "identity-test", str(script)],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


class SystemdComposeSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp_directory.name)
        self.compose_files = (
            BASE_FILE,
            INSTANCE_AI_FILE,
            SELF_HOSTED_FILE,
            SYSBOX_FILE,
        )
        for compose_file in self.compose_files:
            (self.directory / compose_file).touch()
        (self.directory / ".env").write_text(
            "\n".join(
                (
                    f"COMPOSE_FILE={':'.join(self.compose_files)}",
                    "ENABLE_AI_ASSISTANT=true",
                    "N8N_INSTANCE_AI_SANDBOX_PROVIDER=n8n-sandbox",
                    "",
                )
            )
        )

    def tearDown(self):
        self.temp_directory.cleanup()

    def run_build(self, *, rootless=False):
        script = PROJECT_DIR / "generate-systemd.sh"
        shell = r'''
source "$1"
PROJECT_DIR="$2"
RUNTIME=docker
ROOTLESS="$3"
build_compose_files >/dev/null
printf '%s\n' "$COMPOSE_FILES"
'''
        return subprocess.run(
            [
                "bash",
                "-c",
                shell,
                "systemd-test",
                str(script),
                str(self.directory),
                "true" if rootless else "false",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_systemd_reuses_the_wizard_compose_file_list(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = " ".join(
            f"-f {self.directory / compose_file}" for compose_file in self.compose_files
        )
        self.assertEqual(result.stdout.strip(), expected)

    def test_systemd_rejects_self_hosted_sandbox_on_rootless_docker(self):
        result = self.run_build(rootless=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires rootful Docker", result.stderr)

    def test_generated_unit_reads_current_compose_file_and_restarts_when_active(self):
        script = (PROJECT_DIR / "generate-systemd.sh").read_text()
        self.assertIn("ExecStartPre=${stack_script} pull", script)
        self.assertIn("ExecStart=${stack_script} up", script)
        self.assertIn("ExecStop=${stack_script} down", script)
        self.assertIn("After=network-online.target docker.service podman.socket", script)
        self.assertIn('"${systemctl_command[@]}" is-active --quiet "${PROJECT_NAME}.service"', script)
        self.assertIn('systemctl --user is-active --quiet "${PROJECT_NAME}.service"', script)

        wrapper = PROJECT_DIR / "compose-stack.sh"
        self.assertTrue(os.access(wrapper, os.X_OK))
        wrapper_text = wrapper.read_text()
        self.assertIn('RUNTIME=$(get_env_value "CONTAINER_RUNTIME" "")', wrapper_text)
        self.assertIn('CONFIGURED_MODE=$(get_env_value "CONTAINER_RUNTIME_MODE" "")', wrapper_text)
        self.assertIn('export DOCKER_HOST="unix://${CONFIGURED_SOCKET}"', wrapper_text)
        self.assertIn('active daemon identity differs from .env', wrapper_text)
        self.assertIn('wait_for_command "Docker" docker info', wrapper_text)
        self.assertIn('"${COMPOSE_COMMAND[@]}" up -d --build --remove-orphans', wrapper_text)

    def test_user_unit_does_not_require_system_scope_docker_service(self):
        script = (PROJECT_DIR / "generate-systemd.sh").read_text()
        self.assertNotIn("Requires=docker.service", script)

    def test_rootful_engines_use_a_system_unit(self):
        script = (PROJECT_DIR / "generate-systemd.sh").read_text()
        self.assertIn('if [ "$ROOTLESS" = true ]; then', script)
        self.assertNotIn('if [ "$EUID" -eq 0 ] && [ "$ROOTLESS" = false ]; then', script)
        self.assertIn('sudo install -m 0644 "$service_temp_file" "$service_file"', script)

    def test_generator_refuses_a_changed_runtime_mode_and_socket(self):
        fake_bin = self.directory / "bin"
        fake_bin.mkdir()
        fake_docker = fake_bin / "docker"
        fake_docker.write_text(
            """#!/bin/bash
case "${1:-} ${2:-}" in
  "context show") echo default ;;
  "context inspect") echo unix:///var/run/docker.sock ;;
esac
exit 0
"""
        )
        fake_docker.chmod(0o755)
        (self.directory / ".env").write_text(
            "\n".join(
                (
                    "CONTAINER_RUNTIME=docker",
                    "CONTAINER_RUNTIME_MODE=rootless",
                    "DOCKER_SOCK=/run/user/1000/docker.sock",
                    "SETUP_COMPLETED=true",
                    "",
                )
            )
        )
        shell = r'''
source "$1"
PROJECT_DIR="$2"
detect_runtime
'''
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
        result = subprocess.run(
            [
                "bash",
                "-c",
                shell,
                "identity-generator-test",
                str(PROJECT_DIR / "generate-systemd.sh"),
                str(self.directory),
            ],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("active daemon does not match", result.stderr)

    def test_deferred_systemd_activation_includes_scope_cutover(self):
        script = (PROJECT_DIR / "generate-systemd.sh").read_text()
        deferred_branch = script.split(
            'echo -e "${YELLOW}Service file created but not enabled.${NC}"',
            maxsplit=1,
        )[1]
        self.assertIn('${user_systemctl_display} disable --now ${PROJECT_NAME}.service', deferred_branch)
        self.assertIn('${systemctl_display} disable --now ${PROJECT_NAME}.service', deferred_branch)
        self.assertIn('${systemctl_display} enable --now ${PROJECT_NAME}.service', deferred_branch)
        self.assertIn('loginctl enable-linger $(id -un)', deferred_branch)

    def test_generator_persists_synthesized_compose_file_list(self):
        (self.directory / ".env").write_text(
            "\n".join(
                (
                    "COMPOSE_FILE=",
                    "ENABLE_AI_ASSISTANT=true",
                    "N8N_INSTANCE_AI_SANDBOX_PROVIDER=n8n-sandbox",
                    "N8N_SANDBOX_ISOLATION=sysbox",
                    "",
                )
            )
        )
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(
            line.split("=", 1)
            for line in (self.directory / ".env").read_text().splitlines()
            if "=" in line and not line.startswith("#")
        )
        self.assertEqual(values["COMPOSE_FILE"], ":".join(self.compose_files))


if __name__ == "__main__":
    unittest.main()
