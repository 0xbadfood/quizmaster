from quiz_harness.answer_images import answer_image_prompt, stable_seed


def test_answer_prompt_is_category_neutral_and_child_friendly() -> None:
    prompt = answer_image_prompt("African elephant")
    assert "recognizable specifically as African elephant" in prompt
    assert "concrete object, living thing, place, or landmark" in prompt
    assert "prepared dish, material, group, nutrient, process, or abstract concept" in prompt
    assert "high-end 3D animated family-film rendering" in prompt
    assert "comfortable square margins" in prompt
    assert "No text, letters, numbers" in prompt
    assert "Pixar" not in prompt
    assert "Disney" not in prompt


def test_answer_image_seed_is_stable_and_animal_specific() -> None:
    first = stable_seed("african_elephant", 42)
    assert first == stable_seed("african_elephant", 42)
    assert first != stable_seed("lion", 42)
    assert first != stable_seed("african_elephant", 43)
