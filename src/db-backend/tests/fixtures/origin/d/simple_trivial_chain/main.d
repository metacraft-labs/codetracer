// simple_trivial_chain — D
//
// int a = 10; int b = a; int c = b — terminates at Literal.
//
// The D language is currently classifier-untracked (M11 default), so
// the chain query is expected to return DAP error 6103
// (UnsupportedBackend) until the origin-classifier crate gains a D
// tree-sitter grammar.
import std.stdio;

void main() {
    int a = 10;
    int b = a;
    int c = b;
    writeln(c);
}
