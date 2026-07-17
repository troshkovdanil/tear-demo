# tear-demo

Reproducible TEAR demonstrations and experiments

## TEAR DL Streamer POWER_SAVE Demo

Build and run:

```
./scripts/demo.sh
```

Expected output:

[TEAR] POWER_SAVE profile activated at frame 300

Before frame 300:
    ~25 FPS inference throughput

After frame 300:
    ~2-4 FPS inference throughput

PASS: POWER_SAVE enforcement was activated at frame 300
PASS: The inference pipeline completed successfully
