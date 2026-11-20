"""Hold a shallow squat while curling both arms, then stand."""

from eml import Recipe


def recipe() -> Recipe:
    depth = Recipe.param("depth")
    return (
        Recipe("squat-and-curl", "Squat and curl")
        .instructions("Lower into a squat. Hold that depth as you curl and lower both arms, then stand.")
        .start("standing")
        .parameter("depth", default=0.6, minimum=0.4, maximum=0.8)
        .muscles(["quadriceps", "glutes"], ["abdominals"])
        .move("squat-down", 1.4, amount=depth, id="squat")
        .phase(1.0, id="curl")
        .action("squat-down", depth)
        .action("bend-elbows", 0.8)
        .muscles("biceps", ["forearms", "quadriceps", "glutes"], phase=True)
        .move("squat-down", 1.0, amount=depth, id="lower-arms")
        .muscles("biceps", ["forearms", "quadriceps", "glutes"], phase=True)
        .return_to_start(1.4, id="stand")
        .repeat(2)
        .camera(38, 10)
    )
