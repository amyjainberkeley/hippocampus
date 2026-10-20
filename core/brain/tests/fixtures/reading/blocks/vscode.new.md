```
use std::time::Duration;

/// Delete events older than the configured window, oldest first.
pub fn sweep(store: &Store, config: RetentionConfig) -> Result<u64, SweepError> {
    let Some(cutoff_us) = config.cutoff_us(now_us()) else {
        return Ok(0);
    };
    let mut deleted = 0_u64;
    for batch in store.events_before(cutoff_us).chunks(512) {
        deleted += store.delete_batch(batch)?;
        std::thread::sleep(Duration::from_millis(25));
    }
    if deleted > 0 {
        store.vacuum()?; // reclaim pages so deleted text is gone
    }
    Ok(deleted)
}
```

You
Why does the sweep sleep between batches?
Assistant

So a long sweep never holds the writer for more than one batch. Each batch deletes at most 512 events, then yields for 25 ms so capture can write.

You
Could we make the batch size configurable?
Assistant

Yes. Add batch_size to RetentionConfig with a default of 512 and clamp it between 64 and 4096. I can draft the change and a test that checks the clamp.

```
$ cargo test -p mci-agent retention
   Compiling mci-agent v0.3.0
    Finished `test` profile in 41.07s
running 6 tests
test retention::sweep_deletes_oldest_first ... ok
test retention::sweep_stops_at_cutoff ... ok
test result: ok. 6 passed; 0 failed
```
