# Numbers

Lus 2.0 has one `number` type with four subtypes. `math.type` reports the subtype of a number value.

| Subtype | `math.type` | Representation | Literal |
|---|---|---|---|
| integer | `"integer"` | 64-bit two's complement, inline in the value | `42`, `0xff` |
| float | `"float"` | IEEE 754 binary64, inline in the value | `1.5`, `1e9`, `0x1p4` |
| bigint | `"bigint"` | arbitrary precision integer, heap object | `42n`, `0xffn` |
| decimal | `"decimal"` | arbitrary precision base 10 coefficient with a 32-bit exponent, heap object | `1.50d`, `3d`, `1e-2d` |

## Literals

A decimal or hexadecimal integer literal followed directly by `n` is a bigint. Its value is exact, whatever its size. A numeric literal written in decimal notation followed directly by `d` is a decimal. Its digits are kept exactly as written, so `1.50d` keeps two fractional digits. Hexadecimal decimals and floats with an `n` suffix are lexical errors. An integer literal that overflows 64 bits without a suffix converts to a float, as in Lua.

## Integer arithmetic

Integer arithmetic wraps around on overflow, exactly as in Lua 5.4. Wrapping keeps hashing and bit manipulation code predictable and keeps the integer fast path to a single machine instruction. Programs that need exact results beyond 64 bits use bigint values.

## Mixing subtypes

Arithmetic between two operands picks a result subtype with this table, where rows and columns are the operand subtypes.

| | integer | float | bigint | decimal |
|---|---|---|---|---|
| **integer** | integer | float | bigint | decimal |
| **float** | float | float | float | error |
| **bigint** | bigint | float | bigint | decimal |
| **decimal** | decimal | error | decimal | decimal |

Mixing decimal and float raises the error `attempt to mix decimal and float in arithmetic`. A decimal holds an exact base 10 value and a float holds an approximate base 2 value, so the program states which one it wants with `decimal(x)` or `tonumber(x)`.

The `/` operator on integers and bigints produces a float, as in Lua. On decimals it produces a decimal with up to 34 significant digits, rounded half to even. The `//` and `%` operators keep the subtype from the table. Exponentiation produces a float unless both operands are decimals or bigints with a non-negative integer exponent, in which case the result is exact.

Bitwise operators accept integers and bigints. On integers they act on 64 bits. When either operand is a bigint they act on the infinite two's complement representation and produce a bigint.

## Comparison and equality

All four subtypes compare by mathematical value. `1 == 1.0`, `1 == 1n`, and `1n == 1.00d` are all true. Comparing a decimal with a float compares their exact values, which is well defined even though arithmetic between them is an error. NaN compares unequal to everything. Every NaN prints as `nan`. The sign bit of a NaN depends on the hardware that made it, since x86-64 sets it for `0/0` where arm64 clears it, so the runtime never prints it and a program prints the same text on every platform.

## Table keys

A number used as a table key is normalized first. A float with an integral value that fits in 64 bits becomes an integer key, as in Lua. A bigint that fits in 64 bits becomes an integer key. A decimal with an integral value becomes the equivalent integer or bigint key. So `t[1]`, `t[1.0]`, `t[1n]`, and `t[1d]` all name the same slot.

## Conversions

- `bigint(x)` converts an integer, an integral float, a decimal with an integral value, or a numeric string to a bigint. Other inputs raise an error.
- `decimal(x)` converts an integer, a bigint, or a numeric string to a decimal exactly. Converting a float uses the shortest decimal string that round trips to the same float.
- `tonumber(x)` converts bigints and decimals to the nearest float, and keeps integers.
- `math.tointeger(x)` returns an integer when `x` has an integral value that fits in 64 bits, for every subtype.
- `tostring` prints bigints in decimal without a suffix and decimals with exactly their stored digits.

## JSON

`fromjson` decodes numbers into integers and floats by default. With the option `{ exact = true }` it decodes integers that overflow 64 bits as bigints and numbers with a fraction or exponent as decimals, so a round trip through `tojson` reproduces the original digits.

## Virtual machine

Integers and floats live inline in the value and the quickened arithmetic opcodes handle them without branches on heap state. A bigint or decimal operand makes the fast path decline to the generic path, which dispatches on the table above.
