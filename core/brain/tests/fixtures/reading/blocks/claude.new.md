# Rounding question

Why do my order totals drift by a cent?
Two things usually cause it:

1. Rounding each line before adding them up.
2. Rounding half up, so every tie goes the same way.

Round once, on the total, and round half to even:

```
let total = round_half_even(subtotal + tax);
assert_eq!(total, Money::from_cents(7_384));
```

That keeps the total a customer sees equal to the total that settles.
