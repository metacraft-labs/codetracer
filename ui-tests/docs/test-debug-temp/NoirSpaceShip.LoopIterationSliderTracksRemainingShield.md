# NoirSpaceShip.LoopIterationSliderTracksRemainingShield

- **Test Id:** `NoirSpaceShip.LoopIterationSliderTracksRemainingShield`
- **Current Status:** Not Run (pending debugging)
- **Last Attempt:** Not yet executed in this debugging session
- **Purpose:** Drives the flow iteration slider and asserts `remaining_shield`/`damage` variables reflect the expected values for the first few iterations.
- **Notes:** Potential hang point is the slider evaluation via `noUiSlider`. Record console logs if the slider element is missing.
