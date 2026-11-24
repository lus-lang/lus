---
name: fs.watch
module: fs
kind: function
since: 2.0.0
stability: unstable
pledges: ["fs:read"]
origin: lus
params:
  - name: path
    type: string
  - name: options
    type: table
    optional: true
returns: thread
---

Starts watching the file or directory at `path` and returns a coroutine that hands over each change, one per resume. The watch covers every change that happens after the call returns.

Resuming the coroutine waits for the next change, then returns `true` and an event, which is a table with two fields. `kind` is one of these strings.

- `"create"`: a file or directory appeared, by creation or by a rename into place.
- `"modify"`: the contents or the attributes of a file changed.
- `"remove"`: a file or directory disappeared, by removal or by a rename away.
- `"rescan"`: the system dropped events, for example because they arrived faster than the program took them, so the program should look at the tree again.

`path` is the path of the file or directory that changed, which starts with `path` as the call wrote it. A `"rescan"` event carries `path` itself. A rename is reported as a removal of the old name and a creation of the new one.

Events of one path that follow each other within 50 milliseconds merge into one, so an editor that saves a file in several steps produces one `"modify"`. A creation followed by changes stays a `"create"`, a creation followed by a removal produces nothing, and a removal followed by a creation becomes a `"modify"`. An event is therefore delivered at least 50 milliseconds after it happened. Changes that happen while the program does other work wait in a queue for the next resume.

Resumed from a detached coroutine, the wait suspends that coroutine. Resumed anywhere else, it blocks while the detached coroutines run. Closing the coroutine with `coroutine.close` stops the watch, as does the collection of a coroutine that nothing references.

`options` is a table with these optional fields.

- `recursive` is a boolean. With `true` the watch covers every directory below `path`, including directories created during the watch. Without it a directory watch covers the entries of `path` itself.
- `glob` keeps only the events whose path matches it, in the glob syntax of [`fs.list`](/manual/api#fs.list). A glob without `/` and `**` matches the name of the file. Any other glob matches the path relative to `path`, with `/` between its segments.

A watch of a file reports the changes of that file only.

The call requires `fs:read` for `path`. An event of a path that `fs:read` does not cover is never delivered. A `path` that does not exist raises `"cannot watch 'PATH': No such file or directory"`. A system that refuses the watch, such as a sandbox without access to the notification service, raises an error that starts with `"cannot watch 'PATH'"`. An option of the wrong type raises a bad argument error.

The notifications come from inotify on Linux, FSEvents on macOS, and `ReadDirectoryChangesW` on Windows. inotify keeps one watch for each directory of a recursive watch, which counts against the number of watches that the system allows each user (`/proc/sys/fs/inotify/max_user_watches`).

The following example reloads a configuration file whenever it changes.

```lus nocheck
pledge("fs:read=./config")
local changes = fs.watch("config", {glob = "*.json"})
while true do
    local _, event = coroutine.resume(changes)
    if event.kind ~= "remove" then
        print("reloading " .. event.path)
    end
end
```

[`fs.walk`](/manual/api#fs.walk) visits the tree again after a `"rescan"` event.
