# Request-panel test fixtures

## `python_flask/serve.ct` — a recorded Flask session (RS-M5)

A **real recording**, not a hand-built container. The Python recorder's WSGI
middleware wrote its `spans.dat` records while `wsgiref` served eight HTTP
requests to the demo Flask app in the sibling recorder repo
(`codetracer-python-recorder/test-programs/web/flask/app.py`). `meta.dat` bit 13
(`FlagHasSpanStream`) is set by the writer because spans were registered, not by
hand.

It is consumed by `../python_request_panel_vm_test.nim`
(`vm_python_request_panel_rows`), which is registered in
`src/ct_test/release_gate.nim`'s `CoreViewModelGateTests`. It is checked in so
that ViewModel test needs no Python toolchain, no network and no server.

### Regenerating

```sh
direnv exec ../codetracer-python-recorder just \
  record-request-panel-fixture \
  "$PWD/src/tests/gui/tests/request-panel/fixtures/python_flask" flask
```

The recipe **replaces the whole target directory**, which is why this file lives
one level up.

It records exactly the schedule `just demo-request-panel python` records —
`DEMO_REQUESTS` in
`codetracer-python-recorder/test-programs/web/session_driver.py` — so the fixture
and the hand-run demo always show the same session. Regenerate whenever the demo
app's routes, the request schedule or the span metadata change, and update
`ExpectedRows` in the ViewModel test to match. The test asserts the schedule
(methods, URLs, statuses, routes) as constants and the timing-dependent values
(durations, byte counts, step indices) as properties, so a re-recording on a
different machine does not require touching the test.

### What the session contains

| # | Request                    | Status | Route                        |
| - | -------------------------- | ------ | ---------------------------- |
| 1 | `GET /api/users`           | 200    | `/api/users`                 |
| 2 | `POST /api/users`          | 201    | `/api/users`                 |
| 3 | `GET /api/users/2`         | 200    | `/api/users/<int:user_id>`   |
| 4 | `GET /static/app.css`      | 304    | `/static/app.css`            |
| 5 | `GET /api/users/999`       | 404    | `/api/users/<int:user_id>`   |
| 6 | `GET /api/reports/slow`    | 200    | `/api/reports/slow`          |
| 7 | `GET /api/boom`            | 500    | `/api/boom`                  |
| 8 | `GET /api/users`           | 200    | `/api/users`                 |

Every status bucket the panel colours is present, request 6 sleeps 50 ms inside
its handler so a duration is unambiguously non-zero, and request 7's handler
raises so its span carries `error.message`.

The recording's absolute source paths point at the machine that recorded it;
that is fine for the ViewModel test (which only reads spans and step bindings)
but means the editor pane will not find the sources when opening this fixture by
hand. Use `just demo-request-panel python` for that — it records into a fresh
directory next to a live checkout.

## `ruby_sinatra/ruby.ct` — a recorded Sinatra session (RS-M6)

A **real recording**, on the same terms as the Flask one above. The Ruby
recorder's Rack middleware (`codetracer-ruby-recorder`,
`gems/codetracer-rack/lib/codetracer/rack/middleware.rb`) wrote its `spans.dat`
records while that repo's `test-programs/web/rack_server.rb` served eight HTTP
requests to the demo Sinatra app in `test-programs/web/sinatra/app.rb`.

It is consumed by `../ruby_request_panel_vm_test.nim`
(`vm_ruby_request_panel_rows`), registered in `src/ct_test/release_gate.nim`'s
`CoreViewModelGateTests`, and is checked in so that ViewModel test needs no Ruby
toolchain, no Sinatra and no server.

### Regenerating

```sh
direnv exec ../codetracer-ruby-recorder just \
  record-request-panel-fixture \
  "$PWD/src/tests/gui/tests/request-panel/fixtures/ruby_sinatra" sinatra
```

The recipe **replaces the whole target directory** and drops the bundled
`meta_dat/sources/` tree, which is keyed by the recording machine's absolute
paths and would be pure churn here.

It records exactly the schedule `just demo-request-panel ruby` records —
`DEMO_REQUESTS` in
`codetracer-ruby-recorder/test-programs/web/session_driver.rb` — so the fixture
and the hand-run demo always show the same session.

### What the session contains

