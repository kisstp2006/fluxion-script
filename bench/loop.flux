var total = 0;
for (0..50000000) |i| {
    total += i * i % 7;
}
print(total);
