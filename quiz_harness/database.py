from __future__ import annotations

import hashlib
import json
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .models import PlanDocument
from .seeds import SEED_CATALOG


MIGRATIONS: list[tuple[int, str]] = [
    (
        1,
        """
        CREATE TABLE categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            slug TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            age_min INTEGER NOT NULL CHECK (age_min BETWEEN 3 AND 15),
            age_max INTEGER NOT NULL CHECK (age_max BETWEEN 3 AND 15 AND age_max >= age_min),
            sort_order INTEGER NOT NULL DEFAULT 0,
            is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );

        CREATE TABLE quiz_objects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE RESTRICT,
            slug TEXT NOT NULL,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            asset_key TEXT NOT NULL UNIQUE,
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            UNIQUE (category_id, slug)
        );

        CREATE TABLE quiz_plans (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            object_id INTEGER NOT NULL REFERENCES quiz_objects(id) ON DELETE RESTRICT,
            revision INTEGER NOT NULL CHECK (revision >= 1),
            status TEXT NOT NULL DEFAULT 'valid' CHECK (status IN ('draft', 'valid', 'invalid', 'archived')),
            schema_version TEXT NOT NULL,
            plan_json TEXT NOT NULL CHECK (json_valid(plan_json)),
            content_hash TEXT NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('vllm', 'import', 'manual')),
            model TEXT,
            generation_seed INTEGER,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            UNIQUE (object_id, revision),
            UNIQUE (object_id, content_hash)
        );

        CREATE INDEX idx_quiz_objects_category ON quiz_objects(category_id, sort_order, name);
        CREATE INDEX idx_quiz_plans_object_status ON quiz_plans(object_id, status, revision DESC);
        """,
    ),
    (
        2,
        """
        ALTER TABLE categories ADD COLUMN display_title TEXT NOT NULL DEFAULT '';
        ALTER TABLE categories ADD COLUMN editorial_brief TEXT NOT NULL DEFAULT '';
        ALTER TABLE categories ADD COLUMN production_status TEXT NOT NULL DEFAULT 'draft'
            CHECK (production_status IN ('draft', 'production', 'published', 'archived'));

        UPDATE categories
        SET display_title = upper(name || ' Quiz'),
            editorial_brief = description,
            production_status = CASE WHEN slug = 'animals' THEN 'published' ELSE 'draft' END;

        CREATE TABLE provider_connections (
            id TEXT PRIMARY KEY,
            provider_type TEXT NOT NULL
                CHECK (provider_type IN ('imagestudio', 'openai_images', 'openai_compatible_llm', 'vibevoice')),
            name TEXT NOT NULL,
            base_url TEXT NOT NULL,
            secret_ciphertext TEXT,
            secret_fingerprint TEXT,
            secret_last_four TEXT,
            default_model TEXT,
            settings_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(settings_json)),
            discovered_models_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(discovered_models_json)),
            enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
            health_status TEXT NOT NULL DEFAULT 'unchecked'
                CHECK (health_status IN ('unchecked', 'checking', 'healthy', 'unhealthy')),
            health_message TEXT,
            last_checked_at TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );

        CREATE INDEX idx_provider_connections_type
            ON provider_connections(provider_type, enabled, name);

        CREATE TABLE studio_jobs (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            status TEXT NOT NULL
                CHECK (status IN ('queued', 'running', 'complete', 'failed', 'cancelled', 'interrupted')),
            message TEXT NOT NULL,
            progress REAL NOT NULL DEFAULT 0 CHECK (progress >= 0 AND progress <= 1),
            context_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(context_json)),
            result_json TEXT,
            error TEXT,
            created_at TEXT NOT NULL,
            started_at TEXT,
            completed_at TEXT,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE studio_job_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT NOT NULL REFERENCES studio_jobs(id) ON DELETE CASCADE,
            status TEXT NOT NULL,
            message TEXT NOT NULL,
            progress REAL NOT NULL,
            created_at TEXT NOT NULL
        );

        CREATE INDEX idx_studio_jobs_updated ON studio_jobs(updated_at DESC);
        CREATE INDEX idx_studio_job_events_job ON studio_job_events(job_id, id);
        """,
    ),
    (
        3,
        """
        CREATE TABLE question_reviews (
            category_slug TEXT NOT NULL,
            difficulty TEXT NOT NULL CHECK (difficulty IN ('beginner', 'intermediate')),
            question_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'unreviewed'
                CHECK (status IN ('unreviewed', 'approved', 'needs_edit', 'rejected')),
            notes TEXT NOT NULL DEFAULT '',
            reviewer TEXT NOT NULL DEFAULT 'admin',
            reviewed_at TEXT,
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            PRIMARY KEY (category_slug, difficulty, question_id)
        );

        CREATE TABLE question_bank_revisions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            category_slug TEXT NOT NULL,
            difficulty TEXT NOT NULL CHECK (difficulty IN ('beginner', 'intermediate')),
            question_id TEXT NOT NULL,
            action TEXT NOT NULL CHECK (action IN ('imported', 'generated', 'edited', 'reviewed')),
            before_json TEXT CHECK (before_json IS NULL OR json_valid(before_json)),
            after_json TEXT CHECK (after_json IS NULL OR json_valid(after_json)),
            actor TEXT NOT NULL DEFAULT 'admin',
            source_provider TEXT,
            source_model TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );

        CREATE INDEX idx_question_reviews_category
            ON question_reviews(category_slug, difficulty, status, updated_at DESC);
        CREATE INDEX idx_question_revisions_question
            ON question_bank_revisions(category_slug, difficulty, question_id, id DESC);
        """,
    ),
    (
        4,
        """
        CREATE TABLE quiz_set_reviews (
            category_slug TEXT NOT NULL,
            difficulty TEXT NOT NULL CHECK (difficulty IN ('beginner', 'intermediate')),
            set_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'unreviewed'
                CHECK (status IN ('unreviewed', 'approved', 'needs_edit', 'rejected')),
            notes TEXT NOT NULL DEFAULT '',
            reviewer TEXT NOT NULL DEFAULT 'admin',
            reviewed_at TEXT,
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            PRIMARY KEY (category_slug, difficulty, set_id)
        );

        CREATE TABLE quiz_set_revisions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            category_slug TEXT NOT NULL,
            difficulty TEXT NOT NULL CHECK (difficulty IN ('beginner', 'intermediate')),
            set_id TEXT NOT NULL,
            action TEXT NOT NULL CHECK (action IN ('selected', 'reviewed', 'replaced')),
            before_json TEXT CHECK (before_json IS NULL OR json_valid(before_json)),
            after_json TEXT CHECK (after_json IS NULL OR json_valid(after_json)),
            actor TEXT NOT NULL DEFAULT 'admin',
            source_provider TEXT,
            source_model TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );

        CREATE INDEX idx_quiz_set_reviews_category
            ON quiz_set_reviews(category_slug, difficulty, status, updated_at DESC);
        CREATE INDEX idx_quiz_set_revisions_set
            ON quiz_set_revisions(category_slug, difficulty, set_id, id DESC);
        """,
    ),
    (
        5,
        """
        ALTER TABLE categories ADD COLUMN display_tag TEXT NOT NULL DEFAULT '';

        UPDATE categories
        SET display_tag = CASE
            WHEN slug = 'world-history' THEN 'History'
            WHEN length(trim(name)) <= 12 THEN trim(name)
            ELSE trim(substr(trim(name), 1, 12))
        END
        WHERE display_tag = '';
        """,
    ),
]


