<!-- Generated from spec/design/style.md by tools/build-skills.js. Edit that file. -->

# Prose style

These rules govern every piece of prose the Lus project writes: the manual, the stdlib specification, the design notes, the agent skills, comments, commit messages, the changelog, the atmosphere registry, the atmos packages, and the documentation of projects whose agents follow the `lus-writing` skill. The model is the documentation of SQLite at sqlite.org, which states behavior so precisely that a reader can predict the result of a call without running it. Inside the Lus repository, the rules in `AGENTS.md` come first.

Most rules here come from readers who abandoned an earlier manual and from the maintainer's reading of later drafts. Each rule shows a passage that broke it and the rewrite. The checklist at the end lists the checks that a script or a grep can run.

## 1. Fixed rules

These rules hold in every file.

1. **Frame everything positively.** State what the design is and does. A sentence compares Lus only to something the reader can see: Lua, an earlier Lus release, another runtime, or a measurement recorded in the same note. "The only way to run a query is the `query` iterator" states the design. "There is no `tolist` method" describes a proposal the reader never saw.
2. **No em dashes or en dashes.** Rewrite the sentence so it needs no dash, without swapping the dash for a hyphen. `tools/lint-repo.js` enforces this.
3. **No semicolons in prose.** Write two sentences. Semicolons inside code are code.
4. **Full sentences and flowing paragraphs.** A code block follows a complete sentence that says what the block shows.
5. **The name of the Roblox Lua dialect never appears** outside the benchmark files that the lint allows. Describe techniques by what they do, such as "slot-prediction inline caches". `tools/lint-repo.js` enforces this.

## 2. Voice

The subject of a sentence about behavior is the thing that behaves: Lus, the runtime, the compiler, a function, or a value. "`catch` returns `false` and the error object" is the shape. The reader is "you" only in an instruction, such as "Pass a level of `0` to omit the position."

The project speaks as "we" when it explains a decision, in design notes and on the philosophy pages. Reference pages state facts and need no speaker.

Write in the present tense. Behavior happens now, every time. The past tense belongs to history and to measurements ("the peak memory fell from 493 to 452 MB").

The register is plain and dry. A sentence earns trust by being exact, so it carries no enthusiasm: no exclamation marks, and none of "handy", "simply", "just", "easily", "powerful", "blazing", or "seamless". A strong claim that a measurement supports is stated flatly. A claim with weaker evidence carries a precise hedge such as "usually", "on these benchmarks", or "as far as we know", and nothing vaguer.

## 3. Sentences

A sentence opens with its subject and makes one claim. A claim can be one scenario, one object, or one sequence of actions. A sentence of 15 to 30 words that tells one whole is normal. Separate ideas get separate sentences.

### Clause joins

Two independent clauses are never joined with ", and". The bare "and" hides the relation between them. Readers reported the pattern as the first thing that made the manual hard to read. Name the relation, or write two sentences.

> The catch handler receives the error object, and its result replaces the error.

> The catch handler receives the error object and returns its replacement.

A cause and its effect are joined with "so", "because", "which", or "therefore".

> An error raised by an attribute propagates from the assignment, and the variable keeps its previous value.

> An error raised by an attribute propagates from the assignment, which prevents the variable from being written.

A list of three or more items keeps its ", and" before the last item.

### Flow

Splitting every clause into its own sentence overcorrects. A run of short sentences that tell one scenario reads like a list of telegrams. Join the clauses of one scenario with a relative clause ("which", "that", "whose"), a subordinate clause ("when", "while", "because", "until"), a participle, or a comma and "then".

> Many programs spend most of their time waiting. A chat server holds a thousand connections. Each connection sends a line every few minutes. A script requests data from five services. Each answer takes a second to arrive.

> Many programs spend most of their time waiting. A chat server holds a thousand connections that each send a line every few minutes. A script that requests data from five services waits a second for each answer.

A sentence that restates what the previous one said goes.

> `coroutine.resume` on a detached coroutine waits until that coroutine has ended. It then returns what `resume` returns for any coroutine that ends: `true` and the return values, or `false` and the error object.

> `coroutine.resume` on a detached coroutine waits until that coroutine has ended, then returns `true` and the return values, or `false` and the error object.

