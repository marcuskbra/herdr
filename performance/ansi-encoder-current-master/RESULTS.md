# Current-Master ANSI Encoder Results

## Accepted Comparison

V1 is `49e333ae87a57952fc82ba479a55c35b975ff3cc`. V3 is
`90f12051690f46f8d5837b861df14350a6ea4fde`, whose sole parent is V1. The
historical V0-vs-V2 showcase is immutable, separate evidence and is not a
source for the results below.

## Median Latency

The primary statistic is the median of three independent process medians.
Each process contributes one replication.

| Workload | V1 | V3 | Reduction | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Dense colour | 2,936,629 ns | 164,054 ns | 94.41% | 17.90x |
| Plain scroll | 1,404,308 ns | 69,620 ns | 95.04% | 20.17x |
| Sparse edit | 100,262 ns | 31,220 ns | 68.86% | 3.21x |
| Full redraw | 1,338,825 ns | 55,954 ns | 95.82% | 23.93x |

![Median latency for the four current-master workloads][chart-1]

## Independent Process Results

Ranges show the minimum and maximum of 100 per-process batches.

| Round | Position | Workload | V1 Median [Range] ns | V3 Median [Range] ns |
| ---: | --- | --- | ---: | ---: |
| 1 | V1-1/V3-2 | Dense colour | 2,936,629 [2,843,241 to 3,026,187] | 164,054 [155,350 to 222,741] |
| 1 | V1-1/V3-2 | Plain scroll | 1,398,100 [1,349,379 to 1,435,712] | 68,241 [66,733 to 75,325] |
| 1 | V1-1/V3-2 | Sparse edit | 98,350 [97,633 to 104,758] | 31,129 [29,895 to 36,037] |
| 1 | V1-1/V3-2 | Full redraw | 1,321,704 [1,268,108 to 1,372,020] | 55,333 [52,708 to 68,837] |
| 2 | V1-2/V3-1 | Dense colour | 2,899,358 [2,822,775 to 3,002,487] | 166,470 [158,633 to 175,966] |
| 2 | V1-2/V3-1 | Plain scroll | 1,404,308 [1,347,191 to 1,466,600] | 70,820 [67,437 to 77,612] |
| 2 | V1-2/V3-1 | Sparse edit | 100,575 [97,720 to 111,566] | 31,220 [30,012 to 32,645] |
| 2 | V1-2/V3-1 | Full redraw | 1,338,825 [1,282,966 to 1,435,766] | 55,954 [54,783 to 62,325] |
| 3 | V1-1/V3-2 | Dense colour | 2,966,775 [2,873,125 to 3,306,841] | 163,333 [152,341 to 168,862] |
| 3 | V1-1/V3-2 | Plain scroll | 1,435,433 [1,382,645 to 1,475,212] | 69,620 [66,308 to 82,558] |
| 3 | V1-1/V3-2 | Sparse edit | 100,262 [97,775 to 105,762] | 31,337 [31,229 to 35,708] |
| 3 | V1-1/V3-2 | Full redraw | 1,373,975 [1,325,862 to 1,474,416] | 56,316 [55,458 to 68,204] |

## Descriptive p95 Latency

The p95 uses the nearest-rank definition. The pooled value combines all 300
ordered batches for one workload and revision. Pooled batches are descriptive
only because they are repeated observations within three processes. The
process is the replication unit.

| Workload | V1 Process p95 Values | V1 Pooled p95 | V3 Process p95 Values | V3 Pooled p95 |
| --- | ---: | ---: | ---: | ---: |
| Dense colour | 2,983,166; 3,018,220; 2,994,237 | 3,010,054 ns | 168,495; 163,279; 170,845 | 168,495 ns |
| Plain scroll | 1,446,750; 1,423,591; 1,452,179 | 1,447,629 ns | 71,587; 70,587; 73,900 | 72,991 ns |
| Sparse edit | 101,716; 101,950; 101,425 | 101,841 ns | 32,325; 36,133; 34,712 | 34,975 ns |
| Full redraw | 1,380,416; 1,384,529; 1,335,612 | 1,378,733 ns | 72,666; 69,829; 69,225 | 72,279 ns |

![Descriptive pooled p95 latency for the four workloads][chart-2]

## Allocation Scaling

Counts include successful allocations and reallocations made by one encode.
Requested bytes sum allocator request sizes and do not measure retained memory
or resident set size.

| Cells | Geometry | V1 Operations / Bytes | V3 Operations / Bytes | Operation Reduction | Output Bytes / Hash |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1x1 | 16 / 574 | 5 / 248 | 68.750% | 93 / `807b6c9334132b0a` |
| 10 | 10x1 | 130 / 5,271 | 7 / 1,016 | 94.615% | 337 / `b9aee7c2e4342f1b` |
| 100 | 100x1 | 1,248 / 51,189 | 10 / 8,184 | 99.199% | 2,803 / `3e8b76ff15d7ce93` |
| 1,000 | 100x10 | 12,475 / 499,262 | 13 / 65,528 | 99.896% | 27,724 / `dfda67ccfd3a30eb` |
| 10,000 | 200x50 | 124,651 / 5,386,440 | 17 / 1,048,568 | 99.986% | 276,444 / `edfa0379543ed13d` |

![Allocation operations and requested bytes by cell count][chart-3]

## Virtual 800x600 Race

| Round | Position | Revision | Frames | Seconds | FPS |
| ---: | ---: | --- | ---: | ---: | ---: |
| 1 | 1 | V1 | 59 | 10.058310 | 5.866 |
| 1 | 2 | V3 | 1,186 | 10.007498 | 118.511 |
| 2 | 1 | V3 | 1,180 | 10.008534 | 117.899 |
| 2 | 2 | V1 | 72 | 10.112852 | 7.120 |

| Revision | Frames | Seconds | Aggregate FPS |
| --- | ---: | ---: | ---: |
| V1 | 131 | 20.171163 | 6.494 |
| V3 | 2,366 | 20.016032 | 118.205 |

V3 produced 18.20x the aggregate isolated encoder throughput. Every round
emitted 13,254,757 bytes per frame with hash `29e298525b420eb3`. This is an
extreme stress fixture, not a normal terminal frame rate.

![Virtual race throughput][chart-4]

## Equivalence and Supporting Checks

- All 10 comparable timing, allocation and race scopes matched in output byte
  count and FNV-1a hash.
- Render scaling showed no candidate regression.
- Correctness review reported no findings.
- Performance review reported no findings.
- One live-handoff test failed identically on V1 and V3 while 3,272 other tests
  passed. A full `just check` success is not claimed.

The [machine-readable summary][1] is the arithmetic authority. The [JSON][2]
and [TSV][3] ordered-batch files contain all 2,400 values.

[chart-1]: charts/01-median-current-master-latency.svg
[chart-2]: charts/02-p95-current-master-latency.svg
[chart-3]: charts/03-allocation-scaling.svg
[chart-4]: charts/04-race-throughput.svg
[1]: data/summary.json
[2]: data/ordered-batches.json
[3]: data/ordered-batches.tsv
