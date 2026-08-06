"""Resolve and build Docker Compose commands for the autoscaler."""

from __future__ import annotations

import os
import socket
from pathlib import Path
from typing import Iterable


CONFIG_FILES_LABEL = "com.docker.compose.project.config_files"
WORKING_DIR_LABEL = "com.docker.compose.project.working_dir"


def parse_compose_file_paths(value: str, separator: str | None = None) -> list[str]:
    """Parse a Compose-style ordered file list."""
    path_separator = separator or os.getenv("COMPOSE_PATH_SEPARATOR") or os.pathsep
    paths = [path.strip() for path in value.split(path_separator) if path.strip()]
    if not paths:
        raise ValueError("the Compose file list is empty")
    return paths


def _current_container_labels(
    docker_client,
    hostname: str | None = None,
    project_name: str | None = None,
    service_name: str = "n8n-autoscaler",
) -> dict[str, str]:
    container_name = hostname or socket.gethostname()
    try:
        container = docker_client.containers.get(container_name)
        return container.labels or {}
    except Exception as direct_error:
        if not project_name:
            raise

        matches = docker_client.containers.list(
            all=True,
            filters={
                "label": [
                    f"com.docker.compose.project={project_name}",
                    f"com.docker.compose.service={service_name}",
                ]
            },
        )
        if len(matches) != 1:
            raise RuntimeError(
                "could not uniquely identify the autoscaler container "
                f"for Compose project {project_name!r}"
            ) from direct_error
        return matches[0].labels or {}


def _normalise_paths(paths: Iterable[str], project_directory: str) -> list[str]:
    project_path = Path(project_directory)
    return [
        str(path if path.is_absolute() else project_path / path)
        for path in (Path(value) for value in paths)
    ]


def resolve_compose_context(
    docker_client,
    *,
    explicit_file_paths: str | None = None,
    legacy_file_path: str | None = None,
    explicit_project_directory: str | None = None,
    path_separator: str | None = None,
    hostname: str | None = None,
    project_name: str | None = None,
) -> tuple[list[str], str, str]:
    """Return compose files, project directory, and the configuration source.

    Explicit paths take precedence. Otherwise the exact file list and working
    directory recorded by Docker Compose on this container are reused. The
    legacy single-file setting remains as a final compatibility fallback.
    """
    labels: dict[str, str] = {}
    label_error: Exception | None = None

    if explicit_file_paths:
        compose_files = parse_compose_file_paths(explicit_file_paths, path_separator)
        source = "COMPOSE_FILE_PATHS"
    else:
        try:
            labels = _current_container_labels(
                docker_client,
                hostname,
                project_name,
            )
        except Exception as exc:  # Docker and Podman clients expose different errors
            label_error = exc

        label_files = labels.get(CONFIG_FILES_LABEL, "")
        if label_files:
            # Docker Compose records this label as an ordered comma-separated list.
            compose_files = [path.strip() for path in label_files.split(",") if path.strip()]
            source = CONFIG_FILES_LABEL
        elif legacy_file_path:
            compose_files = [legacy_file_path]
            source = "COMPOSE_FILE_PATH"
        elif label_error:
            raise RuntimeError(
                f"could not inspect the autoscaler container labels: {label_error}"
            ) from label_error
        else:
            raise ValueError(
                "no Compose files were configured and the autoscaler container "
                f"does not have the {CONFIG_FILES_LABEL!r} label"
            )

    if not compose_files:
        raise ValueError("the resolved Compose file list is empty")

    project_directory = (
        explicit_project_directory
        or labels.get(WORKING_DIR_LABEL)
        or str(Path(compose_files[0]).parent)
    )
    project_directory = str(Path(project_directory))
    compose_files = _normalise_paths(compose_files, project_directory)

    missing_files = [path for path in compose_files if not Path(path).is_file()]
    if missing_files:
        raise FileNotFoundError(
            "Compose configuration file(s) are not readable inside the autoscaler: "
            + ", ".join(missing_files)
        )

    return compose_files, project_directory, source


def build_compose_command(
    compose_files: Iterable[str],
    project_name: str,
    project_directory: str,
    compose_arguments: Iterable[str],
) -> list[str]:
    """Build a Docker Compose command with one ``-f`` per ordered file."""
    command = ["docker", "compose"]
    for compose_file in compose_files:
        command.extend(["-f", compose_file])
    command.extend(
        [
            "--project-name",
            project_name,
            "--project-directory",
            project_directory,
            *compose_arguments,
        ]
    )
    return command
