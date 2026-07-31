# ---------------------------------------------------------------------------
# Orbit v2 Slice 0 isolated contract freeze
# ---------------------------------------------------------------------------

ruby --disable-gems "$SKILL_ROOT/tests/fixtures/orbit-v2/contract_test.rb" \
  >"$TMPROOT/orbit-v2-slice0-contract-tests.log"
if ! rg -q '^ORBIT_V2_CONTRACT_TESTS_PASS assertions=' "$TMPROOT/orbit-v2-slice0-contract-tests.log"; then
  printf 'FAIL Orbit v2 Slice 0 contract tests did not report completion\n' >&2
  exit 1
fi
pass 'Orbit v2 Slice 0 isolated contracts, authority, negative fixtures, and v1 inventory'
