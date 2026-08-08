from __future__ import annotations

import hashlib
import json
import asyncio
from pathlib import Path

import httpx

from quiz_harness.delivery_api import create_app


def _write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def _registry(root: Path) -> dict[str, object]:
    version_root = root / "animals/versions/000001"
    selector = version_root / "content/assets/category/selector.webp"
    selector.parent.mkdir(parents=True)
    selector.write_bytes(b"selector")
    archive = version_root / "animals-v000001.zip"
    archive.write_bytes(b"bundle")
    archive_sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    record = {
        "schema_version": "category_bundle_v1",
        "bundle_id": "animals",
        "bundle_version": 1,
        "content_hash": "content-hash",
        "minimum_renderer_version": 1,
        "category": {
            "id": "animals",
            "name": "Animals",
            "display_title": "ANIMAL QUIZ",
            "display_tag": "Animals",
            "selector_asset": "assets/category/selector.webp",
        },
        "quiz_count": 20,
        "question_count": 200,
        "generated_at_utc": "2026-08-05T00:00:00+00:00",
        "entrypoint": "category.json",
        "files": [
            {
                "path": "assets/category/selector.webp",
                "bytes": len(selector.read_bytes()),
                "sha256": hashlib.sha256(selector.read_bytes()).hexdigest(),
            }
        ],
        "archive_file": "versions/000001/animals-v000001.zip",
        "archive_bytes": archive.stat().st_size,
        "archive_sha256": archive_sha,
        "record_file": "versions/000001/record.json",
    }
    _write_json(version_root / "record.json", record)
    _write_json(
        root / "animals/current.json",
        {
            "schema_version": "category_bundle_pointer_v1",
            "category_id": "animals",
            "bundle_version": 1,
            "content_hash": "content-hash",
            "record_file": "versions/000001/record.json",
        },
    )
    return record


def test_catalog_metadata_assets_and_downloads(tmp_path: Path) -> None:
    record = _registry(tmp_path)

    async def exercise() -> None:
        transport = httpx.ASGITransport(app=create_app(tmp_path))
        async with httpx.AsyncClient(
            transport=transport, base_url="http://testserver"
        ) as client:
            health = await client.get("/health")
            assert health.status_code == 200
            assert health.json()["category_count"] == 1

            catalog = await client.get("/api/v1/categories")
            assert catalog.status_code == 200
            assert catalog.json()["categories"][0]["question_count"] == 200
            assert catalog.json()["categories"][0]["access"]["has_full_access"] is True
            assert catalog.json()["categories"][0]["category"]["display_tag"] == "Animals"
            assert catalog.json()["categories"][0]["bundle_download_url"].endswith(
                "/bundles/1/download"
            )
            cached = await client.get(
                "/api/v1/categories",
                headers={"If-None-Match": catalog.headers["etag"]},
            )
            assert cached.status_code == 304

            category = await client.get("/api/v1/categories/animals")
            assert category.status_code == 200
            assert category.json()["bundle_version"] == 1
            selector = await client.get("/api/v1/categories/animals/selector")
            assert selector.content == b"selector"

            versions = await client.get("/api/v1/categories/animals/versions")
            assert versions.status_code == 200
            assert versions.json()["current_version"] == 1

            download = await client.get(
                "/api/v1/categories/animals/bundles/1/download"
            )
            assert download.status_code == 200
            assert download.content == b"bundle"
            assert download.headers["x-content-sha256"] == record["archive_sha256"]
            assert "immutable" in download.headers["cache-control"]

    asyncio.run(exercise())


def test_unknown_or_invalid_category_is_not_exposed(tmp_path: Path) -> None:
    async def exercise() -> None:
        transport = httpx.ASGITransport(app=create_app(tmp_path))
        async with httpx.AsyncClient(
            transport=transport, base_url="http://testserver"
        ) as client:
            assert (await client.get("/api/v1/categories/missing")).status_code == 404
            assert (await client.get("/api/v1/categories/INVALID!")).status_code == 404

    asyncio.run(exercise())