A paragraph where most sentences have fewer than 10 words almost always needs this fix.

### Conditions and requirements

Conditions come first and use a fixed shape. "If the handler raises an error, that error propagates to the next `catch`." The other case follows as its own sentence that starts with "Otherwise". Exceptions use "except" or "unless", or, when there are several, a list introduced by a sentence.

Requirements use "must" and "must not". Permissions use "may". A requirement says what happens when it is broken: "The bracketed expression must evaluate to a function. Any other value raises an error at the `catch` site."

Information the reader needs goes in the sentence, not in parentheses. A parenthesis holds only a short gloss, a unit, or a cross-reference.

A sentence that starts with "Note that" states its fact without the lead-in. If the fact is surprising, the surprise belongs in the explanation of why.

## 4. Terms

A term is defined at its first use in a page with the shape "A _term_ is ...", with the term in italics. Bold marks the labels of a list, such as the goals on the introduction page. Code formatting marks every identifier, keyword, literal, and command.

One concept has one name everywhere. Once a page says "error object", it never switches to "error value" or "exception". When two names are unavoidable, for example because Lua uses one and Lus another, the page says once that they name the same thing.

The vocabulary in the table is fixed across the documentation.

| Term | Meaning |
|---|---|
| character | One Unicode code point, including a lone surrogate. Strings index and measure by character. |
| byte | One element of a `vector`. Strings never expose bytes directly. |
| error object | The value an error carries, of any type. |
| raise | What `error` and failing operations do. A `catch` captures. |
| falsy | `nil` or `false`. Every other value, including `0` and `""`, is truthy. |
| detached coroutine | A coroutine that `coroutine.detach` handed to the runtime. |
| permission | A capability such as `fs:read`. A chunk acquires permissions with `pledge`. |
| subtype | One of `integer`, `float`, `bigint`, and `decimal`, as `math.type` reports. |

## 5. Stating behavior precisely

A description is complete when it names the result in every case. For a function that means each return value, in order, on success and on failure, the errors it raises, and what it does with `nil`, empty, negative, and out of range arguments. "Success returns `true` followed by every result of the expression. Failure returns exactly `false` and the raw error object" is complete. "Returns the result or an error" is not.

Numbers are exact and carry units: "a 64-bit integer", "a header of 16 bytes on 64-bit targets", "at most 63 characters". A default is stated together with the name that changes it.

Completeness applies in full to reference pages: the API reference, `spec/stdlib/`, the grammar, the design notes, and the doc comments of a package. Teaching pages follow section 6a, which keeps exactness and leaves completeness to the reference.

An error is stated by its kind and its place. A compile error rejects the whole chunk before it runs. A runtime error is raised at a specific operation. The page says which one, and quotes the message when the message is part of the contract.

Behavior that Lus leaves open is named as such: "The order of iteration is unspecified." A reader then knows not to depend on it, which leaves the runtime free to change it.

A feature that a release added carries the release: "Lus 2.0 adds `continue`." Within the manual for a release, features of that release need no annotation.

A measurement names the program, the build, the machine, the metric, and the numbers before and after, as in "`strings.lus` went from 0.171 to 0.141 seconds, ReleaseFast on an Apple M4 Max". Design notes record measurements this way so that a later change can be checked against them.

## 6. Page structure

A page opens with one or two sentences that say what its subject is and what it is for. The mechanism follows, then the details, then edge cases and limits, then the related pages. A reader who stops after the first paragraph still has a correct, if incomplete, picture.

Headings in the manual are noun phrases in sentence case, such as "Detached coroutines" or "Catch handlers". A heading that names an API element is that element in code, such as `string.sub`. A page that collects surprising behavior may use declarative headings that state each fact, such as "Strings index by character".

A stdlib entry in `spec/stdlib/` follows one template, in this order:

1. A sentence that says what the function does and returns.
2. The parameters, each with its type, its default, and what it means.
3. The return values in order, on success and on failure.
4. The errors it raises and the permission it requires.
5. A short example.
6. Edge cases and related entries.

A package README follows the same idea at a larger scale. Its first sentence says what the package does, a short example shows it doing a recognisable job, and the paragraphs after it state the requirements, the permissions, and where the reference lives.

