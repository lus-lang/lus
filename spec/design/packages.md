# First atmosphere packages

This note plans the first set of packages for the atmosphere registry at atmosp.here. A program loads a package by URL, as in `require("https://atmosp.here/2.0/web.lus")`. Each package lives in a public repository of the `lus-lang` organization, which the atmosphere server fetches without a token.

The set has four groups. The web group is a router and framework modeled on Fastify, with WebSocket and middleware for CORS, cookies, and sessions. The data group validates values against schemas and reads and writes YAML, TOML, HTML templates, and Markdown. The command line group parses arguments, colors terminal output, asks questions, and loads `.env` files. The last group holds JWT and semantic versions. UUID and ULID come from the standard library, so no package provides them.

The web framework is the flagship. Its goal is a request rate within 10% of a bare `network.serve` handler and a peak memory within 10% of it, measured with `tests/bench/compare` on the same machine.

## Conventions for every package

A package is one main module, `NAME.lus`, at the root of its repository. Its file starts with the doc comment header that `spec/design/modules.md` defines: `@package`, `@version`, `@lus`, and `@license`, then `@repository` and one `@permission` line for every permission the package uses. The packages are licensed under 0BSD, like Lus. A package never calls `pledge` to restrict the program that loads it, because a pledge applies to the whole program and the program decides its own permissions.

A package that needs more than one file keeps its helpers in a directory named after the package, such as `markdown/inline.lus`, and loads them as `require("markdown.inline")`. A package that needs another package requires it by its full atmosphere URL on one line. A package on atmosp.here ships as a self-contained bundle that includes every dependency. `session` therefore bundles `cookie`. `cors` and `cookie` register on a `web` scope that the program passes them, so neither loads `web` itself. Only their tests use it.

Every package has the following parts.

- **Doc comments** on every public function, which `lus doc` turns into the reference.
- **Tests** in `tests/*_test.lus`, run with `lus test`. Packages that serve HTTP test through `app:inject` or a server on port `0`, so the tests need no fixed port.
- **AGENTS.md**, which states the scope, the layout, the commands, and the rules for changes.
- **README.md** with one example and the URL to require.
- **CHANGELOG.md** and a license file.

A release is a git tag of the form `VERSION@LUSLINE`, such as `1.0.0@2.0`. The repositories in `lus-lang` hold only packages that the Lus project maintains.

The API follows the standard library. Functions that convert text are named `decode` and `encode`. Functions that check input raise an error object on failure, so a caller uses `catch` when it wants to continue. Error objects are tables with a `message` field and a `__tostring` metamethod, so an uncaught one prints a readable line.

## Packages

The table lists every package with its URL name, its proposed repository, its dependencies, and the permissions its header declares.

| Package | Repository | Depends on | Permissions |
| --- | --- | --- | --- |
| `web` | `lus-lang/atmos-web` | none, routes pass `schema` values | `network:server`, `network:tcp` when it listens |
| `websocket` | `lus-lang/atmos-websocket` | stdlib SHA-1 or SHA-256 | `network:tcp` |
| `cors` | `lus-lang/atmos-cors` | `web` | none |
| `cookie` | `lus-lang/atmos-cookie` | stdlib HMAC | none |
| `session` | `lus-lang/atmos-session` | `cookie`, stdlib HMAC, stdlib random bytes | none |
| `schema` | `lus-lang/atmos-schema` | none | none |
| `yaml` | `lus-lang/atmos-yaml` | none | none |
| `toml` | `lus-lang/atmos-toml` | stdlib `time` | none |
| `html_template` | `lus-lang/atmos-html-template` | none | `fs:read` when it loads files |
| `markdown` | `lus-lang/atmos-markdown` | none | none |
| `cli` | `lus-lang/atmos-cli` | none | none |
| `color` | `lus-lang/atmos-color` | none | `env:read` |
| `prompt` | `lus-lang/atmos-prompt` | `color` | none |
| `dotenv` | `lus-lang/atmos-dotenv` | none | `fs:read`, `env:read` |
| `jwt` | `lus-lang/atmos-jwt` | stdlib HMAC and Ed25519 | none |
| `semver` | `lus-lang/atmos-semver` | none | none |

