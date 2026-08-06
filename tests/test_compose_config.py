import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import sys


sys.path.insert(0, str(Path(__file__).parents[1] / "autoscaler"))

from compose_config import (  # noqa: E402
    CONFIG_FILES_LABEL,
    WORKING_DIR_LABEL,
    build_compose_command,
    parse_compose_file_paths,
    resolve_compose_context,
)


class FakeContainers:
    def __init__(self, labels=None, error=None, matches=None):
        self.labels = labels or {}
        self.error = error
        self.matches = matches or []
        self.requested_name = None
        self.filters = None

    def get(self, name):
        self.requested_name = name
        if self.error:
            raise self.error
        return SimpleNamespace(labels=self.labels)

    def list(self, *, all, filters):
        self.filters = filters
        return self.matches


class ComposeConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.project_directory = Path(self.temp_directory.name)
        self.base_file = self.project_directory / "docker-compose.yml"
        self.override_file = self.project_directory / "docker-compose.override.yml"
        self.base_file.touch()
        self.override_file.touch()

    def tearDown(self):
        self.temp_directory.cleanup()

    def test_reuses_ordered_files_from_compose_labels(self):
        labels = {
            CONFIG_FILES_LABEL: f"{self.base_file},{self.override_file}",
            WORKING_DIR_LABEL: str(self.project_directory),
        }
        containers = FakeContainers(labels)

        files, project_directory, source = resolve_compose_context(
            SimpleNamespace(containers=containers),
            hostname="autoscaler-id",
            legacy_file_path="/app/docker-compose.yml",
        )

        self.assertEqual(files, [str(self.base_file), str(self.override_file)])
        self.assertEqual(project_directory, str(self.project_directory))
        self.assertEqual(source, CONFIG_FILES_LABEL)
        self.assertEqual(containers.requested_name, "autoscaler-id")

    def test_explicit_file_list_takes_precedence(self):
        containers = FakeContainers(error=AssertionError("labels should not be inspected"))

        files, project_directory, source = resolve_compose_context(
            SimpleNamespace(containers=containers),
            explicit_file_paths=f"{self.base_file}:{self.override_file}",
            explicit_project_directory=str(self.project_directory),
            path_separator=":",
        )

        self.assertEqual(files, [str(self.base_file), str(self.override_file)])
        self.assertEqual(project_directory, str(self.project_directory))
        self.assertEqual(source, "COMPOSE_FILE_PATHS")
        self.assertIsNone(containers.requested_name)

    def test_relative_label_paths_use_labeled_working_directory(self):
        labels = {
            CONFIG_FILES_LABEL: "docker-compose.yml,docker-compose.override.yml",
            WORKING_DIR_LABEL: str(self.project_directory),
        }

        files, _, _ = resolve_compose_context(
            SimpleNamespace(containers=FakeContainers(labels))
        )

        self.assertEqual(files, [str(self.base_file), str(self.override_file)])

    def test_finds_container_by_compose_labels_when_hostname_lookup_fails(self):
        labels = {
            CONFIG_FILES_LABEL: f"{self.base_file},{self.override_file}",
            WORKING_DIR_LABEL: str(self.project_directory),
        }
        containers = FakeContainers(
            error=RuntimeError("custom hostname"),
            matches=[SimpleNamespace(labels=labels)],
        )

        files, _, _ = resolve_compose_context(
            SimpleNamespace(containers=containers),
            project_name="n8n-autoscaling",
        )

        self.assertEqual(files, [str(self.base_file), str(self.override_file)])
        self.assertEqual(
            containers.filters,
            {
                "label": [
                    "com.docker.compose.project=n8n-autoscaling",
                    "com.docker.compose.service=n8n-autoscaler",
                ]
            },
        )

    def test_legacy_single_file_fallback_is_preserved(self):
        files, project_directory, source = resolve_compose_context(
            SimpleNamespace(containers=FakeContainers({})),
            legacy_file_path=str(self.base_file),
        )

        self.assertEqual(files, [str(self.base_file)])
        self.assertEqual(project_directory, str(self.project_directory))
        self.assertEqual(source, "COMPOSE_FILE_PATH")

    def test_missing_file_fails_before_scaling(self):
        missing_file = self.project_directory / "missing.yml"

        with self.assertRaisesRegex(FileNotFoundError, str(missing_file)):
            resolve_compose_context(
                SimpleNamespace(containers=FakeContainers({})),
                explicit_file_paths=str(missing_file),
            )

    def test_compose_file_path_separator_is_configurable(self):
        self.assertEqual(
            parse_compose_file_paths("base.yml;override.yml", separator=";"),
            ["base.yml", "override.yml"],
        )

    def test_command_repeats_file_flag_in_order(self):
        command = build_compose_command(
            [str(self.base_file), str(self.override_file)],
            "n8n-autoscaling",
            str(self.project_directory),
            ["up", "-d", "--scale", "n8n-worker=2", "n8n-worker"],
        )

        self.assertEqual(
            command,
            [
                "docker",
                "compose",
                "-f",
                str(self.base_file),
                "-f",
                str(self.override_file),
                "--project-name",
                "n8n-autoscaling",
                "--project-directory",
                str(self.project_directory),
                "up",
                "-d",
                "--scale",
                "n8n-worker=2",
                "n8n-worker",
            ],
        )


if __name__ == "__main__":
    unittest.main()