## 6a. Teaching pages

The guide, the getting started page, the page for Lua programmers, and the opening sections of every topic page teach. A reader of a teaching page wants to know what a feature is for and how to use it well, and reaches for the reference only when that is not enough.

1. **Introduce before use.** A section uses only concepts that an earlier section explained. Destructuring comes after tables, `<close>` after metatables, and queries after tables and iteration.
2. **Purpose first.** A feature opens with the problem it solves and when to reach for it. Mechanics follow. A feature whose purpose is obvious, such as `coroutine.close`, needs only its description.
3. **Examples beat the obvious alternative.** If a reader could ask "why not just write X", the example shows the wrong case. A do expression example that a plain call expresses with less code teaches nothing about do expressions.
4. **Idiomatic code only.** Examples use the standard library as an experienced Lus programmer would, and never show a pattern to avoid unless they label it as one.
5. **One home per topic.** Arithmetic, iteration, and permissions are each explained once and linked from elsewhere.
6. **General programming knowledge only.** A teaching page teaches tables, queries, and patterns from scratch, and explains every clause, aggregate, and pattern item it uses.
7. **User concepts.** Implementation terms such as "closure", "upvalue", "tail call", "provider", and "bytecode" stay out of teaching sections. The page describes what the programmer sees. The Internals section of the guide explains the implementation in its own terms.
8. **No needless precision.** A qualifier that adds no meaning goes. "An integer is a 64-bit number." "Each group field is a local variable." Exhaustive rules, limits, and error messages belong to the reference, and the teaching page links to them.
9. **No syntax before its introduction.** A sentence never names syntax that the reader has not seen yet. It describes what the thing does first.
10. **A link that promises a complete reference leads to one.**

A claim that a later section refines must already be true where it stands.

> The arithmetic operators work on numbers.

> The arithmetic operators work on numbers. Metatables extend them to other values, as the section on metatables shows.

## 6b. Plain statement

### The subject, never the page

A page talks about its subject. It never describes itself, its reader, or how to read it. Such sentences carry no information, so readers took them as the writer performing. This *prompt detritus* includes descriptions of the audience, outlines of what follows, and claims about the page's own qualities.

> This guide assumes no knowledge of Lua and is meant to be read in order. Every example runs as written.

> Lus is a programming language for programs that run on their own, such as command line tools, servers, and scripts.

A section opens with its concept and why it is useful, never with what the section contains.

> Each section below shows a Lua idiom and the Lus code that replaces it.

> Lua code runs in Lus with few changes, and most Lua idioms have a shorter Lus form.

The same holds for a README or a doc comment. "This package provides a router" becomes "Routes HTTP requests to handlers".

### Literal words

*Mannered prose* replaces a direct statement with a metaphor or a flourish. Such phrases make the reader work harder and carry connotations the writer did not choose. When a literal phrase exists, use it.

> Lus claims a handful of names that Lua leaves free.

> Lus has the globals `json`, `fs`, and `network`, which Lua does not define.

> A `while` loop fits a repetition whose number of passes is unknown.

> A `while` loop repeats its body until its condition is falsy, so it suits loops whose number of passes is not known in advance.

A *personified verb* gives code intentions. Idioms do not "strain", callers do not "ask for more", and statements do not "act on" loops. Say what the code does.

> The `continue` statement acts on the innermost loop.

> `continue` jumps to the next iteration of the innermost loop.

A copula beats an elaborate link. "Serves as", "acts as", "marks the", and "plays the role of" become "is" or "are".

> The header doc comment serves as the package manifest.

> The header doc comment is the package manifest.

### Concrete relations

*Symbolic phrasing* names two things and a preposition, then leaves the reader to work out the relation. Say what reads what and why.

> Lus finds C modules through `package.cpath`.

> `require` reads `package.cpath` to locate C modules.

A sentence that implies a contrast that does not exist stays out. "`nil` is a first-class value that can be passed as an argument" suggests that some values cannot be passed.

### Claims that stay true

A page states nothing that depends on when it is read. It has no dates of runs and no "today". A figure that changes with every measurement lives in a table generated from the data.

A count goes stale as the project grows. Write "the following changes" and list them. A count is fine when it is a fixed fact of the example in front of the reader, such as "two workers count the two halves".

