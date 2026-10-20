# @orbit/bundle

DSH profile bundle for Orbit's controlled sessions. The patch disables host
code execution and goal loops, pins approval to `never`, adds the controlled
permission preset, and inserts `@orbit/dsh-host`.

Install into a profile derived from a DSH template:

```sh
dsh --profile orbit-app --from-default-profile web
dsh plugin --profile orbit-app add /path/to/packages/bundle
# dsh plugin add does not edit the profile bundle list; add "@orbit/bundle" to
# dsh.profile.bundles in <DSH_HOME>/profiles/orbit-app/package.json.
DSH_HOME=... orbit-t0 --profile orbit-app
```

The checker profile additionally installs `profiles/orbit-checker.patch.yml` as
its own `cordis.patch.yml` (read-only sandbox). The bundle is not published yet;
the final single npm package and profile derivation land in phase D.
