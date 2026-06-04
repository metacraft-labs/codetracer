// parameter_pass — JavaScript
function receive(p) {
  const local = p;
  console.log(local);
}

function main() {
  const value = 7;
  receive(value);
}

main();
