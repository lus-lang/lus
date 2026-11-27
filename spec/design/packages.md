# Atmosphere packages

The official packages of the atmosphere registry at atmosp.here are libraries that the Lus project maintains. A program loads a package by URL, as in `require("https://atmosp.here/2.0/web.lus")`. Each package has a public repository in the `lus-lang` organization, which the atmosphere server fetches without a token.

The first set of packages has a web group, a data group, a command line group, and a group for tokens and versions. The web group is a router and framework modeled on Fastify, together with WebSocket support and middleware for CORS, cookies, and sessions. The data group validates values against schemas and reads and writes YAML, TOML, HTML templates, and Markdown. The command line group parses arguments, colors terminal output, prompts the user, and loads `.env` files. The last group handles JSON Web Tokens and semantic versions. UUID and ULID come from the standard library, so no package provides them.

The web framework has the strictest goal: a request rate within 10% of a bare `network.serve` handler and a peak memory within 10% of it, measured with `tests/bench/compare` on the same machine.

## Conventions for every package

A package is one main module, `NAME.lus`, at the root of its repository. Its file starts with the doc comment header that `spec/design/modules.md` defines: `@package`, `@version`, `@lus`, and `@license`, then `@repository` and one `@permission` line for every permission the package uses. The packages are licensed under 0BSD, like Lus. A package never calls `pledge` to restrict the program that loads it, because a pledge applies to the whole program and the program decides its own permissions.

A package that needs more than one file keeps its helpers in a directory named after the package, such as `markdown/inline.lus`, and loads them as `require("markdown.inline")`. A package that needs another package requires it by its full atmosphere URL on one line. A package on atmosp.here ships as a self-contained bundle that includes every dependency, so `session` bundles `cookie`. `cors` and `cookie` register on a `web` scope that the program passes them, so only their tests load `web`.

Every package has the following parts.

- **Doc comments** on every public function, which `lus doc` turns into the reference.
- **Tests** in `tests/*_test.lus`, run with `lus test`. Packages that serve HTTP test with `app:inject` or a server on port `0`, so the tests need no fixed port.
- **AGENTS.md**, which states the scope, the layout, the commands, and the rules for changes.
- **README.md** with one example and the URL to require.
- **CHANGELOG.md** and a license file.

A release is a git tag of the form `VERSION@LUSLINE`, such as `1.0.0@2.0`. The repositories in `lus-lang` hold only packages that the Lus project maintains.

The API follows the standard library. Functions that convert text are named `decode` and `encode`. Functions that check input raise an error object on failure, so a caller that continues after a failure uses `catch`. Error objects are tables with a `message` field and a `__tostring` metamethod, so an uncaught one prints a readable line.

## Packages

The following table gives the URL name of each package, its repository, its dependencies, and the permissions its header declares.

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

The URL names are plain nouns, because a reader of `require("https://atmosp.here/2.0/yaml.lus")` then knows what the line loads. Each repository is named after its package with the prefix `atmos-` and every underscore turned into a dash, as in `atmos-html-template` for `html_template`. The prefix groups the packages in the organization and keeps repository names such as `web` and `cli` available for Lus tools. The repositories are public, so they hold no secrets, credentials, or personal details beyond the copyright line of the license.

## web

`web` routes HTTP requests to handlers on top of `network.serve`. It adds routes with path parameters, plugins with their own prefix and hooks, lifecycle hooks, request validation against `schema` values, and response serialization driven by the same schemas. It also answers requests in memory with `app:inject`, so tests run without a socket.

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

A handler returns its response the way a `network.serve` handler does. If the first result is an integer, it is the status, followed by the body and the headers. Otherwise the first result is the body with status 200 and the second result is the headers. A table body is encoded as JSON by the response schema of the route when it has one, or by `tojson` otherwise. A string or vector body is sent as it is, with `text/plain` unless the headers name a type.

A handler that declares a second parameter receives a reply object with `reply:header(name, value)`, `reply:cookie(name, value, options)`, `reply:type(mime)`, and `reply:redirect(url, status)`. `app:get` reads the number of parameters with `arity` when it registers the route, so a handler with one parameter costs no reply object. `arity` needs no permission, where `debug.getinfo` needs `debug`.

The request table is the table that `network.serve` passes, with these fields added.

| Field | Value |
| --- | --- |
| `params` | The path parameters, after validation. |
| `query` | The parsed query string as a table, after validation. A request with a query string keeps the raw text in `req.rawquery`. A request without one gets a shared empty table that raises an error on assignment. |
| `body` | For a method other than `GET` and `HEAD`, the decoded body. JSON is decoded when the content type contains `json`, a form when it is `application/x-www-form-urlencoded`, and text when it starts with `text/`. The raw vector stays in `req.raw`. A `GET` or `HEAD` request keeps the vector that `network.serve` passed. |
| `route` | The route pattern, such as `"/users/:id"`. |
| `app` | The application or plugin scope that owns the route, with its decorations. |

### Routes

Routes are registered with `app:get`, `app:post`, `app:put`, `app:patch`, `app:delete`, `app:head`, `app:options`, `app:all`, and the general `app:route(method, path, options, handler)`. A path segment that starts with `:` is a parameter. A final segment `*` captures the rest of the path in `req.params["*"]`. A static segment takes precedence over a parameter, which takes precedence over a wildcard.

The router keeps static routes in one table keyed by method and path, so most lookups are one table index. Parametric routes are kept in a tree of segments per method. `HEAD` falls back to the `GET` route. A path with a route for another method answers 405 with an `Allow` header. Any other path answers 404.

