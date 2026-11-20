# wordfreq: count word frequencies in a generated text.
import re
import sys
from collections import Counter

n = int(sys.argv[1]) if len(sys.argv) > 1 else 10000000

state = 42


def rand(m):
    global state
    state = (state * 48271) % 2147483647
    return state % m


letters = "abcdefghijklmnopqrstuvwxyz"
vocab = []
for k in range(5000):
    length = 3 + rand(7)
    chars = []
    for j in range(length):
        ch = letters[rand(26)]
        if rand(5) == 0:
            ch = ch.upper()
        chars.append(ch)
    vocab.append("".join(chars))

punct = [",", ".", "!"]
parts = []
for i in range(1, n + 1):
    parts.append(vocab[rand(rand(5000) + 1)])
    if rand(12) == 0:
        parts.append(punct[rand(3)])
    parts.append("\n" if i % 12 == 0 else " ")
text = "".join(parts)
del parts

counts = Counter(w.lower() for w in re.findall(r"[A-Za-z]+", text))
total = sum(counts.values())
ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))

out = ["wordfreq", str(len(ranked)), str(total)]
out += [str(c) for _, c in ranked[:10]]
out += [w for w, _ in ranked[:3]]
print(" ".join(out))
