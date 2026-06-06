// Cross-Process Origin E2E — Fixture A "Account Balance" (per
// Cross-Process-Origin-E2E-Test-Design.md §3.1).
//
// The frontend fetches an account balance from the backend's
// `/api/balance` endpoint and renders it. Tracing the origin of the
// rendered `balance` value walks back through the JSON decode and
// into the backend's value-compute hop via the correlation marker
// declared below.
async function showBalance(userId) {
  // codetracer: send "balance-request" key=userId show=userId desc="GET /api/balance request"
  const response = await fetch(`/api/balance?user=${userId}`);
  const payload = await response.json();
  const balance = payload.balance;
  document.querySelector("#balance").textContent = String(balance);
  return balance;
}
showBalance("user-42");