### Hooks

Hooks run at fixed points of a request: `on_request`, `pre_validation`, `pre_handler`, `on_send`, `on_response`, and `on_error`. `app:hook(name, fn)` adds one. A hook that returns a response ends the request with that response, which is how an authentication hook rejects a request. An `on_send` hook receives `req, status, body, headers` and returns them, possibly changed.

`app:listen` and `app:inject` compile the hooks of every route into one function per route. A route without hooks calls its handler directly, so hooks cost nothing on the routes that have none.

### Plugins

A plugin is a function `plugin(app, options)` that `app:register(plugin, options)` calls with a child scope. Routes, hooks, and decorations added in the child apply to the child and its descendants only. `options.prefix` prefixes every route of the child. `app:decorate(name, value)` adds a field to the scope, which handlers read from `req.app`. `cors`, `cookie`, and `session` are plugins.

### Errors

`web.raise(status, message, details)` raises an error object that the framework turns into a response with that status and a JSON body `{ "error": message }`. Any other error object answers 500 and goes to the `on_error` hooks, then to `app.log`. A failed validation answers 400 with the list of issues that `schema` reports.

### Performance

The framework adds work to a request only for the features that its route uses. The plan is the following.

- The handler that `network.serve` calls is one closure that indexes the static table first.
- The request table of `network.serve` is reused as the request of the framework, so routing allocates nothing for a static route without a schema.
- A request without a query string shares one empty query table, so it allocates no table for its query.
- Response schemas compile into serializer closures when the app starts.

`bench/run.sh` in `lus-lang/atmos-web` measures the package. The script serves `tests/bench/compare/http/server.lus` of this repository and `bench/server_web.lus`, which answers the same routes with `web`, in alternating rounds of `oha -c 64` over keep-alive connections, sampling the resident memory of each server during the load.

The first prototype measured the following on an Apple M4 Max with a ReleaseFast build, in three rounds of 5 seconds. The bare server answered 134,770 to 136,611 requests per second with a peak resident memory of 9 MB. The `web` server answered 126,560 to 130,124 requests per second with a peak of 10 to 11 MB. The gap in throughput is 4 to 7%. The p99 latency went from 0.56 to between 0.58 and 0.64 ms. Other builds ran on the machine during the rounds, so the numbers carry about 3% of noise.

In process, without sockets, a bare handler takes 0.15 µs per request and the `web` handler 0.27 µs. Two changes brought `web` there from 0.33 µs. The first shares one read-only empty table between the requests without a query string or path parameters. The second leaves the body field of a `GET` request untouched. Wrapping the handler in `catch` measured no difference, so every route catches its errors. `web` itself loads no `schema` module and uses whatever schema values a route passes, which removed about 1 MB of the idle memory.

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

When a response sets several cookies, the plugin passes them to `network.serve` as a list of strings, which `network.serve` writes as one `Set-Cookie` line each.

## session

`session` keeps per-client state behind a signed cookie. The default store keeps sessions in memory with a size limit and an expiry. A store is any table with `get(id)`, `set(id, data, ttl)`, and `destroy(id)`, so a program can keep sessions in SQLite with `io.sqlite`. Session identifiers are 128 random bits from the standard library.

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

`schema:serializer()` returns a function that encodes a value of the schema as JSON with only the declared fields. `schema:json_schema()` returns the equivalent JSON Schema as a table, for OpenAPI documents. The checks compile into closures when a schema is built, so `parse` never walks the schema tree for the common constructors.

## yaml

`yaml` reads and writes YAML 1.2 with the core schema. `yaml.decode(text)` returns the first document. `yaml.decode_all(text)` returns every document as a list. `yaml.encode(value, options)` writes block style with two spaces of indentation. Anchors, aliases, and merge keys are read. An alias refers to the same table as its anchor. Tags other than the core ones raise an error, so a document cannot construct values of arbitrary types. Mapping keys become strings and a null value leaves its key out, as `fromjson` does. Mapping keys keep no order in a Lus table, so `encode` writes keys in sorted order unless `options.order` gives a list.

## toml

`toml` reads and writes TOML 1.0. `toml.decode(text)` returns a table and `toml.encode(value)` writes one. An offset date time in UTC becomes a `time` instant, while one with another offset becomes a `time` zoned value that keeps the offset. Local date times, dates, and times become the tables of `toml.localtime`, which have a `kind` field. A round trip therefore keeps every value, fractions of seconds included. Integers stay integers and floats stay floats.

## html_template

`html_template` renders HTML from templates with the syntax of Handlebars. `{{ name }}` inserts an escaped value, `{{{ html }}}` inserts it unescaped, `{{#if}}`, `{{#unless}}`, `{{#each}}`, and `{{#with}}` are the block helpers, `{{> partial}}` includes a partial, and `{{! comment }}` is a comment. A program registers helpers and partials on an environment.

```lus nocheck
local template = require("https://atmosp.here/2.0/html_template.lus")
local page = template.compile("<h1>{{ title }}</h1>{{#each items}}<li>{{ name }}</li>{{/each}}")
print(page({ title = "Lus & co", items = { { name = "a" }, { name = "b" } } }))
--> <h1>Lus &amp; co</h1><li>a</li><li>b</li>
```

`compile` turns a template into a tree of closures, so rendering needs no `load` permission. `@index` counts from 1, as Lus lists do. `template.env({ root = "views" })` loads templates and partials from files, which needs `fs:read`.

