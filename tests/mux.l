# lang 1
# ((1, 0), ((1, 2), (3, 4))) (2, 3)
let a (if x.1.1 [] x.2.1.1) let b (if x.1.2 x.2.2.2 x.2.2.1) (a, b)
