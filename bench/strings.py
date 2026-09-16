words = ["alpha","beta","gamma","delta","epsilon","zeta","eta","theta"]
counts = {}
parts = []
for i in range(400000):
    w = words[i % 8]
    key = f"{w}{i % 100}"
    counts[key] = counts.get(key, 0) + 1
    if i % 1000 == 0: parts.append(key.upper())
total = sum(counts.values())
print(len(counts), total, len(",".join(parts)))
