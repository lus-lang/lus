---
name: greet
kind: module
---

# greet

## GREETING

*Constant*

The greeting used by `greet`.

## greet

```lus
function greet(name)
```

Prints a greeting.

The text is `GREETING` followed by the name.

**Parameters**

- `name` (`string`): Who to greet.

## shout

```lus
function shout(text)
```

**Parameters**

- `text` (`any`)

## join

```lus
function join(sep, ...parts)
```

Joins strings with a separator.

**Parameters**

- `sep` (`string`): The separator.
- `...parts` (`string`): The strings to join.

**Returns**

- `string`: The joined text.