The URL names are plain nouns, because a reader of `require("https://atmosp.here/2.0/yaml.lus")` then knows what the line loads. Each repository is named after its package with the prefix `atmos-` and every underscore turned into a dash, as in `atmos-html-template` for `html_template`. The naming keeps the packages together in the organization and leaves names such as `web` and `cli` free for Lus tools. The repositories are public, so they hold no secrets, credentials, or personal details beyond the copyright line of the license.

## web

`web` routes HTTP requests to handlers on top of `network.serve`. It adds routes with path parameters, plugins with their own prefix and hooks, lifecycle hooks, request validation against `schema` values, and response serialization driven by the same schemas. It also answers requests in memory through `app:inject`, so tests run without a socket.

### API sketch

The following program serves two routes. The second validates its body and serializes its response with schemas.

```lus nocheck
local web = require("https://atmosp.here/2.0/web.lus")
local s = require("https://atmosp.here/2.0/schema.lus")

local app = web.app()

app:get("/", function(req)
    return { message = "hello" }
end)

local User = s.object({ id = s.integer(), name = s.string() })

app:post("/users", {
    body = s.object({ name = s.string():min(1) }),
    response = { [201] = User },
}, function(req)
    local user = { id = next_id(), name = req.body.name }
    return 201, user
end)

app:get("/users/:id", {
    params = s.object({ id = s.coerce.integer() }),
}, function(req)
    return users[req.params.id] or web.raise(404, "no such user")
end)

pledge("network:server=127.0.0.1:8080", "network:tcp=127.0.0.1:8080")
app:listen("127.0.0.1", 8080)
```

A handler returns its response the way a `network.serve` handler does. If the first result is an integer, it is the status, and the body and the headers follow. Otherwise the first result is the body with status 200 and the second result is the headers. A table body becomes JSON, through the response schema of the route when it has one, or through `tojson` otherwise. A string or vector body is sent as it is, with `text/plain` unless the headers name a type.

A handler that declares a second parameter receives a reply object with `reply:header(name, value)`, `reply:cookie(name, value, options)`, `reply:type(mime)`, and `reply:redirect(url, status)`. `app:get` reads the number of parameters with `debug.getinfo` when it registers the route, so a handler with one parameter costs no reply object.

The request table is the table that `network.serve` passes, with these fields added.

| Field | Value |
| --- | --- |
| `params` | The path parameters, after validation. |
| `query` | The parsed query string as a table, after validation. A request with a query string keeps the raw text in `req.rawquery`. A request without one gets a shared empty table that raises an error on assignment. |
| `body` | For a method other than `GET` and `HEAD`, the decoded body. JSON is decoded when the content type contains `json`, a form when it is `application/x-www-form-urlencoded`, and text when it starts with `text/`. The raw vector stays in `req.raw`. A `GET` or `HEAD` request keeps the vector that `network.serve` passed. |
| `route` | The route pattern, such as `"/users/:id"`. |
| `app` | The application or plugin scope that owns the route, with its decorations. |

### Routes

Routes are registered with `app:get`, `app:post`, `app:put`, `app:patch`, `app:delete`, `app:head`, `app:options`, `app:all`, and the general `app:route(method, path, options, handler)`. A path segment that starts with `:` is a parameter. A final segment `*` captures the rest of the path in `req.params["*"]`. A static segment wins over a parameter, which wins over a wildcard.

The router keeps static routes in one table keyed by method and path, so most lookups are one table index. Parametric routes live in a tree of segments per method. `HEAD` falls back to the `GET` route. A path with a route for another method answers 405 with an `Allow` header. Any other path answers 404.

### Hooks

Hooks run at fixed points of a request: `on_request`, `pre_validation`, `pre_handler`, `on_send`, `on_response`, and `on_error`. `app:hook(name, fn)` adds one. A hook that returns a response ends the request with that response, which is how an authentication hook rejects a request. An `on_send` hook receives `req, status, body, headers` and returns them, possibly changed.