| # | Request                    | Status | Route                     |
| - | -------------------------- | ------ | ------------------------- |
| 1 | `GET /api/users`           | 200    | `/api/users`              |
| 2 | `POST /api/users`          | 201    | `/api/users`              |
| 3 | `GET /api/users/2`         | 200    | `/api/users/:user_id`     |
| 4 | `GET /static/app.css`      | 304    | `/static/app.css`         |
| 5 | `GET /api/users/999`       | 404    | `/api/users/:user_id`     |
| 6 | `GET /api/reports/slow`    | 200    | `/api/reports/slow`       |
| 7 | `GET /api/boom`            | 500    | `/api/boom`               |
| 8 | `GET /api/users`           | 200    | `/api/users`              |

The same coverage as the Flask fixture — every status bucket the panel colours,
a 50 ms handler, and a handler that raises so its span carries `error.message`.

Two properties differ from the Python recording and the ViewModel test relies on
both:

- **Every row's seek lands on the matched route's own line.** There is no
  synthetic-step drift here, so `/api/users/:user_id` seeks into the handler
  exactly like a fixed route does.
- **The trace is column-UNAWARE.** The Ruby recorder does not opt into
  column-aware steps, so a step's `global_position_index` is the writer's
  line-only encoding and `decodeGlobalPositionIndex` refuses it; the test
  resolves steps the way `ct print` does, through `buildGlobalLineIndex` over
  `DefaultLinesPerFile`.

## `php_builtin/app.ct` — a recorded `php -S` session (RS-M7)

A **real recording**, not a hand-built container. The PHP recorder's C
extension wrote its `spans.dat` records while a real `php -S` process served
eight HTTP requests to the demo app in the sibling recorder repo
(`codetracer-php-recorder/tests/programs/web/app.php`).

The thing this fixture proves that the Python and Ruby ones cannot: **one
container for the whole session**. Before RS-M7 the PHP extension opened a
trace writer in `PHP_RINIT` and closed it in `PHP_RSHUTDOWN`, so these eight
requests would have been eight separate recordings in eight directories, tied
together only by a `session_manifest.jsonl` sidecar, each re-interning the
application from scratch. The worker now holds one continuous recording, and
the requests are eight intervals of its timeline — visible here as a single
`.ct` with a one-entry path table.

It is consumed by `../php_request_panel_vm_test.nim`
(`vm_php_request_panel_rows_and_seek`), which is registered in
`src/ct_test/release_gate.nim`'s `CoreViewModelGateTests`. It is checked in so
that ViewModel test needs no PHP toolchain, no built C extension and no server.

### Regenerating

```sh
direnv exec ../codetracer-php-recorder just \
  record-request-panel-fixture \
  "$PWD/src/tests/gui/tests/request-panel/fixtures/php_builtin"
```

The recipe **replaces the whole target directory**, which is why this file lives
one level up. It flattens the container out of the `worker_<pid>/` directory the
recorder writes it into, so the fixture path is stable across machines.

It records exactly the schedule `just demo-request-panel php` records —
`CT_DEMO_REQUESTS` in
`codetracer-php-recorder/tests/programs/web/session_driver.php` — so the fixture
and the hand-run demo always show the same session.

### What the session contains

| # | Request                    | Status | Route                        |
| - | -------------------------- | ------ | ---------------------------- |
| 1 | `GET /api/users`           | 200    | `/api/users`                 |
| 2 | `POST /api/users`          | 201    | `/api/users`                 |
| 3 | `GET /api/users/2`         | 200    | `/api/users/{user_id}`       |
| 4 | `GET /static/app.css`      | 304    | `/static/app.css`            |
| 5 | `GET /api/users/999`       | 404    | `/api/users/{user_id}`       |
| 6 | `GET /api/reports/slow`    | 200    | `/api/reports/slow`          |
| 7 | `GET /api/boom`            | 500    | `/api/boom`                  |
| 8 | `GET /api/users`           | 200    | `/api/users`                 |

The same eight-request shape as the Python and Ruby fixtures, so the three rows
of the language matrix are directly comparable. `framework` is `plain`: the demo
app is a plain router, because Laravel needs a Composer install that the
recorder's dev shell does not provide. The Laravel integration ships in that
repo as a middleware and an `auto_prepend_file`
(`tests/programs/web/laravel/`).

The stream holds **sixteen** records, not eight: each request is published as an
open record at `PHP_RINIT` and settled at `PHP_RSHUTDOWN` under the same
`span_id`, and the reader collapses them last-record-wins.
