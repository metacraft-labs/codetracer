// 2 + a.b
// if let Program { node: Node::Int(2), path: "a", name: n, optimize: false } = program { log(n) }
// if let Node::Int(A(i), b, _) = int_node {
//     log(i)
// }

// if (local != local2) { log(1) }
// log(-1 + 2)
// -1

// // log(-c_int_array[1])
// // (c_int_array)[0]
// // a()[0]
// // log(a())
// // -(-1)
// // log(0 * c_int_array[1])
// // log(c_int_array[1] * 0)
// // log(c_int_array[0 * 2])
// // // based on Franz's example
// // --1
// // not true
// // -a.b
// log(-1 + 2 * c_int_array[c_int_array[1 + c_int_array[3 / 2]] + 2] * 3 -(-1))

// // // a * b[2]
// // // BinOp(Name(a), op(*), Index(Name(b), Int(2)))


// // if (a) {
// //   log(A, b, c.field.field2[0][1], "a") // a=1, b=2, c.field.field2[0][1]=3, "a"
// // }
// // log(toText(a)) // toText(a)="5"


// // for (a in args) {
// //   log(a)
// //   log(a)
// // }

// // for (i in 0..<10) {
// //   log(i) // TODO how to log exactly multiple values at a location on a single tracepoint?
// // }

// // for (i, a in args) {
//   log(i, a) // structured logging, separate values, not a single string: i=<i> a=<a>
//   log("i={i} a={text()}") // interpolation, directly text => "i=<> a=<>"
// }

// if (a + b == c) {
//   log(c + d)
// }

// за (i, a в args) {
//   покажи(i, a)
// }

// // show(a)
// // dot vis for trees?
// // or just simpler sexp renderers?
// // default visualizations and some more custom
// // e.g. nim node / other recursive type: tree

// // eventually cprint! log! if needed and clash there?
// // cprint("i={i} {a}")
// // log("i={i} {a}")
// // log!("i={i} {a}")
// // log!("i={} {}", i, a)

if a {
    log(b)
} else if c {
    log(d)
} else if e {
    log(f)
} else {
    log(g)
}

