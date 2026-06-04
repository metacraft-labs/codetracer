# Faux library used by the user-patterns origin fixture.
#
# Without the embedded pattern, the default classifier would treat
# `forward(payload)` as a Computational call (single-arg call that
# transforms its input). The shipped `.codetracer/origin-patterns.toml`
# overrides that, marking the call as TrivialCopy with continuation
# `$value`.


def forward(value):
    """Wrapper that returns its argument unchanged.

    The shipped pattern file tells the origin classifier to treat
    `forward($value)` as a trivial-copy forwarder. The classifier
    therefore continues the origin chain through `$value` rather than
    terminating at the call expression.
    """
    return value
