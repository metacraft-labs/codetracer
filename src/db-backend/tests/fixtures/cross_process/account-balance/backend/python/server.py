# Cross-Process Origin E2E — Fixture A "Account Balance" (Python
# aiohttp variant; per Cross-Process-Origin-E2E-Test-Design.md §3.1).
#
# The backend reads the balance from the database, encodes it as
# JSON, and serves it to the frontend. The receive-side correlation
# marker pairs with the frontend's send marker by the user-id key,
# so the cross-process value-origin chain crosses the network here
# and continues at `db_row.balance` (the value-compute hop).
from aiohttp import web


async def balance_handler(request):
    user_id = request.query.get("user")
    # codetracer: recv "balance-request" key=user_id show=user_id desc="GET /api/balance handler"
    db_row = await db.fetch_one(
        "SELECT balance FROM accounts WHERE user_id = ?", user_id
    )
    payload = {"balance": db_row.balance}
    return web.json_response(payload)