`app:listen` and `app:inject` compile the hooks of every route into one function per route. A route without hooks calls its handler directly. The hooks therefore cost nothing on the routes that have none.

### Plugins

A plugin is a function `plugin(app, options)`. `app:register(plugin, options)` calls it with a child scope. Routes, hooks, and decorations added in the child apply to the child and its descendants only. `options.prefix` prefixes every route of the child. `app:decorate(name, value)` adds a field to the scope, which handlers read through `req.app`. `cors`, `cookie`, and `session` are plugins.

### Errors

`web.raise(status, message, details)` raises an error object that the framework turns into a response with that status and a JSON body `{ "error": message }`. Any other error object answers 500 and goes to the `on_error` hooks, then to `app.log`. A failed validation answers 400 with the list of issues that `schema` reports.

### Performance

The framework adds work to a request only where the route asks for it. The plan is the following.

- The handler that `network.serve` calls is one closure that indexes the static table first.
- The request table of `network.serve` is reused as the request of the framework, so routing allocates nothing for a static route without a schema.
- A request without a query string shares one empty query table, so it allocates no table for its query.
- Response schemas compile into serializer closures when the app starts.

The package measures itself with `bench/run.sh` in `lus-lang/atmos-web`. The script serves `tests/bench/compare/http/server.lus` of this repository and `bench/server_web.lus`, which answers the same routes through `web`, in alternating rounds of `oha -c 64` over keep-alive connections. It samples the resident memory of each server during the load.

The first prototype measured the following on an Apple M4 Max with a ReleaseFast build, in three rounds of 5 seconds. The bare server answered 134,770 to 136,611 requests per second with a peak resident memory of 9 MB. The `web` server answered 126,560 to 130,124 requests per second with a peak of 10 to 11 MB. The gap in throughput is 4 to 7%, and the p99 latency went from 0.56 to between 0.58 and 0.64 ms. Other builds ran on the machine during the rounds, so the numbers carry about 3% of noise.

In process, without sockets, a bare handler takes 0.15 µs per request and the `web` handler 0.27 µs. Two changes brought `web` there from 0.33 µs. A request without a query string or path parameters shares one read-only empty table, and a `GET` request keeps its body field untouched. Wrapping the handler in `catch` measured no difference, so every route catches its errors. `web` itself loads no `schema` module and uses whatever schema values a route passes, which removed about 1 MB of the idle memory.

## websocket

`websocket` implements RFC 6455: the opening handshake, framing, masking, fragmentation, ping and pong, and the closing handshake. `websocket.connect(url)` opens a client connection over `network.tcp`. `websocket.route(fn, options)` returns a handler for a `web` route or for `network.serve` that accepts connections.

```lus nocheck
local ws = require("https://atmosp.here/2.0/websocket.lus")

app:get("/chat", ws.route(function(conn, req)
    for message in conn:messages() do
        conn:send(`echo: $message`)
    end
end))
```

A connection is used from inside its own detached coroutine. `conn:receive()` suspends only that coroutine, so one program holds many connections. `conn:send` takes a string as a text frame and a vector as a binary frame.

On the server side, `ws.route` returns a handler that answers `101` and a function. `network.serve` sends the 101 response with the `Sec-WebSocket-Accept` header that it computes from the key of the request, then calls the function with the TCP socket of the connection. The package implements framing, masking, ping and pong, and the closing handshake on that socket. The socket keeps the `idle_timeout` of the server until the package calls `sock:settimeout`, so a connection that waits for messages without limit calls `sock:settimeout(-1)`.

## cors

`cors` answers preflight requests and adds the `Access-Control-*` headers to responses. Its options are `origin` (a string, a list, a pattern, or a function), `methods`, `headers`, `expose`, `credentials`, and `max_age`.

```lus nocheck
app:register(cors, { origin = { "https://lus.dev" }, credentials = true })
```

## cookie

`cookie` parses a `Cookie` header into a table, formats a `Set-Cookie` header from a name, a value, and options (`path`, `domain`, `max_age`, `expires`, `secure`, `http_only`, `same_site`, `partitioned`), and signs and checks values with HMAC-SHA-256. As a `web` plugin it adds `req.cookies` and `reply:cookie`.

