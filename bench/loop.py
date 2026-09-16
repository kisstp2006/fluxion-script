total = 0
for i in range(50000000):
    total += i * i % 7
print(total)
