// object_destructuring - JavaScript
// `const { a, b } = obj` decomposes into one FieldAccess hop per target
// per spec §7.2 JS override. The terminating object literal is the
// Computational hop whose operand snapshots capture the field values.
function main() {
  const obj = { a: 11, b: 22 };
  const { a, b } = obj;
  console.log(a, b);
}

main();
