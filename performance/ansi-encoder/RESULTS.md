# Validated ANSI Encoder Results

The baseline is `06ca0baa12f4203c5bbad9ecadf53f9a475a52b2`. The
candidate is `d00dc4813d6803ce4efa3e9ad7b1c3533512aaff`, whose sole
parent is the baseline.

## Timing Aggregates

| Workload | Baseline MoM | Candidate MoM | Reduction | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Dense colour | 2,904,975 ns | 177,608 ns | 93.89% | 16.36x |
| Plain scroll | 1,396,079 ns | 67,583 ns | 95.16% | 20.66x |
| Sparse edit | 99,825 ns | 31,750 ns | 68.19% | 3.14x |
| Full redraw | 1,442,512 ns | 233,545 ns | 83.81% | 6.18x |

MoM means the median of three independent process medians.

## Independent Process Medians

| Round | Position | Workload | Baseline Median [Range] ns | Candidate Median [Range] ns |
| ---: | --- | --- | ---: | ---: |
| 1 | B1/C2 | Dense colour | 2,899,783 [2,818,195 to 2,974,645] | 177,212 [175,020 to 361,350] |
| 1 | B1/C2 | Plain scroll | 1,388,770 [1,339,079 to 1,429,937] | 67,583 [64,645 to 74,033] |
| 1 | B1/C2 | Sparse edit | 98,612 [98,179 to 102,716] | 31,679 [31,262 to 32,908] |
| 1 | B1/C2 | Full redraw | 1,441,491 [1,408,558 to 1,526,408] | 229,554 [223,466 to 232,837] |
| 2 | B2/C1 | Dense colour | 2,904,975 [2,839,833 to 3,282,766] | 177,608 [170,495 to 181,687] |
| 2 | B2/C1 | Plain scroll | 1,396,079 [1,340,816 to 1,725,975] | 67,512 [64,579 to 70,037] |
| 2 | B2/C1 | Sparse edit | 99,825 [92,933 to 114,112] | 32,233 [31,620 to 40,379] |
| 2 | B2/C1 | Full redraw | 1,442,512 [1,385,837 to 11,576,637] | 233,545 [224,350 to 467,129] |
| 3 | B1/C2 | Dense colour | 2,994,641 [2,871,233 to 3,230,316] | 183,704 [179,970 to 215,662] |
| 3 | B1/C2 | Plain scroll | 1,432,137 [1,358,379 to 1,524,500] | 68,370 [66,812 to 71,016] |
| 3 | B1/C2 | Sparse edit | 102,016 [95,666 to 150,745] | 31,750 [30,820 to 33,766] |
| 3 | B1/C2 | Full redraw | 1,477,879 [1,389,433 to 1,719,662] | 234,404 [219,370 to 242,395] |

## Allocation Scaling

| Cells | Geometry | Baseline Operations / Bytes | Candidate Operations / Bytes | Operation Reduction | Output Bytes / Hash |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1x1 | 16 / 574 | 5 / 248 | 68.750% | 93 / `807b6c9334132b0a` |
| 10 | 10x1 | 130 / 5,271 | 7 / 1,016 | 94.615% | 337 / `b9aee7c2e4342f1b` |
| 100 | 100x1 | 1,248 / 51,189 | 10 / 8,184 | 99.199% | 2,803 / `3e8b76ff15d7ce93` |
| 1,000 | 100x10 | 12,475 / 499,262 | 13 / 65,528 | 99.896% | 27,724 / `dfda67ccfd3a30eb` |
| 10,000 | 200x50 | 124,651 / 5,386,440 | 17 / 1,048,568 | 99.986% | 276,444 / `edfa0379543ed13d` |

## Virtual 800x600 Race

| Round | Position | Revision | Frames | Seconds | FPS |
| ---: | ---: | --- | ---: | ---: | ---: |
| 1 | 1 | Baseline | 70 | 10.072375 | 6.950 |
| 1 | 2 | Candidate | 1,088 | 10.000544 | 108.794 |
| 2 | 1 | Candidate | 1,057 | 10.005638 | 105.640 |
| 2 | 2 | Baseline | 53 | 10.412027 | 5.090 |

| Revision | Frames | Seconds | Aggregate FPS | Round FPS Range |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 123 | 20.484401 | 6.005 | 1.859 |
| Candidate | 2,145 | 20.006182 | 107.217 | 3.154 |

The aggregate isolated encoder throughput ratio is 17.86x. Every round emitted
13,254,757 bytes per frame with hash `29e298525b420eb3`.

## Final CPU Captures

| Revision | Samples | Active Span | Resolved | Status |
| --- | ---: | ---: | ---: | --- |
| Baseline | 7,894 | 7.895996542 s | 100.0% | Accepted final |
| Candidate | 7,707 | 8.091001458 s | 100.0% | Accepted final |

| Target Leaf | Baseline | Candidate |
| --- | ---: | ---: |
| `write_cell` | 67.5% | 17.7% |
| Legacy `build_sgr` | 21.5% | absent |
| Direct `write_sgr` | absent | 22.0% |
| `BlitEncoder::encode_inner` | 7.3% | 17.6% |
| `write_sgr_colour` | absent | 10.0% |
| `write_u8_decimal` | absent | 6.9% |
| `SgrStyleKey::from_cell` | absent | 6.3% |

| Overlapping Stack Family | Baseline | Candidate |
| --- | ---: | ---: |
| `encode_inner` | 100.0% | 99.7% |
| `write_cell` | 92.1% | 61.9% |
| Direct `write_sgr*` | absent | 43.3% |
| `alloc::fmt::format` | 38.8% | 0.0% |
| `malloc`-containing | 35.6% | 1.3% |
| `realloc`-containing | 31.4% | 1.3% |
| Legacy `build_sgr` | 24.2% | absent |

## Validation Summary

- All 10 comparable timing, allocation and race scopes matched in byte count
  and hash.
- Timing reduction and speedup arithmetic recompute from retained process
  medians.
- Ordered-batch data contains 24 vectors and exactly 2,400 observations.
- Allocation data contains five cell counts for both revisions.
- Collapsed CPU stacks contain 473 data rows. Counts sum to 7,894 baseline and
  7,707 candidate samples.
- CPU leaf categories, including `Other`, sum to each trace's sample count.
- Native allocation call-site attribution remains blocked because the exported
  live-object list is incomplete and excludes transient callers.

The machine-readable authority is [results.json][1]. The ordered batch and CPU
TSVs provide the chart inputs.

[1]: data/results.json
