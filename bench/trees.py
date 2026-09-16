class Node:
    __slots__ = ('left', 'right')
    def __init__(s, l=None, r=None): s.left = l; s.right = r
def make(d):
    if d == 0: return Node()
    return Node(make(d-1), make(d-1))
def check(n):
    if n.left is not None: return 1 + check(n.left) + check(n.right)
    return 1
maxd = 16
long = make(maxd)
for d in range(4, maxd+1, 2):
    it = 1 << (maxd - d + 4)
    total = 0
    for _ in range(it): total += check(make(d))
    print("%d trees of depth %d check %d" % (it, d, total))
print("long lived tree check %d" % check(long))
