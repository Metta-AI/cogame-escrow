# Escrow training

`tools/export_posttrain.nim` records full matches with the shipped trader
teacher, hosted prompts, and production simulator. See that exporter for the
ten-game dataset command.

`tools/train_bridge.nim` exposes the same hosted prompts and a fixed 71-value
observation for numeric training. A choice selects the shipped hoarder or
trader policy. The trader also has two alternative trade sizes. All four
seats decide against the same turn state before the native simulator resolves
their moves. Terminal utilities are each seat's share of total hearts minus
one quarter, so they sum to zero. The post-training exporter supports the
game's unrestricted contract language; the numeric catalog covers baseline
selection and trade sizing.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/escrow-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/escrow-train-bridge
```

From a Metta checkout with the Coworld training stack installed, pass the
absolute bridge binary and manifest paths to `recipes.external.coworld.train`
for native PufferLib or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=4`. Both `standard` and `sprint` variants are supported.

Both variants completed 512 Metta RL timesteps. At epoch ten, evaluation
mean return was -0.036 for standard and -0.008 for sprint. Native PufferLib
CUDA completed 4,096 timesteps per variant and reloaded each checkpoint for
held-out evaluation (four episodes per seed). Standard scores were 238 and
266 for seeds 101 and 102; sprint scores were 123.5 and 114.5. These pilots
verify execution and checkpoint loading, not improved play.
