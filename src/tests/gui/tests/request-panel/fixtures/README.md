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

## `elixir_plug/app.ct` — a recorded Plug/Cowboy session (RS-M8)

A **real recording**, on the same terms as the three above.
`codetracer-beam-recorder`'s `CodetracerBeamRecorder.Plug` middleware opened and
settled every span itself, through
`:codetracer_erlang_runtime.web_request_start/1` and `web_request_stop/2`, while
a real Cowboy listener served twelve HTTP requests over TCP to the demo
`Plug.Router` in that repo's `test-programs/elixir/plug_web/`.

It is consumed by `../elixir_request_panel_vm_test.nim`
(`vm_elixir_request_panel_rows`), which is registered in
`src/ct_test/release_gate.nim`'s `CoreViewModelGateTests`. It is checked in so
that ViewModel test needs no Erlang/Elixir toolchain, no Hex packages and no
server.

### Regenerating

```sh
direnv exec ../codetracer-beam-recorder just \
  record-request-panel-fixture \
  "$PWD/src/tests/gui/tests/request-panel/fixtures/elixir_plug" plug
```

The recipe **replaces the whole target directory**, which is why this file lives
one level up. Pass `phoenix` instead of `plug` to record the Phoenix demo; the
ViewModel test expects the Plug one.

It records exactly the schedule `just demo-request-panel elixir` records —
`PlugWeb.main/0` in `codetracer-beam-recorder` — so the fixture and the hand-run
demo always show the same session.

### What the session contains

Twelve requests in two phases. The first four are issued **at once** and block
in `PlugWeb.Barrier` until the whole cohort has arrived, so all four are inside
their handlers at the same instant; the remaining eight are issued one at a
time.

| #     | Request                     | Status | Route                 | Concurrent |
| ----- | --------------------------- | ------ | --------------------- | ---------- |
| 1..4  | `GET /concurrent/{1..4}`    | 200    | `/concurrent/:slot`   | yes        |
| 5     | `GET /api/users`            | 200    | `/api/users`          | no         |
| 6     | `POST /api/users`           | 201    | `/api/users`          | no         |
| 7     | `GET /api/users/2`          | 200    | `/api/users/:user_id` | no         |
| 8     | `GET /static/app.css`       | 304    | `/static/app.css`     | no         |
| 9     | `GET /api/users/999`        | 404    | `/api/users/:user_id` | no         |
| 10    | `GET /slow`                 | 200    | `/slow`               | no         |
| 11    | `GET /boom`                 | 500    | `/boom`               | no         |
| 12    | `GET /healthz`              | 200    | `/healthz`            | no         |

The cohort's arrival order is a property of the scheduler, so the ViewModel test
compares those four URLs as a set and everything else exactly. Every status
bucket the panel colours is present, `/slow` sleeps 400 ms inside its handler so
one duration is unambiguously substantial, and `/boom` raises and is answered
500 by `Plug.ErrorHandler`.

The stream holds **twenty-four** records, not twelve: each request is published
open when the middleware enters and settled from its `before_send` callback
under the same `span_id`, and the reader collapses them last-record-wins.

### What is different about the BEAM row

**A request is a thread, not a process.** RS-M1b fixes a span's coordinate as
*(process_ord, thread_id, step range)*. The BEAM recorder records one OS process
— the `beam.smp` it launched — and maps each *BEAM* process onto a container
**thread**, so all twelve spans carry `process_ord == 0` and twelve distinct
`thread_id`s, with the BEAM pid alongside as `beam.pid` metadata. Cowboy serves
each request on its own connection process, so this is the first fixture in
which the requests are genuinely different threads of one recording rather than
successive slices of one thread.

**The cohort spans are not `contiguous_on_one_thread`.** The recorder replays
its session sidecar into a single exec stream, so an overlapping request's
events are interleaved into its neighbours' ranges. The eight sequential
requests are contiguous. Both bits are measured from the recorded ranges, not
declared.

**There are no per-line step events.** The recorder applies step instrumentation
to `.erl` sources; an Elixir app recorded through `mix run` reaches the
container as call/return records in `calls.dat`, so a request's step range is
made of the thread events that bracket it. That is a real, distinct, ordered
coordinate — the panel seeks to it — but it does not resolve to a line of
`router.ex`, which is why this row's ViewModel test asserts distinct seek
targets rather than a seek into the handler's source.

## `js_express/index.ct` — a recorded Express session (RS-M9)

A **real recording**, on the same terms as the rows above. The JS recorder's
Express middleware (`codetracer-js-recorder`, `packages/express`) opened and
settled the spans and the recorder's native addon wrote them into `spans.dat`,
while that repo's `test-programs/web/express/index.js` served seven HTTP
requests over loopback to the demo app in `test-programs/web/express/app.js`.

It is consumed by `../js_request_panel_vm_test.nim` (`vm_js_request_panel_rows`),
registered in `src/ct_test/release_gate.nim`'s `CoreViewModelGateTests`, and is
checked in so that ViewModel test needs no Node toolchain, no Express and no
server.

### Regenerating

```sh
direnv exec ../codetracer-js-recorder just \
  record-request-panel-fixture \
  "$PWD/src/tests/gui/tests/request-panel/fixtures/js_express"
```

The recipe **replaces the whole target directory** and keeps only the `.ct`
container: the recorder also writes a `files/<absolute-source-path>` copy of
every recorded source, which reproduces the recording machine's directory tree
verbatim and would put one developer's `$HOME` in this repo's history for no
benefit — the ViewModel test reads the container and nothing else.

It records exactly the schedule `just demo-request-panel js` records.

### What is different about the JavaScript row

**A request is a slice of one event loop.** Node is single-threaded: concurrent
requests do not run in parallel, they interleave across `await` points on one
exec stream. The recorder maps each Node async context
(`async_hooks.executionAsyncId()`) onto a container **thread**, so all seven
spans carry `process_ord == 0` and seven distinct `thread_id`s — the context
each request entered on.

**`contiguous_on_one_thread` takes both values in this one sequential
recording**, and this is the first fixture in which it does. A handler that runs
to completion without yielding is an uninterrupted run of the exec stream and is
contiguous. The `await`ing handler (`/api/reports/slow`) is not, because its own
continuation lands on a different async context inside its range. Neither is the
`POST`, because `express.json()` awaits the request body before the handler
runs. `concurrent_with_siblings` is false throughout this fixture — the demo
driver issues its requests one at a time — and the recorder repo's
`express_span_contiguity_reflects_the_event_loop` test records the same schedule
concurrently and requires the bit to flip, so neither bit can be passing as a
constant.

**Seeks resolve to the handler's source.** The instrumenter instruments the app
but not `node_modules`, so a request's step range is made of real per-line steps
of `app.js`; the ViewModel test walks each range and requires it to cover that
request's own handler lines, distinctly from every other row's — including
telling the two `/api/users/:userId` rows apart by the branch each took.

One caveat the test asserts rather than hides: a span's `start_step` is the
first *exec-stream event* of its interval, and where that event is a
`ThreadStart` (the `POST`, whose handler resumes on a new async context after
the body parser) it carries no source position of its own. The range still
covers the handler.
