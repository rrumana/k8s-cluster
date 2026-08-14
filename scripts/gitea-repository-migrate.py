#!/usr/bin/env python3
"""Inventory and migrate personal GitHub repositories to authoritative Gitea.

The script is intentionally conservative:

* ``discover`` and ``plan`` never mutate either service.
* ``apply`` requires both ``--execute`` and explicit names for replacements.
* imported Gitea repositories are ordinary repositories, never pull mirrors.
* an outbound GitHub mirror is added only after branch/tag ref parity passes.
* tokens are read from the environment and never written to the manifest.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = REPO_ROOT / "docs/gitea-repository-migration.json"
USER_AGENT = "rcrumana-gitea-authoritative-migration/1"


class MigrationError(RuntimeError):
    """An expected, user-actionable migration failure."""


@dataclass
class ApiError(MigrationError):
    method: str
    url: str
    status: int
    detail: str

    def __str__(self) -> str:
        return f"{self.method} {self.url} returned HTTP {self.status}: {self.detail}"


class ApiClient:
    def __init__(self, base_url: str, token: str | None, auth_scheme: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.auth_scheme = auth_scheme

    def request(
        self,
        method: str,
        path_or_url: str,
        *,
        payload: dict[str, Any] | None = None,
        accepted: tuple[int, ...] = (200,),
        timeout: int = 120,
    ) -> tuple[Any, dict[str, str], int]:
        url = (
            path_or_url
            if path_or_url.startswith(("https://", "http://"))
            else f"{self.base_url}/{path_or_url.lstrip('/')}"
        )
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = f"{self.auth_scheme} {self.token}"
        if "api.github.com" in url:
            headers["Accept"] = "application/vnd.github+json"
            headers["X-GitHub-Api-Version"] = "2022-11-28"

        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
                status = response.status
                response_headers = dict(response.headers.items())
        except urllib.error.HTTPError as error:
            raw = error.read()
            status = error.code
            response_headers = dict(error.headers.items())
        except urllib.error.URLError as error:
            raise MigrationError(f"{method} {url} failed: {error.reason}") from error

        if status not in accepted:
            detail = raw.decode("utf-8", errors="replace")[:2000].strip()
            for secret in (self.token, os.environ.get("GITHUB_TOKEN"), os.environ.get("GITEA_TOKEN")):
                if secret:
                    detail = detail.replace(secret, "[REDACTED]")
            raise ApiError(method, url, status, detail or "no response body")

        if not raw:
            return None, response_headers, status
        try:
            return json.loads(raw), response_headers, status
        except json.JSONDecodeError as error:
            raise MigrationError(f"{method} {url} returned invalid JSON") from error

    def get(self, path: str, *, accepted: tuple[int, ...] = (200,)) -> Any:
        return self.request("GET", path, accepted=accepted)[0]

    def get_pages(self, path: str) -> list[Any]:
        items: list[Any] = []
        next_url: str | None = path
        while next_url:
            page, headers, _ = self.request("GET", next_url)
            if not isinstance(page, list):
                raise MigrationError(f"expected a list from {next_url}")
            items.extend(page)
            link = next(
                (value for key, value in headers.items() if key.casefold() == "link"),
                "",
            )
            next_url = parse_next_link(link)
        return items


def parse_next_link(value: str) -> str | None:
    for part in value.split(","):
        section = part.strip().split(";")
        if len(section) < 2 or not any(
            attribute.strip() == 'rel="next"' for attribute in section[1:]
        ):
            continue
        url = section[0].strip()
        if url.startswith("<") and url.endswith(">"):
            return url[1:-1]
    return None


def quote(value: str) -> str:
    return urllib.parse.quote(value, safe="")


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise MigrationError(f"manifest not found: {path}") from error
    except json.JSONDecodeError as error:
        raise MigrationError(f"invalid JSON in {path}: {error}") from error

    if manifest.get("schemaVersion") != 1:
        raise MigrationError("manifest schemaVersion must be 1")
    for key in ("github", "gitea", "defaults", "repositories"):
        if key not in manifest:
            raise MigrationError(f"manifest is missing {key!r}")
    if not isinstance(manifest["repositories"], list):
        raise MigrationError("manifest repositories must be a list")

    seen: set[str] = set()
    for repository in manifest["repositories"]:
        for key in ("sourceName", "destinationName", "enabled", "visibility"):
            if key not in repository:
                raise MigrationError(f"repository entry is missing {key!r}: {repository}")
        name = repository["destinationName"].casefold()
        if name in seen:
            raise MigrationError(f"duplicate destination repository: {repository['destinationName']}")
        seen.add(name)
    return manifest


def token_from_environment(name: str, required: bool = True) -> str | None:
    value = os.environ.get(name)
    if required and not value:
        raise MigrationError(f"set {name} in the environment; it is never persisted")
    return value


def assert_identity(client: ApiClient, expected_login: str, platform: str) -> None:
    user = client.get("/user")
    actual = user.get("login", "") if isinstance(user, dict) else ""
    if actual.casefold() != expected_login.casefold():
        raise MigrationError(
            f"{platform} token belongs to {actual!r}, expected {expected_login!r}"
        )


def selected_repositories(manifest: dict[str, Any], names: list[str]) -> list[dict[str, Any]]:
    enabled = [repository for repository in manifest["repositories"] if repository["enabled"]]
    if not names:
        return enabled
    wanted = {name.casefold() for name in names}
    selected = [
        repository
        for repository in enabled
        if repository["destinationName"].casefold() in wanted
        or repository["sourceName"].casefold() in wanted
    ]
    found = {
        value.casefold()
        for repository in selected
        for value in (repository["sourceName"], repository["destinationName"])
    }
    missing = sorted(name for name in names if name.casefold() not in found)
    if missing:
        raise MigrationError(f"repositories not found or disabled in manifest: {', '.join(missing)}")
    return selected


def gitea_repository(client: ApiClient, owner: str, name: str) -> dict[str, Any] | None:
    path = f"/repos/{quote(owner)}/{quote(name)}"
    try:
        result = client.get(path)
    except ApiError as error:
        if error.status == 404:
            return None
        raise
    if not isinstance(result, dict):
        raise MigrationError(f"unexpected repository response for {owner}/{name}")
    return result


def push_mirrors(client: ApiClient, owner: str, name: str) -> list[dict[str, Any]]:
    result = client.get(f"/repos/{quote(owner)}/{quote(name)}/push_mirrors")
    if not isinstance(result, list):
        raise MigrationError(f"unexpected push mirror response for {owner}/{name}")
    return result


def mirror_matches(mirror: dict[str, Any], remote_address: str) -> bool:
    candidates = (
        mirror.get("remote_address"),
        mirror.get("remoteAddress"),
        mirror.get("repository", {}).get("clone_url") if isinstance(mirror.get("repository"), dict) else None,
    )
    normalized = remote_address.removesuffix("/").removesuffix(".git").casefold()
    return any(
        isinstance(candidate, str)
        and candidate.removesuffix("/").removesuffix(".git").casefold() == normalized
        for candidate in candidates
    )


def desired_gitea_private(repository: dict[str, Any]) -> bool:
    visibility = repository["visibility"]
    if visibility not in ("public", "private"):
        raise MigrationError(
            f"unsupported visibility {visibility!r} for {repository['destinationName']}"
        )
    return visibility == "private"


def metadata_options(manifest: dict[str, Any], repository: dict[str, Any]) -> dict[str, bool]:
    options = dict(manifest["defaults"].get("migrateMetadata", {}))
    options.update(repository.get("migrateMetadata", {}))
    supported = ("issues", "labels", "milestones", "pullRequests", "releases", "wiki", "lfs")
    return {key: bool(options.get(key, False)) for key in supported}


def push_mirror_options(
    manifest: dict[str, Any], repository: dict[str, Any]
) -> dict[str, Any]:
    options = dict(manifest["defaults"].get("githubPushMirror", {}))
    options.update(repository.get("githubPushMirror", {}))
    return options


def github_remote(manifest: dict[str, Any], repository: dict[str, Any]) -> str:
    return (
        f"https://github.com/{manifest['github']['owner']}/"
        f"{repository['sourceName']}.git"
    )


def ref_map(items: Iterable[dict[str, Any]]) -> dict[str, str]:
    refs: dict[str, str] = {}
    for item in items:
        name = item.get("ref")
        target = item.get("object", {})
        sha = target.get("sha") if isinstance(target, dict) else None
        if (
            isinstance(name, str)
            and isinstance(sha, str)
            and name.startswith(("refs/heads/", "refs/tags/"))
        ):
            refs[name] = sha
    return refs


def compare_refs(
    github: ApiClient,
    gitea: ApiClient,
    github_owner: str,
    gitea_owner: str,
    repository: dict[str, Any],
) -> list[str]:
    source_name = quote(repository["sourceName"])
    destination_name = quote(repository["destinationName"])
    source_items: list[dict[str, Any]] = []
    for namespace in ("heads/", "tags/"):
        source_items.extend(
            github.get_pages(
                f"/repos/{quote(github_owner)}/{source_name}/git/matching-refs/{namespace}?per_page=100"
            )
        )
    destination_items = gitea.get(
        f"/repos/{quote(gitea_owner)}/{destination_name}/git/refs"
    )
    if not isinstance(destination_items, list):
        raise MigrationError(f"unexpected ref response for {gitea_owner}/{repository['destinationName']}")

    source_refs = ref_map(source_items)
    destination_refs = ref_map(destination_items)
    differences: list[str] = []
    for name in sorted(source_refs.keys() | destination_refs.keys()):
        if source_refs.get(name) != destination_refs.get(name):
            differences.append(
                f"{name}: GitHub={source_refs.get(name, 'missing')} "
                f"Gitea={destination_refs.get(name, 'missing')}"
            )
    return differences


def command_discover(args: argparse.Namespace) -> int:
    token = token_from_environment("GITHUB_TOKEN", required=False)
    if not token and args.write and not args.allow_public_only:
        raise MigrationError(
            "GITHUB_TOKEN is unset; refuse to write a public-only inventory without "
            "--allow-public-only"
        )

    existing: dict[str, Any] | None = None
    if args.manifest.exists():
        existing = load_manifest(args.manifest)
        github_config = existing["github"]
        gitea_config = existing["gitea"]
        defaults = existing["defaults"]
    else:
        github_config = {"apiUrl": "https://api.github.com", "owner": args.github_owner}
        gitea_config = {"apiUrl": "https://git.rcrumana.xyz/api/v1", "owner": args.gitea_owner}
        defaults = {
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
        }

    github = ApiClient(github_config["apiUrl"], token, "Bearer")
    owner = github_config["owner"]
    if token:
        assert_identity(github, owner, "GitHub")
        path = "/user/repos?affiliation=owner&visibility=all&sort=full_name&per_page=100"
        scope = "all-owned"
    else:
        path = f"/users/{quote(owner)}/repos?type=owner&sort=full_name&per_page=100"
        scope = "public-only"

    discovered = [
        item
        for item in github.get_pages(path)
        if isinstance(item, dict)
        and str(item.get("owner", {}).get("login", "")).casefold() == owner.casefold()
    ]
    old_entries = {
        entry["sourceName"].casefold(): entry
        for entry in (existing or {}).get("repositories", [])
    }
    entries: list[dict[str, Any]] = []
    for item in sorted(discovered, key=lambda value: value["name"].casefold()):
        entry: dict[str, Any] = {
            "sourceName": item["name"],
            "destinationName": item["name"],
            "enabled": True,
            "visibility": "private" if item.get("private") else "public",
            "archived": bool(item.get("archived")),
            "fork": bool(item.get("fork")),
            "defaultBranch": item.get("default_branch") or "main",
        }
        old = old_entries.get(item["name"].casefold(), {})
        for key in (
            "destinationName",
            "enabled",
            "migrateMetadata",
            "githubPushMirror",
            "notes",
        ):
            if key in old:
                entry[key] = old[key]
        entries.append(entry)

    inventory = {
        "schemaVersion": 1,
        "inventory": {
            "generatedAt": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
            "scope": scope,
            "repositoryCount": len(entries),
        },
        "github": github_config,
        "gitea": gitea_config,
        "defaults": defaults,
        "repositories": entries,
    }
    output = json.dumps(inventory, indent=2) + "\n"
    if args.write:
        args.manifest.write_text(output, encoding="utf-8")
        print(f"wrote {len(entries)} repositories to {args.manifest} ({scope})")
    else:
        print(output, end="")
    if scope != "all-owned":
        print(
            "WARNING: inventory is public-only; rerun with GITHUB_TOKEN before migration",
            file=sys.stderr,
        )
    return 0


def command_plan(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.manifest)
    token = token_from_environment("GITEA_TOKEN")
    gitea = ApiClient(manifest["gitea"]["apiUrl"], token, "token")
    owner = manifest["gitea"]["owner"]
    assert_identity(gitea, owner, "Gitea")
    repositories = selected_repositories(manifest, args.repository)
    replacements = {name.casefold() for name in args.replace}
    blocked = 0

    print(f"Plan for {len(repositories)} repositories: GitHub {manifest['github']['owner']} -> Gitea {owner}")
    for repository in repositories:
        name = repository["destinationName"]
        existing = gitea_repository(gitea, owner, name)
        if existing is None:
            action = "IMPORT regular repository"
        elif name.casefold() in replacements:
            action = "REPLACE existing repository, then import"
        elif existing.get("mirror"):
            action = "BLOCKED existing repository is a pull mirror; pass --replace"
            blocked += 1
        else:
            action = "PRESERVE existing regular repository"
        print(f"  {name}: {action}")

        if existing is not None and name.casefold() not in replacements and not existing.get("mirror"):
            mirror_config = push_mirror_options(manifest, repository)
            mirrors = push_mirrors(gitea, owner, name)
            remote = github_remote(manifest, repository)
            if not mirror_config.get("enabled", True):
                mirror_action = "disabled by inventory"
            else:
                mirror_action = (
                    "present"
                    if any(mirror_matches(item, remote) for item in mirrors)
                    else "will add"
                )
            print(f"    GitHub push mirror: {mirror_action}")

    extra_replacements = sorted(
        args.replace,
        key=str.casefold,
    )
    selected_names = {repository["destinationName"].casefold() for repository in repositories}
    extra_replacements = [name for name in extra_replacements if name.casefold() not in selected_names]
    if extra_replacements:
        raise MigrationError(
            f"--replace names are not in the selected set: {', '.join(extra_replacements)}"
        )
    if blocked:
        print(f"\n{blocked} repository/repositories require an explicit replacement decision.")
        return 2
    return 0


def wait_for_repository(
    gitea: ApiClient,
    owner: str,
    name: str,
    timeout: int = 1800,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        repository = gitea_repository(gitea, owner, name)
        if repository is not None:
            return repository
        time.sleep(5)
    raise MigrationError(f"timed out waiting for imported repository {owner}/{name}")


def wait_for_push_mirror(
    gitea: ApiClient,
    owner: str,
    name: str,
    remote: str,
    timeout: int = 300,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        matching = [
            item for item in push_mirrors(gitea, owner, name) if mirror_matches(item, remote)
        ]
        if matching:
            last_error = matching[0].get("last_error") or matching[0].get("lastError")
            if last_error:
                raise MigrationError(f"push mirror for {owner}/{name} failed: {last_error}")
            last_update = matching[0].get("last_update") or matching[0].get("lastUpdate")
            if last_update and not str(last_update).startswith("0001-"):
                return
        time.sleep(5)
    raise MigrationError(f"timed out waiting for GitHub push mirror of {owner}/{name}")


def command_apply(args: argparse.Namespace) -> int:
    if not args.execute:
        raise MigrationError("apply requires --execute after reviewing the plan")

    manifest = load_manifest(args.manifest)
    if manifest.get("inventory", {}).get("scope") != "all-owned" and not args.allow_public_only:
        raise MigrationError(
            "manifest is not an authenticated all-owned inventory; refresh it or pass "
            "--allow-public-only deliberately"
        )

    github_token = token_from_environment("GITHUB_TOKEN")
    gitea_token = token_from_environment("GITEA_TOKEN")
    github = ApiClient(manifest["github"]["apiUrl"], github_token, "Bearer")
    gitea = ApiClient(manifest["gitea"]["apiUrl"], gitea_token, "token")
    github_owner = manifest["github"]["owner"]
    gitea_owner = manifest["gitea"]["owner"]
    assert_identity(github, github_owner, "GitHub")
    assert_identity(gitea, gitea_owner, "Gitea")

    repositories = selected_repositories(manifest, args.repository)
    replacements = {name.casefold() for name in args.replace}
    selected_names = {repository["destinationName"].casefold() for repository in repositories}
    unknown_replacements = sorted(name for name in args.replace if name.casefold() not in selected_names)
    if unknown_replacements:
        raise MigrationError(
            f"--replace names are not in the selected set: {', '.join(unknown_replacements)}"
        )

    for index, repository in enumerate(repositories, start=1):
        source_name = repository["sourceName"]
        name = repository["destinationName"]
        print(f"[{index}/{len(repositories)}] {source_name} -> {gitea_owner}/{name}")
        existing = gitea_repository(gitea, gitea_owner, name)
        if existing is not None and name.casefold() in replacements:
            print("  deleting explicitly approved proof-of-concept repository")
            gitea.request(
                "DELETE",
                f"/repos/{quote(gitea_owner)}/{quote(name)}",
                accepted=(204,),
            )
            existing = None
        elif existing is not None and existing.get("mirror"):
            raise MigrationError(
                f"{gitea_owner}/{name} is a pull mirror; rerun with --replace {name}"
            )

        if existing is None:
            options = metadata_options(manifest, repository)
            payload = {
                "clone_addr": github_remote(manifest, repository),
                "repo_name": name,
                "repo_owner": gitea_owner,
                "service": "github",
                "auth_token": github_token,
                "mirror": False,
                "private": desired_gitea_private(repository),
                "issues": options["issues"],
                "labels": options["labels"],
                "milestones": options["milestones"],
                "pull_requests": options["pullRequests"],
                "releases": options["releases"],
                "wiki": options["wiki"],
                "lfs": options["lfs"],
            }
            print("  importing Git refs and selected metadata as a regular repository")
            gitea.request("POST", "/repos/migrate", payload=payload, accepted=(201,), timeout=1800)
            existing = wait_for_repository(gitea, gitea_owner, name)
        else:
            print("  preserving existing regular repository")

        if existing.get("mirror"):
            raise MigrationError(f"{gitea_owner}/{name} unexpectedly remains a pull mirror")
        if bool(existing.get("private")) != desired_gitea_private(repository):
            raise MigrationError(
                f"{gitea_owner}/{name} visibility does not match the inventory"
            )

        differences = compare_refs(
            github, gitea, github_owner, gitea_owner, repository
        )
        if differences:
            preview = "\n      ".join(differences[:20])
            raise MigrationError(
                f"ref verification failed for {name}; no push mirror was added:\n      {preview}"
            )
        print("  verified branch and tag ref parity")

        mirror_config = push_mirror_options(manifest, repository)
        if not mirror_config.get("enabled", True) or args.skip_push_mirrors:
            print("  push mirror skipped")
            continue
        if repository.get("archived"):
            raise MigrationError(
                f"GitHub repository {github_owner}/{source_name} is archived and cannot "
                "receive mirror pushes; unarchive it or set githubPushMirror.enabled=false"
            )
        remote = github_remote(manifest, repository)
        mirrors = push_mirrors(gitea, gitea_owner, name)
        if any(mirror_matches(item, remote) for item in mirrors):
            print("  GitHub push mirror already present")
            continue
        if mirrors:
            raise MigrationError(
                f"{gitea_owner}/{name} has an unexpected existing push mirror; refusing to add another"
            )
        payload = {
            "remote_address": remote,
            "remote_username": github_owner,
            "remote_password": github_token,
            "interval": mirror_config.get("interval", "8h0m0s"),
            "sync_on_commit": bool(mirror_config.get("syncOnCommit", True)),
        }
        print("  adding one-way Gitea -> GitHub push mirror")
        gitea.request(
            "POST",
            f"/repos/{quote(gitea_owner)}/{quote(name)}/push_mirrors",
            payload=payload,
            accepted=(200,),
        )
        gitea.request(
            "POST",
            f"/repos/{quote(gitea_owner)}/{quote(name)}/push_mirrors-sync",
            accepted=(200,),
        )
        wait_for_push_mirror(gitea, gitea_owner, name, remote)
        print("  verified initial GitHub push-mirror sync")

    print(f"Completed {len(repositories)} repository migration(s).")
    return 0


def command_verify(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.manifest)
    github = ApiClient(
        manifest["github"]["apiUrl"], token_from_environment("GITHUB_TOKEN"), "Bearer"
    )
    gitea = ApiClient(
        manifest["gitea"]["apiUrl"], token_from_environment("GITEA_TOKEN"), "token"
    )
    github_owner = manifest["github"]["owner"]
    gitea_owner = manifest["gitea"]["owner"]
    assert_identity(github, github_owner, "GitHub")
    assert_identity(gitea, gitea_owner, "Gitea")
    failures = 0

    for repository in selected_repositories(manifest, args.repository):
        name = repository["destinationName"]
        existing = gitea_repository(gitea, gitea_owner, name)
        problems: list[str] = []
        if existing is None:
            problems.append("Gitea repository is missing")
        else:
            if existing.get("mirror"):
                problems.append("Gitea repository is still a pull mirror")
            if bool(existing.get("private")) != desired_gitea_private(repository):
                problems.append("visibility mismatch")
            if existing.get("default_branch") != repository["defaultBranch"]:
                problems.append(
                    f"default branch is {existing.get('default_branch')!r}, "
                    f"expected {repository['defaultBranch']!r}"
                )
            differences = compare_refs(
                github, gitea, github_owner, gitea_owner, repository
            )
            problems.extend(differences)
            if push_mirror_options(manifest, repository).get("enabled", True):
                remote = github_remote(manifest, repository)
                mirrors = push_mirrors(gitea, gitea_owner, name)
                matching = [item for item in mirrors if mirror_matches(item, remote)]
                if not matching:
                    problems.append("GitHub push mirror is missing")
                for mirror in matching:
                    last_error = mirror.get("last_error") or mirror.get("lastError")
                    if last_error:
                        problems.append(f"push mirror last error: {last_error}")

        if problems:
            failures += 1
            print(f"FAIL {name}")
            for problem in problems[:25]:
                print(f"  - {problem}")
        else:
            print(f"OK   {name}")

    return 1 if failures else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST,
        help=f"inventory manifest (default: {DEFAULT_MANIFEST.relative_to(REPO_ROOT)})",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    discover = subparsers.add_parser("discover", help="discover GitHub-owned repositories")
    discover.add_argument("--github-owner", default="rrumana")
    discover.add_argument("--gitea-owner", default="rcrumana")
    discover.add_argument("--write", action="store_true", help="replace the manifest")
    discover.add_argument(
        "--allow-public-only",
        action="store_true",
        help="allow writing an incomplete inventory when GITHUB_TOKEN is unset",
    )
    discover.set_defaults(func=command_discover)

    for name, help_text, function in (
        ("plan", "inspect Gitea and print the non-mutating migration plan", command_plan),
        ("verify", "verify Gitea refs, properties, and GitHub mirrors", command_verify),
    ):
        command = subparsers.add_parser(name, help=help_text)
        command.add_argument("--repository", action="append", default=[], help="limit by name")
        if name == "plan":
            command.add_argument(
                "--replace", action="append", default=[], help="show an approved replacement"
            )
        command.set_defaults(func=function)

    apply = subparsers.add_parser("apply", help="perform reviewed imports and push-mirror setup")
    apply.add_argument("--repository", action="append", default=[], help="limit by name")
    apply.add_argument(
        "--replace",
        action="append",
        default=[],
        help="delete and recreate this exact existing Gitea repository",
    )
    apply.add_argument("--execute", action="store_true", help="confirm external mutations")
    apply.add_argument(
        "--allow-public-only",
        action="store_true",
        help="deliberately apply an inventory that may omit private repositories",
    )
    apply.add_argument(
        "--skip-push-mirrors",
        action="store_true",
        help="import and verify without configuring GitHub push mirrors",
    )
    apply.set_defaults(func=command_apply)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except (MigrationError, KeyError, TypeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
