# A program whose repository teaches CodeTracer about itself.
#
# The suites that read it copy this file into a scratch checkout, write a
# `.codetracer/` beside it, and record it there; see
# src/frontend/tui/tests/test_project_definitions_session.nim.
#
# The values are tuples and integers because the Python recorder records
# those structurally (an instance of a class is recorded as its `str()`).


def codetracer_visualise(m):
    # The program's own visualiser (Project-Definitions §5.1, mechanism 1).
    return "a " + str(m[0]) + " by " + str(m[1]) + " matrix"


def scale(m, k):
    total = m[0] * k
    return total


def drift():
    x = 1000
    for i in range(3):
        x = x + 1
    return x


def main():
    m = (3, 4)
    label = codetracer_visualise(m)
    t = scale(m, 2)
    n = (2, 2)
    d = drift()
    print(label, t, n[0], d)


main()
