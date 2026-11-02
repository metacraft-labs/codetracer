## Import before the legacy UI tree. agent_activity constructs two Monaco
## models at module initialization even when its editor is never mounted.
## These inert objects satisfy that unrelated initialization; using a model
## method still fails, so this cannot simulate editor behavior in these tests.
## The handlers under test never invoke Monaco.
{.emit: "globalThis.monaco = {editor: {createModel: function() { return Object.freeze({}); }}};".}
# The build-output pane constructs this converter on import. Use the shipped
# library, rather than replacing its behavior in the DOM fixture.
{.emit: "globalThis.AnsiUp = require(globalThis.ctRepoRoot + '/node_modules/ansi_up/ansi_up.js').AnsiUp;".}