```lus nocheck
local cookie = require("https://atmosp.here/2.0/cookie.lus")
print(cookie.format("theme", "dark", { max_age = 3600, http_only = true }))
--> theme=dark; Max-Age=3600; HttpOnly
```

A response may set several cookies. The plugin passes them to `network.serve` as a list of strings, which writes one `Set-Cookie` line for each.

## session

`session` keeps per-client state behind a signed cookie. The default store keeps sessions in memory with a size limit and an expiry. A store is any table with `get(id)`, `set(id, data, ttl)`, and `destroy(id)`, so a program backs it with SQLite through `io.sqlite`. Session identifiers are 128 random bits from the standard library.

```lus nocheck
app:register(session, { secret = os.getenv("SESSION_SECRET"), ttl = 86400 })

app:post("/login", function(req)
    req.session.user = authenticate(req.body)
    return 204
end)
```

## schema

`schema` describes the shape of a value and checks values against it, in the manner of zod. Schemas are values built from constructors and refined by methods. A schema parses a value and returns the parsed value or raises an error object that lists every issue with its path.

```lus nocheck
local s = require("https://atmosp.here/2.0/schema.lus")

local Config = s.object({
    host = s.string():default("127.0.0.1"),
    port = s.integer():min(1):max(65535),
    mode = s.oneof({ "dev", "prod" }),
    tags = s.array(s.string()):optional(),
})

local config = Config:parse(fromjson(text))
local ok, value_or_err = Config:check(input)
```

The constructors are `string`, `number`, `integer`, `boolean`, `literal`, `oneof`, `array`, `tuple`, `object`, `record`, `union`, `any`, `vector`, and `lazy` for recursive schemas. `s.coerce` holds versions of `string`, `number`, `integer`, and `boolean` that convert strings first, which is what query strings and command line arguments need. The methods are `optional`, `nullable`, `default`, `min`, `max`, `length`, `pattern`, `refine`, `transform`, `strict` for objects that reject unknown keys, and `describe`.

`schema:serializer()` returns a function that encodes a value of the schema as JSON with only the declared fields. `schema:json_schema()` returns the equivalent JSON Schema as a table, for OpenAPI documents. The checks compile into closures when a schema is built, so `parse` runs no interpretation of the schema tree for the common constructors.

## yaml

`yaml` reads and writes YAML 1.2 with the core schema. `yaml.decode(text)` returns the first document. `yaml.decode_all(text)` returns every document as a list. `yaml.encode(value, options)` writes block style with two spaces of indentation. Anchors, aliases, and merge keys are read, and an alias refers to the same table as its anchor. Tags other than the core ones raise an error, so a document cannot construct values of arbitrary types. Mapping keys become strings and a null value leaves its key out, as `fromjson` does. Mapping keys keep no order in a Lus table, so `encode` writes keys in sorted order unless `options.order` gives a list.

## toml

`toml` reads and writes TOML 1.0. `toml.decode(text)` returns a table. `toml.encode(value)` writes one. An offset date time in UTC becomes a `time` instant, and one with another offset becomes a `time` zoned value that keeps the offset. Local date times, dates, and times become the tables of `toml.localtime`, which have a `kind` field. A round trip therefore keeps every value, fractions of seconds included. Integers stay integers and floats stay floats.

## html_template

`html_template` renders HTML from templates with the syntax of Handlebars. `{{ name }}` inserts an escaped value, `{{{ html }}}` inserts it unescaped, `{{#if}}`, `{{#unless}}`, `{{#each}}`, and `{{#with}}` are the block helpers, `{{> partial}}` includes a partial, and `{{! comment }}` is a comment. A program registers helpers and partials on an environment.

```lus nocheck
local template = require("https://atmosp.here/2.0/html_template.lus")
local page = template.compile("<h1>{{ title }}</h1>{{#each items}}<li>{{ name }}</li>{{/each}}")
print(page({ title = "Lus & co", items = { { name = "a" }, { name = "b" } } }))
--> <h1>Lus &amp; co</h1><li>a</li><li>b</li>
```

