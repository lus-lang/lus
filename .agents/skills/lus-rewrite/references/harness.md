# Parity harness templates

The harness has two halves. A recorder runs the original program over the corpus and writes golden files once. A parity test runs the Lus port over the same corpus and compares its output with the golden files. The golden files are committed, so the harness keeps working after the original is gone.

## Layout

```
.lus-rewrite/harness/
    cases/          one input per case, named after the behavior it covers
    golden/         the original program's output for each case
    record.lus      runs the original and writes golden/
    parity_test.lus runs the port and compares
```

## Recorder

The recorder runs a shell command per case. Replace `ORIGINAL` with the command that runs the original program.

```lus nocheck
-- Runs the original program over every case and writes its output as the golden file.
global fs, io, ipairs, print, pledge

pledge("exec", "fs")
pledge("seal")

local ORIGINAL = "python3 legacy/main.py"
local DIR = ".lus-rewrite/harness"

for _, case in ipairs(fs.list(`$DIR/cases`, "*.txt")) do
    local name = fs.path.name(case)
    local p <close> = io.popen(`$ORIGINAL < $DIR/cases/$name 2>&1; echo "exit=$$?"`)
    local out = p:read("a")
    local f <close> = io.open(`$DIR/golden/$name.out`, "w")
    f:write(out)
    print(`recorded $name`)
end
```

Run it from the project root with `lus .lus-rewrite/harness/record.lus`. The `exit=` line makes the exit status part of the golden output, and `2>&1` captures error messages.

## Parity test

The parity test runs once per case through a case table, and the power assert shows both outputs when they differ.

```lus nocheck
-- Runs the Lus port over every case and compares with the golden output.
global assert, fs, io, ipairs, os, pledge, parity_test, TEST_DIR

pledge("exec", "fs:read", "env")

local ROOT = fs.path.parent(fs.path.parent(TEST_DIR))
local LUS = os.getenv("LUS_EXE")
local PORT = `$LUS src/main.lus`

local function run(name)
    local cmd = `cd $ROOT && $PORT < $TEST_DIR/cases/$name 2>&1; echo "exit=$$?"`
    local p <close> = io.popen(cmd)
    return p:read("a")
end

local function golden(name)
    local f <close> = io.open(`$TEST_DIR/golden/$name.out`)
    return f:read("a")
end

local parity_cases = {}
for _, case in ipairs(fs.list(`$TEST_DIR/cases`, "*.txt")) do
    parity_cases[#parity_cases + 1] = fs.path.name(case)
end

function parity_test(name)
    assert(run(name) == golden(name))
end
```

`LUS_EXE` names the interpreter that runs the tests, so the harness always uses the same `lus` as `lus test`. To check the harness itself, set `PORT` to the original command once and confirm every case passes, then alter one golden file and confirm that case fails.

## Normalizing output

Replace nondeterministic text before comparing, and apply the same function to both sides.

```lus
local function normalize(text)
    return (text
        :gsub("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%.%d]*Z?", "<time>")
        :gsub("/tmp/[%w%._%-]+", "<tmp>"))
end

assert(normalize("at 2026-11-19T10:00:00Z in /tmp/x1") == "at <time> in <tmp>")
```

## Network programs

For a client, record each response once into `cases/` as JSON with `tojson`, and give the port a flag or environment variable that reads responses from those files. For a server, start the port with `network.serve` on port 0 in a detached coroutine inside the test, send the recorded requests with `network.fetch`, and compare status, headers that matter, and body with the golden responses.

## Structured output

When the output is JSON, compare parsed values with `same(fromjson(a), fromjson(b))`, since JSON object member order is unspecified. When the output is a table of values, `snapshot(value)` records it in `__snapshots__/` and `lus test -u` accepts a reviewed change.
