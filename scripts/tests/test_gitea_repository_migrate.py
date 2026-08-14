#!/usr/bin/env python3

import argparse
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/gitea-repository-migrate.py"
SPEC = importlib.util.spec_from_file_location("gitea_repository_migrate", SCRIPT)
assert SPEC and SPEC.loader
migration = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = migration
SPEC.loader.exec_module(migration)


class MigrationHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = migration.load_manifest(
            REPO_ROOT / "docs/gitea-repository-migration.json"
        )

    def test_committed_inventory_has_unique_public_repositories(self):
        repositories = self.manifest["repositories"]
        self.assertEqual(29, len(repositories))
        self.assertEqual(
            len(repositories),
            len({item["destinationName"].casefold() for item in repositories}),
        )
        self.assertTrue(all(item["visibility"] == "public" for item in repositories))

    def test_next_link_parser(self):
        value = (
            '<https://api.example.test/items?page=2>; rel="next", '
            '<https://api.example.test/items?page=3>; rel="last"'
        )
        self.assertEqual(
            "https://api.example.test/items?page=2",
            migration.parse_next_link(value),
        )
        self.assertIsNone(migration.parse_next_link(""))

    def test_ref_map_ignores_pull_request_refs(self):
        refs = migration.ref_map(
            [
                {"ref": "refs/heads/main", "object": {"sha": "abc"}},
                {"ref": "refs/tags/v1", "object": {"sha": "def"}},
                {"ref": "refs/pull/1/head", "object": {"sha": "123"}},
            ]
        )
        self.assertEqual(
            {"refs/heads/main": "abc", "refs/tags/v1": "def"},
            refs,
        )

    def test_selection_accepts_source_or_destination_name(self):
        selected = migration.selected_repositories(self.manifest, ["k8s-cluster"])
        self.assertEqual(["k8s-cluster"], [item["destinationName"] for item in selected])
        with self.assertRaises(migration.MigrationError):
            migration.selected_repositories(self.manifest, ["does-not-exist"])

    def test_per_repository_options_override_defaults(self):
        repository = {
            "destinationName": "example",
            "visibility": "private",
            "migrateMetadata": {"wiki": False},
            "githubPushMirror": {"enabled": False},
        }
        metadata = migration.metadata_options(self.manifest, repository)
        mirror = migration.push_mirror_options(self.manifest, repository)
        self.assertTrue(metadata["issues"])
        self.assertFalse(metadata["wiki"])
        self.assertFalse(mirror["enabled"])
        self.assertTrue(migration.desired_gitea_private(repository))

    def test_push_mirror_url_normalization(self):
        mirror = {"remote_address": "https://github.com/rrumana/example.git"}
        self.assertTrue(
            migration.mirror_matches(mirror, "https://github.com/rrumana/example")
        )

    def test_apply_requires_explicit_execute_before_reading_tokens(self):
        args = argparse.Namespace(execute=False)
        with self.assertRaisesRegex(migration.MigrationError, "requires --execute"):
            migration.command_apply(args)


class FakeGithub:
    def get(self, path):
        if path == "/user":
            return {"login": "rrumana"}
        raise AssertionError(f"unexpected GitHub GET {path}")

    def get_pages(self, path):
        if "/matching-refs/heads/" in path:
            return [{"ref": "refs/heads/main", "object": {"sha": "abc"}}]
        if "/matching-refs/tags/" in path:
            return []
        raise AssertionError(f"unexpected GitHub paginated GET {path}")