`bench/bench.lus` in `lus-lang/atmos-html-template` renders the page of the template benchmark of `tests/bench/compare` with the package and with `table.concat`, as `template.lus` does. For 200,000 rows on an Apple M4 Max with a ReleaseFast build, `table.concat` took 0.103 seconds and the package 0.405 seconds. The first version of the package took 0.575 seconds. The built-in `each` then gained a path that writes into the buffer of its parent and updates one frame and one data table per loop, which brought it to 0.420 seconds. Looking up `@` values through the parent frames, in place of a metatable per loop, brought it to 0.405 seconds.

## markdown

`markdown` renders CommonMark to HTML, with the GitHub extensions for tables, strikethrough, task lists, and autolinks. `markdown.render(text, options)` returns HTML. `markdown.parse(text)` returns the syntax tree as nested tables, so a program can walk it. Raw HTML in the input is escaped unless `options.html` is true. The tests hold cases modeled on the examples of the CommonMark and GFM specifications, at least one for every construct. Link destinations with the schemes `javascript`, `vbscript`, `file`, and `data` render empty unless `options.unsafe_links` is true, so untrusted input cannot inject a script through a link. Named character references outside a small table pass through to the browser. The guide of the manual, 250 KB of Markdown, renders in 0.035 seconds on an Apple M4 Max.

## cli

`cli` parses command line arguments into commands, options, and positional arguments. It prints help and errors, following the model of commander.

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

`color` styles terminal text with ANSI escape sequences. `color.red("text")` returns the string wrapped in the codes, with styles that chain, as in `color.bold.red("error")`. The package supports the 16 basic colors, 256 colors, and 24-bit colors with `color.hex("#ff8800")`. Output is plain when the environment variable `NO_COLOR` is set or `TERM` is `dumb`. `FORCE_COLOR` turns it on. `color.strip(text)` removes the codes and `color.width(text)` measures the visible width.

## prompt

`prompt` asks questions on the terminal: `prompt.text(question, options)`, `prompt.confirm(question, default)`, `prompt.number`, `prompt.select(question, choices)`, and `prompt.multiselect`. With a `validate` option, which takes a function or a `schema` value, the prompt repeats the question until the answer passes. On a terminal, `prompt` switches standard input into raw mode with `io.stdin:setraw(true)` and reads one key at a time, which gives arrow key menus and hidden password input. Ctrl-C arrives as `"\3"` in raw mode, so `prompt` restores the terminal and raises an error object that the caller may catch. When standard input is not a terminal, as `io.stdin:isatty()` reports, the prompts read whole lines and a selection reads the number of a choice, so scripts and tests can answer them from a pipe.

## dotenv

`dotenv` reads `.env` files. `dotenv.parse(text)` returns a table of the variables in a text. `dotenv.load(path, options)` reads a file, `.env` by default, and returns the same table. The syntax covers `KEY=value`, `export KEY=value`, single quotes, double quotes with escapes, multiline double quoted values, comments, and `${VAR}` expansion from earlier keys and the environment. `dotenv.get(name)` returns a loaded value or falls back to `os.getenv`. `dotenv.load(path, { export = true })` also sets every value with `os.setenv`, which needs `env:write`, so commands that the program starts see them. A variable that the environment already holds keeps its value unless `override` is true.

## jwt

`jwt` signs and verifies JSON Web Tokens. `jwt.sign(claims, key, options)` returns a token. `jwt.verify(token, key, options)` returns the claims or raises an error object. It checks the signature, `exp`, `nbf`, `iat`, `iss`, `aud`, and a leeway in seconds. `jwt.decode(token)` returns the header and the claims without verifying them. The algorithms are `HS256`, `HS384`, `HS512`, and `EdDSA` with Ed25519. They match the hash functions and signatures of the standard library `crypto` module, which adds SHA-384 for `HS384`. `verify` takes the list of accepted algorithms as a required option, so a token cannot choose its own algorithm.

```lus nocheck
local jwt = require("https://atmosp.here/2.0/jwt.lus")
local token = jwt.sign({ sub = "42", exp = time.now():epoch() + 3600 }, secret, { alg = "HS256" })
local claims = jwt.verify(token, secret, { algorithms = { "HS256" } })
```

## semver

`semver` parses, compares, and matches semantic versions according to Semantic Versioning 2.0.0. `semver.parse(text)` returns a version table with the fields `major`, `minor`, `patch`, `prerelease`, and `build`, whose metatable compares versions with `<` and `==`. `semver.satisfies(version, range)` matches the range syntax of npm: comparators, `^`, `~`, `x` wildcards, hyphen ranges, and `||`. `semver.max_satisfying(list, range)` and `semver.increment(version, part)` complete the API. The atmosphere tools use it to pick package versions. It needs no cryptography.

## Order of work

Each package has its own repository, `lus-lang/atmos-NAME`, so no file of the runtime changes. The order of work follows the dependencies and the value of each package.

1. `schema`, because `web` validates with it.
2. `web`, with the benchmark against the bare server.
3. `cookie`, `cors`, and `session`.
4. `semver`, `dotenv`, `color`, and `cli`.
5. `jwt`.
6. `yaml`, `toml`, `html_template`, and `markdown`.
7. `prompt` and `websocket`.

Every package of the first set has a public repository in `lus-lang`, where its prototype is pushed as it progresses.

