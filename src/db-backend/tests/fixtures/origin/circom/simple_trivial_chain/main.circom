pragma circom 2.0.0;

// simple_trivial_chain — Circom
// a=10; b=a; c=b — origin chain terminates at Literal.
//
// The Value Origin query targets the `out` signal at the trailing
// signal-assignment line.  The chain must walk:
//   out -> c (TrivialCopy) -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
//
// Circom uses the `<==` operator for "signal assignment with witness
// generation", which is the canonical signal-assignment idiom called
// out in spec §7.2 (M23 Circom row).  The classifier override
// recognises `signal_target <== signal_source` as a `TrivialCopy` hop
// with `source_variable = signal_source`, identical to a bare-name copy
// in the universal table.  Constant signal assignments terminate at
// `Literal`.
template FlowTest() {
    signal a;
    signal b;
    signal c;
    signal output out;

    a <== 10;
    b <== a;
    c <== b;
    out <== c;
}

component main = FlowTest();
