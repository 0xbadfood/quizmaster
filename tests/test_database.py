from pathlib import Path

from quiz_harness.database import QuizDatabase
from quiz_harness.models import PlanDocument


def lion_document() -> PlanDocument:
    path = Path("plans/animals-lion-single.json")
    return PlanDocument.model_validate_json(path.read_text(encoding="utf-8"))


def test_migrations_are_idempotent(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    assert database.migrate() == [1, 2, 3, 4, 5, 6, 7]
    assert database.migrate() == []


def test_video_catalog_persists_render_history(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    category = database.create_category(
        name="Geography",
        slug="geography",
        display_title="GEOGRAPHY QUIZ",
        display_tag="Geography",
        description="Places and features of the world.",
        editorial_brief="Child-facing geography with deterministic answers.",
        age_min=5,
        age_max=10,
    )
    created = database.create_studio_video(
        {
            "id": "video-1",
            "category_slug": category["slug"],
            "title": "Geography · Landscape · 20 questions",
            "orientation": "landscape",
            "bundle_version": 3,
            "selections": [
                {"set_id": "geography_beginner_01", "question_count": 10},
                {"set_id": "geography_beginner_02", "question_count": 10},
            ],
            "question_count": 20,
            "status": "queued",
            "created_at": "2026-08-20T10:00:00+00:00",
            "updated_at": "2026-08-20T10:00:00+00:00",
        }
    )
    assert created["selections"][1]["set_id"] == "geography_beginner_02"

    database.attach_studio_video_job(
        "video-1",
        job_id="job-1",
        updated_at="2026-08-20T10:01:00+00:00",
    )
    complete = database.update_studio_video(
        "video-1",
        status="complete",
        file_name="geography.mp4",
        file_path="/tmp/geography.mp4",
        file_bytes=2048,
        duration_seconds=240.5,
        updated_at="2026-08-20T10:05:00+00:00",
    )

    assert complete["job_id"] == "job-1"
    assert complete["duration_seconds"] == 240.5
    assert database.studio_videos("geography")[0]["file_name"] == "geography.mp4"


def test_interrupted_video_render_is_recovered(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    database.create_category(
        name="Space",
        slug="space",
        display_title="SPACE QUIZ",
        display_tag="Space",
        description="Planets and exploration.",
        editorial_brief="Age-appropriate facts about space.",
        age_min=5,
        age_max=10,
    )
    database.create_studio_video(
        {
            "id": "video-running",
            "category_slug": "space",
            "title": "Space · Portrait · 10 questions",
            "orientation": "portrait",
            "bundle_version": 1,
            "selections": [{"set_id": "space_beginner_01", "question_count": 10}],
            "question_count": 10,
            "status": "rendering",
            "created_at": "2026-08-20T10:00:00+00:00",
            "updated_at": "2026-08-20T10:00:00+00:00",
        }
    )

    assert database.mark_interrupted_videos("2026-08-20T10:02:00+00:00") == 1
    assert database.studio_video("video-running")["status"] == "interrupted"


def test_youtube_connection_oauth_state_and_upload_history(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    database.create_category(
        name="Geography",
        slug="geography",
        display_title="GEOGRAPHY QUIZ",
        display_tag="Geography",
        description="Places and features of the world.",
        editorial_brief="Child-facing geography with deterministic answers.",
        age_min=5,
        age_max=10,
    )
    database.create_studio_video(
        {
            "id": "video-youtube",
            "category_slug": "geography",
            "title": "Geography Quiz",
            "orientation": "landscape",
            "bundle_version": 3,
            "selections": [
                {"set_id": "geography_beginner_01", "question_count": 10}
            ],
            "question_count": 10,
            "status": "complete",
            "created_at": "2026-08-21T10:00:00+00:00",
            "updated_at": "2026-08-21T10:00:00+00:00",
        }
    )

    connection = database.save_youtube_credentials(
        client_id="client.apps.googleusercontent.com",
        client_secret_ciphertext="encrypted-client-secret",
        client_secret_last_four="cret",
        created_at="2026-08-21T10:00:00+00:00",
        updated_at="2026-08-21T10:00:00+00:00",
    )
    assert connection["refresh_token_ciphertext"] is None
    authorized = database.authorize_youtube(
        refresh_token_ciphertext="encrypted-refresh-token",
        refresh_token_last_four="oken",
        channel_id="channel-1",
        channel_title="Quizmaster",
        connected_at="2026-08-21T10:01:00+00:00",
    )
    assert authorized["channel_title"] == "Quizmaster"

    database.create_youtube_oauth_state(
        state_hash="state-hash",
        redirect_uri="https://quiz.example/callback",
        expires_at="2026-08-21T10:10:00+00:00",
        created_at="2026-08-21T10:00:00+00:00",
    )
    state = database.consume_youtube_oauth_state(
        state_hash="state-hash", now="2026-08-21T10:02:00+00:00"
    )
    assert state is not None
    assert state["redirect_uri"] == "https://quiz.example/callback"
    assert (
        database.consume_youtube_oauth_state(
            state_hash="state-hash", now="2026-08-21T10:03:00+00:00"
        )
        is None
    )

    upload = database.create_youtube_upload(
        {
            "id": "upload-1",
            "video_id": "video-youtube",
            "title": "Geography Quiz",
            "description": "A quiz description",
            "privacy_status": "private",
            "status": "queued",
            "created_at": "2026-08-21T10:04:00+00:00",
            "updated_at": "2026-08-21T10:04:00+00:00",
        }
    )
    assert upload["status"] == "queued"
    database.attach_youtube_upload_job(
        "upload-1", job_id="job-1", updated_at="2026-08-21T10:05:00+00:00"
    )
    complete = database.update_youtube_upload(
        "upload-1",
        status="complete",
        youtube_video_id="youtube-1",
        youtube_url="https://youtu.be/youtube-1",
        updated_at="2026-08-21T10:06:00+00:00",
    )
    assert complete["job_id"] == "job-1"
    assert database.latest_youtube_upload("video-youtube")["youtube_video_id"] == (
        "youtube-1"
    )


def test_interrupted_youtube_upload_is_recovered(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    database.create_category(
        name="Space",
        slug="space",
        display_title="SPACE QUIZ",
        display_tag="Space",
        description="Planets and exploration.",
        editorial_brief="Age-appropriate facts about space.",
        age_min=5,
        age_max=10,
    )
    database.create_studio_video(
        {
            "id": "video-uploading",
            "category_slug": "space",
            "title": "Space Quiz",
            "orientation": "portrait",
            "bundle_version": 1,
            "selections": [{"set_id": "space_beginner_01", "question_count": 10}],
            "question_count": 10,
            "status": "complete",
            "created_at": "2026-08-21T10:00:00+00:00",
            "updated_at": "2026-08-21T10:00:00+00:00",
        }
    )
    database.create_youtube_upload(
        {
            "id": "upload-running",
            "video_id": "video-uploading",
            "title": "Space Quiz",
            "description": "A space quiz",
            "privacy_status": "unlisted",
            "status": "uploading",
            "created_at": "2026-08-21T10:01:00+00:00",
            "updated_at": "2026-08-21T10:01:00+00:00",
        }
    )

    assert database.mark_interrupted_youtube_uploads(
        "2026-08-21T10:02:00+00:00"
    ) == 1
    interrupted = database.youtube_upload("upload-running")
    assert interrupted["status"] == "interrupted"
    assert "service restarted" in interrupted["error"]


def test_category_metadata_is_persisted_and_slug_is_immutable(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    created = database.create_category(
        name="Ancient Civilizations",
        slug=None,
        display_title="ANCIENT WORLD QUIZ",
        display_tag="Ancient",
        description="Early societies, monuments, writing, and trade.",
        editorial_brief=(
            "Age-appropriate world history focused on early civilizations and "
            "their lasting achievements."
        ),
        age_min=7,
        age_max=10,
    )

    assert created["slug"] == "ancient-civilizations"
    assert created["display_title"] == "ANCIENT WORLD QUIZ"
    assert created["display_tag"] == "Ancient"
    assert created["production_status"] == "draft"

    updated = database.update_category_metadata(
        created["slug"],
        name="Ancient Civilizations",
        display_title="ANCIENT CIVILIZATIONS QUIZ",
        display_tag="Civilization",
        description="Early societies, monuments, writing, and trade.",
        editorial_brief=(
            "Age-appropriate world history focused on early civilizations, "
            "material culture, and their lasting achievements."
        ),
        age_min=7,
        age_max=11,
    )

    assert updated["slug"] == created["slug"]
    assert updated["display_title"] == "ANCIENT CIVILIZATIONS QUIZ"
    assert updated["display_tag"] == "Civilization"
    assert updated["age_max"] == 11

    attempted_rename = database.update_category_metadata(
        created["slug"],
        name="Renamed Category",
        display_title="ANCIENT CIVILIZATIONS QUIZ",
        display_tag="Civilization",
        description="Early societies, monuments, writing, and trade.",
        editorial_brief=(
            "Age-appropriate world history focused on early civilizations, "
            "material culture, and their lasting achievements."
        ),
        age_min=7,
        age_max=11,
    )
    assert attempted_rename["name"] == "Ancient Civilizations"


def test_question_reviews_and_revision_history_are_persistent(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    review = database.upsert_question_review(
        category_slug="animals",
        difficulty="beginner",
        question_id="animals_beginner_001",
        status="approved",
        notes="Clear deterministic clue",
    )
    assert review["status"] == "approved"
    assert review["reviewed_at"] is not None
    assert database.question_reviews("animals")["animals_beginner_001"]["notes"]

    database.record_question_revision(
        category_slug="animals",
        difficulty="beginner",
        question_id="animals_beginner_001",
        action="reviewed",
        before={"status": "unreviewed"},
        after={"status": "approved"},
    )
    history = database.question_revisions(
        "animals", "beginner", "animals_beginner_001"
    )
    assert history[0]["action"] == "reviewed"
    assert history[0]["after"] == {"status": "approved"}


def test_quiz_set_reviews_and_revision_history_are_persistent(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    review = database.upsert_quiz_set_review(
        category_slug="animals",
        difficulty="beginner",
        set_id="animals_beginner_001",
        status="needs_edit",
        notes="Replace one repetitive clue",
    )
    assert review["status"] == "needs_edit"
    assert database.quiz_set_reviews("animals")["animals_beginner_001"]["notes"]

    database.record_quiz_set_revision(
        category_slug="animals",
        difficulty="beginner",
        set_id="animals_beginner_001",
        action="reviewed",
        before={"status": "unreviewed"},
        after={"status": "needs_edit"},
    )
    history = database.quiz_set_revisions(
        "animals", "beginner", "animals_beginner_001"
    )
    assert history[0]["after"] == {"status": "needs_edit"}


def test_seed_catalog_is_idempotent(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    assert database.seed_catalog() == (6, 30)
    assert database.seed_catalog() == (6, 30)
    catalog = database.catalog()
    assert [category["slug"] for category in catalog] == [
        "animals",
        "birds",
        "food",
        "vehicles",
        "space",
        "world-history",
    ]
    assert all(len(category["objects"]) == 5 for category in catalog)


def test_store_plan_creates_immutable_revision_and_history(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    database.seed_catalog()
    document = lion_document()

    first = database.store_plan(document, source="import")
    duplicate = database.store_plan(document, source="import")

    assert first.created is True
    assert first.revision == 1
    assert duplicate.created is False
    assert duplicate.plan_id == first.plan_id
    assert database.plan_document(first.plan_id) == document
    history = database.plan_history()
    assert history[0]["subject"] == "lion"
    assert history[0]["question_ideas"][0]["novelty_key"] == "auditory_association"

    revised_data = document.model_dump(mode="json")
    revised_data["request"]["seed"] += 1
    revised = database.store_plan(
        PlanDocument.model_validate(revised_data), source="manual"
    )
    assert revised.created is True
    assert revised.revision == 2
    assert database.plan_document(first.plan_id) == document


def test_catalog_reports_current_plan_revision(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    database.seed_catalog()
    database.store_plan(lion_document(), source="import")
    animals = database.catalog()[0]
    lion = next(item for item in animals["objects"] if item["slug"] == "lion")
    assert lion["asset_key"] == "animals/lion"
    assert lion["plan_count"] == 1
    assert lion["current_revision"] == 1


def test_interrupted_job_recovery_can_be_scoped_by_kind(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    database.migrate()
    for job_id, kind in (("pipeline", "category_pipeline_api"), ("visual", "visuals")):
        database.create_studio_job(
            {
                "id": job_id,
                "kind": kind,
                "status": "queued",
                "message": "Queued",
                "progress": 0,
                "context": {},
                "created_at": "2026-08-09T00:00:00+00:00",
                "updated_at": "2026-08-09T00:00:00+00:00",
            }
        )

    count = database.mark_interrupted_jobs(
        "2026-08-09T00:01:00+00:00", kinds={"category_pipeline_api"}
    )

    assert count == 1
    assert database.studio_job("pipeline")["status"] == "interrupted"
    assert database.studio_job("visual")["status"] == "queued"
