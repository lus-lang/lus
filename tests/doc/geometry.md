---
name: geometry
kind: module
since: 2.0.0
stability: unstable
---

# geometry

Plane geometry helpers.

Every function works on plain numbers.

## geometry.pi

*Variable*

The ratio of a circle's circumference to its diameter.

## geometry.circle

```lus
function geometry.circle(r)
```

Returns the area of a circle.

**Parameters**

- `r` (`number`): The radius.

**Returns**

- `number`: The area.

## geometry.rect

```lus
function geometry.rect(w, h)
```

Returns the area of a rectangle.

**Parameters**

- `w` (`number`): The width.
- `h` (`number`, optional): The height. It defaults to the width, which gives a square.

**Returns**

- `number`: The area.

## geometry.undocumented

```lus
function geometry.undocumented(x, ...)
```

**Parameters**

- `x` (`any`)

## geometry.scale

```lus
function geometry.scale(factor, ...)
```

Scales every value.

**Parameters**

- `factor` (`number`): The scale factor.
- `...` (`number`, optional): The values to scale.

**Returns**

- `number...`: The scaled values.

## Point:length

```lus
function Point:length()
```

Returns the distance from the origin.

The result is never negative.

**Returns**

- `number`: The distance.

## calls

*Constant*

Number of calls so far.
