// fn run(x: Field, y: [8; Field]) -> Field {
//     let length = 8;
//     for item in 0 .. length {
//         let item = y[i];
//         if check(x, item) {
//             print("found");
//             return x;
//         } else {

//         }
//     }
//         print(">");
//     }
// }

fn main(x: Field, y: pub Field) {
    println(f"x {x}"); // marker: PRINT_X_LINE
    println(f"y {y}"); // marker: PRINT_Y_LINE
    assert(x != y); // marker: ASSERT_LINE
}

// #[test]
// fn test_main() {
//     main(1, 2);

//     // Uncomment to make test fail
//     // main(1, 1);
// }