Prototypes of every package of the first set exist. Each has its tests, a README, and an AGENTS.md. Each passes `lus check` with the package codes `package-header`, `package-flag`, and `package-pledge`. Their tests pass with `lus test` over checkouts of the repositories in one directory, under `LUS_JIT=off`, the default, `LUS_JIT=eager`, and `LUS_JIT=opt-eager`. The `toml` tests include the examples and the invalid documents of the TOML 1.0 specification. The `semver` tests include range cases from the npm `semver` package. The `jwt` tests verify the example token of jwt.io. The `websocket` tests check the handshake example of RFC 6455. The `cookie`, `session`, and `web` tests send two `Set-Cookie` headers over a socket and find two header lines.

Writing the prototypes showed that `enum` and `continue` are keywords in Lus 2.0, so neither can name a field after a dot. The schema constructor for a set of values is therefore `schema.oneof`.

## Runtime additions

The packages needed the following additions to the runtime, which Lus 2.0 adds.

- `network.serve` accepts a handler result of `101` and a function, which it calls with the socket of the connection after it sends the response. `websocket` uses it.
- A response header value may be a list of strings, which becomes one header line per string. `cookie` and `session` use it for `Set-Cookie`.
- `file:isatty()` reports whether a handle is a terminal. `io.stdin:setraw(on)` switches raw terminal mode. `color` and `prompt` use both.
- `os.setenv(name, value)` sets an environment variable under the `env:write` permission, while `os.getenv` checks `env:read`. `dotenv` uses both.

The prototypes of `web`, `color`, and `dotenv` use these additions where the runtime provides them, so their tests pass on runtimes with and without them.

The tests of `session` and `prompt` load their dependency from a sibling checkout. Each maps the atmosphere URL of the dependency to the local module in `package.preload`, which `require` checks for the exact URL before it uses the network.

## Next packages

The second set of official packages starts from the modules that Bun users import and from the packages that JavaScript programs depend on most, measured by weekly downloads on npm. The survey counts the dependencies of applications, such as database drivers, mailers, and loggers, alongside libraries and tools.

### Survey

Each surveyed package is covered by the standard library, covered by the first set, a gap worth an official package, or of no use in Lus. The following tables group the packages by class and area.

#### Covered by the standard library

| npm or Bun package | Lus |
| --- | --- |
| `uuid`, `nanoid`, `ulid` | `crypto.uuid`, `crypto.ulid`, and `crypto.random` |
| `bcrypt`, `argon2`, `Bun.password` | `crypto.hashpassword` and `crypto.verifypassword` |
| `crypto-js`, `sha.js`, `create-hmac` | `crypto.hash`, `crypto.hasher`, and `crypto.hmac` |
| `node-fetch`, `undici`, `cross-fetch` | `network.fetch` |
| `express`, `Bun.serve` at the transport level | `network.serve` |
| `ws` at the socket level | the `101` upgrade of `network.serve` |
| `better-sqlite3`, `bun:sqlite` | `io.sqlite` |
| `csv-parse`, `papaparse`, `csv-stringify` | `fromcsv` and `tocsv` |
| `fs-extra`, `rimraf`, `mkdirp`, `graceful-fs` | the `fs` module |
| `pako`, `zlib`, `brotli`, `lz4`, `zstd` codecs | `vector.archive` |
| `moment`, `dayjs`, `date-fns`, `luxon`, `date-fns-tz` | the `time` module with its IANA zones, `format`, and `parse` |
| `lodash`, `underscore`, `ramda` | `table` functions such as `map`, `filter`, `groupby`, `sortby`, `zip`, and `clone` |
| `bignumber.js`, `decimal.js`, `big.js` | `bigint` and `decimal` numbers |
| `iconv-lite`, `base64-js`, `buffer` | `string.transcode` and vectors |
| `async`, `p-map`, `p-all` | detached coroutines |
| `jest`, `vitest`, `mocha`, `chai`, `bun:test` | `lus test` with power asserts, case tables, snapshots, and fixtures |
| `prettier`, `eslint`, `typescript` checks | `lus fmt` and `lus check` |
| `piscina`, `workerpool` | `worker` |

#### Covered by the first 16 packages

| npm or Bun package | Lus package |
| --- | --- |
| `express`, `fastify`, `koa`, `hono`, `elysia`, `body-parser`, `path-to-regexp` | `web` |
| `ws`, `socket.io` at the message level | `websocket` |
| `cors` | `cors` |
| `cookie`, `cookie-parser`, `Bun.CookieMap` | `cookie` |
| `express-session`, `iron-session` | `session` |
| `zod`, `joi`, `yup`, `valibot`, `ajv`, `validator` | `schema` |
| `js-yaml`, `yaml` | `yaml` |
| `@iarna/toml`, `smol-toml` | `toml` |
| `handlebars`, `mustache`, `ejs`, `nunjucks`, `pug` | `html_template` |
| `marked`, `markdown-it`, `remark` | `markdown` |
| `commander`, `yargs`, `minimist`, `meow`, `cac` | `cli` |
| `chalk`, `picocolors`, `kleur`, `colorette`, `ansi-styles` | `color` |
| `inquirer`, `@inquirer/prompts`, `prompts`, `enquirer` | `prompt` |
| `dotenv`, `dotenv-expand` | `dotenv` |
| `jsonwebtoken`, `jose` | `jwt`, for HMAC and Ed25519 keys |
| `semver`, `Bun.semver` | `semver` |

#### Gaps

The gaps are packages that applications commonly depend on and that nothing in Lus provides yet.