class FakeGitea:
    def __init__(self):
        self.repository = {
            "name": "example",
            "mirror": True,
            "private": False,
            "default_branch": "main",
        }
        self.mirrors = []
        self.requests = []

    def get(self, path):
        if path == "/user":
            return {"login": "rcrumana"}
        if path == "/repos/rcrumana/example":
            if self.repository is None:
                raise migration.ApiError("GET", path, 404, "missing")
            return self.repository
        if path == "/repos/rcrumana/example/git/refs":
            return [{"ref": "refs/heads/main", "object": {"sha": "abc"}}]
        if path == "/repos/rcrumana/example/push_mirrors":
            return self.mirrors
        raise AssertionError(f"unexpected Gitea GET {path}")

    def request(self, method, path, *, payload=None, accepted=(200,), timeout=120):
        self.requests.append((method, path))
        if method == "DELETE" and path == "/repos/rcrumana/example":
            self.repository = None
            return None, {}, 204
        if method == "POST" and path == "/repos/migrate":
            self.repository = {
                "name": "example",
                "mirror": False,
                "private": False,
                "default_branch": "main",
            }
            return self.repository, {}, 201
        if method == "POST" and path.endswith("/push_mirrors"):
            self.mirrors = [
                {
                    "remote_address": payload["remote_address"],
                    "last_update": "0001-01-01T00:00:00Z",
                }
            ]
            return self.mirrors[0], {}, 200
        if method == "POST" and path.endswith("/push_mirrors-sync"):
            self.mirrors[0]["last_update"] = "2026-08-14T21:30:00Z"
            return None, {}, 200
        raise AssertionError(f"unexpected Gitea request {method} {path}")


class ApplySafetyTests(unittest.TestCase):
    def setUp(self):
        self.github = FakeGithub()
        self.gitea = FakeGitea()
        self.manifest = {
            "schemaVersion": 1,
            "inventory": {"scope": "all-owned"},
            "github": {"apiUrl": "https://api.github.test", "owner": "rrumana"},
            "gitea": {"apiUrl": "https://gitea.test/api/v1", "owner": "rcrumana"},
            "defaults": {
                "migrateMetadata": {
                    "issues": True,
                    "labels": True,
                    "milestones": True,
                    "pullRequests": True,
                    "releases": True,
                    "wiki": True,
                    "lfs": True,
                },
                "githubPushMirror": {
                    "enabled": True,
                    "interval": "8h0m0s",
                    "syncOnCommit": True,
                },
            },
            "repositories": [
                {
                    "sourceName": "example",
                    "destinationName": "example",
                    "enabled": True,
                    "visibility": "public",
                    "archived": False,
                    "fork": False,
                    "defaultBranch": "main",
                }
            ],
        }
        temporary = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
        json.dump(self.manifest, temporary)
        temporary.close()
        self.manifest_path = Path(temporary.name)

    def tearDown(self):
        self.manifest_path.unlink(missing_ok=True)

    def arguments(self, replace):
        return argparse.Namespace(
            execute=True,
            manifest=self.manifest_path,
            allow_public_only=False,
            repository=[],
            replace=replace,
            skip_push_mirrors=False,
        )

    def client_factory(self, base_url, token, auth_scheme):
        return self.github if "github" in base_url else self.gitea

    def test_pull_mirror_cannot_be_replaced_implicitly(self):
        with mock.patch.dict(
            os.environ, {"GITHUB_TOKEN": "github-secret", "GITEA_TOKEN": "gitea-secret"}
        ), mock.patch.object(migration, "ApiClient", side_effect=self.client_factory):
            with self.assertRaisesRegex(migration.MigrationError, "rerun with --replace"):
                migration.command_apply(self.arguments([]))
        self.assertFalse(any(method == "DELETE" for method, _ in self.gitea.requests))

    def test_explicit_replacement_imports_verifies_and_adds_mirror(self):
        with mock.patch.dict(
            os.environ, {"GITHUB_TOKEN": "github-secret", "GITEA_TOKEN": "gitea-secret"}
        ), mock.patch.object(migration, "ApiClient", side_effect=self.client_factory):
            result = migration.command_apply(self.arguments(["example"]))
        self.assertEqual(0, result)
        self.assertFalse(self.gitea.repository["mirror"])
        self.assertEqual(
            [
                ("DELETE", "/repos/rcrumana/example"),
                ("POST", "/repos/migrate"),
                ("POST", "/repos/rcrumana/example/push_mirrors"),
                ("POST", "/repos/rcrumana/example/push_mirrors-sync"),
            ],
            self.gitea.requests,
        )


if __name__ == "__main__":
    unittest.main()
