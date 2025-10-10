# Usage

1. Update `Prover.toml` with the desired mission parameters.
2. Run `ct record test-programs/noir_galactic_diff/` to compile and execute the Noir program.
3. Inspect `recording.md` for captured trace IDs.

Flow overview:
```
main -> orchestrator::run_simulation
     -> modules::systems::shield_matrix::evaluate_matrix
     -> modules::telemetry::aggregator::collect_streams
```
