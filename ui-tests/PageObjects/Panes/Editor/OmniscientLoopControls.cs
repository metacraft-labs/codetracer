using Microsoft.Playwright;

namespace UiTests.PageObjects.Panes.Editor;

/// <summary>
/// Wrapper around the omniscient loop control UI attached to editor lines.
/// </summary>
public class OmniscientLoopControls
{
    public OmniscientLoopControls(ILocator root) => Root = root;

    /// <summary>
    /// Root element containing the loop control widgets.
    /// </summary>
    public ILocator Root { get; }

    /// <summary>
    /// Button to step backward within a loop iteration history.
    /// </summary>
    public ILocator BackwardButton()
        => Root.Locator(".flow-loop-button.backward");

    /// <summary>
    /// Button to step forward within a loop iteration history.
    /// </summary>
    public ILocator ForwardButton()
        => Root.Locator(".flow-loop-button.forward");

    /// <summary>
    /// Container element holding the slider widget.
    /// </summary>
    public ILocator SliderContainer()
        => Root.Locator(".flow-loop-slider-container");

    /// <summary>
    /// Slider control used to scrub through loop iterations.
    /// </summary>
    public ILocator Slider()
        => SliderContainer().Locator(".flow-loop-slider");

    /// <summary>
    /// Container for the loop step elements.
    /// </summary>
    public ILocator StepContainer()
        => Root.Locator(".flow-loop-step-container");

    /// <summary>
    /// Element representing condensed loop iterations.
    /// </summary>
    public ILocator ShrinkedIterationContainer()
        => Root.Locator(".flow-loop-shrinked-iteration");

    /// <summary>
    /// Element representing continuous loop iterations.
    /// </summary>
    public ILocator ContinuousIterationContainer()
        => Root.Locator(".flow-loop-continuous-iteration");
}