@dataclass(frozen=True)
class StoredPlan:
    plan_id: int
    object_id: int
    revision: int
    created: bool


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-") or "quiz"


class QuizDatabase:
    def __init__(self, path: Path | str) -> None:
        self.path = Path(path)

    def connect(self) -> sqlite3.Connection:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(self.path, timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA busy_timeout = 30000")
        return connection

    def migrate(self) -> list[int]:
        applied: list[int] = []
        with self.connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                )
                """
            )
            current = {
                row["version"]
                for row in connection.execute("SELECT version FROM schema_migrations")
            }
            for version, sql in MIGRATIONS:
                if version in current:
                    continue
                connection.executescript(sql)
                connection.execute(
                    "INSERT INTO schema_migrations(version) VALUES (?)", (version,)
                )
                applied.append(version)
        return applied

    def seed_catalog(self) -> tuple[int, int]:
        self.migrate()
        with self.connect() as connection:
            for category_order, category in enumerate(SEED_CATALOG, start=1):
                connection.execute(
                    """
                    INSERT INTO categories(
                        slug, name, display_title, display_tag, description, editorial_brief,
                        age_min, age_max, sort_order
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(slug) DO UPDATE SET
                        name = excluded.name,
                        description = excluded.description,
                        age_min = excluded.age_min,
                        age_max = excluded.age_max,
                        sort_order = excluded.sort_order,
                        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                    """,
                    (
                        category["slug"],
                        category["name"],
                        f"{category['name'].upper()} QUIZ",
                        category.get("display_tag", category["name"][:12]),
                        category["description"],
                        category["description"],
                        category["age_min"],
                        category["age_max"],
                        category_order,
                    ),
                )
                category_id = connection.execute(
                    "SELECT id FROM categories WHERE slug = ?", (category["slug"],)
                ).fetchone()["id"]
                for object_order, (slug, name, description) in enumerate(
                    category["objects"], start=1
                ):
                    connection.execute(
                        """
                        INSERT INTO quiz_objects(
                            category_id, slug, name, description, asset_key, sort_order
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(category_id, slug) DO UPDATE SET
                            name = excluded.name,
                            description = excluded.description,
                            sort_order = excluded.sort_order,
                            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                        """,
                        (
                            category_id,
                            slug,
                            name,
                            description,
                            f"{category['slug']}/{slug}",
                            object_order,
                        ),
                    )
            category_count = connection.execute(
                "SELECT COUNT(*) AS count FROM categories"
            ).fetchone()["count"]
            object_count = connection.execute(
                "SELECT COUNT(*) AS count FROM quiz_objects"
            ).fetchone()["count"]
        return category_count, object_count

    def catalog(self) -> list[dict[str, Any]]:
        self.migrate()
        with self.connect() as connection:
            categories = connection.execute(
                """
                SELECT id, slug, name, description, age_min, age_max
                FROM categories WHERE is_active = 1
                ORDER BY sort_order, name
                """
            ).fetchall()
            result: list[dict[str, Any]] = []
            for category in categories:
                objects = connection.execute(
                    """
                    SELECT o.id, o.slug, o.name, o.description, o.asset_key,
                           COUNT(p.id) AS plan_count,
                           MAX(CASE WHEN p.status = 'valid' THEN p.revision END) AS current_revision
                    FROM quiz_objects o
                    LEFT JOIN quiz_plans p ON p.object_id = o.id
                    WHERE o.category_id = ? AND o.status = 'active'
                    GROUP BY o.id
                    ORDER BY o.sort_order, o.name
                    """,
                    (category["id"],),
                ).fetchall()
                item = dict(category)
                item["objects"] = [dict(row) for row in objects]
                result.append(item)
            return result

    def create_category(
        self,
        *,
        name: str,
        slug: str | None,
        description: str,
        age_min: int,
        age_max: int,
        display_title: str = "",
        display_tag: str = "",
        editorial_brief: str = "",
    ) -> dict[str, Any]:
        self.migrate()
        clean_name = name.strip()
        category_slug = _slug(slug or clean_name)
        clean_description = description.strip()
        clean_title = display_title.strip() or f"{clean_name.upper()} QUIZ"
        clean_tag = display_tag.strip() or clean_name
        if not 1 <= len(clean_tag) <= 12:
            raise ValueError("display tag must contain 1 to 12 characters")
        clean_brief = editorial_brief.strip() or clean_description
        with self.connect() as connection:
            sort_order = connection.execute(
                "SELECT COALESCE(MAX(sort_order), 0) + 1 AS value FROM categories"
            ).fetchone()["value"]
            cursor = connection.execute(
                """
                INSERT INTO categories(
                    slug, name, display_title, display_tag, description, editorial_brief,
                    age_min, age_max, sort_order, production_status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'draft')
                """,
                (
                    category_slug,
                    clean_name,
                    clean_title,
                    clean_tag,
                    clean_description,
                    clean_brief,
                    age_min,
                    age_max,
                    sort_order,
                ),
            )
            category_id = int(cursor.lastrowid)
            row = connection.execute(
                "SELECT * FROM categories WHERE id = ?", (category_id,)
            ).fetchone()
        return dict(row)

    def update_category_metadata(
        self,
        slug: str,
        *,
        name: str,
        display_title: str,
        display_tag: str,
        description: str,
        editorial_brief: str,
        age_min: int,
        age_max: int,
    ) -> dict[str, Any]:
        self.migrate()
        clean_tag = display_tag.strip()
        if not 1 <= len(clean_tag) <= 12:
            raise ValueError("display tag must contain 1 to 12 characters")
        with self.connect() as connection:
            cursor = connection.execute(
                """
                UPDATE categories
                SET display_title = ?, display_tag = ?, description = ?,
                    editorial_brief = ?, age_min = ?, age_max = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                WHERE slug = ? AND is_active = 1
                  AND production_status != 'archived'
                """,
                (
                    display_title.strip(),
                    clean_tag,
                    description.strip(),
                    editorial_brief.strip(),
                    age_min,
                    age_max,
                    slug,
                ),
            )
            if not cursor.rowcount:
                raise KeyError(f"category {slug} does not exist")
            row = connection.execute(
                "SELECT * FROM categories WHERE slug = ?", (slug,)
            ).fetchone()
        return dict(row)

    def create_object(
        self,
        *,
        category_id: int,
        name: str,
        slug: str | None,
        description: str,
    ) -> dict[str, Any]:
        self.migrate()
        object_slug = _slug(slug or name)
        with self.connect() as connection:
            category = connection.execute(
                "SELECT id, slug FROM categories WHERE id = ?", (category_id,)
            ).fetchone()
            if category is None:
                raise KeyError(f"category {category_id} does not exist")
            sort_order = connection.execute(
                "SELECT COALESCE(MAX(sort_order), 0) + 1 AS value FROM quiz_objects WHERE category_id = ?",
                (category_id,),
            ).fetchone()["value"]
            cursor = connection.execute(
                """
                INSERT INTO quiz_objects(
                    category_id, slug, name, description, asset_key, sort_order
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    category_id,
                    object_slug,
                    name.strip(),
                    description.strip(),
                    f"{category['slug']}/{object_slug}",
                    sort_order,
                ),
            )
            object_id = int(cursor.lastrowid)
            row = connection.execute(
                "SELECT * FROM quiz_objects WHERE id = ?", (object_id,)
            ).fetchone()
        return dict(row)

    def _ensure_object(
        self, connection: sqlite3.Connection, document: PlanDocument
    ) -> sqlite3.Row:
        category_slug = _slug(document.request.category)
        object_slug = _slug(document.request.subject)
        category = connection.execute(
            "SELECT id FROM categories WHERE slug = ?", (category_slug,)
        ).fetchone()
        if category is None:
            connection.execute(
                """
                INSERT INTO categories(slug, name, description, age_min, age_max, sort_order)
                VALUES (?, ?, ?, ?, ?, 999)
                """,
                (
                    category_slug,
                    document.request.category,
                    f"Custom category for {document.request.category} quizzes.",
                    document.request.age_min,
                    document.request.age_max,
                ),
            )
            category = connection.execute(
                "SELECT id FROM categories WHERE slug = ?", (category_slug,)
            ).fetchone()
        item = connection.execute(
            "SELECT * FROM quiz_objects WHERE category_id = ? AND slug = ?",
            (category["id"], object_slug),
        ).fetchone()
        if item is None:
            connection.execute(
                """
                INSERT INTO quiz_objects(
                    category_id, slug, name, description, asset_key, sort_order
                ) VALUES (?, ?, ?, ?, ?, 999)
                """,
                (
                    category["id"],
                    object_slug,
                    document.request.subject,
                    document.plan.brief.short_description,
                    f"{category_slug}/{object_slug}",
                ),
            )
            item = connection.execute(
                "SELECT * FROM quiz_objects WHERE category_id = ? AND slug = ?",
                (category["id"], object_slug),
            ).fetchone()
        return item

    def store_plan(self, document: PlanDocument, *, source: str = "vllm") -> StoredPlan:
        self.migrate()
        plan_data = document.model_dump(mode="json")
        canonical = json.dumps(
            plan_data, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        )
        content_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            item = self._ensure_object(connection, document)
            existing = connection.execute(
                """
                SELECT id, revision FROM quiz_plans
                WHERE object_id = ? AND content_hash = ?
                """,
                (item["id"], content_hash),
            ).fetchone()
            if existing:
                connection.commit()
                return StoredPlan(
                    plan_id=existing["id"],
                    object_id=item["id"],
                    revision=existing["revision"],
                    created=False,
                )
            revision = connection.execute(
                "SELECT COALESCE(MAX(revision), 0) + 1 AS revision FROM quiz_plans WHERE object_id = ?",
                (item["id"],),
            ).fetchone()["revision"]
            cursor = connection.execute(
                """
                INSERT INTO quiz_plans(
                    object_id, revision, status, schema_version, plan_json,
                    content_hash, source, model, generation_seed
                ) VALUES (?, ?, 'valid', ?, ?, ?, ?, ?, ?)
                """,
                (
                    item["id"],
                    revision,
                    document.plan.schema_version,
                    canonical,
                    content_hash,
                    source,
                    document.generator.model,
                    document.request.seed,
                ),
            )
            connection.commit()
            return StoredPlan(
                plan_id=int(cursor.lastrowid),
                object_id=item["id"],
                revision=revision,
                created=True,
            )

    def plan_history(self, *, limit: int = 50) -> list[dict[str, Any]]:
        self.migrate()
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT plan_json FROM quiz_plans
                WHERE status = 'valid'
                ORDER BY created_at DESC, id DESC LIMIT ?
                """,
                (limit,),
            ).fetchall()
        history: list[dict[str, Any]] = []
        for row in rows:
            try:
                document = PlanDocument.model_validate_json(row["plan_json"])
            except ValueError:
                continue
            plan = document.plan
            history.append(
                {
                    "category": plan.brief.category,
                    "subject": plan.brief.subject,
                    "theme_name": plan.visual_design.theme_name,
                    "question_ideas": [
                        {
                            "novelty_key": question.novelty_key,
                            "learning_objective": question.learning_objective,
                            "prompt_text": question.prompt_text,
                        }
                        for question in plan.questions
                    ],
                }
            )
        return history

    def plan_document(self, plan_id: int) -> PlanDocument:
        self.migrate()
        with self.connect() as connection:
            row = connection.execute(
                "SELECT plan_json FROM quiz_plans WHERE id = ?", (plan_id,)
            ).fetchone()
        if row is None:
            raise KeyError(f"plan {plan_id} does not exist")
        return PlanDocument.model_validate_json(row["plan_json"])

    def object_detail(self, object_id: int) -> dict[str, Any]:
        self.migrate()
        with self.connect() as connection:
            item = connection.execute(
                """
                SELECT o.id, o.slug, o.name, o.description, o.asset_key, o.status,
                       c.id AS category_id, c.slug AS category_slug,
                       c.name AS category_name, c.description AS category_description,
                       c.age_min, c.age_max
                FROM quiz_objects o
                JOIN categories c ON c.id = o.category_id
                WHERE o.id = ?
                """,
                (object_id,),
            ).fetchone()
            if item is None:
                raise KeyError(f"quiz object {object_id} does not exist")
            plans = connection.execute(
                """
                SELECT id, revision, status, schema_version, source, model,
                       generation_seed, created_at
                FROM quiz_plans WHERE object_id = ?
                ORDER BY revision DESC
                """,
                (object_id,),
            ).fetchall()
        result = dict(item)
        result["plans"] = [dict(row) for row in plans]
        result["current_plan_id"] = plans[0]["id"] if plans else None
        return result

    def plan_context(self, plan_id: int) -> dict[str, Any]:
        self.migrate()
        with self.connect() as connection:
            row = connection.execute(
                """
                SELECT p.id AS plan_id, p.revision, p.status AS plan_status,
                       p.source, p.model, p.generation_seed, p.created_at,
                       p.plan_json, o.id AS object_id, o.slug AS object_slug,
                       o.name AS object_name, o.asset_key,
                       c.id AS category_id, c.slug AS category_slug,
                       c.name AS category_name, c.age_min, c.age_max
                FROM quiz_plans p
                JOIN quiz_objects o ON o.id = p.object_id
                JOIN categories c ON c.id = o.category_id
                WHERE p.id = ?
                """,
                (plan_id,),
            ).fetchone()
        if row is None:
            raise KeyError(f"plan {plan_id} does not exist")
        result = dict(row)
        result["document"] = PlanDocument.model_validate_json(result.pop("plan_json"))
        return result

    def studio_categories(self) -> list[dict[str, Any]]:
        self.migrate()
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT id, slug, name, display_title, display_tag, description, editorial_brief,
                       age_min, age_max, production_status, created_at, updated_at
                FROM categories
                WHERE is_active = 1 AND production_status != 'archived'
                ORDER BY sort_order, name
                """
            ).fetchall()
        return [dict(row) for row in rows]

    def studio_category(self, slug: str) -> dict[str, Any]:
        self.migrate()
        with self.connect() as connection:
            row = connection.execute(
                """
                SELECT id, slug, name, display_title, display_tag, description, editorial_brief,
                       age_min, age_max, production_status, created_at, updated_at
                FROM categories
                WHERE slug = ? AND is_active = 1 AND production_status != 'archived'
                """,
                (slug,),
            ).fetchone()
        if row is None:
            raise KeyError(f"category {slug} does not exist")
        return dict(row)

    def question_reviews(
        self, category_slug: str, difficulty: str | None = None
    ) -> dict[str, dict[str, Any]]:
        self.migrate()
        query = "SELECT * FROM question_reviews WHERE category_slug = ?"
        parameters: list[Any] = [category_slug]
        if difficulty:
            query += " AND difficulty = ?"
            parameters.append(difficulty)
        with self.connect() as connection:
            rows = connection.execute(query, parameters).fetchall()
        return {row["question_id"]: dict(row) for row in rows}

    def upsert_question_review(
        self,
        *,
        category_slug: str,
        difficulty: str,
        question_id: str,
        status: str,
        notes: str,
        reviewer: str = "admin",
    ) -> dict[str, Any]:
        self.migrate()
        reviewed_at = None if status == "unreviewed" else "now"
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO question_reviews(
                    category_slug, difficulty, question_id, status, notes,
                    reviewer, reviewed_at
                ) VALUES (?, ?, ?, ?, ?, ?,
                    CASE WHEN ? IS NULL THEN NULL ELSE strftime('%Y-%m-%dT%H:%M:%fZ', 'now') END)
                ON CONFLICT(category_slug, difficulty, question_id) DO UPDATE SET
                    status = excluded.status,
                    notes = excluded.notes,
                    reviewer = excluded.reviewer,
                    reviewed_at = excluded.reviewed_at,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                """,
                (
                    category_slug,
                    difficulty,
                    question_id,
                    status,
                    notes,
                    reviewer,
                    reviewed_at,
                ),
            )
            row = connection.execute(
                """
                SELECT * FROM question_reviews
                WHERE category_slug = ? AND difficulty = ? AND question_id = ?
                """,
                (category_slug, difficulty, question_id),
            ).fetchone()
        return dict(row)

    def record_question_revision(
        self,
        *,
        category_slug: str,
        difficulty: str,
        question_id: str,
        action: str,
        before: dict[str, Any] | None,
        after: dict[str, Any] | None,
        actor: str = "admin",
        source_provider: str | None = None,
        source_model: str | None = None,
    ) -> int:
        self.migrate()
        with self.connect() as connection:
            cursor = connection.execute(
                """
                INSERT INTO question_bank_revisions(
                    category_slug, difficulty, question_id, action,
                    before_json, after_json, actor, source_provider, source_model
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    category_slug,
                    difficulty,
                    question_id,
                    action,
                    json.dumps(before, ensure_ascii=True) if before is not None else None,
                    json.dumps(after, ensure_ascii=True) if after is not None else None,
                    actor,
                    source_provider,
                    source_model,
                ),
            )
        return int(cursor.lastrowid)

    def question_revisions(
        self,
        category_slug: str,
        difficulty: str,
        question_id: str,
        *,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        self.migrate()
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT * FROM question_bank_revisions
                WHERE category_slug = ? AND difficulty = ? AND question_id = ?
                ORDER BY id DESC LIMIT ?
                """,
                (category_slug, difficulty, question_id, limit),
            ).fetchall()
        result: list[dict[str, Any]] = []
        for row in rows:
            item = dict(row)
            before_json = item.pop("before_json")
            after_json = item.pop("after_json")
            item["before"] = (
                json.loads(before_json) if before_json is not None else None
            )
            item["after"] = (
                json.loads(after_json) if after_json is not None else None
            )
            result.append(item)
        return result

    def quiz_set_reviews(
        self, category_slug: str, difficulty: str | None = None
    ) -> dict[str, dict[str, Any]]:
        self.migrate()
        query = "SELECT * FROM quiz_set_reviews WHERE category_slug = ?"
        parameters: list[Any] = [category_slug]
        if difficulty:
            query += " AND difficulty = ?"
            parameters.append(difficulty)
        with self.connect() as connection:
            rows = connection.execute(query, parameters).fetchall()
        return {row["set_id"]: dict(row) for row in rows}

    def upsert_quiz_set_review(
        self,
        *,
        category_slug: str,
        difficulty: str,
        set_id: str,
        status: str,
        notes: str,
        reviewer: str = "admin",
    ) -> dict[str, Any]:
        self.migrate()
        reviewed_at = None if status == "unreviewed" else "now"
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO quiz_set_reviews(
                    category_slug, difficulty, set_id, status, notes,
                    reviewer, reviewed_at
                ) VALUES (?, ?, ?, ?, ?, ?,
                    CASE WHEN ? IS NULL THEN NULL ELSE strftime('%Y-%m-%dT%H:%M:%fZ', 'now') END)
                ON CONFLICT(category_slug, difficulty, set_id) DO UPDATE SET
                    status = excluded.status,
                    notes = excluded.notes,
                    reviewer = excluded.reviewer,
                    reviewed_at = excluded.reviewed_at,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                """,
                (
                    category_slug,
                    difficulty,
                    set_id,
                    status,
                    notes,
                    reviewer,
                    reviewed_at,
                ),
            )
            row = connection.execute(
                """
                SELECT * FROM quiz_set_reviews
                WHERE category_slug = ? AND difficulty = ? AND set_id = ?
                """,
                (category_slug, difficulty, set_id),
            ).fetchone()
        return dict(row)

    def record_quiz_set_revision(
        self,
        *,
        category_slug: str,
        difficulty: str,
        set_id: str,
        action: str,
        before: dict[str, Any] | None,
        after: dict[str, Any] | None,
        actor: str = "admin",
        source_provider: str | None = None,
        source_model: str | None = None,
    ) -> int:
        self.migrate()
        with self.connect() as connection:
            cursor = connection.execute(
                """
                INSERT INTO quiz_set_revisions(
                    category_slug, difficulty, set_id, action,
                    before_json, after_json, actor, source_provider, source_model
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    category_slug,
                    difficulty,
                    set_id,
                    action,
                    json.dumps(before, ensure_ascii=True) if before is not None else None,
                    json.dumps(after, ensure_ascii=True) if after is not None else None,
                    actor,
                    source_provider,
                    source_model,
                ),
            )
        return int(cursor.lastrowid)

    def quiz_set_revisions(
        self,
        category_slug: str,
        difficulty: str,
        set_id: str,
        *,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        self.migrate()
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT * FROM quiz_set_revisions
                WHERE category_slug = ? AND difficulty = ? AND set_id = ?
                ORDER BY id DESC LIMIT ?
                """,
                (category_slug, difficulty, set_id, limit),
            ).fetchall()
        result: list[dict[str, Any]] = []
        for row in rows:
            item = dict(row)
            before_json = item.pop("before_json")
            after_json = item.pop("after_json")
            item["before"] = json.loads(before_json) if before_json else None
            item["after"] = json.loads(after_json) if after_json else None
            result.append(item)
        return result

    def seed_provider_connections(self, connections: list[dict[str, Any]]) -> None:
        self.migrate()
        with self.connect() as connection:
            for item in connections:
                connection.execute(
                    """
                    INSERT OR IGNORE INTO provider_connections(
                        id, provider_type, name, base_url, default_model,
                        settings_json, enabled
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        item["id"],
                        item["provider_type"],
                        item["name"],
                        item["base_url"],
                        item.get("default_model"),
                        json.dumps(item.get("settings", {}), ensure_ascii=True),
                        int(item.get("enabled", True)),
                    ),
                )

    def provider_connections(self) -> list[dict[str, Any]]:
        self.migrate()
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT * FROM provider_connections
                ORDER BY CASE provider_type
                    WHEN 'openai_compatible_llm' THEN 1
                    WHEN 'imagestudio' THEN 2
                    WHEN 'openai_images' THEN 3
                    WHEN 'vibevoice' THEN 4
                    ELSE 9 END, name
                """
            ).fetchall()
        return [self._provider_row(row) for row in rows]

    def provider_connection(self, provider_id: str) -> dict[str, Any]:
        self.migrate()
        with self.connect() as connection:
            row = connection.execute(
                "SELECT * FROM provider_connections WHERE id = ?", (provider_id,)
            ).fetchone()
        if row is None:
            raise KeyError(f"provider {provider_id} does not exist")
        return self._provider_row(row)

    @staticmethod
    def _provider_row(row: sqlite3.Row) -> dict[str, Any]:
        result = dict(row)
        result["enabled"] = bool(result["enabled"])
        result["settings"] = json.loads(result.pop("settings_json"))
        result["discovered_models"] = json.loads(
            result.pop("discovered_models_json")
        )
        return result

    def create_provider_connection(self, item: dict[str, Any]) -> dict[str, Any]:
        self.migrate()
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO provider_connections(
                    id, provider_type, name, base_url, secret_ciphertext,
                    secret_fingerprint, secret_last_four, default_model,
                    settings_json, enabled
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    item["id"],
                    item["provider_type"],
                    item["name"],
                    item["base_url"],
                    item.get("secret_ciphertext"),
                    item.get("secret_fingerprint"),
                    item.get("secret_last_four"),
                    item.get("default_model"),
                    json.dumps(item.get("settings", {}), ensure_ascii=True),
                    int(item.get("enabled", True)),
                ),
            )
        return self.provider_connection(item["id"])

    def update_provider_connection(
        self, provider_id: str, item: dict[str, Any]
    ) -> dict[str, Any]:
        existing = self.provider_connection(provider_id)
        values = {**existing, **item}
        with self.connect() as connection:
            connection.execute(
                """
                UPDATE provider_connections SET
                    name = ?, base_url = ?, secret_ciphertext = ?,
                    secret_fingerprint = ?, secret_last_four = ?,
                    default_model = ?, settings_json = ?, enabled = ?,
                    health_status = 'unchecked', health_message = NULL,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                WHERE id = ?
                """,
                (
                    values["name"],
                    values["base_url"],
                    values.get("secret_ciphertext"),
                    values.get("secret_fingerprint"),
                    values.get("secret_last_four"),
                    values.get("default_model"),
                    json.dumps(values.get("settings", {}), ensure_ascii=True),
                    int(values.get("enabled", True)),
                    provider_id,
                ),
            )
        return self.provider_connection(provider_id)

    def update_provider_health(
        self,
        provider_id: str,
        *,
        status: str,
        message: str,
        checked_at: str,
        models: list[str] | None = None,
        default_model: str | None = None,
    ) -> dict[str, Any]:
        existing = self.provider_connection(provider_id)
        discovered = models if models is not None else existing["discovered_models"]
        selected = default_model or existing.get("default_model")
        if not selected and len(discovered) == 1:
            selected = discovered[0]
        with self.connect() as connection:
            connection.execute(
                """
                UPDATE provider_connections SET
                    health_status = ?, health_message = ?, last_checked_at = ?,
                    discovered_models_json = ?, default_model = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                WHERE id = ?
                """,
                (
                    status,
                    message,
                    checked_at,
                    json.dumps(discovered, ensure_ascii=True),
                    selected,
                    provider_id,
                ),
            )
        return self.provider_connection(provider_id)

    def mark_interrupted_jobs(
        self, updated_at: str, *, kinds: set[str] | None = None
    ) -> int:
        self.migrate()
        kind_clause = ""
        parameters: list[Any] = [updated_at, updated_at]
        if kinds:
            placeholders = ", ".join("?" for _ in kinds)
            kind_clause = f" AND kind IN ({placeholders})"
            parameters.extend(sorted(kinds))
        with self.connect() as connection:
            cursor = connection.execute(
                f"""
                UPDATE studio_jobs
                SET status = 'interrupted',
                    message = 'Interrupted by service restart',
                    error = 'The service restarted before this job completed.',
                    completed_at = ?, updated_at = ?
                WHERE status IN ('queued', 'running')
                {kind_clause}
                """,
                parameters,
            )
        return cursor.rowcount

    def create_studio_job(self, item: dict[str, Any]) -> dict[str, Any]:
        self.migrate()
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO studio_jobs(
                    id, kind, status, message, progress, context_json,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    item["id"],
                    item["kind"],
                    item["status"],
                    item["message"],
                    item.get("progress", 0),
                    json.dumps(item.get("context", {}), ensure_ascii=True),
                    item["created_at"],
                    item["updated_at"],
                ),
            )
            connection.execute(
                """
                INSERT INTO studio_job_events(job_id, status, message, progress, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    item["id"],
                    item["status"],
                    item["message"],
                    item.get("progress", 0),
                    item["updated_at"],
                ),
            )
        return self.studio_job(item["id"])

    def update_studio_job(
        self,
        job_id: str,
        *,
        status: str,
        message: str,
        progress: float,
        updated_at: str,
        result: dict[str, Any] | None = None,
        error: str | None = None,
    ) -> dict[str, Any]:
        started_at = updated_at if status == "running" else None
        completed_at = updated_at if status in {"complete", "failed", "cancelled"} else None
        with self.connect() as connection:
            connection.execute(
                """
                UPDATE studio_jobs SET
                    status = ?, message = ?, progress = ?, result_json = ?,
                    error = ?, started_at = COALESCE(started_at, ?),
                    completed_at = COALESCE(?, completed_at), updated_at = ?
                WHERE id = ?
                """,
                (
                    status,
                    message,
                    progress,
                    json.dumps(result, ensure_ascii=True) if result is not None else None,
                    error,
                    started_at,
                    completed_at,
                    updated_at,
                    job_id,
                ),
            )
            connection.execute(
                """
                INSERT INTO studio_job_events(job_id, status, message, progress, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (job_id, status, message, progress, updated_at),
            )
        return self.studio_job(job_id)

    def studio_job(self, job_id: str) -> dict[str, Any]:
        self.migrate()
        with self.connect() as connection:
            row = connection.execute(
                "SELECT * FROM studio_jobs WHERE id = ?", (job_id,)
            ).fetchone()
        if row is None:
            raise KeyError(job_id)
        result = dict(row)
        result["context"] = json.loads(result.pop("context_json"))
        result["result"] = (
            json.loads(result.pop("result_json"))
            if result.get("result_json") is not None
            else None
        )
        return result

    def studio_jobs(self, *, limit: int = 50) -> list[dict[str, Any]]:
        self.migrate()
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT id FROM studio_jobs ORDER BY updated_at DESC LIMIT ?", (limit,)
            ).fetchall()
        return [self.studio_job(row["id"]) for row in rows]

    def studio_job_events(self, job_id: str, *, after: int = 0) -> list[dict[str, Any]]:
        self.studio_job(job_id)
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT id, job_id, status, message, progress, created_at
                FROM studio_job_events
                WHERE job_id = ? AND id > ? ORDER BY id
                """,
                (job_id, after),
            ).fetchall()
        return [dict(row) for row in rows]
