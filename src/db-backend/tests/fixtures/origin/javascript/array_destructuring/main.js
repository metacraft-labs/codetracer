// array_destructuring - JavaScript
// `const [a, b] = arr` decomposes into one IndexAccess hop per target per
// spec §7.2 JS override. The terminating array literal is the Computational
// hop whose operand snapshots capture the element values.
function main() {
  const arr = [11, 22];
  const [a, b] = arr;
  console.log(a, b);
}

main();
