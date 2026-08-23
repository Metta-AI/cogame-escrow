# Tuning the scripted `trader` baseline

The `trader` baseline is the no-credentials fallback, the certification opponent and a fieldable
policy, so its knobs are not free parameters to guess at. They are the argmax of a grid sweep,
re-run in CI on every push.

## The knobs

`src/escrow/llm.nim` `TraderParams`:

| knob | what it does |
|---|---|
| `tradeUnits` | units the baseline puts on the table in one contract (`min(tradeUnits, surplus)`) |
| `needFills` | copies of its own commission it reserves before it calls a good surplus |
| `housePrice` | the flat table it values a bundle with, deciding which offers it signs |

## The harness

`tools/tune_baseline.nim`. It plays whole all-scripted episodes through `escrow/sim` and
`escrow/llm` — `initSim` / `pendingSeats` / `scriptedAction` / `applyMove`, the same calls the
server's turn loop makes — so the sweep measures the shipped bot, not a model of it. Every
decision is put through `sim.validateMove` and every episode's event log is scanned for a
`reject`, so an illegal cell is disqualified before it can win. Each cell is scored over a fixed
seed set:

- `minted` — mean hearts minted by an all-trader table (the game's headline number)
- `ratio` — that against the all-hoarder (autarky) floor for the same seed; `tests/test_bot.nim`
  test 14 requires the shipped cell to clear **1.3x**
- `hearts` — mean free hearts per seat at the end
- `mixT` / `mixH` — a 3-trader/1-hoarder mix: a trader seat's mean hearts against the hoarder's.
  A cell that only pays when all four seats play it is not a good cell for a fielded policy.

Reproduce:

```
nim r --path:src tools/tune_baseline.nim                     # the recorded grid below
nim r --path:src tools/tune_baseline.nim --units=2..12 --fills=1..6 --price=3..3
nim r --path:src tools/tune_baseline.nim --quick --check     # what CI runs
```

`--check` exits non-zero unless the shipped `DefaultTraderParams` is still a best legal cell of
the grid and still clears 1.3x, so these numbers cannot rot silently.

## The grid (recorded run)

`nim r --hints:off -d:release --path:src tools/tune_baseline.nim --check`, Nim 2.2.4:

```
escrow trader sweep: seeds=@[1, 7, 42, 1234, 20260823] turns=16 units=@[2, 3, 4, 5, 6] fills=@[1, 2, 3] price=@[2, 3, 4]
autarky floor (hearts minted per seed): @[474, 474, 474, 474, 474]

price units fills |   minted   ratio  hearts  signed |  mixT   mixH | legal
------------------+---------------------------------+--------------+------
    2     2     1 |    654.0    1.38   183.5    38.0 | 152.4  132.8 | yes
    2     2     2 |    664.0    1.40   186.0    42.0 | 153.1  132.8 | yes
    2     2     3 |    714.0    1.51   198.5    48.0 | 156.4  132.8 | yes
    2     3     1 |    642.0    1.35   180.5    28.0 | 152.4  132.8 | yes
    2     3     2 |    552.0    1.16   158.0    32.0 | 146.4  132.8 | yes
    2     3     3 |    814.0    1.72   223.5    48.0 | 163.1  132.8 | yes
    2     4     1 |    714.0    1.51   198.5    26.0 | 156.4  132.8 | yes
    2     4     2 |    834.0    1.76   228.5    38.0 | 164.4  132.8 | yes
    2     4     3 |    594.0    1.25   168.5    14.0 | 148.4  132.8 | yes
    2     5     1 |    774.0    1.63   213.5    26.0 | 160.4  132.8 | yes
    2     5     2 |    774.0    1.63   213.5    26.0 | 160.4  132.8 | yes
    2     5     3 |    624.0    1.32   176.0    14.0 | 150.4  132.8 | yes
    2     6     1 |    834.0    1.76   228.5    24.0 | 164.4  132.8 | yes
    2     6     2 |    684.0    1.44   191.0    18.0 | 154.4  132.8 | yes
    2     6     3 |   1074.0    2.27   288.5    45.2 | 180.4  132.8 | yes
    3     2     1 |    654.0    1.38   183.5    38.0 | 152.4  132.8 | yes
    3     2     2 |    664.0    1.40   186.0    42.0 | 153.1  132.8 | yes
    3     2     3 |    714.0    1.51   198.5    48.0 | 156.4  132.8 | yes
    3     3     1 |    642.0    1.35   180.5    28.0 | 152.4  132.8 | yes
    3     3     2 |    552.0    1.16   158.0    32.0 | 146.4  132.8 | yes
    3     3     3 |    814.0    1.72   223.5    48.0 | 163.1  132.8 | yes
    3     4     1 |    714.0    1.51   198.5    26.0 | 156.4  132.8 | yes
    3     4     2 |    834.0    1.76   228.5    38.0 | 164.4  132.8 | yes
    3     4     3 |    594.0    1.25   168.5    14.0 | 148.4  132.8 | yes
    3     5     1 |    774.0    1.63   213.5    26.0 | 160.4  132.8 | yes
    3     5     2 |    774.0    1.63   213.5    26.0 | 160.4  132.8 | yes
    3     5     3 |    624.0    1.32   176.0    14.0 | 150.4  132.8 | yes
    3     6     1 |    834.0    1.76   228.5    24.0 | 164.4  132.8 | yes
    3     6     2 |    684.0    1.44   191.0    18.0 | 154.4  132.8 | yes
    3     6     3 |   1074.0    2.27   288.5    45.2 | 180.4  132.8 | yes
    4     2     1 |    654.0    1.38   183.5    38.0 | 152.4  132.8 | yes
    4     2     2 |    664.0    1.40   186.0    42.0 | 153.1  132.8 | yes
    4     2     3 |    714.0    1.51   198.5    48.0 | 156.4  132.8 | yes
    4     3     1 |    642.0    1.35   180.5    28.0 | 152.4  132.8 | yes
    4     3     2 |    552.0    1.16   158.0    32.0 | 146.4  132.8 | yes
    4     3     3 |    814.0    1.72   223.5    48.0 | 163.1  132.8 | yes
    4     4     1 |    714.0    1.51   198.5    26.0 | 156.4  132.8 | yes
    4     4     2 |    834.0    1.76   228.5    38.0 | 164.4  132.8 | yes
    4     4     3 |    594.0    1.25   168.5    14.0 | 148.4  132.8 | yes
    4     5     1 |    774.0    1.63   213.5    26.0 | 160.4  132.8 | yes
    4     5     2 |    774.0    1.63   213.5    26.0 | 160.4  132.8 | yes
    4     5     3 |    624.0    1.32   176.0    14.0 | 150.4  132.8 | yes
    4     6     1 |    834.0    1.76   228.5    24.0 | 164.4  132.8 | yes
    4     6     2 |    684.0    1.44   191.0    18.0 | 154.4  132.8 | yes
    4     6     3 |   1074.0    2.27   288.5    45.2 | 180.4  132.8 | yes

argmax: price=2 tradeUnits=6 needFills=3 -> 1074.0 hearts minted (2.27x the autarky floor), 288.5 free hearts per seat; in a 3-trader mix 180.4 hearts a trader against the hoarder's 132.8
price: every column is identical — a flat table values an equal-count swap at zero gain at any level, so this axis is degenerate under all-scripted play
cells: 45 swept, 45 legal, 3 tied at the top
shipped: price=3 tradeUnits=6 needFills=3
check: the shipped cell is still the grid's best legal cell
```

## Wider, to prove the argmax is not an edge

`--units=2..12 --fills=1..6 --price=3..3`:

```
escrow trader sweep: seeds=@[1, 7, 42, 1234, 20260823] turns=16 units=@[2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] fills=@[1, 2, 3, 4, 5, 6] price=@[3]
autarky floor (hearts minted per seed): @[474, 474, 474, 474, 474]

price units fills |   minted   ratio  hearts  signed |  mixT   mixH | legal
------------------+---------------------------------+--------------+------
    3     2     1 |    654.0    1.38   183.5    38.0 | 152.4  132.8 | yes
    3     2     2 |    664.0    1.40   186.0    42.0 | 153.1  132.8 | yes
    3     2     3 |    714.0    1.51   198.5    48.0 | 156.4  132.8 | yes
    3     2     4 |    714.0    1.51   198.5    48.0 | 156.4  132.8 | yes
    3     2     5 |    714.0    1.51   198.5    48.0 | 156.4  132.8 | yes
    3     2     6 |    714.0    1.51   198.5    48.0 | 156.4  132.8 | yes
    3     3     1 |    642.0    1.35   180.5    28.0 | 152.4  132.8 | yes
    3     3     2 |    552.0    1.16   158.0    32.0 | 146.4  132.8 | yes
    3     3     3 |    814.0    1.72   223.5    48.0 | 163.1  132.8 | yes
    3     3     4 |    814.0    1.72   223.5    48.0 | 163.1  132.8 | yes
    3     3     5 |    814.0    1.72   223.5    48.0 | 163.1  132.8 | yes
    3     3     6 |    814.0    1.72   223.5    48.0 | 163.1  132.8 | yes
    3     4     1 |    714.0    1.51   198.5    26.0 | 156.4  132.8 | yes
    3     4     2 |    834.0    1.76   228.5    38.0 | 164.4  132.8 | yes
    3     4     3 |    594.0    1.25   168.5    14.0 | 148.4  132.8 | yes
    3     4     4 |    914.0    1.93   248.5    48.0 | 169.7  132.8 | yes
    3     4     5 |    914.0    1.93   248.5    48.0 | 169.7  132.8 | yes
    3     4     6 |    914.0    1.93   248.5    48.0 | 169.7  132.8 | yes
    3     5     1 |    774.0    1.63   213.5    26.0 | 160.4  132.8 | yes
    3     5     2 |    774.0    1.63   213.5    26.0 | 160.4  132.8 | yes
    3     5     3 |    624.0    1.32   176.0    14.0 | 150.4  132.8 | yes
    3     5     4 |    624.0    1.32   176.0    14.0 | 150.4  132.8 | yes
    3     5     5 |   1004.0    2.12   271.0    48.0 | 175.7  132.8 | yes
    3     5     6 |   1004.0    2.12   271.0    48.0 | 175.7  132.8 | yes
    3     6     1 |    834.0    1.76   228.5    24.0 | 164.4  132.8 | yes
    3     6     2 |    684.0    1.44   191.0    18.0 | 154.4  132.8 | yes
    3     6     3 |   1074.0    2.27   288.5    45.2 | 180.4  132.8 | yes
    3     6     4 |    906.0    1.91   246.5    33.2 | 180.4  132.8 | yes
    3     6     5 |    906.0    1.91   246.5    33.2 | 180.4  132.8 | yes
    3     6     6 |   1074.0    2.27   288.5    46.0 | 180.4  132.8 | yes
    3     7     1 |    784.0    1.65   216.0    22.0 | 161.1  132.8 | yes
    3     7     2 |    732.0    1.54   203.0    18.8 | 168.4  132.8 | yes
    3     7     3 |    826.0    1.74   226.5    25.2 | 168.4  132.8 | yes
    3     7     4 |    952.0    2.01   258.0    35.2 | 170.4  132.8 | yes
    3     7     5 |   1008.0    2.13   272.0    42.4 | 175.7  132.8 | yes
    3     7     6 |    888.0    1.87   242.0    31.6 | 162.4  132.8 | yes
    3     8     1 |    828.0    1.75   227.0    23.2 | 163.7  132.8 | yes
    3     8     2 |    828.0    1.75   227.0    23.2 | 163.7  132.8 | yes
    3     8     3 |    754.0    1.59   208.5    18.0 | 159.1  132.8 | yes
    3     8     4 |    984.0    2.08   266.0    32.0 | 174.4  132.8 | yes
    3     8     5 |    954.0    2.01   258.5    32.0 | 172.4  132.8 | yes
    3     8     6 |    714.0    1.51   198.5    18.0 | 156.4  132.8 | yes
    3     9     1 |    824.0    1.74   226.0    21.2 | 162.4  132.8 | yes
    3     9     2 |    882.0    1.86   240.5    23.2 | 167.1  132.8 | yes
    3     9     3 |    664.0    1.40   186.0    14.0 | 153.1  132.8 | yes
    3     9     4 |    794.0    1.68   218.5    20.0 | 161.7  132.8 | yes
    3     9     5 |    994.0    2.10   268.5    34.0 | 175.1  132.8 | yes
    3     9     6 |    724.0    1.53   201.0    16.0 | 157.1  132.8 | yes
    3    10     1 |    786.0    1.66   216.5    16.8 | 160.4  132.8 | yes
    3    10     2 |    908.0    1.92   247.0    23.2 | 167.7  132.8 | yes
    3    10     3 |    774.0    1.63   213.5    17.6 | 153.7  132.8 | yes
    3    10     4 |    790.0    1.67   217.5    20.0 | 153.7  132.8 | yes
    3    10     5 |    864.0    1.82   236.0    26.8 | 170.4  132.8 | yes
    3    10     6 |    864.0    1.82   236.0    27.6 | 170.4  132.8 | yes
    3    11     1 |    824.0    1.74   226.0    18.0 | 163.7  132.8 | yes
    3    11     2 |    824.0    1.74   226.0    18.0 | 163.7  132.8 | yes
    3    11     3 |    936.0    1.97   254.0    23.2 | 170.4  132.8 | yes
    3    11     4 |    768.0    1.62   212.0    16.0 | 155.7  132.8 | yes
    3    11     5 |    838.0    1.77   229.5    21.2 | 169.7  132.8 | yes
    3    11     6 |    912.0    1.92   248.0    26.8 | 162.4  132.8 | yes
    3    12     1 |    816.0    1.72   224.0    16.4 | 162.4  132.8 | yes
    3    12     2 |    836.0    1.76   229.0    17.2 | 163.7  132.8 | yes
    3    12     3 |    948.0    2.00   257.0    23.2 | 170.4  132.8 | yes
    3    12     4 |    762.0    1.61   210.5    16.0 | 152.4  132.8 | yes
    3    12     5 |    726.0    1.53   201.5    14.4 | 152.4  132.8 | yes
    3    12     6 |    958.0    2.02   259.5    27.6 | 172.4  132.8 | yes

argmax: price=3 tradeUnits=6 needFills=3 -> 1074.0 hearts minted (2.27x the autarky floor), 288.5 free hearts per seat; in a 3-trader mix 180.4 hearts a trader against the hoarder's 132.8
cells: 66 swept, 66 legal, 2 tied at the top
shipped: price=3 tradeUnits=6 needFills=3
```

## What was chosen, and why

**`tradeUnits = 6`, `needFills = 3`, `housePrice = 3/3/3/1`.**

- 6/3 is the argmax of the recorded grid (1074 hearts minted a seed, **2.27x** the 474-heart
  autarky floor) and it is still the argmax of the wider 66-cell sweep, so the range's edge is
  not doing the work: 7..12 units and 4..6 fills are all worse or tied.
- It is also the best cell in the mixed field — 180.4 hearts for a trader seat against a
  hoarder's 132.8 — so the cell is not an artefact of everyone playing it.
- Every cell in both grids is legal (`validateMove` clean, no `reject` event, `liveContracts`
  never over `MaxLive`), so legality did not constrain the choice; the 1.3x canary does not bind
  either, at 2.27x.
- The previously shipped 4/2 was a guess and it is beaten: 834 minted, 1.76x, 164.4 mixed. It was
  replaced by this sweep.
- Why 6/3 wins, mechanically: reserving three commission fills instead of two keeps a seat from
  offering away stock it will want back, and a six-unit contract clears a whole turn of a
  specialist's 6-a-turn production in one swap, so the pair spends fewer turns re-posting. The
  cells around it are jagged (6/2 mints 684, 5/3 mints 624) because the bot only posts when both
  it and the addressee hold zero live contracts: a cell that mis-sizes the swap desynchronises
  the pairing for several turns.

### The price axis is degenerate, and the sweep says so

Every price column of the recorded grid is identical, and the harness prints that finding rather
than tie-breaking a choice it did not make. The reason is structural: a baseline contract is
always an equal-count swap of two goods, and a **flat** table values that at exactly zero gain
whatever the level, so no price in 2..4 changes a single decision in an all-scripted episode. The
table therefore stays at the value the design note gives it (3/3/3, hearts at 1): flat, so an
equal-count swap is exactly fair and an unequal one is obviously not, and hearts cheap enough
that score is never bought as an input. Where the level does bite is on a *model's* asymmetric
offer, which an all-scripted sweep cannot produce — that is the constraint that binds this knob,
and it is a judgement, not a measurement.
