// The fixture checkout page whose recorded session is the golden narrative
// of tests/narrate.rs (see ../README.md). It declares its experiment arm
// (data-ct-arms in index.html), labels (data-ct-label) and marks (ct.mark),
// checks the e-mail field with a declassifier, and talks to the server.
(function () {
  var $ = function (id) {
    return document.getElementById(id);
  };
  var cart = 0;
  var isValidEmail = ct.declassify(
    function isValidEmail(el) {
      return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(el.value);
    },
    { id: "isValidEmail" },
  );
  ct.mark("exposure:checkout", { arm: "B" });
  // Adding to the cart and showing the details read nothing the log holds:
  // each click is an input and a change of the page, nothing else.
  $("add").addEventListener("click", function () {
    cart++;
    $("status").textContent = cart + " in cart";
  });
  $("details").addEventListener("click", function () {
    $("detail-text").hidden = !$("detail-text").hidden;
  });
  $("continue").addEventListener("click", function () {
    var startedAt = Date.now();
    if (!isValidEmail($("email"))) {
      $("email-error").textContent = "Please enter a valid e-mail address.";
      return;
    }
    $("email-error").textContent = "";
    fetch("/api/checkout", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: $("name").value, items: cart }),
    })
      .then(function (r) {
        return r.json();
      })
      .then(function (j) {
        $("status").textContent =
          "order " + j.order + " in " + (Date.now() - startedAt) + " ms";
      });
  });
  $("pay").addEventListener("click", function () {
    fetch("/api/pay", { method: "POST" }).then(function (r) {
      if (r.status === 200) ct.mark("conversion:purchase", { items: cart });
      $("status").textContent = r.status === 200 ? "paid" : "declined";
      document.body.setAttribute("data-done", "1");
    });
  });
})();
