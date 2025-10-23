using System.Collections.Concurrent;
using System.Linq;
using UiTests.Tests;

namespace UiTests.Execution;

internal interface ITestRegistry
{
    bool TryResolve(string identifier, out UiTestDescriptor descriptor);
    IReadOnlyCollection<UiTestDescriptor> All { get; }
}

internal sealed class TestRegistry : ITestRegistry
{
    private readonly ConcurrentDictionary<string, UiTestDescriptor> _tests;

    public TestRegistry()
    {
        _tests = new ConcurrentDictionary<string, UiTestDescriptor>(StringComparer.OrdinalIgnoreCase);

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.JumpToAllEvents",
                "Noir Space Ship / Jump To All Events",
                async context => await NoirSpaceShipTests.JumpToAllEvents(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.EditorLoadedMainNrFile",
                "Noir Space Ship / Editor Loads main.nr",
                async context => await NoirSpaceShipTests.EditorLoadedMainNrFile(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.CreateSimpleTracePoint",
                "Noir Space Ship / Create Simple Trace Point",
                async context => await NoirSpaceShipTests.CreateSimpleTracePoint(context.Page)));
    }

    public IReadOnlyCollection<UiTestDescriptor> All => _tests.Values.ToList();

    public bool TryResolve(string identifier, out UiTestDescriptor descriptor)
        => _tests.TryGetValue(identifier, out descriptor);

    private void Register(UiTestDescriptor descriptor)
    {
        if (!_tests.TryAdd(descriptor.Id, descriptor))
        {
            throw new InvalidOperationException($"Duplicate test identifier registered: {descriptor.Id}");
        }
    }
}
