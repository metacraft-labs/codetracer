// destructuring_or_index — JavaScript
function main() {
  const pair = [11, 22];
  const [first, second] = pair;  // array destructuring
  const indexed = pair[1];       // index access
  console.log(first, second, indexed);
}

main();