> A Lua 5.5 program may need six changes to run in Lus.

> A Lua program may need the following changes to run in Lus.

A version number of Lua or another project stays only when it records history ("Lus is derived from Lua 5.5", "Lua 5.4 introduced `<close>`"). Where the sentence would also be true of a later version, or a later version could make it false, the number goes. Lus versions stay in release notes, in `@lus` headers, and where a feature records the release that added it.

A claim that something outside Lus contradicts stays out, including a contrast that is false of the thing contrasted. A standalone `lua` executable runs scripts without a host, so the passage below is false as a contrast.

> Lus is a language for complete programs. The `lus` executable runs a script without a host.

> The `lus` executable contains the libraries and tools that a complete program needs, such as JSON, HTTP, SQLite, a test runner, and a formatter.

### Design notes

A design note in `spec/design/` states the decision, the reason, and the measurement that supports it. Alternatives that were built and measured belong in the note with their numbers, because the note is the record of what was tried. The note describes the design that ships first and the measured alternatives after it.

## 7. Examples

Every rule that has an observable effect is followed by an example. The example comes after the rule it illustrates, never before it, and the sentence before it says what it shows.

An example is small, usually between 3 and 15 lines, and shows one idea. Output appears as a `-->` comment on the line that produces it, and the output is what a real run prints. Lus code uses 4-space indentation.

Every ` ```lus ` block runs under `lus test --doc`, so every example is a complete chunk that runs as written. A block that shows an error or a fragment is fenced as ` ```lus nocheck `. Use `nocheck` only for code that cannot run, since a block that runs is a block that stays correct.

An example does a job the reader recognises: a user record, a route of a blog, a line of a log file, a configuration file. Names such as `foo`, `x`, and `t` with values such as `1` and `"hello"` show syntax and nothing else. The sentence before the example says what it is for, never what it mechanically does.

> The example prints one sentence.

> The example greets each user by name and skips the accounts that are disabled.

A surprising case is shown as a pair: the form that surprises and the form that behaves as expected, each with a sentence that says which is which.

A comparison of two languages shows the same program twice. Both versions define the same functions, handle the same inputs, and print the same output, so the reader sees only the difference the comparison is about. Each version runs under its own interpreter before it is published.

> A Lua block that guards one call with `pcall`, beside a Lus block that guards two calls with `catch` and prints a third line.

> A Lua block and a Lus block that guard the same two calls and print the same two lines.

## 8. Links