| Area | npm or Bun packages |
| --- | --- |
| Web and HTTP | `multer`, `busboy`, `formidable`, `qs`, `form-data`, `serve-static`, `send`, `mime-types`, `express-rate-limit`, `axios`, `got`, `ky`, `helmet`, `compression`, `http-proxy` |
| HTML and XML | `cheerio`, `htmlparser2`, `parse5`, `sanitize-html`, `entities`, `he`, `fast-xml-parser`, `xml2js`, `HTMLRewriter` |
| Databases | `pg`, `postgres`, `Bun.sql`, `redis`, `ioredis`, `Bun.redis`, `mysql2`, `mongodb`, `knex`, `drizzle-kit` migrations |
| Queues and jobs | `bullmq`, `bee-queue`, `p-queue`, `node-cron`, `croner`, `cron-parser` |
| Email | `nodemailer`, `mailparser` |
| Logging | `pino`, `winston`, `morgan`, `debug` |
| Auth | `passport`, `openid-client`, `arctic`, `otplib`, `speakeasy` |
| Cloud storage | `@aws-sdk/client-s3`, `Bun.S3Client` |
| Dates and i18n | `i18next`, `intl-messageformat`, `ms`, `pretty-bytes`, `timeago.js` |
| Command line | `ora`, `cli-progress`, `listr2`, `cli-table3`, `string-width`, `wrap-ansi`, `strip-ansi`, `boxen` |
| Archives | `tar`, `archiver`, `adm-zip`, `jszip`, `yauzl`, which the standard library takes on |
| Processes and files | `execa`, `cross-spawn`, `Bun.spawn`, `Bun.$`, `chokidar`, `glob`, `fast-glob`, `minimatch`, `picomatch`, `Bun.Glob` |

#### Not applicable

