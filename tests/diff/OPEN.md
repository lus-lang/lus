# Open findings

This list holds the bugs and questions that the testing harnesses found and that are not fixed yet. Each entry names the harness, the smallest reproducer, and what is known. A fixed bug leaves this list and gains a regression test in `tests/conformance`.

## Decimal arithmetic with an extreme exponent takes unbounded time

Found by the numbers fuzz target under the sanitizer build, as a run that stopped making progress. Addition and subtraction of decimals are exact, so they align the two operands to the smaller exponent, and the work grows with the square of the difference of the exponents. `decimal("1e500000") + 1d` takes 5 seconds and makes a value of 500,001 digits, and `decimal("1e-9999999") + 1d` or `decimal("1e9999999") + 0d` runs for many minutes. `decimal(s)` accepts such a string from any input, so untrusted text can stall a program. The sum of `1e9999999` and `0` needs one digit, so part of the cost is avoidable, but the sum of `1e-9999999` and `1` needs ten million digits if it stays exact. A fix is a design decision, for example a range for decimal exponents, such as the plus or minus 6,144 of decimal128, or rounding sums to a precision.