A term links to its definition at its first mention in a section. Later mentions in the same section stay plain. An API name links to its entry, as in [`math.type`](/manual/api#math.type). A manual section links as `/manual/guide#section-slug`.

The link text is the thing linked, never "here" or "this page". A section that ends with related reading names each page and says in a few words what it holds.

## 9. Comparisons and tradeoffs

Lua is the baseline every Lus reader knows, and Lus shares its central value: a small language that says a lot in a few words. A comparison with Lua explains what Lua does and why that serves Lua, then what Lus does and why. It treats Lua with respect, as the language Lus grew from. "Lua indexes strings by byte, which keeps its string library small and encoding agnostic. Lus indexes by character, so that `#s` and `string.sub` agree with what a reader sees" is the shape. Every comparison must be true today and must stay true as both languages change.

A comparison with another runtime rests on a measurement and links to it. Where another runtime wins, the page says so in the same plain voice it uses for a Lus win: "A server that answers on several threads serves more HTTP requests per second than `network.serve`, which runs every connection on one thread." A figure that changes with each run belongs in the generated table, not in the sentence. A limit of Lus is stated as a fact, with the reason when the reason is known.

A design decision is explained by its consequences. The page says what the decision makes possible and what it costs, so the reader can judge the tradeoff without the page arguing for it.

## 10. Word choice

The left column shows words that weaken a sentence. The right column shows what replaces them.

| Avoid | Prefer |
|---|---|
| simply, just, easily | Omit the word. |
| handy, powerful, blazing | State the property and its measurement. |
| very, really, extremely | A number, or omit the word. |
| it should be noted that, note that | State the fact. |
| in order to | to |
| utilize | use |
| a number of | several, or the number |
| currently, at the moment, today | Omit the word, or name the release. |
| etc., and so on | Name every item, or say "such as" before a partial list. |
| (or false) | A full sentence, or the defined term "falsy". |
| serves as, acts as, marks the | is, are |
| via, through (for a relation) | The verb that states the relation. |
| instead of, rather than (for an unseen alternative) | State the design. |
| this section, below, above, the following section | Open with the subject. |

## 11. Before and after

The rewrites in this section apply the guide to passages of an earlier manual.

The opening of the guide addressed the reader with enthusiasm and promised more than it described:

> This handy guide will give you a brief rundown on the language. If you manage to make it through, you will be equipped with a good understanding of the language's internals and know everything necessary to write idiomatic Lus code.

The rewrite states what the page covers and how it is arranged:

> The guide is the complete reference for the Lus language. It describes every value type, operator, and statement, then functions, tables, coroutines, errors, the standard library, and the tools.

The description of optional chaining used an undefined term, put a rule in a parenthesis, and described the feature by what it avoids:

> The `?` suffix operator short-circuits a chain of indexing or call operations when any intermediate value is nil (or false), avoiding nested nil checks.

The rewrite defines the behavior in both cases:

> The `?` suffix makes the rest of a chain of indexing and calls conditional on the value before it. If that value is falsy, Lus skips every operation after the `?` and the whole chain evaluates to that value, so `false` stays `false`. Otherwise the chain continues as written.

The description of uncaught errors left the result to the host and hedged with a parenthesis:

> If an error is not caught, it propagates up to the host program, which can handle it appropriately (for example, by printing a message and exiting).

The rewrite says exactly what the `lus` command does:

> An error that no `catch` captures ends the chunk and returns to the host. The `lus` command prints the error object and a traceback to standard error and exits with status 1.

## 12. Checklist

Some rules are enforced by a script, some can be found with a grep and judged by hand, and the rest need a reader.

`tools/lint-repo.js` fails on an em dash or an en dash in any tracked file, and on the name of the Roblox Lua dialect outside the benchmark files. It reads only tracked files, so commit before running it. `lus test --doc` runs every ` ```lus ` block in the manual, the spec, and the skills. `lus check` covers the doc comments of a package.

The greps below find candidates. Each hit is judged by the rule it points to, since a list of three items legitimately contains ", and" and code legitimately contains semicolons.

```sh
grep -n ', and ' FILE                  # section 3: every hit is a list of three or more
grep -n ';' FILE                       # section 1: only in code
grep -nE '[0-9]' FILE                  # section 6b: counts and versions that go stale
grep -n 'Lua 5\.' FILE                 # section 6b: versions that are not history
grep -niE 'this (section|page|guide|package|module)|below|above|the following section' FILE
grep -niE 'serves as|acts as|marks the|plays the role' FILE
grep -niE '\b(via|through|instead of|rather than)\b' FILE
grep -niE '\b(simply|just|easily|handy|powerful|currently|today)\b' FILE
grep -niE 'assumes|meant to be read|every example runs' FILE
```

A reader then checks each point.

1. No sentence describes the design by an alternative the reader has not seen.
2. No paragraph is a run of short sentences that tell one scenario.
3. No phrase is a metaphor, a personified verb, or a preposition that hides a relation.
4. Every term is defined at first use and keeps one name. Nothing is used before it is introduced.
5. Every function description covers success, failure, and the edge cases.
6. Every example does a recognisable job. The two sides of a comparison do the same job.
7. Every claim is true today, stays true as the project grows, and survives a reader who knows the thing it is compared with.
8. Every claim about speed or memory names its measurement.
9. The page reads correctly from start to end, in order, for a reader who has only read the pages before it.

## 13. Outside the Lus repository

The `lus-writing` agent skill carries this guide to other repositories. `lus agents init` installs it with the other Lus skills, and lus.dev serves it at `/agents/skills/lus-writing/`. Its reference file is generated from this note by `tools/build-skills.js`, and `mise run gen:check` fails when the copy is stale, so this note stays the only text anyone edits.

The atmosphere registry, the atmos packages, and the package template each say in their `AGENTS.md` that prose follows the `lus-writing` skill. Projects created with `atmos init` inherit that line.
