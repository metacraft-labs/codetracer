# Text a terminal may draw at another width than it is counted at: a
# decomposed accent, an em dash and an ellipsis (East Asian Width A), and a
# joined emoji sequence. CodeTracer's terminal front-end draws each as
# recorded (PLAT-71, Terminal-Adaptation 6.5 and 6.6).

GREETING = "café — 👩‍💻 ok"
WAITING = "wait…"


def main():
    print(GREETING)
    print(WAITING)


main()