Front-end frameworks such as `react`, `vue`, and `svelte` target the browser, as do their build tools such as `vite`, `webpack`, `esbuild`, and `babel`. Polyfills such as `core-js`, `tslib`, and `regenerator-runtime` solve problems of the JavaScript language that Lus does not have. So do helpers for the language itself such as `eventemitter3`, `rxjs`, and `inherits`. Native addons such as `sharp`, `canvas`, and `puppeteer` wrap large C or browser engines, which a package written in Lus cannot carry. [Later packages](#later-packages) covers images.

### Proposed packages

The plan groups the packages in tiers that follow the order of work. The first tier is for web applications, which are the largest group of programs in the survey. A later tier may start once the standard library additions it needs exist.

| Package | Repository | Replaces | Depends on | Permissions |
| --- | --- | --- | --- | --- |
| `log` | `lus-lang/atmos-log` | `pino`, `winston`, `morgan` | none | none |
| `form` | `lus-lang/atmos-form` | `qs`, `multer`, `busboy`, `form-data` | none | none |
| `static` | `lus-lang/atmos-static` | `serve-static`, `send`, `mime-types` | none | `fs:read` |
| `rate_limit` | `lus-lang/atmos-rate-limit` | `express-rate-limit` | none | none |
| `http_client` | `lus-lang/atmos-http-client` | `axios`, `got`, `ky` | `form` | `network:http` |
| `html` | `lus-lang/atmos-html` | `cheerio`, `htmlparser2`, `sanitize-html` | none | none |
| `postgres` | `lus-lang/atmos-postgres` | `pg`, `postgres`, `Bun.sql` | stdlib TLS, PBKDF2 | `network:tcp` |
| `redis` | `lus-lang/atmos-redis` | `ioredis`, `redis`, `Bun.redis` | stdlib TLS | `network:tcp` |
| `migrate` | `lus-lang/atmos-migrate` | `knex` and `drizzle-kit` migrations | none | `fs:read` |
| `mail` | `lus-lang/atmos-mail` | `nodemailer` | stdlib TLS | `network:tcp` |
| `cron` | `lus-lang/atmos-cron` | `node-cron`, `croner`, `cron-parser` | stdlib `time` | none |
| `queue` | `lus-lang/atmos-queue` | `bullmq`, `p-queue` | `redis` for its Redis store | none |
| `oauth` | `lus-lang/atmos-oauth` | `openid-client`, `arctic`, `passport` | `jwt`, stdlib RSA and ECDSA | `network:http` |
| `otp` | `lus-lang/atmos-otp` | `otplib`, `speakeasy` | none | none |
| `s3` | `lus-lang/atmos-s3` | `@aws-sdk/client-s3`, `Bun.S3Client` | `xml` | `network:http` |
| `xml` | `lus-lang/atmos-xml` | `fast-xml-parser`, `xml2js` | none | none |
| `humanize` | `lus-lang/atmos-humanize` | `ms`, `pretty-bytes`, `timeago.js` | none | none |
| `i18n` | `lus-lang/atmos-i18n` | `i18next`, `intl-messageformat` | none | `fs:read` when it loads catalogs |
| `term` | `lus-lang/atmos-term` | `ora`, `cli-progress`, `cli-table3`, `string-width`, `wrap-ansi` | `color` | none |

#### Tier 1: web applications

**log** writes structured log records as JSON lines, with levels, child loggers that add fields, and redaction of named fields. A pretty printer formats the lines for a terminal. Registered on a `web` scope, it logs one line per request with its method, path, status, and duration.

```lus nocheck
local log = require("https://atmosp.here/2.0/log.lus")
local logger = log.new({ level = "info", redact = { "password" } })
local db_log = logger:child({ component = "db" })
db_log:info("connected", { host = "localhost", ms = 12 })
app:register(log, { logger = logger })
```

The goal for `log` is the goal of `pino`: a disabled level costs one comparison. An enabled one costs one `tojson` call and one write.

**form** decodes and encodes `application/x-www-form-urlencoded` bodies with the nested keys of `qs`, such as `user[name]=x`. It parses `multipart/form-data` bodies into fields and files, with limits on the number of parts and the size of each. It builds multipart bodies for `network.fetch`. Registered on a `web` scope, it parses both types into `req.body` and `req.files`.

```lus nocheck
local form = require("https://atmosp.here/2.0/form.lus")
local fields = form.decode("user[name]=Ada&tags[]=a&tags[]=b")
local parts = form.multipart(req.body, req.headers["content-type"], { max_file_size = 10 * 1024 * 1024 })
for _, file in ipairs(parts.files) do print(file.name, file.filename, #file.data) end
local body, content_type = form.encode_multipart({ title = "x", upload = { filename = "a.png", data = bytes } })
```

**static** serves the files of a directory with a content type from its table of extensions, `ETag` and `Last-Modified` validators, `Range` requests, `Cache-Control`, and index files. It refuses paths that leave the root. It works as a `web` plugin and as a bare `network.serve` handler.

```lus nocheck
local static = require("https://atmosp.here/2.0/static.lus")
app:register(static, { root = "public", prefix = "/assets", max_age = 3600 })
network.serve("0.0.0.0", 8080, static.handler({ root = "public" }))
```

**rate_limit** limits requests per key with a fixed window, a sliding window, or a token bucket. Its store holds counters in memory by default and accepts any table with `incr`, `get`, `set`, and an optional atomic `take`, which `redis.rate_limit_store` provides. It sets the `RateLimit` headers of the IETF draft and answers 429.

```lus nocheck
local rate_limit = require("https://atmosp.here/2.0/rate_limit.lus")
app:register(rate_limit, { window = 60, max = 100, key = function(req) return req.ip end })
```

**http_client** wraps `network.fetch` with a base URL, query encoding, JSON bodies and replies, timeouts, retries with exponential backoff on 429 and 5xx, and hooks before a request and after a response. An error object carries the status and the decoded body.

```lus nocheck
local http_client = require("https://atmosp.here/2.0/http_client.lus")
local api = http_client.new({ base = "https://api.example.com", headers = { authorization = `Bearer $(token)` }, retries = 3 })
local user = api:get("/users/42", { query = { fields = "name" } }):json()
local created = api:post("/users", { json = { name = "Ada" } })
```

**html** parses HTML5 into a tree, queries it with CSS selectors, edits it, and renders it back to text. `html.sanitize` removes every tag and attribute outside an allowlist, which makes user input safe to embed. `html.escape` and `html.unescape` cover the named character references. The parser follows the tree construction rules of the HTML standard, so its tree matches the tree of a browser.

```lus nocheck
local html = require("https://atmosp.here/2.0/html.lus")
local doc = html.parse(page)
for _, a in ipairs(doc:select("a[href]")) do print(a:attr("href"), a:text()) end
local safe = html.sanitize(comment, { tags = { "b", "i", "a", "p" }, attributes = { a = { "href" } } })
```

#### Tier 2: databases, mail, and jobs

**postgres** implements the PostgreSQL wire protocol. It authenticates with SCRAM-SHA-256, runs queries with the extended protocol and bound parameters, keeps a pool of connections, and exposes transactions, `LISTEN` and `NOTIFY`, and `COPY`. A query result is a source for Lus queries by its `__query` metamethod, as the results of `io.sqlite` are. Each connection suspends a detached coroutine while it waits, so a `web` handler can query without blocking the server. It needs TLS client sockets and PBKDF2 from the standard library.

```lus nocheck
local postgres = require("https://atmosp.here/2.0/postgres.lus")
local db = postgres.connect("postgres://app@localhost/app", { pool = 10 })
for row in db:query("select id, name from users where id = $1", 42) do print(row.name) end
db:transaction(function(tx) tx:run("update accounts set balance = balance - $1 where id = $2", 10, 1) end)
```

**redis** implements RESP3 for Redis and Valkey, with pipelining, pub/sub, scripts, and a pool. Every command is a method, as in `r:set("k", "v", { ex = 60 })`. It provides the store interface of `rate_limit`, `session`, and `queue`.

```lus nocheck
local redis = require("https://atmosp.here/2.0/redis.lus")
local r = redis.connect("redis://localhost:6379")
r:set("visits", 0)
print(r:incr("visits"))                          --> 1
local results = r:pipeline(function(p) p:get("a") p:get("b") end)
```

**migrate** applies numbered SQL files from a directory in order and records each applied file in a table of the database. It runs each file in a transaction and checks the recorded checksum of every applied file. It works with `io.sqlite` and `postgres` by a small adapter that provides `exec` and `query`.

```lus nocheck
local migrate = require("https://atmosp.here/2.0/migrate.lus")
migrate.up(io.sqlite("app.db", "rw"), "migrations")
print(migrate.status(db, "migrations")[1].name)   --> 0001_create_users.sql
```

**mail** builds MIME messages with text and HTML parts, attachments, and encoded headers. It sends them over SMTP with STARTTLS or implicit TLS, `AUTH PLAIN` or `LOGIN`, and a pool of connections. `mail.message` returns the raw message, so a program can also send it with an HTTP mail service.

```lus nocheck
local mail = require("https://atmosp.here/2.0/mail.lus")
local smtp = mail.smtp({ host = "smtp.example.com", port = 587, user = user, password = password })
smtp:send({ from = "app@example.com", to = "ada@example.com", subject = "Welcome", text = "Hello", html = "<p>Hello</p>" })
```

**cron** parses cron expressions with five or six fields, the nicknames such as `@daily`, and time zones. `cron.next(expr, after)` returns the next matching `zoned` value. `cron.ticks(expr)` is an iterator that sleeps until each match. `cron.schedule` returns a detached coroutine that runs a function at every match.

```lus nocheck
local cron = require("https://atmosp.here/2.0/cron.lus")
print(cron.next("0 9 * * mon-fri", time.now(), "Europe/Paris"):iso())
for at in cron.ticks("0 3 * * *", { zone = "Europe/Paris" }) do backup(at) end
local job = cron.schedule("*/5 * * * *", function() cleanup() end)
coroutine.close(job)
```

**queue** runs jobs with retries, backoff, delays, priorities, and a limit on concurrency. Its default store is an SQLite table, which survives a restart of a single process. A Redis store shares jobs between processes. `q:process` returns its workers as detached coroutines, which a caller resumes to wait for them and closes to cancel them.

```lus nocheck
local queue = require("https://atmosp.here/2.0/queue.lus")
local emails = queue.new("emails", { store = queue.sqlite("jobs.db"), concurrency = 4, retries = 5 })
emails:process(function(job) smtp:send(job.data) end)
emails:add({ to = "ada@example.com", subject = "Hi" }, { delay = 60 })
```

#### Tier 3: auth and cloud

**oauth** implements the authorization code flow of OAuth 2.0 with PKCE, token refresh, and OpenID Connect discovery. It verifies ID tokens against the keys of the provider, fetched from its JWKS URL and cached. It ships settings for common providers such as GitHub, Google, Microsoft, Apple, and GitLab. Google and Microsoft sign ID tokens with RS256, so `oauth` needs RSA verification in the standard library. `jwt` gains RS256, PS256, and ES256 at the same time.

```lus nocheck
local oauth = require("https://atmosp.here/2.0/oauth.lus")
local github = oauth.provider("github", { client_id = id, client_secret = secret, redirect = "https://app.example/callback" })
local url, state = github:authorize_url({ scope = { "read:user" } })
local tokens = github:exchange(req.query_params.code, state)
```

**otp** generates and checks HOTP and TOTP codes from RFC 4226 and RFC 6238, with a window for clock drift. It also builds the `otpauth://` URI that authenticator apps scan. It needs only HMAC-SHA1 from `crypto`.

```lus nocheck
local otp = require("https://atmosp.here/2.0/otp.lus")
local secret = otp.secret()
print(otp.uri(secret, { issuer = "App", account = "ada@example.com" }))
print(otp.verify(secret, "492039", { window = 1 }))
```

**s3** signs requests with AWS Signature Version 4 and covers the object API of S3 and of compatible stores such as R2, MinIO, and Backblaze: get, put, delete, head, list, presigned URLs, and multipart uploads. It parses the XML replies with `xml`.

```lus nocheck
local s3 = require("https://atmosp.here/2.0/s3.lus")
local bucket = s3.bucket({ name = "uploads", region = "auto", endpoint = endpoint, key = key, secret = secret })
bucket:put("avatars/42.png", bytes, { content_type = "image/png" })
print(bucket:presign("avatars/42.png", { expires = 600 }))
```

#### Tier 4: data, text, and tools

**xml** parses XML into a tree or into plain tables with the conventions of `fast-xml-parser`, streams large documents event by event, and writes XML back. It handles namespaces, CDATA, and the predefined entities. It rejects external entities by default.

```lus nocheck
local xml = require("https://atmosp.here/2.0/xml.lus")
local feed = xml.decode(text)
print(feed.rss.channel.title)
print(xml.encode({ note = { _attr = { id = 1 }, to = "Ada" } }))   --> <note id="1"><to>Ada</to></note>
```

**humanize** turns numbers and durations into short text and back: `humanize.duration("2h 5m")` gives a `time` duration, `humanize.bytes(1536)` gives `"1.5 KiB"`, and `humanize.ago(instant)` gives `"3 minutes ago"`. It covers English, while `i18n` adds other languages.

**i18n** loads message catalogs per locale, formats messages with the ICU MessageFormat syntax for plurals and selections, and falls back from `fr-CA` to `fr` to the default locale. It formats numbers, currencies, and dates for a bundled set of CLDR locales. The plural rules come from CLDR.

```lus nocheck
local i18n = require("https://atmosp.here/2.0/i18n.lus")
local t = i18n.new({ default = "en", catalogs = { en = { cart = "{n, plural, one {# item} other {# items}}" } } })
print(t:format("en", "cart", { n = 3 }))         --> 3 items
print(t:number("fr", 1234.5))                    --> 1 234,5
```

**term** measures and lays out terminal text. It computes the display width of a string with wide and combining characters, wraps and truncates text that contains color codes, draws tables and boxes, and shows spinners and progress bars that redraw only on a terminal.

```lus nocheck
local term = require("https://atmosp.here/2.0/term.lus")
print(term.table({ { "name", "size" }, { "lus", "2.1 MB" } }, { header = true }))
local bar = term.progress({ total = #files })
for _, f in ipairs(files) do process(f) bar:tick() end
```

### Standard library additions

Some gaps belong in the runtime, because a package written in Lus cannot fill them or because many packages need them.

- **TLS client sockets.** `network.tls.connect(host, port, options)` returns a socket with the methods of a TCP socket. `sock:starttls(host)` upgrades an open one. `postgres`, `redis`, and `mail` need them. The HTTP client of the runtime contains the TLS code.
- **Streaming bodies.** `network.fetch` returns a reader for a body that arrives over time. A `network.serve` handler may return a function that writes the body in parts. Server-sent events, proxies, large downloads, and clients of streaming AI APIs need both.
- **RSA and ECDSA.** The standard library verifies and signs with RS256, PS256, and ES256, reading keys from PEM and JWK. `jwt` and `oauth` need them for the ID tokens of the large identity providers.
- **Key derivation and symmetric encryption.** SCRAM authentication in `postgres` needs PBKDF2 and HKDF. Encrypted cookies and sessions need AES-256-GCM. MD5 joins `crypto.hash` for the protocols that still require it, such as S3 checksums.
- **Processes with arguments.** `os.spawn(argv, options)` starts a program without a shell, with pipes for its three streams, a working directory, an environment, and its exit status. It covers `execa`, `cross-spawn`, and `Bun.spawn`. It passes each argument as given, with none of the quoting that `io.popen` needs.
- **File watching.** `fs.watch(path)` returns a coroutine that yields one change per resume, using kqueue, inotify, or ReadDirectoryChangesW, and stays suspended until the next change arrives. It covers `chokidar` and the reload loop of a development server.
- **Signals.** `os.signal(name)` returns a coroutine that yields once for each delivery of `SIGINT`, `SIGTERM`, or `SIGHUP`, so a server can stop accepting connections and finish its requests before it exits.
- **Recursive globs.** `fs.list` accepts `**` and braces. `fs.walk(path)` iterates over a directory tree. Together they cover `glob`, `fast-glob`, `minimatch`, and `Bun.Glob`.
- **ZIP and tar.** Readers and writers of both containers join `vector.archive`, next to the codecs they use. They read entries one at a time and refuse entry paths that leave the target directory.

### Later packages

These packages have users in the survey but depend on the earlier tiers or on a standard library addition.

- `mysql` and `mongodb` drivers, after `postgres` sets the shape of a driver.
- `sse` for server-sent events and an `ai` client for the streaming APIs of model providers, both after streaming bodies.
- `msgpack`, `cbor`, and `protobuf` encodings.
- `graphql`, a parser and executor of GraphQL queries for `web`.
- `diff`, a text diff with unified output.
- `faker` for test data and a property testing library for `lus test`.
- `proxy`, an HTTP reverse proxy for `web`, after streaming bodies.
- `image`, `qrcode`, `pdf`, and `xlsx`. Decoding and resizing images at the speed of `sharp` needs native code, so `image` waits for a decision on codecs in the runtime. `qrcode`, `pdf`, and `xlsx` writers can be written in Lus.

Other gaps join existing packages. `web` gains a compression plugin built on `vector.archive` and a plugin for security headers in the manner of `helmet`. `websocket` gains rooms and broadcast, which `socket.io` users expect.

### Coroutines

Anything that waits is a coroutine. A scheduler or a worker is a detached coroutine, so a program waits for it with `coroutine.resume` and cancels it with `coroutine.close`. These two functions are the only way to wait for or cancel the work of a package. A stream is an iterator whose steps block, such as `ws:messages()`, `cron.ticks(expr)`, and `xml.events(reader)`, so it suspends inside a detached coroutine and waits in place in the main chunk.

Some functions that the packages accept run synchronously and never wait, so they stay functions.

- The hooks of `web` are steps of the request pipeline. Each runs inside the coroutine of the connection and returns a value or nothing.
- `before_request` and `after_response` in `http_client` transform a request or a response in place.
- The `key`, `skip`, and `cost` options of `rate_limit` compute a value from a request.
- The `backoff` option of `queue` may be a function from the attempt to a delay.
- The `clock` and `sleep` options of `cron` and `queue` replace the time source in tests.
- The language hooks of `humanize`, the `missing` option of `i18n`, and the `write` option of `log` produce or consume a string.

### Status

The packages that need no new standard library exist as prototypes in the same layout as the first set: `log`, `form`, `static`, `rate_limit`, `http_client`, `html`, `migrate`, `cron`, `queue`, `otp`, `xml`, `humanize`, `i18n`, and `term`. Each passes `lus check` and its tests under every JIT mode.

The `html` tree builder matched parse5 on about 250,000 random inputs and 41 real pages. Its inline tree cases take their expected trees from parse5. `html.sanitize` is tested against a set of XSS vectors. The `i18n` tables come from CLDR 48. Its tests replay ICU outputs for the locales it bundles. The `otp` tests use the vectors of RFC 4226, RFC 6238, and RFC 4648.

Plugins for `web` register like `cors`: `app:register(static, options)`. Writing them fixed the following faults of `web`, each with a test.

- A hook that answers a request keeps its body and headers.
- The `on_send` and `on_response` hooks also run for error responses and for unmatched requests.
- Percent escapes in queries and path parameters decode as UTF-8.

Until the standard library gains `coroutine.sleep`, `cron` and `queue` sleep on the receive timeout of a UDP socket and declare `network:udp`. Each keeps that sleep in one internal function. `static` derives its `ETag` from the file content until `fs.stat` exists. `postgres`, `redis`, `mail`, `oauth`, and `s3` wait for TLS sockets and the new cryptography.
