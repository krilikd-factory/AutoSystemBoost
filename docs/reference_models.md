# Reference Models

This directory holds explanatory models and review artefacts that are **not** executable tests of the AutoSystemBoost production implementation.

## `asb_allocator_reference_model.py`

This Python file models generic dynamic-array growth and integer-overflow checks. It does not import, compile, call, or parse any C source from `src/`; therefore, a green result from the model cannot prove the safety of the ASB governor or its session-history handling.

It is intentionally kept out of `tests/`, has no GitHub Actions dependency on `pytest`, and is not part of `tools/asb_full_regression.sh`. This avoids a misleading CI signal in which a reference implementation passes while a different production implementation is untested.

> A future production-quality replacement must be a host C harness that exercises the actual ASB session/history parser and allocation path with bounded fixture files, malformed inputs, growth boundaries, and overflow assertions.

The reference model may be used for design discussion only; it must not be cited as regression coverage for the module.
