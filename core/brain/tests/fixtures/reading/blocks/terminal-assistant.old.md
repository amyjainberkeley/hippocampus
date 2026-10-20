```
dev@studio trailhead-shop % claude
⏺ Update(src/tax.rs)
  ⎿  Updated src/tax.rs with 2 additions and 1 removal
       14    pub fn order_total(lines: &[Line]) -> Money {
       15 -      let subtotal: Money = lines.iter().map(|l| l.price.round_cents() * l.qty).sum();
       15 +      let subtotal: Money = lines.iter().map(|l| l.price * l.qty).sum();
⏺ Bash(cargo test tax)
  ⎿  test tax::tests::rounds_half_to_even ... ok
     test result: ok. 6 passed; 0 failed

⏺ The totals now round once, half to even, and all six tax tests pass.
```
