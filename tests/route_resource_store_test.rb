# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../lib/orbit/route_resource_store"

# The route resource store and its per-call report. Every fact, price and usage
# figure here is a scripted fixture: no network, no credentials, no model call.
module RouteResourceStoreTest
  module_function

  ENTRY = File.expand_path("../scripts/orbit-route-resources", __dir__)

  def run
    @assertions = 0
    Dir.mktmpdir("orbit-route-resources-") do |tmp|
      @tmp = tmp
      test_import_is_validated_atomic_and_auditable
      test_unknown_effective_fact_is_archived_but_never_selected_or_priced
      test_selection_is_exact_newest_and_valid
      test_report_prices_attributed_calls_and_keeps_unknowns
      test_report_uses_actual_account_and_refuses_conflicting_context
      test_script_speaks_one_json_object
    end
    puts("ROUTE_RESOURCE_STORE_TEST_PASS assertions=#{@assertions}")
  end

  def project(name)
    root = File.join(@tmp, name)
    FileUtils.mkdir_p(root)
    root
  end

  def store(name = "store", **options)
    Orbit::RouteResourceStore.new(project_root: project(name), **options)
  end

  def route(model: "glm-5.2", reasoning: "unknown", billing_route: "direct_api")
    { "provider" => "zhipu", "model" => model, "reasoning" => reasoning, "billing_route" => billing_route }
  end

  def fact(route: route(), account_scope: "acct-1", plan: "payg", verified_at: "2026-09-28T00:00:00Z",
           valid_until: "2026-10-05T00:00:00Z", effective_from: "2026-08-01T00:00:00Z",
           reference: "https://example.test/pricing")
    { "schema_version" => Orbit::RouteResourceFacts::SCHEMA_VERSION, "scope" => "omp_route", "route" => route,
      "source" => { "kind" => "first_party_pricing", "detail" => "scripted price list",
                    "verifier" => "scripted fixture", "reference" => reference },
      "verification" => { "retrieved_at" => verified_at, "valid_until" => valid_until },
      "effective" => { "from" => effective_from, "until" => nil },
      "applicability" => { "account_scope" => account_scope, "plan" => plan, "conditions" => "scripted" },
      "currency" => "USD",
      "categories" => { "input" => { "unit" => "token", "price" => 0.6, "per" => 1_000_000 },
                        "output" => { "unit" => "token", "price" => 2.2, "per" => 1_000_000 } } }
  end

  def quota_fact(route:, account_scope: "acct-1", plan: "coding plan", unit: "weighted_request")
    { "schema_version" => Orbit::RouteResourceFacts::SCHEMA_VERSION, "scope" => "omp_route", "route" => route,
      "source" => { "kind" => "plan_document", "detail" => "scripted plan page",
                    "verifier" => "scripted fixture", "reference" => "https://example.test/plan" },
      "verification" => { "retrieved_at" => "2026-09-28T00:00:00Z", "valid_until" => "2026-10-05T00:00:00Z" },
      "effective" => { "from" => "2026-08-01T00:00:00Z", "until" => nil },
      "applicability" => { "account_scope" => account_scope, "plan" => plan, "conditions" => "scripted" },
      "currency" => nil, "categories" => {},
      "quota" => { "unit" => unit, "rules" => "scripted published plan rules", "plan" => plan, "reset" => "monthly" } }
  end

  def ledger(task_path)
    Orbit::ResourceCallLedger.new(task_path: task_path, task_id: File.basename(task_path),
                                  clock: -> { Time.utc(2026, 9, 29, 12) })
  end

  def task_dir(name = "task-1")
    path = File.join(@tmp, name)
    FileUtils.mkdir_p(path)
    path
  end

  def record_call(ledger, id, model:, usage:, status: "completed", usage_status: nil, reasoning: "unknown",
                  billing_route: "direct_api", started_at: "2026-09-29T11:00:00Z",
                  completed_at: "2026-09-29T11:05:00Z")
    ledger.record(call_id: id, role: "checker", phase: "reviewer", status: status, provider: "zhipu",
                  actual_model: model, reasoning: reasoning, billing_route: billing_route,
                  usage: usage, usage_status: usage_status, usage_source: "native_message",
                  started_at: started_at, completed_at: completed_at,
                  usage_units: (usage || {}).keys.to_h { |key| [key, "token"] })
  end

  def test_unknown_effective_fact_is_archived_but_never_selected_or_priced
    built = store("unknown-effective")
    unknown_effective = fact.merge("effective" => { "from" => nil, "until" => nil, "unknown" => true })
    assert_equal(1, built.import(unknown_effective)["count"], "a real reading with no publisher date is archived, not refused")
    listed = built.list.first
    assert_equal(true, listed.dig("effective", "unknown"), "list exposes the explicit unknown effective status")
    assert_equal(nil, listed.dig("effective", "from"), "no date is invented for the archived reading")
    check_time = Time.utc(2026, 9, 29, 12)
    assert_equal(nil, built.select(scope: "omp_route", route: route(), account_scope: "acct-1", plan: "payg", at: check_time),
                 "an unknown effective date selects nothing, even inside the verification window")

    known = fact(route: route(model: "glm-5.3"))
    built.import(known)
    assert(built.select(scope: "omp_route", route: route(model: "glm-5.3"), account_scope: "acct-1", plan: "payg",
                        at: check_time),
           "a different identity with a known effective date still selects: unknown-effective is not generalized")

    dir = task_dir("unknown-effective-task")
    record_call(ledger(dir), "call-1", model: "glm-5.2", usage: { "input" => 1000, "output" => 200 })
    report = built.report(task_path: dir, account_scope: "acct-1", plan: "payg")
    row = report.fetch("calls").first
    assert(row["cost"].nil? && row["estimate"].nil? && row["gap"].include?("no verified resource fact"),
           "the archived reading never prices the call: the row stays unknown with a named gap")
    assert_equal(0, report.dig("coverage", "calls_priced"), "an archived unknown-effective fact is not a priced call")
    assert_equal([], report["cash"], "no cash is summed from an unknown effective date")
  end

  def test_report_uses_actual_account_and_refuses_conflicting_context
    built = store("actual-account")
    built.import(fact(account_scope: "served-account", plan: nil))
    dir = task_dir("actual-account-task")
    ledger(dir).record(call_id: "served-call", role: "root", phase: "execute", status: "completed",
      provider: "zhipu", actual_model: "glm-5.2", reasoning: "unknown", billing_route: "direct_api",
      usage: { "input" => 1000, "output" => 200 }, usage_source: "native_message",
      account_scope: "served-account", credential_id: 7, account_id: "account-7",
      account_identity_source: "oauth_accounts_by_credential_id",
      started_at: "2026-09-29T11:00:00Z", completed_at: "2026-09-29T11:01:00Z")
    row = built.report(task_path: dir).fetch("calls").first
    assert(row["cost"] && row["account_scope"] == "served-account" && row["credential_id"] == 7,
           "the final call's actual account is consumed without a caller account map")
    conflicting = built.report(task_path: dir, account_scope: "preferred-account").fetch("calls").first
    assert(conflicting["cost"].nil? && conflicting["gap"].include?("conflicts") &&
           conflicting["account_scope"] == "served-account",
           "a preferred or stale caller account cannot overwrite the account that served the call")
  end

  def test_import_is_validated_atomic_and_auditable
    built = store
    result = built.import([fact, fact(route: route(model: "glm-4.9"), verified_at: "2026-09-27T00:00:00Z")])
    assert_equal(2, result["count"], "both scripted facts are stored")
    assert_equal(0o600, File.stat(built.path).mode & 0o777, "the store file is private")
    assert_equal(0o700, File.stat(File.dirname(built.path)).mode & 0o777, "the store directory is private")
    leftovers = Dir.children(File.dirname(built.path)) - [File.basename(built.path), "route-resources.lock"]
    assert_equal([], leftovers, "no temporary files remain")

    audit = built.read
    assert_equal(Orbit::RouteResourceStore::SCHEMA_VERSION, audit["schema_version"], "the raw document is auditable")
    assert_equal(2, audit["entries"].length, "read returns the stored facts")
    assert_equal(0.6, built.list.first.dig("categories", "input", "price"), "list returns the raw fact fields")

    again = built.import(fact)
    assert_equal(0, again["stored"].length, "re-importing the same reading stores nothing")
    assert_equal(1, again["kept_existing"].length, "the identical reading is kept")
    assert_equal(2, again["count"], "re-importing the same reading is idempotent")
    newer = built.import(fact(verified_at: "2026-09-29T00:00:00Z"))
    assert_equal(1, newer["stored"].length, "a later verification of the same identity is stored as its own snapshot")
    assert_equal(3, newer["count"], "each accepted reading stays auditable")

    plan_less = built.import(fact(route: route(model: "glm-5.3"), plan: nil))
    assert_equal(1, plan_less["stored"].length, "a schema-valid fact without a plan is stored, never over-rejected")

    before = File.read(built.path)
    assert_raises(Orbit::RouteResourceFacts::Error) do
      built.import(fact.merge("source" => { "kind" => "first_party_pricing", "detail" => "x" }))
    end
    assert_raises do
      built.import(fact(reference: "https://user:secret@example.test/pricing"))
    end
    amended = fact
    amended["categories"] = amended["categories"].merge("input" => { "unit" => "token", "price" => 9.9, "per" => 1_000_000 })
    assert_raises { built.import(amended) }
    assert_equal(before, File.read(built.path),
                 "a rejected import and a conflicting price at the same verification time leave the store untouched")

    tampered = JSON.parse(before)
    tampered["entries"].first["categories"] = { "input" => { "unit" => "token", "price" => "cheap", "per" => 1_000_000 } }
    File.write(built.path, JSON.generate(tampered))
    assert_raises { built.read }
    assert_raises { built.list }
    assert_raises { built.select(scope: "omp_route", route: route(), account_scope: "acct-1", plan: "payg") }
  end

  def test_selection_is_exact_newest_and_valid
    built = store("selection")
    built.import([fact(verified_at: "2026-09-20T00:00:00Z"),
                  fact(verified_at: "2026-09-28T00:00:00Z"),
                  fact(route: route(billing_route: "unknown")),
                  fact(route: route(reasoning: "default")),
                  fact(route: route(model: "glm-4.9")),
                  fact(verified_at: "2026-09-27T00:00:00Z", valid_until: "2026-09-29T00:00:00Z"),
                  fact(verified_at: "2026-09-29T00:00:00Z", valid_until: "2026-09-29T06:00:00Z"),
                  fact(account_scope: "acct-2"),
                  fact(route: route(model: "glm-5.3"), plan: nil)])
    at = Time.utc(2026, 9, 29, 12)
    selected = built.select(scope: "omp_route", route: route(), account_scope: "acct-1", plan: "payg", at: at)
    assert_equal("2026-09-28T00:00:00Z", selected.verification["retrieved_at"],
                 "the newest verified reading of the exact identity is selected")
    assert_equal(0.6, selected.categories.dig("input", "price"), "the selected fact is the real stored reading")

    assert_equal(nil, built.select(scope: "omp_route", route: route(reasoning: "high"), account_scope: "acct-1",
                                   plan: "payg", at: at),
                 "a reasoning variant with no stored fact is never borrowed from another variant")
    assert_equal(nil, built.select(scope: "omp_route", route: route(billing_route: "subscription_quota"),
                                   account_scope: "acct-1", plan: "payg", at: at),
                 "an unverified billing route is never matched by similarity")
    assert_equal(nil, built.select(scope: "omp_route", route: route(), account_scope: "acct-9", plan: "payg", at: at),
                 "another account scope is never assumed")
    assert_equal(nil, built.select(scope: "omp_route", route: route(), account_scope: "acct-1", plan: "payg",
                                   at: Time.utc(2026, 7, 1)),
                 "a call before the published effective date stays unpriced")
    assert_equal(nil, built.select(scope: "omp_route", route: route(), account_scope: nil, plan: "payg", at: at),
                 "an unstated account scope selects nothing instead of the newest fact")
    assert_equal(nil, built.select(scope: "omp_route", route: route(), account_scope: "unknown", plan: "payg", at: at),
                 "an explicitly unknown account scope selects nothing")
    assert_equal(nil, built.select(scope: "omp_route", route: route(), account_scope: "acct-1", plan: nil, at: at),
                 "an unstated plan never wildcard-matches a fact that declares one")
    assert_equal(nil, built.select(scope: "omp_route", route: route(), account_scope: "acct-1", plan: "unknown", at: at),
                 "an explicitly unknown plan selects nothing")
    plan_less = built.select(scope: "omp_route", route: route(model: "glm-5.3"), account_scope: "acct-1", plan: nil, at: at)
    assert_equal("glm-5.3", plan_less.route["model"], "a nil observation matches a plan-less general API price exactly")
    assert_equal(nil, built.select(scope: "omp_route", route: route(model: "glm-5.3"), account_scope: "acct-1",
                                   plan: "payg", at: at),
                 "a plan-less fact never stands in for another plan")
    shortly = built.select(scope: "omp_route", route: route(), account_scope: "acct-1", plan: "payg",
                           at: Time.utc(2026, 9, 29, 5))
    assert_equal("2026-09-29T00:00:00Z", shortly.verification["retrieved_at"],
                 "the newest reading is selected while its snapshot is still valid")
    assert_equal("2026-09-28T00:00:00Z",
                 built.select(scope: "omp_route", route: route(), account_scope: "acct-1", plan: "payg", at: at)
                      .verification["retrieved_at"],
                 "a lapsed newest snapshot is skipped in favour of the newest usable one")

    assert_equal([], built.list(source_kind: "plan_document"), "list filters by the exact source kind")
    assert_equal(9, built.read["entries"].length, "selection never rewrites the stored history")
  end

  def test_report_prices_attributed_calls_and_keeps_unknowns
    built = store("report")
    built.import([fact, quota_fact(route: route(model: "kimi-k3", billing_route: "subscription_quota"))])
    dir = task_dir
    calls = ledger(dir)
    record_call(calls, "call-priced", model: "glm-5.2", usage: { "input" => 1000, "output" => 200 })
    record_call(calls, "call-failed", model: "glm-5.2", usage: nil, status: "failed")
    record_call(calls, "call-gap-usage", model: "glm-5.2", usage: { "input" => 5 }, usage_status: "partial")
    record_call(calls, "call-unpriced-route", model: "glm-4.9", usage: { "input" => 10, "output" => 2 })
    record_call(calls, "call-quota", model: "kimi-k3", usage: { "input" => 10 },
                billing_route: "subscription_quota")
    record_call(calls, "call-no-start", model: "glm-5.2", usage: { "input" => 10, "output" => 1 },
                started_at: nil, completed_at: nil)

    report = built.report(task_path: dir, account_scope: "acct-1",
                          plan: { "zhipu/glm-5.2" => "payg", "zhipu/kimi-k3" => "coding plan" },
                          at: Time.utc(2026, 9, 29, 12))
    rows = report["calls"].to_h { |row| [row["call_id"], row] }
    assert_equal(6, rows.length, "every recorded call is reported, including failures and unknowns")
    assert_equal("USD", rows.dig("call-priced", "cost", "currency"), "the priced call keeps the fact's currency")
    assert_in_delta(0.00104, rows.dig("call-priced", "cost", "amount"),
                    "the priced call uses the stored fact's own unit price")
    assert_equal(1, report["cash"].length, "cash is grouped into one currency and account scope")
    assert_equal("USD", report["cash"].first["currency"], "cash keeps the fact's currency")
    assert_equal("acct-1", report["cash"].first["account_scope"], "cash keeps the observed account scope")
    assert_in_delta(0.00104, report["cash"].first["amount"], "cash sums only the priced calls")
    assert_equal(["call-priced"], report["cash"].first["calls"], "cash names the calls it covers")
    assert_equal("reported usage is unknown; a total is not claimed", rows.dig("call-failed", "gap"),
                 "a failed call keeps its own consumption gap")
    assert_equal("reported usage is partial; a total is not claimed", rows.dig("call-gap-usage", "gap"),
                 "partially reported usage is never priced")
    assert(rows.dig("call-unpriced-route", "gap").to_s.include?("no verified resource fact"),
           "a route without a stored fact stays unknown")
    assert_equal("weighted_request", rows.dig("call-quota", "quota", "unit"),
                 "a subscription call reports the plan's own unit")
    assert_equal(nil, rows.dig("call-quota", "quota", "consumption"),
                 "a subscription route never has a computed consumption")
    assert_equal(1, report["quota"].length, "quota is grouped by plan and unit")
    assert_equal(nil, report["quota"].first["consumption"], "quota is never converted to money")
    assert_equal(6, report.dig("coverage", "calls_total"), "coverage counts every call")
    assert_equal(6, report.dig("coverage", "calls_recorded"), "coverage is limited to the recorded calls")
    assert_equal(false, report.dig("coverage", "unknown"), "a report with recorded calls is not the empty case")
    assert_equal(1, report.dig("coverage", "calls_priced"), "coverage counts the priced calls")
    assert_equal(4, report.dig("coverage", "calls_unknown"), "coverage counts the unknown calls")
    assert_equal({ "completed" => 5, "failed" => 1 }, report.dig("coverage", "status_counts"),
                 "coverage states exactly which statuses were recorded")
    assert_equal(4, report["gaps"].length, "every unpriced call keeps an explicit gap")
    assert_equal(["call-failed", "call-gap-usage", "call-no-start", "call-unpriced-route"],
                 report["gaps"].map { |gap| gap["call_id"] }.sort,
                 "failed, timing-less, partially reported and unpriced calls are all reported as gaps")

    spanning = built
    spanning.import(fact(route: route(model: "glm-4.8"), verified_at: "2026-09-28T00:00:00Z",
                         valid_until: "2026-09-29T12:00:00Z"))
    crossing = task_dir("crossing-task")
    record_call(ledger(crossing), "call-crossing", model: "glm-4.8", usage: { "input" => 10, "output" => 1 },
                started_at: "2026-09-29T11:50:00Z", completed_at: "2026-09-29T12:10:00Z")
    crossing_report = spanning.report(task_path: crossing, account_scope: "acct-1", plan: "payg",
                                      at: Time.utc(2026, 9, 29, 13))
    assert(crossing_report["calls"].first["gap"].to_s.include?("spans beyond"),
           "a call whose end leaves the fact's verified window is not priced with one snapshot")

    queueless_plan = task_dir("quota-plan-task")
    spanning.import(quota_fact(route: route(model: "kimi-k3-lite", billing_route: "subscription_quota"), plan: nil))
    record_call(ledger(queueless_plan), "call-quota-planless", model: "kimi-k3-lite", usage: { "input" => 10 },
                billing_route: "subscription_quota")
    planless_report = spanning.report(task_path: queueless_plan, account_scope: "acct-1", plan: nil,
                                      at: Time.utc(2026, 9, 29, 13))
    assert(planless_report["calls"].first["gap"].to_s.include?("does not state its plan"),
           "a quota fact without a stated plan cannot authorize quota accounting")
    assert_equal(false, report.dig("unknown", "quota_consumption_computed"), "quota consumption is never invented")
    assert(field_names(report).none? { |name| name.match?(/budget|spend_limit|max_cost|hard_limit/i) },
           "no budget, spend limit or cost gate appears anywhere in the report")
    assert(report["note"].to_s.include?("no provider-reported SDK cost"),
           "a provider-reported SDK cost is never used as a price")

    assert_equal("the call has no recorded start time; a recording time never stands in for it",
                 rows.dig("call-no-start", "gap"),
                 "a call without a real start time is never priced from its recording time")

    unverified = built.report(task_path: dir, at: Time.utc(2026, 9, 29, 12))
    unverified_plan = built.report(task_path: dir, account_scope: "acct-1", at: Time.utc(2026, 9, 29, 12))
    assert_equal(0, unverified_plan.dig("coverage", "calls_priced"),
                 "an unobserved plan never picks a fact that declares one")
    assert(unverified_plan["calls"].select { |row| row["route_fact"].nil? }.length == 6,
           "without an observed plan no call selects a stored fact")
    assert_equal(0, unverified.dig("coverage", "calls_priced"),
                 "without an observed account scope nothing is priced")
    assert(unverified["calls"].all? { |row| row["cost"].nil? && row["quota"].nil? },
           "without an observed account scope nothing is priced or claimed as quota")
    assert_equal(5, unverified["calls"].count { |row| row["gap"].to_s.include?("account_scope_unverified") },
                 "every started call is refused for the unstated account scope instead of borrowing a fact's one")
    assert(unverified["calls"].all? { |row| row["route_fact"].nil? },
           "no fact is selected at all while the observed account scope is unstated")
    assert_equal([], unverified["quota"], "no quota group is reported without a verified account scope")

    unknown_plan = built.report(task_path: dir, account_scope: "acct-1", plan: "unknown",
                                at: Time.utc(2026, 9, 29, 12))
    assert_equal(0, unknown_plan.dig("coverage", "calls_priced"),
                 "an explicitly unknown plan never prices from the newest fact")
    assert_equal(5, unknown_plan["calls"].count { |row| row["gap"].to_s.include?("plan is explicitly unknown") },
                 "every started call is refused for the unknown plan instead of guessing one")
    assert(unknown_plan["calls"].all? { |row| row["route_fact"].nil? },
           "no fact is selected at all while the observed plan is explicitly unknown")

    empty = built.report(task_path: task_dir("empty-task"), account_scope: "acct-1", plan: "payg",
                         at: Time.utc(2026, 9, 29, 12))
    assert_equal(0, empty.dig("coverage", "calls_total"), "an empty ledger reports no calls")
    assert_equal(true, empty.dig("coverage", "unknown"), "an empty ledger states that nothing is known")
    assert_equal("recorded_calls_only", empty.dig("coverage", "scope"), "coverage is limited to recorded calls")
    assert_equal(false, empty.dig("unknown", "cost_complete"), "an empty report never claims complete cost")
    native_dir = task_dir("native-pending-task")
    record_call(ledger(native_dir), "settled-native-call", model: "glm-5.2", usage: { "input" => 10, "output" => 2 })
    assert_equal(true, built.report(task_path: native_dir, account_scope: "acct-1", plan: "payg").dig("unknown", "cost_complete"),
                 "fully reported attributed calls can be priced inside the recorded-only scope")
    File.write(File.join(native_dir, "native-model-calls.json"), JSON.generate(
      "schema_version" => "orbit-native-model-calls-v1", "task_id" => File.basename(native_dir),
      "calls" => { "pending-call" => { "finalized" => false } }, "gaps" => []))
    pending = built.report(task_path: native_dir, account_scope: "acct-1", plan: "payg")
    assert_equal(1, pending.dig("coverage", "native_observations", "pending_calls"), "an unresolved provider boundary stays visible")
    assert_equal(false, pending.dig("unknown", "cost_complete"), "pending calls prevent a complete-cost claim")
    File.write(File.join(native_dir, "native-model-calls.json"), "{corrupt")
    corrupt = built.report(task_path: native_dir, account_scope: "acct-1", plan: "payg")
    assert_equal(false, corrupt.dig("unknown", "cost_complete"), "corrupt invocation observations never become zero consumption")
    assert(!corrupt.dig("coverage", "native_observations", "gaps").empty?, "corruption remains explicit in the report")

    mixed_dir = task_dir("mixed-accounts-task")
    built.import(fact(route: route(model: "glm-4.9"), account_scope: "acct-2"))
    record_call(ledger(mixed_dir), "account-one", model: "glm-5.2", usage: { "input" => 10, "output" => 2 })
    record_call(ledger(mixed_dir), "account-two", model: "glm-4.9", usage: { "input" => 10, "output" => 2 })
    mixed = built.report(task_path: mixed_dir, account_scope: { "zhipu/glm-5.2" => "acct-1", "zhipu/glm-4.9" => "acct-2" }, plan: "payg")
    assert_equal(["acct-1", "acct-2"], mixed["cash"].map { |cash| cash["account_scope"] }.sort,
                 "mapped accounts remain separate currency/account subtotals")
    assert_equal([], empty["cash"], "an empty report claims no cash")
  end

  def test_script_speaks_one_json_object
    root = project("script")
    facts = JSON.generate("action" => "import", "project_root" => root, "facts" => [fact])
    out, err, status = run_script(facts)
    payload = JSON.parse(out)
    assert(status.success? && payload["ok"] == true && payload["stored"] == 1 && payload["count"] == 1,
           "import returns one JSON object and succeeds")
    assert_equal(1, out.lines.length, "stdout carries exactly one JSON object")
    assert_equal("", err, "the script writes nothing to stderr on success")

    out, _err, status = run_script(JSON.generate("action" => "list", "project_root" => root, "account_scope" => "acct-1"))
    payload = JSON.parse(out)
    assert(status.success? && payload["facts"].length == 1 && payload["facts"].first["scope"] == "omp_route",
           "list returns the raw stored facts")

    dir = task_dir("script-task")
    record_call(ledger(dir), "call-1", model: "glm-5.2", usage: { "input" => 1000, "output" => 200 })
    out, _err, status = run_script(JSON.generate("action" => "report", "project_root" => root, "task_path" => dir,
                                                "account_scope" => "acct-1", "plan" => "payg"))
    payload = JSON.parse(out)
    assert(status.success? && payload.dig("report", "cash").first["amount"] > 0,
           "report prices the real ledger through the store")

    out, _err, status = run_script(JSON.generate("action" => "report", "project_root" => root, "task_path" => dir,
                                                "account_scope" => "acct-1"))
    payload = JSON.parse(out)
    assert(status.success? && payload.dig("report", "coverage", "calls_priced") == 0 &&
           payload.dig("report", "unknown", "cost_complete") == false,
           "without an observed plan the script reports the same unknown instead of guessing one")

    out, _err, status = run_script(JSON.generate("action" => "delete", "project_root" => root))
    payload = JSON.parse(out)
    assert(!status.success? && payload["ok"] == false && payload["error"].include?("unknown action"),
           "an unsupported action fails closed with one JSON object")
  end

  def field_names(value, found = [])
    case value
    when Hash
      value.each { |key, entry| found << key.to_s; field_names(entry, found) }
    when Array
      value.each { |entry| field_names(entry, found) }
    end
    found.uniq
  end

  def run_script(stdin)
    Open3.capture3(RbConfig.ruby, "--disable-gems", ENTRY, stdin_data: stdin)
  end

  def assert(value, message)
    @assertions += 1
    raise("assertion failed: #{message}") unless value

    true
  end

  def assert_equal(expected, actual, message)
    assert(expected == actual, "#{message} (expected #{expected.inspect}, got #{actual.inspect})")
  end

  def assert_in_delta(expected, actual, message)
    assert(actual.is_a?(Numeric) && (actual - expected).abs < 1e-12,
           "#{message} (expected #{expected}, got #{actual.inspect})")
  end

  def assert_raises(error_class = Orbit::RouteResourceStore::Error)
    @assertions += 1
    begin
      yield
    rescue error_class
      return true
    end
    raise("assertion failed: expected #{error_class}")
  end
end

RouteResourceStoreTest.run
