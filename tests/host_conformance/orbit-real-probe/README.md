# Real-model acceptance driver

Creates a `standard`-preset Root on `deepseek-account/deepseek-flash`, then drives
one task: start → declare → write hello.txt → check → finish/accept → complete.
The checker runs through the `dsh-sdk` backend in a separate isolated home.

Setup (credentials are copied read-only; never commit them):

```sh
node packages/orbit/scripts/derive-profile.mjs --home /tmp/orbit-real --profile orbit-app --template web
node packages/orbit/scripts/derive-profile.mjs --home /tmp/orbit-real-checker --profile orbit-checker --template sdk --checker
install -m 600 ~/.dsh/.credentials.yaml /tmp/orbit-real/.credentials.yaml
install -m 600 ~/.dsh/.credentials.yaml /tmp/orbit-real-checker/.credentials.yaml
DSH_HOME=/tmp/orbit-real dsh plugin --profile orbit-app add \
  @deepseek-ai/dsh-subagent-dsh-sdk@0.2.1-rc.2 @deepseek-ai/dsh-sdk-client@0.2.1-rc.2
# restore the Orbit bundle after pnpm install (it is not a profile dependency)
mkdir -p /tmp/orbit-real/profiles/orbit-app/node_modules/@zeen
cp -R packages/orbit /tmp/orbit-real/profiles/orbit-app/node_modules/@zeen/orbit
```

Then configure the app profile patch with `orbit-host` checker route and the
`subagent-dsh-sdk` insert (see the 2026-10-20 acceptance record), copy
`index.js` into the profile, and boot `dsh --profile orbit-app --no-open`.
Remove the copied `.credentials.yaml` files after the run.

This probe is not part of `npm test`: it spends real model quota and needs the
desktop account login.
