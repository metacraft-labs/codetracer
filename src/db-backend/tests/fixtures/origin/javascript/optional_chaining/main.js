// optional_chaining - JavaScript
// `x = obj?.field` classifies as FieldAccess per spec §7.2 JS override.
// When `obj` is non-null the optional chain behaves identically to the
// non-optional member access; the classifier records confidence >= 0.7
// to acknowledge the potential null-collapse branch.
function main() {
  const obj = { field: 42 };
  const x = obj?.field;
  console.log(x);
}

main();
