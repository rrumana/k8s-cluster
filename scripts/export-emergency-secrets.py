#!/usr/bin/env python3

import argparse
import base64
import hashlib
import json
import os
import re
import sys
from pathlib import Path


def decode_value(encoded: str) -> str:
    try:
        return base64.b64decode(encoded).decode("utf-8", "replace")
    except Exception:
        return "<decode-error>"


def safe_name(value: str) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-")
    return sanitized or "unknown"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export deduplicated plaintext Kubernetes secrets for the emergency dump."
    )
    parser.add_argument("--input", required=True, help="Path to kubectl get secrets -A -o json output")
    parser.add_argument("--output-dir", required=True, help="Directory for unique secret files")
    parser.add_argument("--consolidated-file", required=True, help="Path for consolidated plaintext output")
    parser.add_argument("--duplicates-file", required=True, help="Path for duplicate mapping TSV")
    parser.add_argument("--summary-file", required=True, help="Path for JSON summary")
    parser.add_argument(
        "--namespace",
        action="append",
        default=[],
        help="Namespace allowlist entry. Repeat for multiple values.",
    )
    parser.add_argument(
        "--skip-name-regex",
        default=r"^(default-token-.*|harbor-pull-creds|sh\.helm\.release\.v1\..*)$",
        help="Skip secret names matching this regex.",
    )
    parser.add_argument(
        "--skip-type-regex",
        default=r"^(kubernetes\.io/service-account-token|kubernetes\.io/dockerconfigjson)$",
        help="Skip secret types matching this regex.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    namespaces = set(args.namespace)
    skip_name_re = re.compile(args.skip_name_regex)
    skip_type_re = re.compile(args.skip_type_regex)

    with open(args.input, "r", encoding="utf-8") as handle:
        payload = json.load(handle)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    consolidated_lines = []
    duplicates = []
    unique_records = []
    seen = {}

    for secret in payload.get("items", []):
        metadata = secret.get("metadata", {})
        namespace = metadata.get("namespace", "unknown")
        name = metadata.get("name", "unknown")
        secret_type = secret.get("type", "Opaque")

        if namespaces and namespace not in namespaces:
            continue
        if skip_name_re.search(name):
            continue
        if skip_type_re.search(secret_type):
            continue

        raw_data = secret.get("data") or {}
        decoded = {key: decode_value(value) for key, value in sorted(raw_data.items())}
        canonical = json.dumps(decoded, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
        digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()

        record = {
            "namespace": namespace,
            "name": name,
            "type": secret_type,
            "data": decoded,
            "digest": digest,
        }

        if digest in seen:
            duplicates.append(
                {
                    "canonical_namespace": seen[digest]["namespace"],
                    "canonical_name": seen[digest]["name"],
                    "duplicate_namespace": namespace,
                    "duplicate_name": name,
                    "digest": digest,
                }
            )
            continue

        seen[digest] = record
        unique_records.append(record)

        consolidated_lines.append(f"### {namespace}/{name} ({secret_type})")
        if decoded:
            for key, value in decoded.items():
                consolidated_lines.append(f"{key}={value}")
        else:
            consolidated_lines.append("(no data)")
        consolidated_lines.append("")

        secret_dir = output_dir / safe_name(namespace)
        secret_dir.mkdir(parents=True, exist_ok=True)
        secret_path = secret_dir / f"{safe_name(name)}.env"
        with open(secret_path, "w", encoding="utf-8") as handle:
            for key, value in decoded.items():
                handle.write(f"{key}={value}\n")

    with open(args.consolidated_file, "w", encoding="utf-8") as handle:
        handle.write("\n".join(consolidated_lines).rstrip() + "\n")

    with open(args.duplicates_file, "w", encoding="utf-8") as handle:
        handle.write("canonical_namespace\tcanonical_name\tduplicate_namespace\tduplicate_name\tdigest\n")
        for duplicate in duplicates:
            handle.write(
                "{canonical_namespace}\t{canonical_name}\t{duplicate_namespace}\t{duplicate_name}\t{digest}\n".format(
                    **duplicate
                )
            )

    summary = {
        "total_input_items": len(payload.get("items", [])),
        "unique_exported": len(unique_records),
        "duplicates_skipped": len(duplicates),
        "namespace_allowlist": sorted(namespaces),
        "skip_name_regex": args.skip_name_regex,
        "skip_type_regex": args.skip_type_regex,
    }
    with open(args.summary_file, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
