# Code Quality gate

`quality.yml` runs on pull requests, pushes to `main`, merge-queue events and
manual dispatch. It does not use path filters. Existing Rust, shell, component
and WebUI job names remain unchanged.

## What is required

`CI infrastructure` runs the cache regression suite and the quality workflow's
own regressions without reusing successful test results. A pinned actionlint
version checks `quality.yml`'s Actions syntax and expressions. ShellCheck remains
in the dedicated shell job; actionlint is not replacing it.

The four existing quality jobs run only after this preflight passes. The final
**CI Quality Gate** job runs with `always()` and reports failure if any upstream
job fails, is cancelled, is skipped, or has a missing/unknown result. It has no
checkout, network dependency or write permission. Its `needs` list must contain
every other job; the regression suite checks that invariant.

To enforce this at merge time, a repository administrator must select
**CI Quality Gate** as a required status check in the branch protection rule or
ruleset. This workflow change does not change repository settings. Keep the
separate module build, validation, network and device-acceptance requirements;
this summary covers only jobs in `quality.yml`.

## Cache boundaries and diagnostics

Dependency/build caches and exact-result caches remain enabled for expensive
checks. Whole-repository source sanity, ShellCheck and the cache/CI regression
suites run every time. The previous `host` scope omitted WebUI, Rust, docs and
root `kam.sh`, so it was not a safe input boundary for those checks.

Each quality job has a timeout. Failed WebUI runs upload `webui/test-results/`
for seven days, including Playwright's existing failure screenshots and traces.
An installation failure may occur before these files exist; in that case the
job log remains the diagnostic source. No user device data is collected.

For a complete uncached recheck, manually run **Code Quality** with
`force_tests=true`. Locally, with the usual project toolchains installed:

```sh
python3 scripts/test-ci-test-cache.py
python3 scripts/test-ci-quality.py
CI_TEST_FORCE=1 bash scripts/quality-gate.sh all
```

The new gate tests execute its actual Python summary and shared shell entrypoint.
Temporary Git repositories and an explicit cache-hit stub reproduce the stale
success boundary; they do not require an Android device or run production
network commands. The shared release gate also runs these CI regressions.