`compile` turns a template into a tree of closures, so rendering needs no `load` permission. `@index` counts from 1, as Lus lists do. `template.env({ root = "views" })` loads templates and partials from files, which needs `fs:read`.

`bench/bench.lus` in `lus-lang/atmos-html-template` renders the page of the template benchmark of `tests/bench/compare` with `table.concat`, as `template.lus` does, and through the package. For 200,000 rows on an Apple M4 Max with a ReleaseFast build, `table.concat` took 0.103 seconds and the package 0.405 seconds. The first version of the package took 0.575 seconds. The built-in `each` then gained a path that writes into the buffer of its parent and updates one frame and one data table per loop, which brought it to 0.420 seconds. Looking up `@` values through the parent frames, in place of a metatable per loop, brought it to 0.405 seconds.

## markdown

`markdown` renders CommonMark to HTML, with the GitHub extensions for tables, strikethrough, task lists, and autolinks. `markdown.render(text, options)` returns HTML. `markdown.parse(text)` returns the syntax tree as nested tables, so a program can walk it. Raw HTML in the input is escaped unless `options.html` is true. The tests hold about 110 cases modeled on the examples of the CommonMark and GFM specifications, at least one for every construct. Link destinations with the schemes `javascript`, `vbscript`, `file`, and `data` render empty unless `options.unsafe_links` is true, so untrusted input cannot inject a script through a link. Named character references outside a small table pass through to the browser. The guide of the manual, 250 KB of Markdown, renders in 0.035 seconds on an Apple M4 Max.

## cli

`cli` parses command line arguments into commands, options, and positional arguments, and prints help and errors. The model is commander.

```lus nocheck
local cli = require("https://atmosp.here/2.0/cli.lus")

local program = cli.program("todo", "1.0.0")
    :describe("Keeps a list of tasks.")

program:command("add <title> [notes...]")
    :option("-p, --priority <n>", "priority from 1 to 5", { type = "integer", default = 3 })
    :option("--done", "mark the task done")
    :action(function(args, options)
        add(args.title, args.notes, options.priority, options.done)
    end)

program:run(arg)
```

`<name>` marks a required argument, `[name]` an optional one, and `...` a list. Options take the types `string`, `integer`, `number`, and `boolean`, or a `schema` value. `--help` and `--version` are built in. An unknown option or a missing argument prints the error and the usage to standard error and exits with status 2. `program:parse(list)` returns the parsed command, arguments, and options without running an action, which is how the tests call it.

## color

`color` styles terminal text with ANSI escape sequences. `color.red("text")` returns the string wrapped in the codes, and styles chain, as in `color.bold.red("error")`. The package supports the 16 basic colors, 256 colors, and 24-bit colors through `color.hex("#ff8800")`. Output is plain when the environment variable `NO_COLOR` is set or `TERM` is `dumb`. `FORCE_COLOR` turns it on. `color.strip(text)` removes the codes, and `color.width(text)` measures the visible width.

## prompt

`prompt` asks questions on the terminal: `prompt.text(question, options)`, `prompt.confirm(question, default)`, `prompt.number`, `prompt.select(question, choices)`, and `prompt.multiselect`. A `validate` option takes a function or a `schema` value and asks again until the answer passes. On a terminal, `prompt` switches standard input into raw mode with `io.stdin:setraw(true)` and reads one key at a time, which gives arrow key menus and hidden password input. Ctrl-C arrives as `"\3"` in raw mode, so `prompt` restores the terminal and raises an error object that the caller may catch. When standard input is not a terminal, as `io.stdin:isatty()` reports, the prompts read whole lines and a selection reads the number of a choice, so scripts and tests can answer them through a pipe.

## dotenv

`dotenv` reads `.env` files. `dotenv.parse(text)` returns a table. `dotenv.load(path, options)` reads `.env` by default and returns the table. The syntax covers `KEY=value`, `export KEY=value`, single quotes, double quotes with escapes, multiline double quoted values, comments, and `${VAR}` expansion from earlier keys and the environment. `dotenv.get(name)` returns a loaded value or falls back to `os.getenv`. `dotenv.load(path, { export = true })` also sets every value with `os.setenv`, so commands that the program starts see them. That option needs `env:write`. A variable that the environment already holds keeps its value unless `override` is true.

