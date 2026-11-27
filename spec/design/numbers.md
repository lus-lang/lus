# Numbers

Lus 2.0 has one `number` type with four subtypes. `math.type` reports the subtype of a number value.

| Subtype | `math.type` | Representation | Literal |
|---|---|---|---|
| integer | `"integer"` | 64-bit two's complement, inline in the value | `42`, `0xff` |
| float | `"float"` | IEEE 754 binary64, inline in the value | `1.5`, `1e9`, `0x1p4` |
| bigint | `"bigint"` | arbitrary precision integer, heap object | `42n`, `0xffn` |
| decimal | `"decimal"` | exact base 10 coefficient and exponent, at most 131,072 digits before the point and 16,383 after, heap object | `1.50d`, `3d`, `1e-2d` |

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

## Limits of decimals

A decimal holds at most 131,072 digits before its point and 16,383 digits after it, the same limits as the exact `numeric` type of PostgreSQL. Sums, differences, and products stay exact, and any result, numeral, or conversion that needs more digits raises `decimal out of range: more than 131072 digits before the point`, or `more than 16383 digits after the point`. A decimal literal past the limits is a compile error. `decimal(s)` raises for a numeral past the limits and returns `nil` for text that is no numeral, and `fromjson` with `{ exact = true }` reports `number out of range`. An integer or bigint operand of decimal arithmetic must fit the limits too.

Exact arithmetic aligns the exponents of its operands, so without limits a sum such as `1e-9999999d + 1` would need ten million digits, and its work grows with the square of the distance between the exponents. The limits bound the work of every operation. On an Apple M4 Max, the slowest operations on decimals at the limits convert between decimals and text. Printing a decimal of 147,456 characters with `tostring`, `string.format`, or `tojson` takes about 100 milliseconds, and so does its conversion to a float, which goes through text. Parsing one takes about 40 milliseconds. A sum, a product, a division, a remainder, or a comparison takes under 25 milliseconds. The conversion to text splits the number in halves at powers of ten and divides through Barrett reciprocals that Newton iteration builds from multiplications, so its time grows like that of a multiplication and well below the square of the digits. Bigints print the same way. Before it computes a power, Lus estimates the digits of the result from the bit length of the base and raises when the power cannot fit, so `2d ^ 2000000000` raises at once. A bigint shifts left by at most 2^24 bits, and a larger amount raises `shift amount too large`. A right shift past the bits of its operand gives 0 or -1 whatever its amount. Integers beyond the limits stay exact as bigints, which keep any size through arithmetic.

Bitwise operators accept integers and bigints. On integers they act on 64 bits. When either operand is a bigint they act on the infinite two's complement representation and produce a bigint.

## Limits of bigints

A bigint keeps any size through arithmetic. Its conversions between text and value handle at most 16,384 digits, not counting the sign and the `0x` prefix of a hexadecimal numeral. `bigint(s)` and every conversion of a bigint to text, such as `tostring`, `print`, `..`, `string.format`, and `tojson`, raise `bigint out of range: more than 16384 digits` past the limit. A longer bigint literal is a compile error that reports `bigint literal out of range`. `fromjson` with `{ exact = true }` reports `number out of range` for a longer integer. Reading decimal text takes time that grows with the square of its digits, so the limit bounds the work of one conversion. A program that writes a larger bigint as text splits it with `//` and `%` by a power of ten. The debugger shows such a value as its bit length.

## Comparison and equality

All four subtypes compare by mathematical value. `1 == 1.0`, `1 == 1n`, and `1n == 1.00d` are all true. Comparing a decimal with a float compares their exact values, which is well defined even though arithmetic between them is an error. NaN compares unequal to everything. Every NaN prints as `nan`. The sign bit of a NaN depends on the hardware that made it, since x86-64 sets it for `0/0` where arm64 clears it, so the runtime never prints it and a program prints the same text on every platform.

## Table keys

A number used as a table key is normalized first. A float with an integral value that fits in 64 bits becomes an integer key, as in Lua. A bigint that fits in 64 bits becomes an integer key. A decimal with an integral value becomes the equivalent integer or bigint key. So `t[1]`, `t[1.0]`, `t[1n]`, and `t[1d]` all name the same slot. A bigint or a decimal whose value a float holds exactly becomes that float, so `t[1e20]` and `t[100000000000000000000n]` name one slot, as do `t[0.5]` and `t[0.5d]`. Any other decimal key loses its trailing zeros, so `t[0.1d]` and `t[0.10d]` name one slot. Numbers that compare equal are therefore one key, and `pairs` returns the key in its normalized form.

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
