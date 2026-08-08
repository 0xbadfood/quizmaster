from quiz_harness.question_models import SetGenerationRequest
from quiz_harness.question_prompts import build_drafter_prompt


def test_drafter_prompt_requests_candidate_pool_and_final_size() -> None:
    prompt = build_drafter_prompt(
        SetGenerationRequest(
            category="Animals",
            difficulty="expert",
            set_number=1,
            seed=42,
        )
    )
    assert '"candidate_question_count": 14' in prompt
    assert '"final_question_count": 10' in prompt
    assert '"difficulty": "expert"' in prompt