## jwt

`jwt` signs and verifies JSON Web Tokens. `jwt.sign(claims, key, options)` returns a token. `jwt.verify(token, key, options)` returns the claims or raises an error object. It checks the signature, `exp`, `nbf`, `iat`, `iss`, `aud`, and a leeway in seconds. `jwt.decode(token)` returns the header and the claims without verifying them. The algorithms are `HS256`, `HS384`, `HS512`, and `EdDSA` with Ed25519. They match the hash functions and signatures of the standard library `crypto` module, which adds SHA-384 for `HS384`. `verify` takes the list of accepted algorithms as a required option, so a token cannot choose its own algorithm.

```lus nocheck
local jwt = require("https://atmosp.here/2.0/jwt.lus")
local token = jwt.sign({ sub = "42", exp = os.time() + 3600 }, secret, { alg = "HS256" })
local claims = jwt.verify(token, secret, { algorithms = { "HS256" } })
```

## semver

`semver` parses, compares, and matches semantic versions according to Semantic Versioning 2.0.0. `semver.parse(text)` returns a version table with `major`, `minor`, `patch`, `prerelease`, and `build`, and a metatable that compares versions with `<` and `==`. `semver.satisfies(version, range)` matches the range syntax of npm: comparators, `^`, `~`, `x` wildcards, hyphen ranges, and `||`. `semver.max_satisfying(list, range)` and `semver.increment(version, part)` complete the API. The atmosphere tools use it to pick package versions. It needs no cryptography.

## Order of work

Each package lives in its own repository, `lus-lang/atmos-NAME`, and no file of the runtime changes. The order of work follows the dependencies and the value of each package.

1. `schema`, because `web` validates with it.
2. `web`, with the benchmark against the bare server.
3. `cookie`, `cors`, and `session`.
4. `semver`, `dotenv`, `color`, and `cli`.
5. `jwt`.
6. `yaml`, `toml`, `html_template`, and `markdown`.
7. `prompt` and `websocket`.

The 16 repositories exist as public repositories of `lus-lang`. Each prototype is pushed to its repository as it progresses.

The prototypes cover every step, so all 16 packages exist. Each has its tests, a README, and an AGENTS.md, and each passes `lus check` with the package codes `package-header`, `package-flag`, and `package-pledge`. Their 196 tests pass with `lus test` over checkouts of the 16 repositories in one directory, under `LUS_JIT=off`, the default, `LUS_JIT=eager`, and `LUS_JIT=opt-eager`. The `toml` tests include the examples and 28 invalid documents of the TOML 1.0 specification. The `semver` tests include 95 range cases from the npm `semver` package. The `jwt` tests verify the example token of jwt.io, and the `websocket` tests check the handshake example of RFC 6455. The `cookie`, `session`, and `web` tests send two `Set-Cookie` headers over a socket and find two header lines.

Writing the prototypes showed that `enum` and `continue` are keywords in Lus 2.0, so neither can name a field after a dot. The schema constructor for a set of values is therefore `schema.oneof`.

## Runtime additions

The packages needed four additions to the runtime, which Lus 2.0 adds.

- `network.serve` accepts a handler result of `101` and a function, and calls the function with the socket of the connection after it sends the response. `websocket` uses it.
- A response header value may be a list of strings, which becomes one header line per string. `cookie` and `session` use it for `Set-Cookie`.
- `file:isatty()` reports whether a handle is a terminal, and `io.stdin:setraw(on)` switches raw terminal mode. `color` and `prompt` use them.
- `os.setenv(name, value)` sets an environment variable under the `env:write` permission, and `os.getenv` checks `env:read`. `dotenv` uses both.

The prototypes of `web`, `color`, and `dotenv` use these additions where the runtime provides them, so their tests pass on runtimes with and without them.

The tests of `session` and `prompt` load their dependency from a sibling checkout. Each maps the atmosphere URL of the dependency to the local module through `package.preload`, which `require` consults under the exact URL before it goes to the network.
