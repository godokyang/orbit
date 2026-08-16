# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "yaml"

require_relative "../../../lib/orbit/v2/canonical_json"
require_relative "../../../lib/orbit/v2/code_surface"
require_relative "../../../lib/orbit/v2/errors"
require_relative "../../../lib/orbit/v2/aggregate_outcome"
require_relative "../../../lib/orbit/v2/context_projection"
require_relative "../../../lib/orbit/v2/budget_projection"
require_relative "../../../lib/orbit/v2/integrity_audit"
require_relative "../../../lib/orbit/v2/relationship_view"
require_relative "../../../lib/orbit/v2/gate_strength"
require_relative "../../../lib/orbit/v2/active_root"
require_relative "../../../lib/orbit/v2/control_store"
require_relative "../../../lib/orbit/v2/immutable_store"
require_relative "../../../lib/orbit/v2/policy_store"
require_relative "../../../lib/orbit/v2/protocol_root"
require_relative "../../../lib/orbit/v2/task_store"
require_relative "../../../lib/orbit/v2/transaction_log"
require_relative "../../../lib/orbit/v2/policy_issuance"
require_relative "../../../lib/orbit/v2/rule_resolution"
require_relative "../../../lib/orbit/v2/schema_catalog"
require_relative "../../../lib/orbit/v2/task_authority"
require_relative "../../../lib/orbit/v2/validator"
require_relative "../../../lib/orbit/v2/work_authority"
require_relative "fixture_factory"
require_relative "schema_parity"

module OrbitV2ContractTest
  module_function

  ROOT = File.expand_path("../../..", __dir__)

  def run
    @assertions = 0
    valid_bundle = OrbitV2FixtureFactory.valid_bundle
    assert(validator.validate(valid_bundle).empty?, "valid fixture must pass")
    test_schema_catalog
    test_contract_files
    test_gate_strength_schema_parity
    test_canonical_json
    test_rule_resolution
    test_authority_verifier(valid_bundle)
    test_schema_parity(valid_bundle)
    test_invalid_fixtures
    test_slice2_control_increment1
    test_slice2_control_increment2
    test_slice2_control_increment3
    test_slice2_control_increment4
    test_slice1_retry_does_not_invalidate_dispatch
    test_authority_graph_regressions
    test_policy_issuance_and_stale_authority_regressions
    test_policy_assertion_pinning
    test_lifecycle_writer_and_chronology
    test_task_and_work_authority_and_gate_aggregation
    test_eighth_review_regressions
    test_evidence_reference_and_path_scope_regressions
    test_evidence_requirement_class_use_pairing
    test_rule_resolution_immutable_history_and_binding
    test_finding_typed_basis_and_disposition
    test_budget_assessment_consumer_closure
    test_aggregate_outcome_projection
    test_context_projection
    test_relationship_view
    test_budget_projection
    test_code_surface
    test_integrity_audit
    test_immutable_stores(valid_bundle)
    test_transaction_log_store
    test_transaction_log_concurrency_and_crash
    test_protocol_root_marker
    test_protocol_root_preflight
    test_policy_store_genesis
    test_policy_store_rotation
    test_policy_store_concurrent_rotation
    test_policy_store_lineage_fail_closed
    test_control_store_genesis
    test_control_store_conflicts
    test_control_store_concurrency
    test_control_store_checkpoint
    test_control_store_lineage_fail_closed
    test_task_store_genesis
    test_task_store_lineage_fail_closed
    test_task_store_cross_transaction
    test_task_store_concurrency
    test_v1_inventory
    test_slice_isolation
    puts(
      "ORBIT_V2_CONTRACT_TESTS_PASS assertions=#{@assertions} " \
        "schema_parity=#{@schema_parity_counts.sort.map { |key, value| "#{key}:#{value}" }.join(",")}"
    )
  end

  def test_schema_catalog
    expected = {
      "protocol_root" => "orbit-protocol-root-v1",
      "authority_assertion" => "orbit-authority-assertion-v1",
      "authorization_record" => "orbit-authorization-record-v1",
      "project_policy_revision" => "orbit-project-policy-v1",
      "task_revision" => "orbit-task-v2",
      "work_unit" => "orbit-work-unit-v1",
      "change_thesis" => "orbit-change-thesis-v1",
      "agent_instance" => "orbit-agent-runtime-v1",
      "logical_lead" => "orbit-agent-runtime-v1",
      "lead_session" => "orbit-agent-runtime-v1",
      "lead_control_registry" => "orbit-lead-control-registry-v1",
      "lead_checkpoint" => "orbit-lead-checkpoint-v1",
      "work_unit_attempt" => "orbit-agent-runtime-v1",
      "rule_resolution" => "orbit-rule-resolution-v2",
      "evidence_record" => "orbit-evidence-v2",
      "gate_requirement" => "orbit-gate-requirement-v1",
      "gate_evaluation" => "orbit-gate-evaluation-v1",
      "finding" => "orbit-finding-v1",
      "finding_resolution" => "orbit-finding-resolution-v1",
      "contract_bundle" => "orbit-v2-contract-bundle-v1"
    }
    assert(Orbit::V2::SchemaCatalog::SUPPORTED == expected, "schema dispatch must be exact")
    expect_contract_error("unsupported_schema_version") do
      Orbit::V2::SchemaCatalog.check!("task_revision", "schema_version" => "orbit-task-v1")
    end
  end

  def test_authority_verifier(valid_bundle)
    codes = Orbit::V2::Validator.new(project_root: ROOT).validate(valid_bundle).map(&:code)
    assert(
      codes.include?("authority_provider_unconfigured"),
      "authority validation fails closed without a configured provider"
    )
    assert(
      codes.include?("lifecycle_provider_unconfigured"),
      "lifecycle validation fails closed without a configured writer provider"
    )
    assert(
      codes.include?("runtime_identity_provider_unconfigured"),
      "runtime identity validation fails closed without a configured provider"
    )

    self_report = OrbitV2FixtureFactory.deep_copy(valid_bundle)
    assertion = self_report.fetch("authority_assertions").first
    assertion.fetch("verification_receipt")["receipt"] = "hmac-sha256:#{'0' * 64}"
    codes = validator.validate(self_report).map(&:code)
    assert(
      codes.include?("authority_receipt_invalid"),
      "structurally valid self-reported user authority is rejected"
    )
  end

  def test_schema_parity(valid_bundle)
    examples = OrbitV2SchemaParity.structural_examples(valid_bundle)
    examples.each_with_index do |example, index|
      assert(
        Orbit::V2::SchemaCatalog.structure_errors("contract_bundle", example).empty?,
        "schema parity seed #{index} must be structurally valid"
      )
    end
    parity_cases = OrbitV2SchemaParity.cases(examples)
    @schema_parity_counts = parity_cases.group_by { |item| item.fetch("category") }
                                        .transform_values(&:length)
    %w[required type enum const unknown_nested_field].each do |category|
      assert(@schema_parity_counts.fetch(category, 0).positive?, "schema parity covers #{category}")
    end
    parity_cases.each do |item|
      mutated = OrbitV2SchemaParity.mutate(item)
      errors = Orbit::V2::SchemaCatalog.structure_errors("contract_bundle", mutated)
      assert(
        errors.any?,
        "schema accepted #{item.fetch("category")} mutation at " \
          "#{OrbitV2SchemaParity.format_path(item.fetch("path"))}"
      )
    end

    nested_epoch = OrbitV2FixtureFactory.deep_copy(valid_bundle)
    nested_epoch.fetch("rule_resolution_artifacts").first.fetch("identity")["protocol_epoch"] =
      "orbit-v1"
    assert(
      Orbit::V2::SchemaCatalog.structure_errors("contract_bundle", nested_epoch)
        .any? { |error| error.code == "protocol_epoch_mismatch" },
      "nested RuleResolution epoch mixing is rejected"
    )

    nested_project = OrbitV2FixtureFactory.deep_copy(valid_bundle)
    artifact = nested_project.fetch("rule_resolution_artifacts").first
    identity = OrbitV2FixtureFactory.deep_copy(artifact.fetch("identity"))
    identity["project_id"] = "oproj_otherproject"
    rebuilt = Orbit::V2::RuleResolution.build(
      identity,
      created_at: artifact.dig("envelope", "created_at"),
      project_root: ROOT
    )
    rebuilt["project_id"] = OrbitV2FixtureFactory::PROJECT_ID
    nested_project["rule_resolution_artifacts"][0] = rebuilt
    assert(
      validator.validate(nested_project)
        .any? { |error| error.code == "rule_resolution_identity_mismatch" },
      "nested RuleResolution project mixing is rejected"
    )
  end

  def test_contract_files
    schema_paths = Dir.glob(File.join(ROOT, "contracts/orbit-v2/schemas/*.json")).sort
    expected_names = %w[
      agent-runtime.schema.json
      authority.schema.json
      common.schema.json
      contract-bundle.schema.json
      evidence.schema.json
      finding.schema.json
      gate.schema.json
      lead-control.schema.json
      protocol-root.schema.json
      rule-resolution.schema.json
      task-work.schema.json
    ]
    assert(schema_paths.map { |path| File.basename(path) } == expected_names, "schema file inventory changed")
    schema_paths.each do |path|
      schema = JSON.parse(File.read(path))
      assert(schema["$schema"] == "https://json-schema.org/draft/2020-12/schema", "#{path} draft")
      assert(schema["$id"].start_with?("https://orbit.local/contracts/orbit-v2/"), "#{path} stable ID")
      assert(deep_contains_closed_object?(schema), "#{path} must declare closed object contracts")
    end
    contract = YAML.safe_load(
      File.read(File.join(ROOT, "contracts/orbit-v2/contract.yaml")),
      aliases: false
    )
    assert(contract.dig("activation", "status") == "isolated_contract_only", "Slice 0 cannot activate v2")
    assert(contract.dig("activation", "v1_fallback_allowed") == false, "v1 fallback forbidden")
    assert(contract.dig("gate_evaluation", "verdict_owner") == "GateEvaluation", "single verdict owner")
    assert(contract.dig("rule_resolution", "hash_domain") == "canonical_identity_only", "hash domain")
    assert(
      contract.dig(
        "work_model",
        "WorkUnitAttempt",
        "lifecycle_event_union",
        "assignment_allowed_only_on"
      ) == "AttemptCreated",
      "Attempt assignment has one typed lifecycle owner"
    )
    assert(
      contract.dig(
        "gate_evaluation",
        "evaluator_gate_binding",
        "review",
        "capability"
      ) == "review.evaluate",
      "review gate freezes its AgentInstance capability"
    )
    assert(
      contract.dig(
        "work_model",
        "ChangeThesis",
        "work_unit_initial_ref"
      ) == "exact_revision_one_genesis",
      "ChangeThesis initial ref pins the unique revision-one genesis"
    )
    assert(
      contract.dig(
        "work_model",
        "GateRequirement",
        "stable_lineage_identity"
      ) == "gate_lineage_id",
      "GateRequirement has one stable lineage identity across per-revision records"
    )
    assert(
      contract.dig(
        "policy_lineage",
        "protected_task_change",
        "provider_signed_scope"
      ) == "canonical_protected_change_digest",
      "protected changes require provider-signed exact diff identity"
    )
    assert(
      contract.dig(
        "policy_lineage",
        "issuance_envelope",
        "candidate_byte_change_after_receipt"
      ) == "fail_closed",
      "policy issuance binds the exact candidate content digest"
    )
    assert(
      contract.dig(
        "policy_lineage",
        "rotation",
        "authority_source"
      ) == "unique_exact_parent_grant",
      "policy rotation authority comes from the exact parent"
    )
    assert(
      contract.dig(
        "policy_lineage",
        "task_closure",
        "caller_owned_closure_flag"
      ) == "forbidden",
      "closure eligibility is a derived projection"
    )
    assert(
      contract.dig(
        "immutability",
        "evidence_acceptance_time",
        "included_in_content_digest"
      ) == true,
      "stale-submission chronology is immutable evidence content"
    )
    assert(
      contract.dig(
        "work_model",
        "TaskRevision",
        "authority_grants",
        "allowed_actions"
      ) == Orbit::V2::TaskAuthority::ACTIONS,
      "task authority action enum has one contract owner"
    )
    assert(
      contract.dig(
        "work_model",
        "WorkUnit",
        "authorization_records",
        "stable_actions"
      ) == Orbit::V2::WorkAuthority::ACTIONS,
      "work authority action enum has one contract owner"
    )
    assert(
      contract.dig(
        "work_model",
        "WorkUnitAttempt",
        "assignment_agent_binding",
        "kind_purpose_mapping"
      ) == Orbit::V2::WorkAuthority::WORK_UNIT_PURPOSES,
      "WorkUnit kind and Attempt purpose mapping has one contract owner"
    )
    assert(
      contract.dig(
        "work_model",
        "AgentInstance",
        "runtime_identity",
        "uniqueness"
      ) == "one_verified_provider_subject_per_agent_instance_id",
      "AgentInstance IDs cannot alias one verified runtime subject"
    )
    assert(
      contract.dig(
        "evidence_record",
        "implementation_check",
        "scope_match"
      ) == "pass_with_evidence",
      "accepted implementation EvidenceRecord freezes complete scope proof"
    )
    task_schema = JSON.parse(
      File.read(File.join(ROOT, "contracts/orbit-v2/schemas/task-work.schema.json"))
    )
    assert(
      !task_schema.dig("$defs", "TaskRevision", "properties").key?("closure_eligible"),
      "TaskRevision schema contains no writable closure flag"
    )
    assert(
      contract.dig(
        "finding_resolution",
        "disproved",
        "gate_binding"
      ) == "exact_finding_gate_requirement_subject_evidence_level_and_independence",
      "FindingResolution binds the exact resolving gate evaluation"
    )
    assert(
      contract.dig(
        "finding_resolution",
        "lineage_refs",
        "supersedes_cycles"
      ) == "forbidden",
      "supersedes lineage cycles are forbidden"
    )

    matrix = YAML.safe_load(
      File.read(File.join(ROOT, "contracts/orbit-v2/authority-matrix.yaml")),
      aliases: false
    )
    facts = matrix.fetch("facts")
    assert(facts.map { |fact| fact.fetch("fact") }.uniq.length == facts.length, "authority facts unique")
    assert(facts.all? { |fact| !fact.fetch("authoritative_owner").to_s.empty? }, "every fact has one owner")
    verdict = facts.find { |fact| fact["fact"] == "evaluator_verdict_and_question_or_acceptance_answers" }
    assert(verdict["authoritative_owner"] == "GateEvaluation", "matrix verdict owner")
  end

  def test_gate_strength_schema_parity
    gate_schema = JSON.parse(
      File.read(File.join(ROOT, "contracts/orbit-v2/schemas/gate.schema.json"))
    )
    authority_schema = JSON.parse(
      File.read(File.join(ROOT, "contracts/orbit-v2/schemas/authority.schema.json"))
    )
    gate_properties = gate_schema.dig("$defs", "GateRequirement", "properties")
    minimum_properties = authority_schema.dig(
      "$defs",
      "ProjectPolicyRevision",
      "properties",
      "protected_gate_minimums",
      "items",
      "properties"
    )
    evidence_keys = Orbit::V2::GateStrength::EVIDENCE_LEVELS.keys
    independence_keys = Orbit::V2::GateStrength::INDEPENDENCE_LEVELS.keys
    assert(
      gate_properties.dig("evidence_level", "enum") == evidence_keys &&
        minimum_properties.dig("evidence_level", "enum") == evidence_keys,
      "GateStrength evidence ordering keys exactly equal every schema enum"
    )
    assert(
      gate_properties.dig("independence", "enum") == independence_keys &&
        minimum_properties.dig("independence", "enum") == independence_keys,
      "GateStrength independence ordering keys exactly equal every schema enum"
    )
  end

  def test_canonical_json
    assert(
      Orbit::V2::CanonicalJSON.dump("b" => 1, "a" => 2) == "{\"a\":2,\"b\":1}",
      "canonical object key ordering"
    )
    composed = "\u00e9"
    decomposed = "e\u0301"
    assert(
      Orbit::V2::CanonicalJSON.dump("value" => composed) ==
        Orbit::V2::CanonicalJSON.dump("value" => decomposed),
      "canonical strings use NFC"
    )
    begin
      Orbit::V2::CanonicalJSON.dump("not_allowed" => 1.25)
      raise "floating point canonicalization unexpectedly passed"
    rescue ArgumentError => error
      assert(error.message.include?("floating-point"), "floats fail closed")
    end
    begin
      Orbit::V2::CanonicalJSON.dump("too_large" => 9_007_199_254_740_992)
      raise "non-interoperable integer unexpectedly passed"
    rescue ArgumentError => error
      assert(error.message.include?("signed 53-bit"), "non-interoperable integers fail closed")
    end
    begin
      Orbit::V2::CanonicalJSON.dump(composed => 1, decomposed => 2)
      raise "NFC key collision unexpectedly passed"
    rescue ArgumentError => error
      assert(error.message.include?("collide"), "NFC key collisions fail closed")
    end
  end

  def test_rule_resolution
    bundle = OrbitV2FixtureFactory.valid_bundle
    artifact = bundle.fetch("rule_resolution_artifacts").first
    identity = OrbitV2FixtureFactory.deep_copy(artifact.fetch("identity"))
    repeated = Orbit::V2::RuleResolution.build(
      identity,
      created_at: "2099-01-01T00:00:00Z",
      project_root: ROOT
    )
    assert(repeated["resolution_id"] == artifact["resolution_id"], "envelope time excluded from identity")
    assert(repeated["identity_sha256"] == artifact["identity_sha256"], "repeat digest deterministic")
    assert(
      Orbit::V2::CanonicalJSON.dump(repeated["identity"]) ==
        Orbit::V2::CanonicalJSON.dump(artifact["identity"]),
      "assigned/submitted identity bytes deterministic"
    )
    semantic_change = OrbitV2FixtureFactory.deep_copy(identity)
    semantic_change["required_rules"][0]["relation"] = "overrides"
    changed = Orbit::V2::RuleResolution.build(
      semantic_change,
      created_at: "2026-07-30T00:00:00Z",
      project_root: ROOT
    )
    assert(changed["resolution_id"] != artifact["resolution_id"], "semantic rule changes alter ID")
    invalid_path = OrbitV2FixtureFactory.deep_copy(identity)
    invalid_path["required_rules"][0]["path"] = "../rules/coding.md"
    expect_contract_error("rule_resolution_path") do
      Orbit::V2::RuleResolution.build(
        invalid_path,
        created_at: "2026-07-30T00:00:00Z",
        project_root: ROOT
      )
    end
    test_rule_symlink_alias(identity)
  end

  def test_invalid_fixtures
    manifest = YAML.safe_load(
      File.read(File.join(__dir__, "invalid-cases.yaml")),
      aliases: false
    )
    manifest.fetch("cases").each do |definition|
      bundle = mutate(definition.fetch("id"), OrbitV2FixtureFactory.valid_bundle)
      codes = validator.validate(bundle).map(&:code)
      assert(
        codes.include?(definition.fetch("expected_error")),
        "#{definition.fetch("id")} expected #{definition.fetch("expected_error")}, got #{codes.uniq.sort.join(",")}"
      )
    end
  end

  def test_slice2_control_increment1
    bundle = OrbitV2FixtureFactory.valid_bundle
    assert(validator.validate(bundle).empty?, "increment 1 happy path: genesis and linear successor pass")

    duplicate = OrbitV2FixtureFactory.deep_copy(bundle)
    second = OrbitV2FixtureFactory.deep_copy(duplicate.fetch("lead_checkpoints").first)
    second["lead_checkpoint_id"] = "olcheckpoint_secondgenesis"
    duplicate.fetch("lead_checkpoints") << OrbitV2FixtureFactory.digested(second)
    codes = validator.validate(duplicate).map(&:code)
    assert(codes.include?("control_genesis_duplicate"), "duplicate genesis fails closed")

    unverified = OrbitV2FixtureFactory.deep_copy(bundle)
    unverified.fetch("lead_sessions").first["lead_runtime_subject_assertion_digest"] = "sha256:#{'0' * 64}"
    codes = validator.validate(unverified).map(&:code)
    assert(codes.include?("lead_session_invalid"), "provider subject assertion must stay exact")

    forged_writer = OrbitV2FixtureFactory.deep_copy(bundle)
    forged_writer.fetch("control_registries").first.dig("writer_authority_provenance", "assertion_ref")["assertion_id"] = "oassert_selfreported"
    codes = validator.validate(forged_writer).map(&:code)
    assert(
      codes.include?("control_writer_authority_invalid"),
      "genesis writer authority must come from a provider-verified assertion"
    )

    dup_queue = OrbitV2FixtureFactory.deep_copy(bundle)
    add_task_successor(dup_queue)
    registry, task2 = dup_queue.fetch("control_registries").first, dup_queue.fetch("task_revisions").last
    registry.fetch("owned_task_refs") << { "task_id" => task2["task_id"], "task_revision_id" => task2["task_revision_id"], "content_digest" => task2["content_digest"] }
    codes = validator.validate(dup_queue).map(&:code)
    assert(codes.include?("control_task_ownership_invalid"), "queue refs are unique per task identity")

    late_context = OrbitV2FixtureFactory.deep_copy(bundle)
    session = late_context.fetch("lead_sessions").first
    session["session_generation"] = 2
    session.dig("lifecycle_events", 0)["context_generation"] = 2
    OrbitV2FixtureFactory.resign_event(session.dig("lifecycle_events", 0))
    agent = late_context.fetch("agent_instances").find { |candidate| candidate["agent_instance_id"] == session["agent_instance_id"] }
    agent.fetch("lifecycle_events") << OrbitV2FixtureFactory.event(
      "oevent_leadlatecontext", "AgentContextAdvanced",
      agent.dig("lifecycle_events", 0, "event_digest"),
      "context_generation" => 2, "recorded_at" => "2026-07-30T01:00:00Z", "reason" => "Late generation probe"
    )
    agent.fetch("lifecycle_events").last["previous_event_digest"] = agent.dig("lifecycle_events", 0, "event_digest")
    OrbitV2FixtureFactory.resign_event(agent.fetch("lifecycle_events").last)
    codes = validator.validate(late_context).map(&:code)
    assert(codes.include?("lead_session_invalid"), "late exact generation context fails closed")

    fork = OrbitV2FixtureFactory.deep_copy(bundle)
    forked = OrbitV2FixtureFactory.deep_copy(fork.fetch("lead_checkpoints").last)
    forked["lead_checkpoint_id"] = "olcheckpoint_forkedlineage"
    fork.fetch("lead_checkpoints") << OrbitV2FixtureFactory.digested(forked)
    codes = validator.validate(fork).map(&:code)
    assert(codes.include?("checkpoint_lineage_invalid"), "lineage fork / multiple tip fails closed")

    pin_mismatch = OrbitV2FixtureFactory.deep_copy(bundle)
    genesis = pin_mismatch.fetch("lead_checkpoints").first
    genesis["lead_runtime_subject_ref"] = "runtime-subject:foreign"
    pin_mismatch.fetch("lead_checkpoints")[0] = OrbitV2FixtureFactory.digested(genesis)
    codes = validator.validate(pin_mismatch).map(&:code)
    assert(codes.include?("checkpoint_pin_invalid"), "checkpoint subject pin mismatch fails closed")

    policy_mismatch = OrbitV2FixtureFactory.deep_copy(bundle)
    add_policy_successor(policy_mismatch)
    tip = policy_mismatch.fetch("lead_checkpoints").last
    genesis_policy = policy_mismatch.fetch("project_policy_revisions").first
    tip["project_policy_revision_ref"] = { "policy_revision_id" => genesis_policy["policy_revision_id"], "content_digest" => genesis_policy["content_digest"] }
    checkpoints = policy_mismatch.fetch("lead_checkpoints")
    checkpoints[checkpoints.index(tip)] = OrbitV2FixtureFactory.digested(tip)
    codes = validator.validate(policy_mismatch).map(&:code)
    assert(codes.include?("checkpoint_pin_invalid"), "lineage tip must pin the exact active policy")
  end

  def test_slice2_control_increment2
    bundle = OrbitV2FixtureFactory.valid_bundle
    tip = bundle.fetch("lead_checkpoints").last
    facts = {
      "bundle" => bundle,
      "lead_control_id" => OrbitV2FixtureFactory::CONTROL_ID,
      "lead_checkpoint_ref" => {
        "lead_checkpoint_id" => tip["lead_checkpoint_id"],
        "content_digest" => tip["content_digest"]
      }
    }
    recovery = Orbit::V2::LeadControl.reconcile(facts, "recovery")
    replay = Orbit::V2::LeadControl.reconcile(facts, "recovery")
    assert(
      recovery == replay,
      "recovery is idempotent"
    )

    forged = OrbitV2FixtureFactory.deep_copy(bundle)
    forged_tip = forged.fetch("lead_checkpoints").last
    forged_tip["lead_decision"] = {
      "state" => "blocked", "action" => "continue", "reason" => "self-reported"
    }
    checkpoints = forged.fetch("lead_checkpoints")
    checkpoints[checkpoints.index(forged_tip)] = OrbitV2FixtureFactory.digested(forged_tip)
    codes = validator.validate(forged).map(&:code)
    assert(
      codes.include?("checkpoint_decision_replay_invalid"),
      "forged lead_decision fails closed"
    )
  end

  # Increment 4: anomaly/fuse/budget machinery completing Slice 2. Focused
  # hand-written scenarios for the high-risk public seams (LeadControl.reconcile
  # and the accepted-checkpoint validator); structural missing/type/null/unknown
  # permutations stay with schema parity.
  def test_slice2_control_increment4
    reconcile_of = lambda do |bundle, checkpoint|
      {
        "bundle" => bundle,
        "lead_control_id" => OrbitV2FixtureFactory::CONTROL_ID,
        "lead_checkpoint_ref" => OrbitV2FixtureFactory.cp_ref(checkpoint)
      }
    end

    # 1. Retry fuse happy path: two same-fingerprint failures are recorded
    #    with separate supporting provenance and an ordered prior chain; the
    #    second-failure checkpoint stops at needs_user; the provider-verified
    #    task.retry.override (authorized against the second-failure
    #    checkpoint, consumed by the later dispatch checkpoint) resumes the
    #    third dispatch on authority_change.
    bundle = OrbitV2FixtureFactory.retry_fuse_bundle(override: true)
    assert(validator.validate(bundle).empty?, "retry override authorizes the third same-fingerprint dispatch")

    # 2. Without the override the third same-fingerprint dispatch is
    #    needs_user (never frozen, never an automatic continue); a forged
    #    dispatch decision on the needs_user checkpoint fails decision
    #    replay.
    bundle = OrbitV2FixtureFactory.retry_fuse_bundle(override: false)
    assert(validator.validate(bundle).empty?, "needs_user second-failure checkpoint is accepted")
    second_failure = bundle["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_fuseterminal_two"
    end
    decision = Orbit::V2::LeadControl.reconcile(reconcile_of.call(bundle, second_failure), "attempt_terminal")
    assert(decision["state"] == "needs_user", "third same-fingerprint without override is needs_user")
    forged = OrbitV2FixtureFactory.deep_copy(bundle)
    forged_cp = forged["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_fuseterminal_two"
    end
    forged_cp["lead_decision"] = {
      "state" => "blocked", "action" => "dispatch", "reason" => "self-reported"
    }
    forged_cp["next_trigger"] = {
      "event" => "attempt_created", "reason" => "Self-reported continuation."
    }
    forged["lead_checkpoints"][forged["lead_checkpoints"].index(forged_cp)] =
      OrbitV2FixtureFactory.digested(forged_cp)
    codes = validator.validate(forged).map(&:code)
    assert(
      codes.include?("checkpoint_decision_replay_invalid"),
      "forged third dispatch without user authority fails replay"
    )
    recovery = Orbit::V2::LeadControl.reconcile(reconcile_of.call(bundle, second_failure), "recovery")
    assert(
      recovery == decision,
      "recovery re-runs the needs_user pipeline and never thaws it"
    )

    # HIGH 4: a retry override issued under a policy that is not the exact
    # active policy of the consuming checkpoint (rotation/revocation) fails
    # closed at consumption.
    stale_policy = OrbitV2FixtureFactory.retry_fuse_bundle(override: true)
    stale_record = stale_policy["authorization_records"].find do |candidate|
      candidate["authorization_record_id"] == "oauthz_retryoverride"
    end
    stale_record["project_policy_revision_id"] = "opolicy_revokedpolicy"
    stale_policy["authorization_records"][stale_policy["authorization_records"].index(stale_record)] =
      OrbitV2FixtureFactory.digested(stale_record)
    assert(
      validator.validate(stale_policy).any? { |error| error.code == "checkpoint_retry_override_invalid" },
      "a retry override from a non-active policy fails closed at consumption"
    )

    # 3. Fingerprint identity/provenance fail-closed: a non-recomputable
    #    fingerprint, a prior-chain gap, a fingerprint recorded without a
    #    failure, and a failure recorded without any fingerprint are all
    #    rejected; the same stable identity in a different Attempt/outcome
    #    record must never be treated as a new failure.
    bundle = OrbitV2FixtureFactory.retry_fuse_bundle(override: false, forged_fingerprint: "sha256:#{'0' * 64}")
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_fingerprint_invalid" },
      "non-recomputable fingerprint fails closed"
    )
    bundle = OrbitV2FixtureFactory.retry_fuse_bundle(override: false, gap_chain: true)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_fingerprint_invalid" },
      "prior chain gap fails closed"
    )
    bundle = OrbitV2FixtureFactory.retry_fuse_bundle(override: false, fingerprint_without_failure: true)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_fingerprint_invalid" },
      "fingerprint without a failure pin fails closed"
    )
    bundle = OrbitV2FixtureFactory.retry_fuse_bundle(override: false, omit_fingerprint: true)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_fingerprint_invalid" },
      "failed round without provable fingerprint fails closed"
    )
    # A real failure signal with agent-changed strings must fail: the
    # fingerprint basis must byte-equal the trusted terminal failure signal
    # recorded on the AttemptFailed event itself.
    bundle = OrbitV2FixtureFactory.retry_fuse_bundle(override: false)
    forged_signal_cp = bundle["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_fuseterminal_two"
    end
    forged_signal_cp["fingerprint_identity_basis"]["stable_signal_identity"] = {
      "test_or_check_id" => "agent-invented-test",
      "signal_subject_id" => "agent-invented-subject",
      "normalized_failure_code" => "agent-invented-code"
    }
    forged_signal_cp["fingerprint"] =
      Orbit::V2::ControlAuthority.fingerprint_digest(forged_signal_cp["fingerprint_identity_basis"])
    bundle["lead_checkpoints"][bundle["lead_checkpoints"].index(forged_signal_cp)] =
      OrbitV2FixtureFactory.digested(forged_signal_cp)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_fingerprint_invalid" },
      "an agent-invented stable signal string fails closed"
    )
    # An intermediate checkpoint re-pinning the same failure event with the
    # same fingerprint counts the occurrence exactly once (dedupe by exact
    # terminal event identity), so the second-failure chain stays [first].
    bundle = OrbitV2FixtureFactory.retry_fuse_bundle(override: false, intermediate_repin: true)
    assert(
      validator.validate(bundle).empty?,
      "re-pinned historical failure events are counted once per occurrence"
    )
    # A provider-written terminal failure event is immutable; the trusted
    # failure_signal is its only fingerprint anchor, so it must be REQUIRED
    # on AttemptFailed/AttemptBlocked. A correctly signed terminal failure
    # without the signal (even unobserved by any checkpoint) fails closed at
    # the schema.
    bundle = OrbitV2FixtureFactory.valid_bundle
    review = bundle["work_unit_attempts"].find do |candidate|
      candidate["attempt_id"] == "oattempt_independentreview"
    end
    review["events"] << OrbitV2FixtureFactory.event(
      "oevent_signallessfailure",
      "AttemptFailed",
      review.dig("events", 0, "event_digest"),
      "ended_at" => "2026-07-30T02:00:00Z",
      "status" => "failed"
    )
    assert(
      validator.validate(bundle).any? { |error| error.code == "contract_shape_invalid" },
      "a signed terminal failure without the trusted failure_signal is rejected"
    )

    # The compound bypass: mutate ONLY basis.failure_code to a new agent
    # value, recompute the fingerprint, clear the prior chain, drop the
    # override ref, and use a legal successor_before trigger; the trusted
    # terminal failure_signal stays byte-equal to stable_signal_identity.
    # The failure_code binding must reject the minted fingerprint.
    bundle = OrbitV2FixtureFactory.retry_fuse_bundle(override: true)
    third = bundle["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_fusethird_dispatch"
    end
    index = bundle["lead_checkpoints"].index(third)
    forged = OrbitV2FixtureFactory.deep_copy(third)
    forged["fingerprint_identity_basis"]["failure_code"] = "agent-invented-code"
    forged["fingerprint"] =
      Orbit::V2::ControlAuthority.fingerprint_digest(forged["fingerprint_identity_basis"])
    forged["fingerprint_supporting_provenance"]["prior_attempt_chain"] = []
    forged.delete("retry_override_ref")
    forged["reconcile_trigger"] = {
      "event" => "successor_before", "reason" => "Legal successor boundary."
    }
    forged = OrbitV2FixtureFactory.digested(forged)
    bundle["lead_checkpoints"][index] = forged
    observation = bundle["lead_checkpoints"][index + 1]
    observation["predecessor_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(forged)
    %w[delivery_progress assurance_progress].each do |field|
      observation[field]["predecessor_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(forged)
    end
    fusethree = bundle["work_unit_attempts"].find do |candidate|
      candidate["attempt_id"] == "oattempt_fuseattemptthree"
    end
    resolution = bundle["rule_resolution_artifacts"].find do |candidate|
      candidate["resolution_id"] ==
        fusethree.dig("events", 0, "assignment", "assigned_rule_resolution_id")
    end
    bundle["lead_checkpoints"][index + 1] = OrbitV2FixtureFactory.reseal_checkpoint(
      observation,
      policy: bundle["project_policy_revisions"].first,
      predecessor_checkpoint: forged,
      attempt: fusethree,
      resolution: resolution
    )
    fusethree["dispatch_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(forged)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_fingerprint_invalid" },
      "mutating only the fingerprint failure_code cannot mint a new fingerprint for the same real failure"
    )

    # 4. Wall-clock fallback: only the exact active policy (or a
    #    policy-authorized record) may pin the finite fallback, the timer is
    #    scheduled only as checkpoint_due, and checkpoint_due can only be
    #    produced by the exact scheduled lineage predecessor.
    bundle = OrbitV2FixtureFactory.fallback_bundle
    assert(validator.validate(bundle).empty?, "scheduled fallback and timer round are accepted")
    bundle = OrbitV2FixtureFactory.fallback_bundle(bad_fallback: true)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_fallback_invalid" },
      "unresolvable fallback authorization record fails closed"
    )
    bundle = OrbitV2FixtureFactory.fallback_bundle(missing_schedule: true)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_trigger_invalid" },
      "checkpoint_due without an exact scheduled predecessor fails closed"
    )
    bundle = OrbitV2FixtureFactory.fallback_bundle(unpinned_policy: true)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_fallback_invalid" },
      "fallback pinned to a stale policy digest fails closed"
    )
    bundle = OrbitV2FixtureFactory.fallback_bundle(deadline_drift: true)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_fallback_invalid" },
      "a self-reported or drifted deadline fails closed (deadline must derive from the trusted basis plus the exact interval)"
    )
    bundle = OrbitV2FixtureFactory.fallback_bundle(early_due: true)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_trigger_invalid" },
      "a checkpoint_due observation recorded before the scheduled deadline fails closed"
    )
    bundle = OrbitV2FixtureFactory.fallback_bundle(unrelated_basis: true)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_fallback_invalid" },
      "a schedule basis event not yet pinned by the schedule checkpoint or a strict lineage ancestor fails closed"
    )
    bundle = OrbitV2FixtureFactory.fallback_bundle
    due = bundle["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_fallbackdue"
    end
    review = bundle["work_unit_attempts"].find { |c| c["attempt_id"] == "oattempt_independentreview" }
    terminal = review["events"].last
    due["checkpoint_due_observation_ref"] = {
      "kind" => "attempt_event",
      "id" => review["attempt_id"],
      "event_id" => terminal["event_id"],
      "digest" => terminal["event_digest"]
    }
    bundle["lead_checkpoints"][bundle["lead_checkpoints"].index(due)] =
      OrbitV2FixtureFactory.digested(due)
    assert(
      !validator.validate(bundle).empty?,
      "an ordinary lifecycle event can never act as the timer due receipt"
    )

    # 5. Verified budget overrun: mechanical overrun is derived ONLY from
    #    verified measurements; over the effective ceiling without an
    #    override it is needs_user, and the override raises the ceiling that
    #    is then enforced mechanically.
    bundle = OrbitV2FixtureFactory.budget_override_bundle(mode: :overrun)
    dispatch = bundle["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone"
    end
    decision = Orbit::V2::LeadControl.reconcile(reconcile_of.call(bundle, dispatch), "attempt_terminal")
    assert(decision["state"] == "needs_user", "verified overrun without override is needs_user")
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_decision_replay_invalid" },
      "a stored dispatch decision on a verified overrun fails replay"
    )
    bundle = OrbitV2FixtureFactory.budget_override_bundle(mode: :override)
    assert(validator.validate(bundle).empty?, "consumed override keeps the verified usage within the raised ceiling")
    # Usage tamper: the attestation binds the exact usage; a self-reported
    # numeric change diverges from the attested scope and fails closed.
    tampered = OrbitV2FixtureFactory.deep_copy(bundle)
    tampered_dispatch = tampered["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone"
    end
    tampered_dispatch["effective_budget_bindings"][0]["measurements"]["test_count"]["usage"] = 13
    tampered["lead_checkpoints"][tampered["lead_checkpoints"].index(tampered_dispatch)] =
      OrbitV2FixtureFactory.digested(tampered_dispatch)
    assert(
      validator.validate(tampered).any? { |error| error.code == "checkpoint_budget_invalid" },
      "a usage tampered away from the attested scope fails closed"
    )
    bundle = OrbitV2FixtureFactory.budget_override_bundle(mode: :override, usage_count: 25, usage_lines: 700)
    decision = Orbit::V2::LeadControl.reconcile(
      reconcile_of.call(bundle, bundle["lead_checkpoints"].find { |c| c["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone" }),
      "attempt_terminal"
    )
    assert(decision["state"] == "needs_user", "usage over even the override ceiling stays needs_user")

    # 6. test.budget.override consume|inherit: a record is consumed by
    #    exactly one origin checkpoint; later checkpoints inherit only along
    #    the continuous accepted lineage; a second consume and a skipped
    #    origin fail closed.
    bundle = OrbitV2FixtureFactory.budget_override_bundle(mode: :second_consume)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_budget_invalid" },
      "a second consume of the same override record fails closed"
    )
    bundle = OrbitV2FixtureFactory.budget_override_bundle(mode: :inherit)
    assert(validator.validate(bundle).empty?, "override inheritance along the continuous lineage is accepted")
    bundle = OrbitV2FixtureFactory.budget_override_bundle(mode: :inherit_gap)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_budget_invalid" },
      "override inherit skipping the origin fails closed"
    )

    # The task_lineage override binds the canonical null WorkUnit ref; it is
    # constructible and never implies a relaxed WorkUnit-lineage binding
    # (the two layers derive independently).
    bundle = OrbitV2FixtureFactory.budget_override_bundle(
      mode: :override, scope: "task_lineage", usage_count: 8, usage_lines: 200
    )
    assert(validator.validate(bundle).empty?, "task_lineage override with canonical null WorkUnit ref is accepted")
    task_dispatch = bundle["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone"
    end
    wu_binding = task_dispatch["effective_budget_bindings"].first
    assert(
      wu_binding["source_kind"] == "policy_default" &&
        wu_binding["effective_test_count"] == 10,
      "a task_lineage override never relaxes the work_unit_lineage binding"
    )
    # Cross-scope replay: the work_unit binding consuming the task_lineage
    # record fails closed.
    bundle = OrbitV2FixtureFactory.budget_override_bundle(mode: :second_consume, scope: "task_lineage")
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_budget_invalid" },
      "a work_unit binding replaying the task_lineage override fails closed"
    )
    # A typed AuthorizationRecord action must carry exactly its own envelope:
    # a budget override record with an extra retry envelope fails closed.
    bundle = OrbitV2FixtureFactory.budget_override_bundle(mode: :override)
    record = bundle["authorization_records"].find do |candidate|
      candidate["authorization_record_id"] == "oauthz_budgetoverride"
    end
    record["retry_override_envelope"] = {
      "scope_digest" => "sha256:#{'d' * 64}",
      "project_id" => OrbitV2FixtureFactory::PROJECT_ID,
      "task_ref" => record.dig("budget_override_envelope", "task_ref"),
      "work_unit_ref" => record.dig("budget_override_envelope", "work_unit_ref"),
      "fingerprint" => "sha256:#{'e' * 64}",
      "prior_attempt_chain" => [],
      "authorizing_checkpoint_ref" => record.dig("budget_override_envelope", "authorizing_checkpoint_ref"),
      "lead_control_id" => OrbitV2FixtureFactory::CONTROL_ID
    }
    bundle["authorization_records"][bundle["authorization_records"].index(record)] =
      OrbitV2FixtureFactory.digested(record)
    assert(
      !validator.validate(bundle).empty?,
      "a typed action record with an extra typed envelope fails closed"
    )

    # 7. In-ceiling test.budget.adjust: the typed payload canonicalizes to
    #    budget_adjustment_digest (no checkpoint self-reference, no
    #    measurement tuple) and the derived binding carries the absolute
    #    requested ceilings; above the lead ceiling, a forged digest, and an
    #    absent-adjustment fake digest fail closed.
    bundle = OrbitV2FixtureFactory.adjustment_bundle
    assert(validator.validate(bundle).empty?, "in-ceiling lead adjustment is accepted inside the delegation envelope")
    bundle = OrbitV2FixtureFactory.adjustment_bundle(mode: :over_ceiling)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_budget_invalid" },
      "adjustment above the policy lead ceiling fails closed"
    )
    bundle = OrbitV2FixtureFactory.adjustment_bundle(mode: :forged_digest)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_budget_invalid" },
      "budget_adjustment_digest must match the typed payload"
    )
    bundle = OrbitV2FixtureFactory.adjustment_bundle(mode: :absent_digest)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_budget_invalid" },
      "an adjustment digest without any payload is explicitly absent, never forged"
    )
    # Slice 2 phase boundary: default dispatch may proceed unverified/pending,
    # but a lead_adjustment may never rest on unverified numbers — the
    # adjusted scope must carry provider-attested verified measurements.
    bundle = OrbitV2FixtureFactory.adjustment_bundle(mode: :unverified_adjust)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_budget_invalid" },
      "a pending (unverified) budget adjustment fails closed in Slice 2"
    )

    # 8. Measurement canonical shape: unverified measurements require
    #    canonical nulls plus the typed pending assessment; pending cannot
    #    carry a review ref and accepted/rejected depend on the Slice 4
    #    independent budget assessment consumer (fail closed in Slice 2).
    pending_assessment = OrbitV2FixtureFactory.unverified_pending_measurements.fetch("test_count")
      .fetch("unverified_assessment")
    unverified_with_usage = {
      "test_count" => {
        "status" => "unverified", "usage" => 5, "source_ref" => nil,
        "unverified_assessment" => pending_assessment
      },
      "test_code_lines" => {
        "status" => "unverified", "usage" => nil, "source_ref" => nil,
        "unverified_assessment" => pending_assessment
      }
    }
    pending_with_ref = OrbitV2FixtureFactory.deep_copy(pending_assessment)
    pending_with_ref["review_gate_evaluation_ref"] = {
      "gate_evaluation_id" => "ogeval_slice0review",
      "content_digest" => OrbitV2FixtureFactory.digest_for("review")
    }
    unverified_with_ref = OrbitV2FixtureFactory.deep_copy(unverified_with_usage)
    unverified_with_ref["test_count"]["usage"] = nil
    unverified_with_ref["test_count"]["unverified_assessment"] = pending_with_ref
    accepted = OrbitV2FixtureFactory.deep_copy(pending_assessment)
    accepted["lead_disposition"] = "proceed_after_independent_review"
    accepted["review_status"] = "accepted"
    accepted["review_gate_evaluation_ref"] = {
      "gate_evaluation_id" => "ogeval_slice0review",
      "content_digest" => OrbitV2FixtureFactory.digest_for("review")
    }
    unverified_accepted = OrbitV2FixtureFactory.deep_copy(unverified_with_usage)
    unverified_accepted["test_count"]["usage"] = nil
    unverified_accepted["test_count"]["unverified_assessment"] = accepted
    [
      [unverified_with_usage, "unverified measurement with a numeric usage"],
      [unverified_with_ref, "pending review carrying a review ref"],
      [unverified_accepted, "Slice 4 accepted review state"]
    ].each do |measurements, label|
      bundle = OrbitV2FixtureFactory.budget_override_bundle(mode: :overrun)
      dispatch = bundle["lead_checkpoints"].find do |candidate|
        candidate["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone"
      end
      index = bundle["lead_checkpoints"].index(dispatch)
      resealed = OrbitV2FixtureFactory.reseal_checkpoint(
        dispatch,
        policy: bundle["project_policy_revisions"].first,
        predecessor_checkpoint: bundle["lead_checkpoints"][index - 1],
        measurements: measurements
      )
      bundle["lead_checkpoints"][index] = resealed
      assert(
        validator.validate(bundle).any? { |error| error.code == "checkpoint_budget_invalid" },
        "#{label} fails closed"
      )
    end

    # Measurement scope replay: a task_lineage metric referencing the
    # work_unit_lineage attestation diverges from its canonical null WorkUnit
    # scope and fails closed.
    bundle = OrbitV2FixtureFactory.budget_override_bundle(mode: :overrun)
    dispatch = bundle["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone"
    end
    dispatch["effective_budget_bindings"][1]["measurements"]["test_count"]["source_ref"] = {
      "kind" => "measurement_attestation",
      "id" => "oassert_measurement_work_unit_lineage_test_count",
      "digest" => bundle["authority_assertions"].find do |candidate|
        candidate["assertion_id"] == "oassert_measurement_work_unit_lineage_test_count"
      end["assertion_digest"]
    }
    bundle["lead_checkpoints"][bundle["lead_checkpoints"].index(dispatch)] =
      OrbitV2FixtureFactory.digested(dispatch)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_budget_invalid" },
      "a task_lineage metric replaying the work_unit attestation fails closed"
    )

    # 9. One-way digest chain: every stored plan/closure digest must be
    #    recomputable byte-identical from the ordered bindings and frozen
    #    dispatch-time refs; binding order is canonical.
    %i[plan_digest basis_digest].each do |mutation|
      bundle = OrbitV2FixtureFactory.digest_chain_mutation_bundle(mutation)
      assert(
        validator.validate(bundle).any? { |error| error.code == "checkpoint_digest_invalid" },
        "#{mutation} mutation fails closed"
      )
    end
    bundle = OrbitV2FixtureFactory.digest_chain_mutation_bundle(:binding_order)
    assert(
      validator.validate(bundle).any? { |error| error.code == "checkpoint_budget_invalid" },
      "binding order mutation fails closed"
    )
  end

  # Increment 3: cross-lineage closure and exact release/acquire + executor
  # transfer provenance, one minimal two-lineage fixture with small mutations.
  # Structural permutations stay with schema parity; different projects are
  # independent by construction (one bundle pins one project).
  def test_slice2_control_increment3
    secondary = lambda do |bundle, control_id, agent: nil, session_id: "oleadsession_slice0secondary", predecessor: nil, started_at: "2026-07-30T00:00:00Z"|
      writer = OrbitV2FixtureFactory.assertion(
        "oassert_controlwriter2",
        %w[control.genesis control.checkpoint],
        "control-plane-writer",
        authority_scope_ref: control_id
      )
      bundle["authority_assertions"] << writer
      task2 = OrbitV2FixtureFactory.extra_task(
        bundle,
        task_id: "otask_slice0secondary",
        revision_id: "trev_slice0secondary_r1",
        gate_id: "ogreq_slice0secondary",
        gate_lineage_id: "ogline_slice0secondary"
      )
      bundle["agent_instances"] << agent if agent
      OrbitV2FixtureFactory.second_lineage(
        bundle,
        control_id: control_id,
        writer_assertion: writer,
        agent: agent || bundle["agent_instances"].first,
        task: task2["task"],
        logical_lead_id: "olead_slice0secondary",
        session_id: session_id,
        predecessor_session_ref: predecessor,
        started_at: started_at
      )
    end

    # 1. Disjoint task sets and active canonical runtime subjects parallel.
    bundle = OrbitV2FixtureFactory.valid_bundle
    secondary.call(bundle, "olcontrol_slice0secondary",
      agent: OrbitV2FixtureFactory.agent("oagent_secondarylead", "lead"))
    assert(validator.validate(bundle).empty?, "disjoint two-lineage parallelism is accepted")

    # 2. Overlap mutations: duplicate task ownership and one canonical subject
    #    backing two active LeadSessions both fail closed (AgentInstance
    #    aliases are already covered by the runtime_identity_duplicate matrix).
    bundle = OrbitV2FixtureFactory.valid_bundle
    secondary.call(bundle, "olcontrol_slice0secondary",
      agent: OrbitV2FixtureFactory.agent("oagent_secondarylead", "lead"))
    main_task = bundle["task_revisions"].first
    genesis2 = bundle["lead_checkpoints"].find { |c| c["lead_control_id"] == "olcontrol_slice0secondary" }
    genesis2["task_queue"] = [OrbitV2FixtureFactory.task_ref(main_task)]
    bundle["lead_checkpoints"][bundle["lead_checkpoints"].index(genesis2)] =
      OrbitV2FixtureFactory.digested(genesis2)
    registry2 = bundle["control_registries"].find { |c| c["lead_control_id"] == "olcontrol_slice0secondary" }
    registry2["owned_task_refs"] = [OrbitV2FixtureFactory.task_ref(main_task)]
    registry2["genesis_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(genesis2)
    bundle["control_registries"][bundle["control_registries"].index(registry2)] =
      OrbitV2FixtureFactory.digested(registry2)
    codes = validator.validate(bundle).map(&:code)
    assert(codes.include?("control_task_ownership_conflict"), "overlapping tip task sets fail closed")
    bundle = OrbitV2FixtureFactory.valid_bundle
    secondary.call(bundle, "olcontrol_slice0secondary")
    codes = validator.validate(bundle).map(&:code)
    assert(
      codes.include?("runtime_subject_active_conflict") &&
        codes.include?("session_binding_invalid"),
      "one canonical subject cannot bind two active LeadSessions across controls"
    )

    rehash_tail = lambda do |bundle, checkpoint|
      start = bundle["lead_checkpoints"].index(checkpoint)
      bundle["lead_checkpoints"][start] = OrbitV2FixtureFactory.digested(checkpoint)
      control = checkpoint["lead_control_id"]
      (start + 1...bundle["lead_checkpoints"].length).each do |index|
        candidate = bundle["lead_checkpoints"][index]
        break unless candidate["lead_control_id"] == control

        candidate["predecessor_lead_checkpoint_ref"] =
          OrbitV2FixtureFactory.cp_ref(bundle["lead_checkpoints"][index - 1])
        %w[delivery_progress assurance_progress].each do |field|
          candidate[field]["predecessor_lead_checkpoint_ref"] =
            candidate["predecessor_lead_checkpoint_ref"]
        end
        bundle["lead_checkpoints"][index] = OrbitV2FixtureFactory.digested(candidate)
      end
    end
    acquire_of = lambda do |bundle|
      bundle["lead_checkpoints"].find do |c|
        c["lead_control_id"] == OrbitV2FixtureFactory::TRANSFER_CONTROL_ID &&
          c.dig("lead_decision", "action") == "acquire"
      end
    end

    # 3. Valid task transfer: release checkpoint first, then acquire with the
    #    exact old checkpoint ref, old/new control IDs, and Task refs; the new
    #    lineage continues the work through a cross-control successor Attempt.
    bundle = OrbitV2FixtureFactory.transfer_bundle
    assert(validator.validate(bundle).empty?, "release then acquire with exact provenance is accepted")

    # 4. Invalid transfer table on the same fixture: missing release, wrong
    #    released control, a future acquire after the dispatch checkpoint, and
    #    a non-terminal release all fail closed; none of the forged or
    #    reordered acquires can authorize the cross-control successor.
    bundle = OrbitV2FixtureFactory.transfer_bundle
    acquire_of.call(bundle)["task_transfer_acquire"]["released_checkpoint_ref"] = {
      "lead_checkpoint_id" => "olcheckpoint_absentrelease",
      "content_digest" => "sha256:#{'0' * 64}"
    }
    rehash_tail.call(bundle, acquire_of.call(bundle))
    codes = validator.validate(bundle).map(&:code)
    assert(
      codes.include?("task_transfer_invalid") &&
        codes.include?("attempt_successor_invalid"),
      "an unresolvable acquire payload fails closed and never authorizes"
    )
    bundle = OrbitV2FixtureFactory.transfer_bundle
    acquire_of.call(bundle)["task_transfer_acquire"]["released_lead_control_id"] =
      "olcontrol_wronglineage"
    rehash_tail.call(bundle, acquire_of.call(bundle))
    codes = validator.validate(bundle).map(&:code)
    assert(
      codes.include?("task_transfer_invalid") &&
        codes.include?("attempt_successor_invalid"),
      "wrong released control revokes the transfer and the cross-control successor"
    )
    bundle = OrbitV2FixtureFactory.transfer_bundle
    checkpoints = bundle["lead_checkpoints"]
    acquire = acquire_of.call(bundle)
    dispatch = checkpoints.find { |c| c["lead_checkpoint_id"] == "olcheckpoint_transferdispatch_b" }
    genesis_b = checkpoints.find do |c|
      c["lead_checkpoint_id"] == "olcheckpoint_genesis_slice0transfertarget"
    end
    checkpoints << checkpoints.delete_at(checkpoints.index(acquire))
    dispatch["predecessor_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(genesis_b)
    rehash_tail.call(bundle, dispatch)
    bundle["work_unit_attempts"].find do |c|
      c["attempt_id"] == "oattempt_slice0transfersuccessor"
    end["dispatch_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(
      checkpoints.find { |c| c["lead_checkpoint_id"] == "olcheckpoint_transferdispatch_b" }
    )
    codes = validator.validate(bundle).map(&:code)
    assert(
      codes.include?("attempt_successor_invalid"),
      "a future acquire after the dispatch checkpoint never authorizes a past cross-control Attempt"
    )
    bundle = OrbitV2FixtureFactory.transfer_bundle(terminalize_review: false)
    codes = validator.validate(bundle).map(&:code)
    assert(codes.include?("task_transfer_invalid"), "release with a non-terminal Attempt fails closed")

    # 5. Valid executor transfer: old session terminal/release precedes the
    #    new session successor/bind with exact cross-control provenance.
    executor_base = lambda do |predecessor_event|
      bundle = OrbitV2FixtureFactory.valid_bundle
      # The old lineage's active session moves to a different subject, so the
      # transferred subject is not active in the old lineage.
      replacement_agent = OrbitV2FixtureFactory.agent("oagent_successorreplacement", "lead")
      replacement_agent["lifecycle_events"] << OrbitV2FixtureFactory.event(
        "oevent_successorreplacementcontext",
        "AgentContextAdvanced",
        replacement_agent.dig("lifecycle_events", 0, "event_digest"),
        "context_generation" => 2,
        "recorded_at" => "2026-07-30T00:05:30Z",
        "reason" => "Successor session context."
      )
      bundle["agent_instances"] << replacement_agent
      successor = bundle["lead_sessions"].find { |c| c["lead_session_id"] == "oleadsession_successor" }
      successor["agent_instance_id"] = replacement_agent["agent_instance_id"]
      successor["lead_runtime_subject_ref"] =
        replacement_agent.dig("runtime_identity", "runtime_subject_id")
      successor["lead_runtime_subject_assertion_digest"] =
        OrbitV2FixtureFactory.digest_for(
          replacement_agent.dig("runtime_identity", "verification_receipt_ref")
        )
      tip = bundle["lead_checkpoints"].last
      tip["lead_agent_instance_ref"] = { "agent_instance_id" => replacement_agent["agent_instance_id"] }
      tip["lead_runtime_subject_ref"] = successor["lead_runtime_subject_ref"]
      tip["lead_runtime_subject_assertion_digest"] = successor["lead_runtime_subject_assertion_digest"]
      bundle["lead_checkpoints"][-1] = OrbitV2FixtureFactory.digested(tip)
      old_session = bundle["lead_sessions"].find { |c| c["lead_session_id"] == "oleadsession_slice0contract" }
      secondary.call(
        bundle,
        "olcontrol_slice0executor",
        session_id: "oleadsession_slice0executor",
        predecessor: {
          "lead_session_id" => old_session["lead_session_id"],
          "session_generation" => old_session["session_generation"],
          "event_id" => predecessor_event["event_id"],
          "event_digest" => predecessor_event["event_digest"]
        },
        started_at: "2026-07-30T00:06:01Z"
      )
      bundle
    end
    old_session = OrbitV2FixtureFactory.valid_bundle["lead_sessions"].find do |c|
      c["lead_session_id"] == "oleadsession_slice0contract"
    end
    bundle = executor_base.call(old_session["lifecycle_events"].last)
    assert(validator.validate(bundle).empty?, "controlled executor transfer with terminal/release provenance is accepted")

    # 6. Early/mismatched executor bind: the successor pins a non-terminal
    #    event of the old session.
    bundle = executor_base.call(old_session["lifecycle_events"].first)
    codes = validator.validate(bundle).map(&:code)
    assert(codes.include?("session_binding_invalid"), "executor bind before terminal/release fails closed")
  end

  def test_slice1_retry_does_not_invalidate_dispatch
    bundle = OrbitV2FixtureFactory.valid_bundle
    review = bundle.fetch("work_unit_attempts").find { |c| c["attempt_id"] == "oattempt_independentreview" }
    review["events"] << OrbitV2FixtureFactory.event("oevent_reviewterminalretryprobe", "AttemptCompleted",
      review.fetch("events").last.fetch("event_digest"), "ended_at" => "2026-07-30T00:03:30Z", "status" => "completed")
    bundle.fetch("work_unit_attempts") << retry_attempt_for(
      bundle,
      "oattempt_implementationoneretry2",
      "oattempt_implementationonesuccessor",
      "2026-07-30T00:04:00Z",
      "2026-07-30T00:04:30Z"
    )
    assert(
      validator.validate(bundle).empty?,
      "a dependency retry after a legal dispatch does not retroactively invalidate it"
    )
  end

  def retry_attempt_for(bundle, attempt_id, predecessor_ref, started_at, ended_at)
    predecessor = bundle["work_unit_attempts"].find { |c| c["attempt_id"] == predecessor_ref }
    base_rule = bundle["rule_resolution_artifacts"].find do |candidate|
      candidate.dig("identity", "attempt_id") == predecessor_ref
    end
    identity = OrbitV2FixtureFactory.deep_copy(base_rule.fetch("identity"))
    identity["attempt_id"] = attempt_id
    rule = Orbit::V2::RuleResolution.build(identity, created_at: started_at, project_root: ROOT)
    thesis = bundle["change_theses"].find { |c| c["work_unit_id"] == predecessor["work_unit_id"] }
    unit = bundle["work_units"].find { |c| c["work_unit_id"] == predecessor["work_unit_id"] }
    bundle["rule_resolution_artifacts"] << rule
    attempt = OrbitV2FixtureFactory.attempt(
      attempt_id,
      predecessor["work_unit_id"],
      identity["agent_instance_id"],
      identity["resolved_role"],
      "implementation",
      thesis,
      rule["resolution_id"],
      9,
      bundle["project_policy_revisions"].first["content_digest"],
      authorization_record_refs: unit.dig("authority_scope", "authorization_record_refs"),
      predecessor_work_unit_attempt_ref: predecessor_ref,
      started_at: started_at
    )
    OrbitV2FixtureFactory.append_dispatch_checkpoint(bundle, attempt: attempt, unit: unit,
      pin_attempt_id: bundle["lead_checkpoints"].last.dig("current_or_terminal_attempt_ref", "attempt_id"))
    attempt["events"] << OrbitV2FixtureFactory.event(
      "oevent_#{attempt_id.delete_prefix("oattempt_")}_completed",
      "AttemptCompleted",
      attempt.dig("events", 0, "event_digest"),
      "ended_at" => ended_at,
      "status" => "completed"
    )
    attempt
  end

  def test_authority_graph_regressions
    cross_task = mutate(
      "cross_task_implementation_subject",
      OrbitV2FixtureFactory.valid_bundle
    )
    expect_contract_error("subject_lineage_invalid") do
      Orbit::V2::EvaluationSubject.select(
        gate_requirement: cross_task.fetch("gate_requirements").first,
        task_revision: cross_task.fetch("task_revisions").first,
        work_units: cross_task.fetch("work_units"),
        attempts: cross_task.fetch("work_unit_attempts"),
        evidence_records: cross_task.fetch("evidence_records"),
        repository_snapshot: cross_task.fetch("repository_snapshot"),
        code_surface: cross_task.fetch("code_surface")
      )
    end

    terminal = OrbitV2FixtureFactory.valid_bundle
    attempt = terminal.fetch("work_unit_attempts").find do |candidate|
      candidate["attempt_id"] == "oattempt_independentreview"
    end
    attempt.fetch("events") << OrbitV2FixtureFactory.event(
      "oevent_validattemptcompleted",
      "AttemptCompleted",
      attempt.dig("events", 0, "event_digest"),
      "ended_at" => "2026-07-30T02:00:00Z",
      "status" => "completed"
    )
    assert(validator.validate(terminal).empty?, "one typed Attempt terminal event is valid")

    successor = OrbitV2FixtureFactory.valid_bundle
    thesis = OrbitV2FixtureFactory.deep_copy(successor.fetch("change_theses").first)
    thesis["revision"] = 2
    thesis["root_cause_status"] = "hypothesis"
    rehash(thesis)
    successor.fetch("change_theses") << thesis
    thesis_ref = {
      "change_thesis_id" => thesis["change_thesis_id"],
      "revision" => thesis["revision"],
      "content_digest" => thesis["content_digest"]
    }
    successor_attempt = successor.fetch("work_unit_attempts").first
    successor_attempt.dig("events", 0, "assignment")["change_thesis_ref"] = thesis_ref
    OrbitV2FixtureFactory.resign_event(successor_attempt.dig("events", 0))
    if successor_attempt.fetch("events").length > 1
      terminal = successor_attempt.fetch("events").last
      terminal["previous_event_digest"] =
        successor_attempt.dig("events", 0, "event_digest")
      OrbitV2FixtureFactory.resign_event(terminal)
    end
    successor_record = successor.fetch("evidence_records").first
    successor_record.dig("implementation_check")["change_thesis_ref"] = thesis_ref
    rehash(successor_record)
    # The dispatch checkpoint froze the proposed successor thesis at dispatch
    # time; the same-lineage successor revision must be proposed there too
    # for the AttemptCreated assignment to exact match.
    dispatch_cp = successor["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone"
    end
    Array(dispatch_cp.dig("delivery_progress", "supporting_refs")).each do |ref|
      next unless ref["kind"] == "change_thesis"

      ref["id"] = thesis_ref["change_thesis_id"]
      ref["digest"] = thesis_ref["content_digest"]
    end
    rebind_checkpoint_refs(successor)
    refresh_evaluation_subject(successor)
    assert(
      validator.validate(successor).empty?,
      "Attempt may pin a contiguous same-lineage ChangeThesis successor"
    )

    %w[addressed disproved].each do |outcome|
      resolved = OrbitV2FixtureFactory.valid_bundle
      make_evaluator_resolution(resolved, outcome)
      assert(
        validator.validate(resolved).empty?,
        "#{outcome} resolution requires a distinct immutable follow-up GateEvaluation"
      )
    end

    cross_revision_resolution = OrbitV2FixtureFactory.valid_bundle
    add_cross_revision_resolution(cross_revision_resolution, "addressed")
    assert(
      validator.validate(cross_revision_resolution).empty?,
      "a descendant TaskRevision may resolve an inherited Finding through a distinct " \
        "current-subject evaluation in the stable gate lineage"
    )

    unchanged_successor = OrbitV2FixtureFactory.valid_bundle
    add_task_successor(unchanged_successor)
    assert(
      validator.validate(unchanged_successor).empty?,
      "an unchanged protected gate successor is recreated for and owned by the child revision"
    )

    parent_gate_reuse = OrbitV2FixtureFactory.valid_bundle
    successor = add_task_successor(parent_gate_reuse)
    successor.fetch("task")["gate_requirement_refs"] =
      [OrbitV2FixtureFactory::GATE_ID]
    rehash(successor.fetch("task"))
    parent_gate_reuse["gate_requirements"].delete(successor.fetch("gate"))
    codes = validator.validate(parent_gate_reuse).map(&:code)
    assert(
      codes.include?("gate_requirement_ownership_invalid") &&
        codes.include?("protected_gate_lineage_invalid"),
      "a child TaskRevision cannot reuse its parent-owned GateRequirement"
    )

    authority_change_without_approval = OrbitV2FixtureFactory.valid_bundle
    successor = add_task_successor(authority_change_without_approval)
    successor.fetch("task")["authority_grant_refs"] = ["oauthz_findingwaiver"]
    rehash(successor.fetch("task"))
    assert(
      validator.validate(authority_change_without_approval).map(&:code)
        .include?("protected_gate_lineage_invalid"),
      "a child cannot change protected task authority grants without exact approval"
    )

    authorized_change = OrbitV2FixtureFactory.valid_bundle
    add_authorized_protected_successor(authorized_change)
    assert(
      validator.validate(authorized_change).empty?,
      "an exact provider-bound protected-change envelope authorizes its candidate diff"
    )

    active_policy_change = OrbitV2FixtureFactory.valid_bundle
    prepare_for_policy_rotation(active_policy_change)
    active_policy = add_policy_successor(
      active_policy_change,
      protected_change_grant: true
    )
    add_authorized_protected_successor(
      active_policy_change,
      authorization_policy: active_policy,
      candidate_policy: active_policy
    )
    assert(
      validator.validate(active_policy_change).empty?,
      "protected change is authorized by the current active policy after rotation"
    )

    stale_policy_change = OrbitV2FixtureFactory.valid_bundle
    prepare_for_policy_rotation(stale_policy_change)
    parent_policy = stale_policy_change["project_policy_revisions"].first
    active_policy = add_policy_successor(
      stale_policy_change,
      protected_change_grant: false
    )
    add_authorized_protected_successor(
      stale_policy_change,
      authorization_policy: parent_policy,
      candidate_policy: active_policy
    )
    assert(
      validator.validate(stale_policy_change).map(&:code)
        .include?("protected_gate_lineage_invalid"),
      "superseded policy authorization is rejected when the active policy revoked it"
    )

    forged_nonprotected_lineage = OrbitV2FixtureFactory.valid_bundle
    successor = add_task_successor(forged_nonprotected_lineage)
    parent_gate = forged_nonprotected_lineage["gate_requirements"].first
    child_gate = successor.fetch("gate")
    parent_gate["protected"] = false
    rehash(parent_gate)
    child_gate["protected"] = false
    child_gate["parent_gate_requirement_ref"] = nil
    rehash(child_gate)
    assert(
      validator.validate(forged_nonprotected_lineage).map(&:code)
        .include?("protected_gate_lineage_invalid"),
      "non-protected gate lineage reuse also requires an exact immediate-parent edge"
    )

    cross_task_replay = OrbitV2FixtureFactory.deep_copy(authorized_change)
    authorization = cross_task_replay["authorization_records"].last
    authorization.dig("protected_change_envelope")["task_id"] = "otask_unrelatedcontract"
    rehash_envelope(authorization.fetch("protected_change_envelope"))
    rehash(authorization)
    assert(
      validator.validate(cross_task_replay).map(&:code)
        .include?("protected_gate_lineage_invalid"),
      "protected-change authorization cannot replay across tasks"
    )

    cross_revision_replay = OrbitV2FixtureFactory.deep_copy(authorized_change)
    authorization = cross_revision_replay["authorization_records"].last
    authorization["subject_ref"] = "trev_unrelatedcandidate"
    rehash(authorization)
    assert(
      validator.validate(cross_revision_replay).map(&:code)
        .include?("protected_gate_lineage_invalid"),
      "protected-change authorization cannot replay across candidate revisions"
    )

    changed_diff_replay = OrbitV2FixtureFactory.deep_copy(authorized_change)
    gate = changed_diff_replay["gate_requirements"].last
    gate.dig("subject_selector", "work_unit_refs") << "owu_implementationone"
    rehash(gate)
    assert(
      validator.validate(changed_diff_replay).map(&:code)
        .include?("protected_gate_lineage_invalid"),
      "protected-change authorization cannot replay after the protected diff changes"
    )

    circular_resolution = OrbitV2FixtureFactory.valid_bundle
    resolution = circular_resolution["finding_resolutions"].first
    source_evaluation = circular_resolution["gate_evaluations"].first
    source_finding = circular_resolution["findings"].first
    resolution.delete("authorization_record_ref")
    resolution["resolution"] = "disproved"
    resolution["issuer_attempt_id"] = source_evaluation["evaluator_attempt_id"]
    resolution["issuer_submission_record_id"] =
      source_evaluation["evaluator_submission_record_id"]
    resolution["source_finding_ref"] = {
      "finding_id" => source_finding["finding_id"],
      "content_digest" => source_finding["content_digest"]
    }
    resolution["source_gate_evaluation_ref"] = {
      "gate_evaluation_id" => source_evaluation["gate_evaluation_id"],
      "content_digest" => source_evaluation["content_digest"]
    }
    resolution["resolving_gate_evaluation_ref"] =
      OrbitV2FixtureFactory.deep_copy(resolution["source_gate_evaluation_ref"])
    resolution["supporting_record_refs"] = ["oevr_implementationone"]
    rehash(resolution)
    assert(
      validator.validate(circular_resolution).map(&:code)
        .include?("finding_resolution_gate_binding_invalid"),
      "the GateEvaluation that reports a Finding cannot resolve that same Finding"
    )

    test_resolution_variant_exclusivity
  end

  def test_resolution_variant_exclusivity
    waived = OrbitV2FixtureFactory.valid_bundle
    waived_resolution = waived["finding_resolutions"].first
    waived_resolution["issuer_attempt_id"] = "oattempt_independentreview"
    waived_resolution["issuer_submission_record_id"] = "oevr_independentreview"
    waived_resolution["resolving_gate_evaluation_ref"] = {
      "gate_evaluation_id" => "ogeval_slice0review",
      "content_digest" => waived["gate_evaluations"].first["content_digest"]
    }
    rehash(waived_resolution)
    assert(
      validator.validate(waived).map(&:code).include?("contract_shape_invalid"),
      "waived schema variant forbids evaluator provenance"
    )

    addressed = OrbitV2FixtureFactory.valid_bundle
    make_evaluator_resolution(addressed, "addressed")
    addressed["finding_resolutions"].first["authorization_record_ref"] =
      "oauthz_findingwaiver"
    rehash(addressed["finding_resolutions"].first)
    assert(
      validator.validate(addressed).map(&:code).include?("contract_shape_invalid"),
      "addressed schema variant forbids waiver provenance"
    )

    disproved = OrbitV2FixtureFactory.valid_bundle
    make_evaluator_resolution(disproved, "disproved")
    disproved["finding_resolutions"].first["proposal_evidence_record_id"] =
      "oevr_implementationone"
    rehash(disproved["finding_resolutions"].first)
    assert(
      validator.validate(disproved).map(&:code).include?("contract_shape_invalid"),
      "disproved schema variant forbids addressed-only proposal provenance"
    )

    semantic = validator
    semantic.send(
      :validate_resolution_provenance_fields,
      waived_resolution,
      "finding_resolutions.semantic_variant_probe"
    )
    assert(
      semantic.errors.any? { |error| error.code == "finding_resolution_provenance_invalid" },
      "semantic validator independently rejects outcome-inapplicable provenance"
    )

    semantic_bundle = OrbitV2FixtureFactory.valid_bundle
    semantic_support = validator
    semantic_support.validate(semantic_bundle)
    waived_with_support = OrbitV2FixtureFactory.deep_copy(
      semantic_bundle["finding_resolutions"].first
    )
    waived_with_support["supporting_record_refs"] = ["oevr_phantomsupport"]
    records = semantic_bundle["evidence_records"].to_h do |record|
      [record["evidence_record_id"], record]
    end
    semantic_support.send(
      :validate_resolution_supporting_records,
      waived_with_support,
      records,
      "finding_resolutions.semantic_support_probe"
    )
    assert(
      semantic_support.errors.any? do |error|
        error.code == "finding_resolution_authority_invalid"
      end,
      "semantic validator independently rejects waiver supporting records"
    )
  end

  def test_policy_issuance_and_stale_authority_regressions
    historical = OrbitV2FixtureFactory.valid_bundle
    prepare_for_policy_rotation(historical)
    active_policy = add_policy_successor(historical)
    assert_structure_valid(historical, "provider-authorized policy rotation")
    assert(
      validator.validate(historical).empty?,
      "terminal historical Attempts and evidence remain valid after policy rotation"
    )

    late_submission = OrbitV2FixtureFactory.deep_copy(historical)
    late_submission["evidence_records"].first["acceptance_recorded_at"] =
      "2026-07-30T07:30:00Z"
    rehash(late_submission["evidence_records"].first)
    assert_structure_valid(late_submission, "post-rotation accepted submission")
    assert(
      validator.validate(late_submission).map(&:code)
        .include?("evidence_authority_stale"),
      "a terminal historical Attempt cannot accept new evidence after policy replacement"
    )

    late_terminal = OrbitV2FixtureFactory.deep_copy(historical)
    terminal = late_terminal["work_unit_attempts"].first.fetch("events").last
    terminal["ended_at"] = "2026-07-30T07:30:00Z"
    terminal["recorded_at"] = terminal["ended_at"]
    OrbitV2FixtureFactory.resign_event(terminal)
    assert_structure_valid(late_terminal, "post-rotation terminal Attempt")
    assert(
      validator.validate(late_terminal).map(&:code).include?("attempt_authority_stale"),
      "terminal status cannot disguise work that ended after policy replacement"
    )

    candidate_replay = OrbitV2FixtureFactory.deep_copy(historical)
    candidate = candidate_replay["project_policy_revisions"].last
    candidate["authority_grants"] << {
      "action" => "project.escalate",
      "required_external_grant" => "project.escalate"
    }
    rehash(candidate)
    assert_structure_valid(candidate_replay, "candidate-policy replay")
    assert(
      validator.validate(candidate_replay).map(&:code).include?("policy_issuance_invalid"),
      "a policy issuance receipt cannot replay after any candidate policy content change"
    )

    no_parent_grant = OrbitV2FixtureFactory.valid_bundle
    parent = no_parent_grant["project_policy_revisions"].first
    parent["authority_grants"].reject! { |grant| grant["action"] == "policy.rotate" }
    reissue_genesis_policy(no_parent_grant)
    prepare_for_policy_rotation(no_parent_grant)
    add_policy_successor(no_parent_grant)
    assert_structure_valid(no_parent_grant, "parent without rotation grant")
    assert(
      validator.validate(no_parent_grant).map(&:code)
        .include?("policy_rotation_unauthorized"),
      "a provider-valid successor is rejected when its exact parent grants no rotation authority"
    )

    revoked = OrbitV2FixtureFactory.valid_bundle
    prepare_for_policy_rotation(revoked)
    add_policy_successor(revoked, rotation_grant: false)
    assert(
      validator.validate(revoked).empty?,
      "a parent may issue a successor that revokes future rotation authority"
    )
    add_policy_successor(revoked)
    assert_structure_valid(revoked, "revoked parent rotation")
    assert(
      validator.validate(revoked).map(&:code)
        .include?("policy_rotation_unauthorized"),
      "a successor cannot rotate again after its parent revoked rotation authority"
    )

    stale = OrbitV2FixtureFactory.valid_bundle
    stale_policy = add_policy_successor(stale)
    assert_structure_valid(stale, "stale active Attempts")
    stale_codes = validator.validate(stale).map(&:code)
    assert(
      stale_codes.include?("attempt_authority_stale") &&
        stale_codes.include?("evidence_authority_stale"),
      "active Attempts and accepted submissions cannot continue under a stale TaskRevision policy"
    )

    rebound = OrbitV2FixtureFactory.deep_copy(stale)
    creation = rebound["work_unit_attempts"].first.fetch("events").first
    creation.dig(
      "assignment",
      "authority_snapshot"
    )["project_policy_revision_ref"] = {
      "policy_revision_id" => stale_policy["policy_revision_id"],
      "content_digest" => stale_policy["content_digest"]
    }
    rehash_named(creation, "event_digest")
    assert_structure_valid(rebound, "attempt policy laundering")
    assert(
      validator.validate(rebound).map(&:code).include?("attempt_authority_invalid"),
      "an Attempt cannot bind the active policy directly while its TaskRevision remains stale"
    )

    forbidden_flag = OrbitV2FixtureFactory.valid_bundle
    forbidden_flag["task_revisions"].first["closure_eligible"] = false
    assert(
      Orbit::V2::SchemaCatalog.structure_errors("contract_bundle", forbidden_flag)
        .any? { |error| error.code == "contract_shape_invalid" },
      "closure eligibility is derived and cannot reappear as authoritative TaskRevision input"
    )
  end

  def test_policy_assertion_pinning
    genesis_replacement = OrbitV2FixtureFactory.valid_bundle
    genesis_policy = genesis_replacement["project_policy_revisions"].first
    replacement = OrbitV2FixtureFactory.policy_issuance_assertion(
      genesis_policy,
      parent_policy: nil,
      assertion_id: genesis_policy["authorization_source_ref"],
      subject: "replacement-project-owner",
      issued_at: "2026-07-30T00:00:00Z"
    )
    genesis_replacement["authority_assertions"][0] = replacement
    assert_structure_valid(genesis_replacement, "same-ID genesis assertion replacement")
    assert(
      validator.validate(genesis_replacement).map(&:code)
        .include?("authority_bootstrap_invalid"),
      "genesis policy pins the exact provider-verified assertion digest, not only its ID"
    )

    genesis_reissue = OrbitV2FixtureFactory.valid_bundle
    genesis_policy = genesis_reissue["project_policy_revisions"].first
    reissued = OrbitV2FixtureFactory.policy_issuance_assertion(
      genesis_policy,
      parent_policy: nil,
      assertion_id: genesis_policy["authorization_source_ref"],
      subject: "project-owner",
      issued_at: "2026-07-30T00:00:01Z"
    )
    genesis_reissue["authority_assertions"][0] = reissued
    assert_structure_valid(genesis_reissue, "same-ID genesis receipt reissue")
    assert(
      validator.validate(genesis_reissue).map(&:code)
        .include?("authority_bootstrap_invalid"),
      "genesis policy rejects a same-ID assertion reissued with different signed claims"
    )

    rotation_replacement = OrbitV2FixtureFactory.valid_bundle
    prepare_for_policy_rotation(rotation_replacement)
    parent = rotation_replacement["project_policy_revisions"].first
    child = add_policy_successor(rotation_replacement)
    child_assertion = rotation_replacement["authority_assertions"].find do |assertion|
      assertion["assertion_id"] == child["authorization_source_ref"]
    end
    replaced_child_assertion = OrbitV2FixtureFactory.policy_issuance_assertion(
      child,
      parent_policy: parent,
      assertion_id: child_assertion["assertion_id"],
      subject: "replacement-rotation-owner",
      issued_at: child_assertion.dig("verification_receipt", "issued_at")
    )
    index = rotation_replacement["authority_assertions"].index(child_assertion)
    rotation_replacement["authority_assertions"][index] = replaced_child_assertion
    assert_structure_valid(rotation_replacement, "same-ID rotation assertion replacement")
    assert(
      validator.validate(rotation_replacement).map(&:code)
        .include?("policy_issuance_invalid"),
      "rotation policy and issuance source pin the exact assertion digest"
    )
  end

  def test_lifecycle_writer_and_chronology
    tampered = OrbitV2FixtureFactory.valid_bundle
    creation = tampered.dig("work_unit_attempts", 0, "events", 0)
    creation["started_at"] = "2026-07-30T00:03:00Z"
    creation["recorded_at"] = creation["started_at"]
    rehash_named(creation, "event_digest")
    assert_structure_valid(tampered, "untrusted lifecycle timestamp rewrite")
    assert(
      validator.validate(tampered).map(&:code)
        .include?("lifecycle_receipt_invalid"),
      "rehashing an event cannot replace its provider-backed writer timestamp"
    )

    impossible = OrbitV2FixtureFactory.valid_bundle
    prepare_for_policy_rotation(impossible)
    add_policy_successor(impossible)
    attempt = impossible["work_unit_attempts"].first
    created = attempt["events"].first
    terminal = attempt["events"].last
    created["started_at"] = "2026-07-30T08:00:00Z"
    created["recorded_at"] = created["started_at"]
    OrbitV2FixtureFactory.resign_event(created)
    terminal["previous_event_digest"] = created["event_digest"]
    terminal["ended_at"] = "2026-07-30T06:00:00Z"
    terminal["recorded_at"] = terminal["ended_at"]
    OrbitV2FixtureFactory.resign_event(terminal)
    record = impossible["evidence_records"].find do |candidate|
      candidate["attempt_id"] == attempt["attempt_id"]
    end
    record["acceptance_recorded_at"] = "2026-07-30T06:30:00Z"
    rehash(record)
    refresh_all_evaluation_subjects(impossible)
    assert_structure_valid(impossible, "trusted impossible lifecycle chronology")
    impossible_codes = validator.validate(impossible).map(&:code)
    assert(
      impossible_codes.include?("lifecycle_chronology_invalid") &&
        impossible_codes.include?("attempt_authority_stale") &&
        impossible_codes.include?("evidence_chronology_invalid"),
      "trusted events still require monotonic start/end and evidence-after-start chronology"
    )

    post_cutoff = OrbitV2FixtureFactory.valid_bundle
    prepare_for_policy_rotation(post_cutoff)
    add_policy_successor(post_cutoff)
    attempt = post_cutoff["work_unit_attempts"].first
    created = attempt["events"].first
    terminal = attempt["events"].last
    created["started_at"] = "2026-07-30T08:00:00Z"
    created["recorded_at"] = created["started_at"]
    OrbitV2FixtureFactory.resign_event(created)
    terminal["previous_event_digest"] = created["event_digest"]
    terminal["ended_at"] = "2026-07-30T09:00:00Z"
    terminal["recorded_at"] = terminal["ended_at"]
    OrbitV2FixtureFactory.resign_event(terminal)
    record = post_cutoff["evidence_records"].find do |candidate|
      candidate["attempt_id"] == attempt["attempt_id"]
    end
    record["acceptance_recorded_at"] = "2026-07-30T08:30:00Z"
    rehash(record)
    refresh_all_evaluation_subjects(post_cutoff)
    assert_structure_valid(post_cutoff, "chronological post-cutoff lifecycle")
    post_cutoff_codes = validator.validate(post_cutoff).map(&:code)
    assert(
      post_cutoff_codes.include?("attempt_authority_stale") &&
        post_cutoff_codes.include?("evidence_authority_stale"),
      "historical retention requires start, end, and evidence acceptance before the policy cutoff"
    )

    early_evidence = OrbitV2FixtureFactory.valid_bundle
    evidence = early_evidence["evidence_records"].first
    evidence["acceptance_recorded_at"] = "2026-07-29T23:59:59Z"
    rehash(evidence)
    refresh_all_evaluation_subjects(early_evidence)
    assert_structure_valid(early_evidence, "evidence accepted before attempt start")
    assert(
      validator.validate(early_evidence).map(&:code)
        .include?("evidence_chronology_invalid"),
      "EvidenceRecord acceptance cannot be backdated before its Attempt start"
    )
  end

  def test_task_and_work_authority_and_gate_aggregation
    %w[first second].each do |duplicate_position|
      duplicate = OrbitV2FixtureFactory.valid_bundle
      policy = duplicate["project_policy_revisions"].first
      stronger = {
        "action" => "finding.waive",
        "required_external_grant" => "risk.admin"
      }
      if duplicate_position == "first"
        policy["authority_grants"].unshift(stronger)
      else
        policy["authority_grants"] << stronger
      end
      reissue_genesis_policy(duplicate)
      assert_structure_valid(duplicate, "duplicate authority action #{duplicate_position}")
      assert(
        validator.validate(duplicate).map(&:code)
          .include?("policy_authority_grant_ambiguous"),
        "duplicate authority actions fail closed independent of array order"
      )
    end

    delegated = OrbitV2FixtureFactory.valid_bundle
    add_task_authority(delegated, action: "task.risk_authority.delegate")
    assert_structure_valid(delegated, "task-scoped authority")
    assert(
      validator.validate(delegated).empty?,
      "an allowed task authority action with exact canonical task scope is valid"
    )

    cross_action = OrbitV2FixtureFactory.valid_bundle
    task = cross_action["task_revisions"].first
    task["authority_grant_refs"] = ["oauthz_findingwaiver"]
    rehash(task)
    refresh_evaluation_subject(cross_action)
    assert_structure_valid(cross_action, "cross-action task authority")
    assert(
      validator.validate(cross_action).map(&:code).include?("task_authority_invalid"),
      "TaskRevision authority refs reject a finding-scoped action"
    )

    cross_subject = OrbitV2FixtureFactory.valid_bundle
    add_task_authority(
      cross_subject,
      action: "task.risk_authority.delegate",
      subject_override: digest_for("unrelated-task-authority-scope")
    )
    assert_structure_valid(cross_subject, "cross-subject task authority")
    assert(
      validator.validate(cross_subject).map(&:code).include?("task_authority_invalid"),
      "TaskRevision authority refs reject a valid action bound to another subject"
    )

    work_scoped = OrbitV2FixtureFactory.valid_bundle
    add_work_authority(work_scoped)
    assert_structure_valid(work_scoped, "work-scoped implementation authority")
    assert(
      validator.validate(work_scoped).empty?,
      "WorkUnit and Attempt accept the exact assignment action and canonical work scope"
    )

    work_cross_action = OrbitV2FixtureFactory.deep_copy(work_scoped)
    unit = work_cross_action["work_units"].first
    unit.dig("authority_scope", "authorization_record_refs")
      .replace(["oauthz_findingwaiver"])
    rehash(unit)
    refresh_all_evaluation_subjects(work_cross_action)
    assert_structure_valid(work_cross_action, "WorkUnit cross-action authority")
    assert(
      validator.validate(work_cross_action).map(&:code)
        .include?("work_unit_authority_invalid"),
      "WorkUnit rejects an authorization for a different action and subject kind"
    )

    work_cross_subject = OrbitV2FixtureFactory.valid_bundle
    add_work_authority(
      work_cross_subject,
      subject_override: digest_for("unrelated-work-unit-scope")
    )
    assert_structure_valid(work_cross_subject, "WorkUnit cross-subject authority")
    assert(
      validator.validate(work_cross_subject).map(&:code)
        .include?("work_unit_authority_invalid"),
      "WorkUnit rejects provider-valid work authority bound to another canonical scope"
    )

    attempt_cross_action = OrbitV2FixtureFactory.deep_copy(work_scoped)
    creation = attempt_cross_action.dig("work_unit_attempts", 0, "events", 0)
    creation.dig(
      "assignment",
      "authority_snapshot",
      "authorization_record_refs"
    ).replace(["oauthz_findingwaiver"])
    OrbitV2FixtureFactory.resign_event(creation)
    refresh_all_evaluation_subjects(attempt_cross_action)
    assert_structure_valid(attempt_cross_action, "Attempt cross-action authority")
    assert(
      validator.validate(attempt_cross_action).map(&:code)
        .include?("attempt_authority_invalid"),
      "Attempt rejects refs incompatible with its WorkUnit and assignment purpose"
    )

    same_kind = OrbitV2FixtureFactory.valid_bundle
    add_gate_requirement(
      same_kind,
      kind: "review",
      gate_id: "ogreq_slice0selectedreview",
      lineage_id: "ogline_slice0selectedreview",
      evidence_level: "outcome_quality",
      independence: "independent_evaluator",
      selector_scope: "selected_work_units",
      work_unit_refs: ["owu_implementationone"]
    )
    assert_structure_valid(same_kind, "same-kind gates with distinct subjects")
    assert(
      validator.validate(same_kind).empty?,
      "multiple same-kind GateRequirements remain valid across distinct lineages and subjects"
    )

    %w[first second].each do |weak_position|
      weak_gate = OrbitV2FixtureFactory.valid_bundle
      add_gate_requirement(
        weak_gate,
        kind: "review",
        gate_id: "ogreq_slice0weakreview",
        lineage_id: "ogline_slice0weakreview",
        evidence_level: "mechanical_check",
        independence: "same_agent_allowed",
        insert_first: weak_position == "first"
      )
      assert_structure_valid(weak_gate, "weak protected review gate #{weak_position}")
      assert(
        validator.validate(weak_gate).map(&:code)
          .include?("task_authority_invalid"),
        "every same-kind protected gate must meet the minimum independent of ref order"
      )
    end

    unprotected_extra = OrbitV2FixtureFactory.valid_bundle
    add_gate_requirement(
      unprotected_extra,
      kind: "review",
      gate_id: "ogreq_slice0advisoryreview",
      lineage_id: "ogline_slice0advisoryreview",
      evidence_level: "mechanical_check",
      independence: "same_agent_allowed",
      protected: false,
      selector_scope: "selected_work_units",
      work_unit_refs: ["owu_implementationone"]
    )
    assert_structure_valid(unprotected_extra, "unprotected advisory same-kind gate")
    assert(
      validator.validate(unprotected_extra).empty?,
      "policy minimum aggregation applies to all matching protected gates, not advisory gates"
    )

    duplicate_minimum = OrbitV2FixtureFactory.valid_bundle
    policy = duplicate_minimum["project_policy_revisions"].first
    policy["protected_gate_minimums"] << {
      "gate_kind" => "review",
      "evidence_level" => "mechanical_check",
      "independence" => "same_agent_allowed"
    }
    reissue_genesis_policy(duplicate_minimum)
    assert_structure_valid(duplicate_minimum, "duplicate policy gate minimum")
    assert(
      validator.validate(duplicate_minimum).map(&:code)
        .include?("policy_gate_minimum_ambiguous"),
      "ProjectPolicyRevision gate minimums also require a unique gate kind"
    )
  end

  def test_immutable_stores(bundle)
    record = bundle.fetch("evidence_records").first
    store = Orbit::V2::CreateOnlyStore.new
    assert(store.create("EvidenceRecord", record["evidence_record_id"], record) == :created, "create")
    assert(store.create("EvidenceRecord", record["evidence_record_id"], record) == :idempotent, "same bytes idempotent")
    altered = OrbitV2FixtureFactory.deep_copy(record)
    altered["accepted"] = false
    expect_contract_error("immutable_record_reuse") do
      store.create("EvidenceRecord", record["evidence_record_id"], altered)
    end
    expect_contract_error("immutable_record_delete") do
      store.delete("EvidenceRecord", record["evidence_record_id"])
    end

    stream = Orbit::V2::AppendOnlyEventStore.new
    events = bundle.fetch("work_unit_attempts").first.fetch("events")
    original = OrbitV2FixtureFactory.deep_copy(events[0])
    original_digest = original.fetch("event_digest")
    assert(stream.append("attempt", original) == :appended, "first lifecycle event")
    original["status"] = "caller-mutated"
    assert(
      stream.events("attempt").first["status"] == "active",
      "caller mutation cannot change stored event bytes"
    )
    returned = stream.events("attempt")
    returned.first["status"] = "reader-mutated"
    assert(
      stream.events("attempt").first["status"] == "active",
      "event reads return detached copies"
    )
    successor = OrbitV2FixtureFactory.event(
      "oevent_storetestcompleted",
      "AttemptCompleted",
      original_digest,
      "ended_at" => "2026-07-30T03:00:00Z",
      "status" => "completed"
    )
    assert(stream.append("attempt", successor) == :appended, "successor lifecycle event")
    assert(stream.append("attempt", successor) == :idempotent, "event append idempotent")
    expect_contract_error("append_only_event_delete") do
      stream.delete("attempt", events[0]["event_id"])
    end

    protected_bundle = OrbitV2FixtureFactory.valid_bundle
    protected = add_authorized_protected_successor(protected_bundle)
    authorization = protected.fetch("authorization")
    envelope = authorization.fetch("protected_change_envelope")
    assert(
      envelope["envelope_digest"] ==
        Orbit::V2::ProtectedChange.envelope_digest(envelope),
      "protected-change authorization envelope is content-addressed"
    )
    authorization_store = Orbit::V2::CreateOnlyStore.new
    assert(
      authorization_store.create(
        "AuthorizationRecord",
        authorization["authorization_record_id"],
        authorization
      ) == :created,
      "protected-change authorization is create-only"
    )
    altered_authorization = OrbitV2FixtureFactory.deep_copy(authorization)
    altered_authorization.dig("protected_change_envelope")["issued_at"] =
      "2026-07-30T00:00:01Z"
    rehash_envelope(altered_authorization.fetch("protected_change_envelope"))
    rehash(altered_authorization)
    expect_contract_error("immutable_record_reuse") do
      authorization_store.create(
        "AuthorizationRecord",
        altered_authorization["authorization_record_id"],
        altered_authorization
      )
    end
  end

  def test_transaction_log_store
    Dir.mktmpdir do |dir|
      path = File.join(dir, "transactions.json")

      # Empty log: no file, no chain, genesis expectation; reopens empty.
      log = Orbit::V2::TransactionLog.new(path: path)
      assert(log.tip_digest.nil?, "empty log has no tip")
      assert(log.records == [], "empty log has no records")
      assert(
        Orbit::V2::TransactionLog.new(path: path).records == [],
        "empty log reopens empty"
      )

      # Append/reopen: verified chain survives reopen; reads are detached.
      assert(
        log.append(
          transaction_id: "otxn_storegenesis",
          expected_tip_digest: nil,
          payload: { "kind" => "genesis", "origin" => "test" }
        ) == :appended,
        "genesis append"
      )
      tip = log.tip_digest
      assert(tip.is_a?(String) && tip.start_with?("sha256:"), "tip is a sha256 digest")
      assert(
        log.append(
          transaction_id: "otxn_storesecond",
          expected_tip_digest: tip,
          payload: { "kind" => "later", "count" => 2 }
        ) == :appended,
        "chained append"
      )
      tip = log.tip_digest
      reopened = Orbit::V2::TransactionLog.new(path: path)
      assert(reopened.tip_digest == tip, "reopen sees the same verified tip")
      records = reopened.records
      assert(
        records.map { |record| record["transaction_id"] } ==
          %w[otxn_storegenesis otxn_storesecond],
        "reopen returns chain records in verified order"
      )
      assert(records.first["previous_tip_digest"].nil?, "genesis record has a null previous tip")
      assert(
        records.last["previous_tip_digest"] ==
          "sha256:#{Orbit::V2::CanonicalJSON.sha256(records.first)}",
        "successor pins the exact previous record digest"
      )
      records.last.dig("payload")["count"] = 999
      assert(
        reopened.records.last.dig("payload", "count") == 2,
        "records are detached copies"
      )

      # Stale compare-and-append leaves bytes and chain unchanged.
      stale_before = File.binread(path)
      assert(
        log.append(
          transaction_id: "otxn_storestale",
          expected_tip_digest: "sha256:#{'0' * 64}",
          payload: { "kind" => "never" }
        ) == :stale,
        "stale expectation reports :stale"
      )
      assert(File.binread(path) == stale_before, "stale append leaves bytes unchanged")
      assert(
        log.records.map { |record| record["transaction_id"] } ==
          %w[otxn_storegenesis otxn_storesecond],
        "stale append does not extend the chain"
      )

      # Same id + byte-identical canonical payload is idempotent; same id
      # with different content fails closed. expected_tip_digest is
      # compare-and-append input for a NEW transaction only and never part
      # of replay equivalence: a retry of an already-committed transaction
      # returns :idempotent even with the pre-append tip.
      assert(
        log.append(
          transaction_id: "otxn_storegenesis",
          expected_tip_digest: log.tip_digest,
          payload: { "kind" => "genesis", "origin" => "test" }
        ) == :idempotent,
        "same id and canonical content is idempotent"
      )
      assert(
        log.append(
          transaction_id: "otxn_storegenesis",
          expected_tip_digest: nil,
          payload: { "kind" => "genesis", "origin" => "test" }
        ) == :idempotent,
        "idempotent retry does not require the pre-append tip"
      )
      assert(
        log.append(
          transaction_id: "otxn_storegenesis",
          expected_tip_digest: log.tip_digest,
          payload: { "origin" => "test", "kind" => "genesis" }
        ) == :idempotent,
        "canonical key order does not change content identity"
      )
      expect_contract_error("transaction_log_reuse") do
        log.append(
          transaction_id: "otxn_storegenesis",
          expected_tip_digest: log.tip_digest,
          payload: { "kind" => "different" }
        )
      end
      assert(
        log.records.map { |record| record["transaction_id"] } ==
          %w[otxn_storegenesis otxn_storesecond],
        "rejected reuse does not write"
      )

      # Committed corruption and truncation fail closed, never latest-wins.
      bytes = File.binread(path)
      corrupted = bytes.dup
      corrupted[corrupted.length / 2] = (corrupted[corrupted.length / 2].ord ^ 1).chr
      File.write(path, corrupted)
      expect_contract_error("transaction_log_corrupt") do
        Orbit::V2::TransactionLog.new(path: path).tip_digest
      end
      File.write(path, bytes[0, bytes.length / 2])
      expect_contract_error("transaction_log_corrupt") do
        Orbit::V2::TransactionLog.new(path: path).records
      end
      File.write(path, "#{bytes}\n")
      expect_contract_error("transaction_log_corrupt") do
        Orbit::V2::TransactionLog.new(path: path).tip_digest
      end
      unknown_envelope = JSON.parse(bytes)
      unknown_envelope["authority"] = "not-a-log-field"
      File.write(path, Orbit::V2::CanonicalJSON.dump(unknown_envelope))
      expect_contract_error("transaction_log_corrupt") do
        Orbit::V2::TransactionLog.new(path: path).records
      end
      unknown_record = JSON.parse(bytes)
      unknown_record.dig("records", 0)["authority"] = "not-a-record-field"
      unknown_record["file_digest"] =
        "sha256:#{Orbit::V2::CanonicalJSON.sha256(unknown_record.fetch('records'))}"
      File.write(path, Orbit::V2::CanonicalJSON.dump(unknown_record))
      expect_contract_error("transaction_log_corrupt") do
        Orbit::V2::TransactionLog.new(path: path).tip_digest
      end
      File.write(path, bytes)
      broken = JSON.parse(bytes)
      broken.dig("records", 1)["previous_tip_digest"] = "sha256:#{'f' * 64}"
      broken["file_digest"] = "sha256:#{Orbit::V2::CanonicalJSON.sha256(broken.fetch('records'))}"
      File.write(path, JSON.generate(broken))
      expect_contract_error("transaction_log_corrupt") do
        Orbit::V2::TransactionLog.new(path: path).records
      end
      duped = JSON.parse(bytes)
      duped["records"] << duped.fetch("records").last
      duped["file_digest"] = "sha256:#{Orbit::V2::CanonicalJSON.sha256(duped.fetch('records'))}"
      File.write(path, JSON.generate(duped))
      expect_contract_error("transaction_log_corrupt") do
        Orbit::V2::TransactionLog.new(path: path).tip_digest
      end

      # Canonical deterministic rebuild: a fresh store appending the same
      # transactions (payload keys in any insertion order) writes the same
      # bytes, and delete + re-append rebuilds byte-identically.
      File.write(path, bytes)
      rebuild_path = File.join(dir, "rebuild.json")
      rebuild = Orbit::V2::TransactionLog.new(path: rebuild_path)
      rebuild.append(
        transaction_id: "otxn_storegenesis",
        expected_tip_digest: nil,
        payload: { "kind" => "genesis", "origin" => "test" }
      )
      rebuild.append(
        transaction_id: "otxn_storesecond",
        expected_tip_digest: rebuild.tip_digest,
        payload: { "count" => 2, "kind" => "later" }
      )
      assert(
        File.binread(rebuild_path) == bytes,
        "same transactions rebuild byte-identical regardless of key insertion order"
      )
      File.delete(rebuild_path)
      rebuild = Orbit::V2::TransactionLog.new(path: rebuild_path)
      rebuild.append(
        transaction_id: "otxn_storegenesis",
        expected_tip_digest: nil,
        payload: { "kind" => "genesis", "origin" => "test" }
      )
      rebuild.append(
        transaction_id: "otxn_storesecond",
        expected_tip_digest: rebuild.tip_digest,
        payload: { "kind" => "later", "count" => 2 }
      )
      assert(
        File.binread(rebuild_path) == bytes,
        "delete and re-append rebuilds byte-identically"
      )

      # A symlink or other non-regular final path fails closed so an alias
      # path can never split the log and bypass compare-and-append.
      alias_path = File.join(dir, "alias.json")
      File.symlink(path, alias_path)
      alias_log = Orbit::V2::TransactionLog.new(path: alias_path)
      expect_contract_error("transaction_log_path_invalid") do
        alias_log.tip_digest
      end
      expect_contract_error("transaction_log_path_invalid") do
        alias_log.append(
          transaction_id: "otxn_alias",
          expected_tip_digest: nil,
          payload: {}
        )
      end
      assert(File.symlink?(alias_path), "failed alias append never replaced the symlink")
      assert(
        log.append(
          transaction_id: "otxn_realside",
          expected_tip_digest: log.tip_digest,
          payload: { "side" => "real" }
        ) == :appended,
        "real store is unaffected by the alias path"
      )
      directory_path = File.join(dir, "log-directory")
      FileUtils.mkdir_p(directory_path)
      expect_contract_error("transaction_log_path_invalid") do
        Orbit::V2::TransactionLog.new(path: directory_path).records
      end

      # Invalid canonical payloads fail closed with the argument error and
      # never leave a log record.
      ids_before = log.records.map { |record| record["transaction_id"] }
      expect_contract_error("transaction_log_argument_invalid") do
        log.append(
          transaction_id: "otxn_badpayload",
          expected_tip_digest: log.tip_digest,
          payload: { "float" => 1.5 }
        )
      end
      expect_contract_error("transaction_log_argument_invalid") do
        log.append(
          transaction_id: "otxn_badpayload",
          expected_tip_digest: log.tip_digest,
          payload: { symbol_key: "unsupported" }
        )
      end
      assert(
        log.records.map { |record| record["transaction_id"] } == ids_before,
        "invalid canonical payload leaves no log record"
      )

      # Transaction ids must be canonical NFC UTF-8: a composed/decomposed
      # alias would collapse to one id in the committed file and commit
      # state the reader rejects as a duplicate, so it fails closed and the
      # log stays valid and unchanged.
      assert(
        log.append(
          transaction_id: "otxn_nfc_\u00E9",
          expected_tip_digest: log.tip_digest,
          payload: { "x" => 1 }
        ) == :appended,
        "composed NFC transaction id appends"
      )
      valid_bytes = File.binread(path)
      valid_tip = log.tip_digest
      expect_contract_error("transaction_log_argument_invalid") do
        log.append(
          transaction_id: "otxn_nfc_e\u0301",
          expected_tip_digest: valid_tip,
          payload: { "x" => 2 }
        )
      end
      expect_contract_error("transaction_log_argument_invalid") do
        log.append(
          transaction_id: "otxn_badbytes_\xFF".b,
          expected_tip_digest: valid_tip,
          payload: { "x" => 3 }
        )
      end
      expect_contract_error("transaction_log_argument_invalid") do
        log.append(
          transaction_id: "",
          expected_tip_digest: valid_tip,
          payload: { "x" => 4 }
        )
      end
      assert(File.binread(path) == valid_bytes, "rejected aliases left committed bytes unchanged")
      assert(log.tip_digest == valid_tip, "rejected aliases left the verified tip unchanged")
      assert(
        Orbit::V2::TransactionLog.new(path: path).records.last["transaction_id"] ==
          "otxn_nfc_\u00E9",
        "rejected alias left the verified chain readable and unchanged"
      )

      # Hard-linked alias paths fail closed: both entries share one inode
      # until a rename replaces only its own directory entry, which would
      # fork the log into two independently valid chains.
      real_tip = log.tip_digest
      hard_alias = File.join(dir, "hard-alias.json")
      File.link(path, hard_alias)
      hard_log = Orbit::V2::TransactionLog.new(path: hard_alias)
      expect_contract_error("transaction_log_path_invalid") do
        hard_log.tip_digest
      end
      expect_contract_error("transaction_log_path_invalid") do
        hard_log.append(
          transaction_id: "otxn_hardalias",
          expected_tip_digest: real_tip,
          payload: {}
        )
      end
      assert(
        File.stat(path).nlink == 2 && File.stat(hard_alias).nlink == 2,
        "failed hard-alias append never replaced either link"
      )
      expect_contract_error("transaction_log_path_invalid") do
        log.tip_digest
      end
      File.delete(hard_alias)
      assert(
        log.tip_digest == real_tip,
        "real path remains readable after removing the hard alias"
      )
      assert(
        log.append(
          transaction_id: "otxn_afterhardlink",
          expected_tip_digest: real_tip,
          payload: { "ok" => true }
        ) == :appended,
        "real path appends again once nlink is 1"
      )

      # A planted staging symlink is never followed: exclusive randomized
      # stage creation writes a different file, the victim is untouched,
      # and the committed log stays a single-link regular file.
      victim = File.join(dir, "victim.txt")
      File.write(victim, "USER_BYTES")
      planted = File.join(dir, ".#{File.basename(path)}.tmp.#{$$}.1.victim")
      File.symlink(victim, planted)
      assert(
        log.append(
          transaction_id: "otxn_planted",
          expected_tip_digest: log.tip_digest,
          payload: { "kind" => "planted" }
        ) == :appended,
        "append succeeds using a different exclusive staging file"
      )
      assert(
        File.binread(victim) == "USER_BYTES",
        "planted staging symlink never overwrote the victim"
      )
      assert(
        File.symlink?(planted),
        "planted staging symlink was never followed or replaced"
      )
      assert(File.stat(path).nlink == 1, "committed log remains a single-link regular file")
      assert(
        Orbit::V2::TransactionLog.new(path: path).records.last["transaction_id"] ==
          "otxn_planted",
        "log is readable with the new record after the planted symlink"
      )
    end
  end

  def test_transaction_log_concurrency_and_crash
    Dir.mktmpdir do |dir|
      path = File.join(dir, "transactions.json")

      # Two real processes append from the same genesis tip: the exclusive
      # lock serializes the compare-and-append so exactly one commits and
      # the loser observes :stale with bytes unchanged.
      ready_r, ready_w = IO.pipe
      go_r, go_w = IO.pipe
      out_r, out_w = IO.pipe
      pids = %w[otxn_winner_a otxn_winner_b].map do |id|
        fork do
          ready_r.close
          go_w.close
          out_r.close
          ready_w.write("r")
          ready_w.close
          go_r.read(1)
          log = Orbit::V2::TransactionLog.new(path: path)
          begin
            result = log.append(
              transaction_id: id,
              expected_tip_digest: nil,
              payload: { "origin" => id }
            )
            out_w.write("#{result}\n")
          rescue StandardError => error
            out_w.write("error:#{error.class}\n")
          end
          out_w.close
          exit!(0)
        end
      end
      ready_w.close
      go_r.close
      out_w.close
      2.times { ready_r.read(1) }
      ready_r.close
      2.times { go_w.write("g") }
      go_w.close
      outcomes = out_r.read.split("\n").sort
      out_r.close
      pids.each { |pid| Process.wait(pid) }
      assert(outcomes == %w[appended stale], "exactly one concurrent winner, got #{outcomes.inspect}")
      committed = Orbit::V2::TransactionLog.new(path: path).records
      assert(committed.size == 1, "loser left no record")
      assert(
        %w[otxn_winner_a otxn_winner_b].include?(committed.first["transaction_id"]),
        "chain contains only the winner's transaction"
      )

      # Crash before the commit boundary preserves the previous accepted
      # state: a child is frozen mid-staged-write, killed, and the committed
      # bytes and chain are untouched; the orphaned staging file is ignored.
      log = Orbit::V2::TransactionLog.new(path: path)
      assert(log.append(
        transaction_id: "otxn_committed",
        expected_tip_digest: log.tip_digest,
        payload: { "state" => "committed" }
      ) == :appended, "committed baseline")
      baseline = File.binread(path)
      baseline_ids = log.records.map { |record| record["transaction_id"] }
      staging_glob = File.join(dir, ".#{File.basename(path)}.tmp.*")
      payload = { "blob" => "x" * (32 * 1024 * 1024) }
      frozen = false
      3.times do
        ready_r, ready_w = IO.pipe
        pid = fork do
          ready_r.close
          ready_w.write("r")
          ready_w.close
          child = Orbit::V2::TransactionLog.new(path: path)
          begin
            child.append(
              transaction_id: "otxn_crashy",
              expected_tip_digest: child.tip_digest,
              payload: payload
            )
          rescue StandardError
          end
          exit!(0)
        end
        ready_w.close
        ready_r.read(1)
        ready_r.close
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
        staging = nil
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          staging = Dir.glob(staging_glob).first
          break if staging
          sleep 0.001
        end
        assert(staging, "staged write appeared before the commit boundary")
        begin
          Process.kill("STOP", pid)
        rescue Errno::ESRCH
        end
        if Dir.glob(staging_glob).any?
          Process.kill("KILL", pid)
          Process.wait(pid)
          frozen = true
          break
        end
        begin
          Process.kill("CONT", pid)
        rescue Errno::ESRCH
        end
        Process.wait(pid)
      end
      assert(frozen, "froze the child before rename")
      assert(File.binread(path) == baseline, "crash before commit left committed bytes unchanged")
      assert(
        Orbit::V2::TransactionLog.new(path: path).records.map { |r| r["transaction_id"] } ==
          baseline_ids,
        "crash before commit left the verified chain unchanged"
      )
      assert(Dir.glob(staging_glob).any?, "orphaned staging file remains but is never read")
      assert(
        log.append(
          transaction_id: "otxn_after",
          expected_tip_digest: log.tip_digest,
          payload: { "ok" => true }
        ) == :appended,
        "store accepts new transactions after the crash"
      )
      assert(
        Orbit::V2::TransactionLog.new(path: path).records.map { |r| r["transaction_id"] } ==
          baseline_ids + ["otxn_after"],
        "orphaned staging never became accepted truth"
      )

      # A failure before the commit boundary (read-only directory blocks the
      # staged write) leaves the previous accepted state readable.
      FileUtils.chmod(0o500, dir)
      begin
        failed = false
        begin
          log.append(
            transaction_id: "otxn_blocked",
            expected_tip_digest: log.tip_digest,
            payload: { "kind" => "blocked" }
          )
        rescue SystemCallError
          failed = true
        end
        assert(failed, "staged write failure propagates")
        assert(
          Orbit::V2::TransactionLog.new(path: path).records.map { |r| r["transaction_id"] } ==
            baseline_ids + ["otxn_after"],
          "failed append leaves the previous accepted state readable"
        )
      ensure
        FileUtils.chmod(0o700, dir)
      end
      assert(
        log.append(
          transaction_id: "otxn_finally",
          expected_tip_digest: log.tip_digest,
          payload: { "kind" => "ok" }
        ) == :appended,
        "store recovers after the failed append"
      )

      # Abandoned staging files — garbage or a complete valid extension of
      # the chain — are never read and never become accepted truth.
      File.write(
        File.join(dir, ".#{File.basename(path)}.tmp.99999.1"),
        "this is not json"
      )
      extension_dir = Dir.mktmpdir
      begin
        extension = Orbit::V2::TransactionLog.new(
          path: File.join(extension_dir, "extension.json")
        )
        extension.append(
          transaction_id: "otxn_committed",
          expected_tip_digest: nil,
          payload: { "state" => "committed" }
        )
        extension.append(
          transaction_id: "otxn_stagingonly",
          expected_tip_digest: extension.tip_digest,
          payload: { "kind" => "never" }
        )
        File.write(
          File.join(dir, ".#{File.basename(path)}.tmp.88888.2"),
          File.binread(File.join(extension_dir, "extension.json"))
        )
      ensure
        FileUtils.remove_entry(extension_dir)
      end
      assert(
        Orbit::V2::TransactionLog.new(path: path).records.map { |r| r["transaction_id"] } ==
          baseline_ids + %w[otxn_after otxn_finally],
        "abandoned staging is never read as accepted truth"
      )
    end
  end

  def test_protocol_root_marker
    assert(
      Orbit::V2::ProtocolRoot.singleton_methods(false).sort ==
        %i[create marker_path preflight read],
      "ProtocolRoot exposes exactly its four public seam methods"
    )
    assert(
      Orbit::V2::DurableFile.singleton_methods(false).sort ==
        %i[atomic_write verify_single_link! with_exclusive_lock],
      "DurableFile exposes exactly its three consumed primitives"
    )
    Dir.mktmpdir do |dir|
      marker_path = File.join(dir, ".orbit", "protocol.yaml")
      genesis_ref = {
        "policy_revision_id" => "opolicy_genesis0001",
        "content_digest" => "sha256:#{'a' * 64}"
      }

      # Missing marker: read fails closed, then create -> read -> reopen ->
      # idempotent create round-trips the exact record.
      expect_contract_error("protocol_root_missing") do
        Orbit::V2::ProtocolRoot.read(project_root: dir)
      end
      assert(
        Orbit::V2::ProtocolRoot.create(
          project_root: dir,
          project_id: "oproj_slice0fixture",
          policy_genesis_ref: genesis_ref
        ) == :created,
        "create writes the first marker"
      )
      record = Orbit::V2::ProtocolRoot.read(project_root: dir)
      assert(record["protocol_epoch"] == "orbit-v2", "marker pins the orbit-v2 epoch")
      assert(
        record["project_policy_genesis_ref"] == genesis_ref,
        "marker pins the exact genesis id+digest ref"
      )
      assert(
        record["content_digest"] == Orbit::V2::CanonicalJSON.content_digest(record),
        "marker content_digest matches its canonical semantic content"
      )
      assert(
        Orbit::V2::ProtocolRoot.read(project_root: dir)["project_id"] == "oproj_slice0fixture",
        "reopen reads the same verified marker"
      )
      marker_bytes = File.binread(marker_path)
      assert(
        Orbit::V2::ProtocolRoot.create(
          project_root: dir,
          project_id: "oproj_slice0fixture",
          policy_genesis_ref: genesis_ref
        ) == :idempotent,
        "same accepted marker content is idempotent"
      )
      assert(File.binread(marker_path) == marker_bytes, "idempotent create left bytes unchanged")

      # Create-only: different content never overwrites the marker.
      expect_contract_error("protocol_root_reuse") do
        Orbit::V2::ProtocolRoot.create(
          project_root: dir,
          project_id: "oproj_slice0other",
          policy_genesis_ref: genesis_ref
        )
      end
      assert(File.binread(marker_path) == marker_bytes, "rejected reuse left the marker unchanged")
      expect_contract_error("protocol_root_argument_invalid") do
        Orbit::V2::ProtocolRoot.create(
          project_root: dir,
          project_id: "not-a-project-id",
          policy_genesis_ref: genesis_ref
        )
      end

      # Noncanonical marker bytes and unknown fields fail closed.
      File.write(marker_path, "#{marker_bytes}\n")
      expect_contract_error("protocol_root_corrupt") do
        Orbit::V2::ProtocolRoot.read(project_root: dir)
      end
      tampered = JSON.parse(JSON.generate(record))
      tampered["authority"] = "not-a-marker-field"
      File.write(marker_path, YAML.dump(tampered))
      expect_contract_error("protocol_root_corrupt") do
        Orbit::V2::ProtocolRoot.read(project_root: dir)
      end
      tampered = JSON.parse(JSON.generate(record))
      tampered["content_digest"] = "sha256:#{'f' * 64}"
      File.write(marker_path, YAML.dump(tampered))
      expect_contract_error("protocol_root_corrupt") do
        Orbit::V2::ProtocolRoot.read(project_root: dir)
      end
      File.write(
        marker_path,
        marker_bytes.sub(/^(content_digest:.*)$/, "\\1\\n\\1")
      )
      expect_contract_error("protocol_root_corrupt") do
        Orbit::V2::ProtocolRoot.read(project_root: dir)
      end
      wrong_schema = JSON.parse(JSON.generate(record))
      wrong_schema["schema_version"] = "orbit-protocol-root-v9"
      File.write(marker_path, YAML.dump(wrong_schema))
      expect_contract_error("unsupported_schema_version") do
        Orbit::V2::ProtocolRoot.read(project_root: dir)
      end

      # Symlink and hard-linked marker paths fail closed; the real path
      # recovers once the alias is removed.
      File.write(marker_path, marker_bytes)
      alias_root = File.join(dir, "alias-root")
      FileUtils.mkdir_p(File.join(alias_root, ".orbit"))
      File.symlink(
        marker_path,
        File.join(alias_root, ".orbit", "protocol.yaml")
      )
      expect_contract_error("protocol_root_path_invalid") do
        Orbit::V2::ProtocolRoot.read(project_root: alias_root)
      end
      expect_contract_error("protocol_root_path_invalid") do
        Orbit::V2::ProtocolRoot.create(
          project_root: alias_root,
          project_id: "oproj_slice0fixture",
          policy_genesis_ref: genesis_ref
        )
      end
      assert(File.symlink?(File.join(alias_root, ".orbit", "protocol.yaml")), "alias symlink never replaced")
      hard_alias = File.join(dir, "marker-hard.yaml")
      File.link(marker_path, hard_alias)
      expect_contract_error("protocol_root_path_invalid") do
        Orbit::V2::ProtocolRoot.read(project_root: dir)
      end
      expect_contract_error("protocol_root_path_invalid") do
        Orbit::V2::ProtocolRoot.create(
          project_root: dir,
          project_id: "oproj_slice0fixture",
          policy_genesis_ref: genesis_ref
        )
      end
      File.delete(hard_alias)
      assert(
        Orbit::V2::ProtocolRoot.read(project_root: dir)["content_digest"] ==
          record["content_digest"],
        "real marker path recovers after alias removal"
      )

      # A failure before the commit boundary (read-only .orbit blocks the
      # staged write) leaves the previous state — an absent marker —
      # readable, and a later create succeeds.
      fresh = File.join(dir, "fresh-root")
      FileUtils.mkdir_p(File.join(fresh, ".orbit"))
      FileUtils.chmod(0o500, File.join(fresh, ".orbit"))
      begin
        failed = false
        begin
          Orbit::V2::ProtocolRoot.create(
            project_root: fresh,
            project_id: "oproj_slice0fixture",
            policy_genesis_ref: genesis_ref
          )
        rescue SystemCallError
          failed = true
        end
        assert(failed, "marker create failure propagates")
        expect_contract_error("protocol_root_missing") do
          Orbit::V2::ProtocolRoot.read(project_root: fresh)
        end
      ensure
        FileUtils.chmod(0o700, File.join(fresh, ".orbit"))
      end
      assert(
        Orbit::V2::ProtocolRoot.create(
          project_root: fresh,
          project_id: "oproj_slice0fixture",
          policy_genesis_ref: genesis_ref
        ) == :created,
        "create succeeds after the failed attempt and leaves one durable marker"
      )

      # Known v1 authority artifacts inside the active root fail closed at
      # create; the marker itself stays readable, and v1 archives outside
      # the active root are irrelevant.
      FileUtils.mkdir_p(File.join(dir, ".orbit", "runtime", "sessions"))
      File.write(File.join(dir, ".orbit", "runtime", "sessions", "v1.json"), "{}")
      expect_contract_error("protocol_root_mixed_epoch") do
        Orbit::V2::ProtocolRoot.create(
          project_root: dir,
          project_id: "oproj_slice0fixture",
          policy_genesis_ref: genesis_ref
        )
      end
      assert(
        Orbit::V2::ProtocolRoot.read(project_root: dir)["project_id"] == "oproj_slice0fixture",
        "mixed-epoch rejection never touches the committed marker"
      )
      FileUtils.remove_entry(File.join(dir, ".orbit", "runtime"))
      outside = File.join(Dir.tmpdir, "v1-archive-outside-root-#{$$}")
      FileUtils.mkdir_p(File.join(outside, ".orbit", "runtime"))
      begin
        assert(
          Orbit::V2::ProtocolRoot.create(
            project_root: dir,
            project_id: "oproj_slice0fixture",
            policy_genesis_ref: genesis_ref
          ) == :idempotent,
          "v1 archives outside the active root are irrelevant"
        )
      ensure
        FileUtils.remove_entry(outside)
      end
    end
  end

  def policy_store_genesis_pair
    bundle = OrbitV2FixtureFactory.valid_bundle
    policy = bundle["project_policy_revisions"].first
    assertion = OrbitV2FixtureFactory.policy_issuance_assertion(
      policy,
      parent_policy: nil,
      assertion_id: "oassert_policygenesis",
      subject: "project-owner"
    )
    [policy, assertion]
  end

  def policy_store_successor_pair(parent_policy, revision_id, assertion_id)
    policy = OrbitV2FixtureFactory.deep_copy(parent_policy)
    policy["policy_revision_id"] = revision_id
    policy["parent_policy_revision_id"] = parent_policy["policy_revision_id"]
    policy["authorization_source_ref"] = assertion_id
    policy["authorization_assertion_digest"] =
      OrbitV2FixtureFactory.policy_issuance_assertion_digest(
        assertion_id: assertion_id,
        required_grant: "policy.rotate",
        subject: "project-owner",
        issued_at: "2026-07-30T07:00:00Z"
      )
    policy["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(policy)
    assertion = OrbitV2FixtureFactory.policy_issuance_assertion(
      policy,
      parent_policy: parent_policy,
      assertion_id: assertion_id,
      subject: "project-owner"
    )
    [policy, assertion]
  end

  def policy_store_other_project_genesis_pair
    policy = OrbitV2FixtureFactory.valid_bundle["project_policy_revisions"].first
    policy_b = OrbitV2FixtureFactory.deep_copy(policy)
    policy_b["project_id"] = "oproj_slice0other"
    policy_b["authorization_source_ref"] = "oassert_policygenesisother"
    assertion_base_b = {
      "schema_version" => "orbit-authority-assertion-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => "oproj_slice0other",
      "assertion_id" => "oassert_policygenesisother",
      "issuer_kind" => "user",
      "issuer_subject" => "project-owner",
      "provider_id" => OrbitV2FixtureFactory::AUTHORITY_PROVIDER_ID,
      "grants" => ["policy.genesis"],
      "asserted_at" => "2026-07-30T00:00:00Z"
    }
    digest_b = Orbit::V2::AuthorityVerifier.assertion_digest(assertion_base_b)
    policy_b["authorization_assertion_digest"] = digest_b
    policy_b["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(policy_b)
    envelope_b = Orbit::V2::PolicyIssuance.build_envelope(
      candidate_policy: policy_b,
      parent_policy: nil,
      assertion_id: "oassert_policygenesisother",
      assertion_digest: digest_b,
      provider_id: OrbitV2FixtureFactory::AUTHORITY_PROVIDER_ID,
      receipt_id: "oareceipt_policygenesisother",
      issued_at: "2026-07-30T00:00:00Z"
    )
    assertion_b = assertion_base_b.merge(
      "authority_scope_ref" => envelope_b["envelope_digest"],
      "policy_issuance_envelope" => envelope_b,
      "assertion_digest" => digest_b
    )
    assertion_b["verification_receipt"] =
      OrbitV2FixtureFactory::FAKE_AUTHORITY_PROVIDER.issue(
        assertion_b,
        receipt_id: "oareceipt_policygenesisother",
        issued_at: "2026-07-30T00:00:00Z"
      )
    [policy_b, assertion_b]
  end

  def policy_store_seeded_root(dir)
    FileUtils.mkdir_p(File.join(dir, ".orbit"))
    policy, assertion = policy_store_genesis_pair
    store = Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit"))
    assert(
      store.genesis(
        policy: policy,
        assertion: assertion,
        authority_verifier: OrbitV2FixtureFactory.authority_verifier
      ) == :appended,
      "seed durable policy genesis"
    )
    [store, policy, assertion]
  end

  def protocol_root_preflight(dir, verifier, project_id: OrbitV2FixtureFactory::PROJECT_ID)
    Orbit::V2::ProtocolRoot.preflight(
      project_root: dir,
      expected_project_id: project_id,
      authority_verifier: verifier
    )
  end

  def test_policy_store_genesis
    assert(
      Orbit::V2::PolicyStore.singleton_methods(false).empty?,
      "PolicyStore adds no class-level methods beyond the inherited constructor"
    )
    assert(
      Orbit::V2::PolicyStore.instance_methods(false).sort ==
        %i[genesis records resolve rotate],
      "PolicyStore exposes exactly its four public seams"
    )
    assert(
      Orbit::V2::TransactionLog.instance_methods(false).sort ==
        %i[append append_with records tip_digest],
      "TransactionLog exposes exactly its four public seams"
    )
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".orbit"))
      verifier = OrbitV2FixtureFactory.authority_verifier
      store = Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit"))
      policy, assertion = policy_store_genesis_pair
      genesis_ref = {
        "policy_revision_id" => policy["policy_revision_id"],
        "content_digest" => policy["content_digest"]
      }

      # Controlled genesis: schema/digests/project/issuance validated
      # before append; policy + assertion commit as ONE canonical
      # transaction.
      assert(
        store.genesis(policy: policy, assertion: assertion, authority_verifier: verifier) == :appended,
        "controlled genesis appends"
      )
      records = store.records
      assert(records.size == 1, "one accepted transaction")
      assert(records.first.keys.sort == %w[assertion policy], "one transaction carries policy + assertion")
      resolved = store.resolve(pinned_genesis_ref: genesis_ref, authority_verifier: verifier)
      assert(
        resolved["genesis_policy"]["policy_revision_id"] == policy["policy_revision_id"],
        "resolve returns the stored genesis"
      )
      assert(
        resolved["active_policy"]["policy_revision_id"] == policy["policy_revision_id"],
        "genesis is the initial active tip"
      )
      assert(
        resolved["genesis_assertion"]["assertion_id"] == assertion["assertion_id"],
        "resolve returns the stored genesis assertion"
      )

      # Idempotent genesis replay: same revision id + byte-identical
      # canonical content.
      marker_bytes = File.binread(
        File.join(dir, ".orbit", Orbit::V2::PolicyStore::POLICY_TRANSACTIONS_FILE)
      )
      assert(
        store.genesis(policy: policy, assertion: assertion, authority_verifier: verifier) == :idempotent,
        "idempotent genesis replay"
      )
      assert(
        File.binread(
          File.join(dir, ".orbit", Orbit::V2::PolicyStore::POLICY_TRANSACTIONS_FILE)
        ) == marker_bytes,
        "idempotent replay left bytes unchanged"
      )

      # Same revision id with different canonical content fails closed.
      policy2 = OrbitV2FixtureFactory.deep_copy(policy)
      policy2["authority_grants"] << {
        "action" => "task.additional.override",
        "required_external_grant" => "task.additional.override"
      }
      policy2["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(policy2)
      assertion2 = OrbitV2FixtureFactory.policy_issuance_assertion(
        policy2,
        parent_policy: nil,
        assertion_id: "oassert_policygenesis",
        subject: "project-owner"
      )
      expect_contract_error("policy_store_reuse") do
        store.genesis(policy: policy2, assertion: assertion2, authority_verifier: verifier)
      end
      assert(store.records.size == 1, "rejected reuse left the store unchanged")

      # Invalid/unconfigured/self-reported authority leaves no transaction.
      bad_assertion = OrbitV2FixtureFactory.deep_copy(assertion)
      bad_assertion.dig("policy_issuance_envelope")["envelope_digest"] = "sha256:#{'0' * 64}"
      expect_contract_error("policy_store_genesis_invalid") do
        store.genesis(policy: policy, assertion: bad_assertion, authority_verifier: verifier)
      end
      wrong_grant_assertion = OrbitV2FixtureFactory.deep_copy(assertion)
      wrong_grant_assertion["grants"] = ["policy.rotate"]
      expect_contract_error("policy_store_genesis_invalid") do
        store.genesis(policy: policy, assertion: wrong_grant_assertion, authority_verifier: verifier)
      end
      expect_contract_error("policy_store_genesis_invalid") do
        store.genesis(
          policy: policy,
          assertion: assertion,
          authority_verifier: Orbit::V2::AuthorityVerifier.new
        )
      end
      self_reported = OrbitV2FixtureFactory.deep_copy(assertion)
      self_reported["issuer_kind"] = "agent"
      expect_contract_error("policy_store_argument_invalid") do
        store.genesis(policy: policy, assertion: self_reported, authority_verifier: verifier)
      end
      assert(store.records.size == 1, "invalid authority left the store unchanged")

      # A different genesis on a non-empty store fails closed.
      other_dir = File.join(dir, "other")
      FileUtils.mkdir_p(File.join(other_dir, ".orbit"))
      other_store = Orbit::V2::PolicyStore.new(active_root: File.join(other_dir, ".orbit"))
      other_policy = OrbitV2FixtureFactory.deep_copy(policy)
      other_policy["policy_revision_id"] = "opolicy_genesis0009"
      other_policy["authorization_source_ref"] = "oassert_policygenesis9"
      other_policy["authorization_assertion_digest"] =
        OrbitV2FixtureFactory.policy_issuance_assertion_digest(
          assertion_id: "oassert_policygenesis9",
          required_grant: "policy.genesis",
          subject: "project-owner",
          issued_at: "2026-07-30T00:00:00Z"
        )
      other_policy["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(other_policy)
      other_assertion = OrbitV2FixtureFactory.policy_issuance_assertion(
        other_policy,
        parent_policy: nil,
        assertion_id: "oassert_policygenesis9",
        subject: "project-owner"
      )
      assert(
        other_store.genesis(
          policy: other_policy,
          assertion: other_assertion,
          authority_verifier: verifier
        ) == :appended,
        "different store accepts its own genesis"
      )
      expect_contract_error("policy_store_genesis_conflict") do
        other_store.genesis(policy: policy, assertion: assertion, authority_verifier: verifier)
      end

      # Missing/absent active root fails closed.
      expect_contract_error("policy_store_argument_invalid") do
        Orbit::V2::PolicyStore.new(active_root: File.join(dir, "absent-root"))
      end
    end
  end

  def test_policy_store_rotation
    Dir.mktmpdir do |dir|
      store, policy, = policy_store_seeded_root(dir)
      genesis_ref = {
        "policy_revision_id" => policy["policy_revision_id"],
        "content_digest" => policy["content_digest"]
      }
      verifier = OrbitV2FixtureFactory.authority_verifier
      successor, successor_assertion = policy_store_successor_pair(
        policy, "opolicy_rotated0002", "oassert_policyrotated"
      )

      # Rotation extends an ACTIVE trust root only: without a valid marker
      # pinning the store genesis, rotation fails closed and leaves the
      # unreferenced genesis inert.
      expect_contract_error("policy_store_unpinned") do
        store.rotate(
          policy: successor,
          assertion: successor_assertion,
          authority_verifier: verifier
        )
      end
      assert(store.records.size == 1, "unpinned rotation left the store unchanged")
      Orbit::V2::ProtocolRoot.create(
        project_root: dir,
        project_id: OrbitV2FixtureFactory::PROJECT_ID,
        policy_genesis_ref: {
          "policy_revision_id" => policy["policy_revision_id"],
          "content_digest" => policy["content_digest"]
        }
      )

      # Authorized rotation: parent = resolved active tip, parent grants
      # policy.rotate, provider verifies the exact rotation issuance.
      assert(
        store.rotate(
          policy: successor,
          assertion: successor_assertion,
          authority_verifier: verifier
        ) == :appended,
        "authorized rotation appends one successor"
      )
      assert(store.records.size == 2, "genesis plus one successor")
      resolved = store.resolve(pinned_genesis_ref: genesis_ref, authority_verifier: verifier)
      assert(
        resolved["active_policy"]["policy_revision_id"] == "opolicy_rotated0002",
        "active tip is the accepted successor"
      )
      assert(
        resolved["genesis_policy"]["policy_revision_id"] == policy["policy_revision_id"],
        "genesis is unchanged after rotation"
      )
      assert(
        store.rotate(
          policy: successor,
          assertion: successor_assertion,
          authority_verifier: verifier
        ) == :idempotent,
        "rotation replay is idempotent"
      )

      # Stale parent: a successor whose parent is no longer the active tip.
      stale_pair = policy_store_successor_pair(policy, "opolicy_rotated0003", "oassert_policyrotated3")
      expect_contract_error("policy_store_rotation_invalid") do
        store.rotate(
          policy: stale_pair[0],
          assertion: stale_pair[1],
          authority_verifier: verifier
        )
      end
      assert(store.records.size == 2, "stale rotation left the store unchanged")

      # Unauthorized: a successor of the CURRENT tip whose issuance cannot
      # be provider-verified (tampered grants break the pinned digest).
      forged_successor = OrbitV2FixtureFactory.deep_copy(successor)
      forged_successor["policy_revision_id"] = "opolicy_rotated0005"
      forged_successor["parent_policy_revision_id"] = successor["policy_revision_id"]
      forged_successor["authorization_source_ref"] = "oassert_policyrotatedforged"
      forged_successor["authorization_assertion_digest"] =
        OrbitV2FixtureFactory.policy_issuance_assertion_digest(
          assertion_id: "oassert_policyrotatedforged",
          required_grant: "policy.rotate",
          subject: "project-owner",
          issued_at: "2026-07-30T07:00:00Z"
        )
      forged_successor["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(forged_successor)
      forged_assertion = OrbitV2FixtureFactory.policy_issuance_assertion(
        forged_successor,
        parent_policy: successor,
        assertion_id: "oassert_policyrotatedforged",
        subject: "project-owner"
      )
      forged_assertion["grants"] = ["policy.genesis"]
      expect_contract_error("policy_store_rotation_invalid") do
        store.rotate(
          policy: forged_successor,
          assertion: forged_assertion,
          authority_verifier: verifier
        )
      end
      expect_contract_error("policy_store_lineage_invalid") do
        store.rotate(
          policy: forged_successor,
          assertion: forged_assertion,
          authority_verifier: Orbit::V2::AuthorityVerifier.new
        )
      end
      assert(store.records.size == 2, "unauthorized rotation left the store unchanged")

      # Cross-project successor fails the exact project binding.
      policy_b, assertion_b = policy_store_other_project_genesis_pair
      cross_successor = OrbitV2FixtureFactory.deep_copy(policy_b)
      cross_successor["policy_revision_id"] = "opolicy_rotated0004"
      cross_successor["parent_policy_revision_id"] = successor["policy_revision_id"]
      cross_successor["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(cross_successor)
      expect_contract_error("policy_store_rotation_invalid") do
        store.rotate(
          policy: cross_successor,
          assertion: assertion_b,
          authority_verifier: verifier
        )
      end

      # Rotation without genesis fails closed.
      empty_dir = File.join(dir, "empty")
      FileUtils.mkdir_p(File.join(empty_dir, ".orbit"))
      empty_store = Orbit::V2::PolicyStore.new(active_root: File.join(empty_dir, ".orbit"))
      expect_contract_error("policy_store_rotation_invalid") do
        empty_store.rotate(
          policy: successor,
          assertion: successor_assertion,
          authority_verifier: verifier
        )
      end

      # A marker pinning a DIFFERENT genesis ref (forged pin) fails the
      # in-snapshot lineage resolution and never authorizes rotation.
      forged_dir = File.join(dir, "forged-pin")
      FileUtils.mkdir_p(File.join(forged_dir, ".orbit"))
      forged_store = Orbit::V2::PolicyStore.new(active_root: File.join(forged_dir, ".orbit"))
      forged_store.genesis(
        policy: policy,
        assertion: OrbitV2FixtureFactory.policy_issuance_assertion(
          policy,
          parent_policy: nil,
          assertion_id: "oassert_policygenesis",
          subject: "project-owner"
        ),
        authority_verifier: verifier
      )
      Orbit::V2::ProtocolRoot.create(
        project_root: forged_dir,
        project_id: OrbitV2FixtureFactory::PROJECT_ID,
        policy_genesis_ref: {
          "policy_revision_id" => policy["policy_revision_id"],
          "content_digest" => "sha256:#{'c' * 64}"
        }
      )
      expect_contract_error("policy_store_lineage_invalid") do
        forged_store.rotate(
          policy: successor,
          assertion: successor_assertion,
          authority_verifier: verifier
        )
      end
      assert(forged_store.records.size == 1, "forged-pin rotation left the store unchanged")

      # POLICY_STORE_ROTATION_REQUIRES_MARKER_PROJECT_BINDING: a marker for
      # project B pinning project A's genesis never authorizes rotation of
      # the A store.
      project_mismatch_dir = File.join(dir, "project-mismatch")
      FileUtils.mkdir_p(File.join(project_mismatch_dir, ".orbit"))
      mismatch_store = Orbit::V2::PolicyStore.new(
        active_root: File.join(project_mismatch_dir, ".orbit")
      )
      mismatch_store.genesis(
        policy: policy,
        assertion: OrbitV2FixtureFactory.policy_issuance_assertion(
          policy,
          parent_policy: nil,
          assertion_id: "oassert_policygenesis",
          subject: "project-owner"
        ),
        authority_verifier: verifier
      )
      Orbit::V2::ProtocolRoot.create(
        project_root: project_mismatch_dir,
        project_id: "oproj_slice0other",
        policy_genesis_ref: {
          "policy_revision_id" => policy["policy_revision_id"],
          "content_digest" => policy["content_digest"]
        }
      )
      expect_contract_error("policy_store_unpinned") do
        mismatch_store.rotate(
          policy: successor,
          assertion: successor_assertion,
          authority_verifier: verifier
        )
      end
      assert(
        mismatch_store.records.size == 1,
        "marker-project-mismatch rotation left the store unchanged"
      )

      # POLICY_STORE_ROTATION_REQUIRES_CANONICAL_ACTIVE_ROOT: a shadow
      # store in a sibling directory that copied the same genesis can never
      # borrow the real project's marker pin to rotate.
      shadow_dir = File.join(dir, "shadow")
      FileUtils.mkdir_p(shadow_dir)
      shadow_store = Orbit::V2::PolicyStore.new(active_root: shadow_dir)
      shadow_store.genesis(
        policy: policy,
        assertion: OrbitV2FixtureFactory.policy_issuance_assertion(
          policy,
          parent_policy: nil,
          assertion_id: "oassert_policygenesis",
          subject: "project-owner"
        ),
        authority_verifier: verifier
      )
      expect_contract_error("policy_store_unpinned") do
        shadow_store.rotate(
          policy: successor,
          assertion: successor_assertion,
          authority_verifier: verifier
        )
      end
      assert(
        shadow_store.records.size == 1,
        "shadow-store rotation left the shadow store unchanged"
      )
      assert(
        store.records.size == 2,
        "shadow-store rotation never touched the real store"
      )
    end
  end

  def test_policy_store_concurrent_rotation
    Dir.mktmpdir do |dir|
      store, policy, = policy_store_seeded_root(dir)
      genesis_ref = {
        "policy_revision_id" => policy["policy_revision_id"],
        "content_digest" => policy["content_digest"]
      }
      verifier = OrbitV2FixtureFactory.authority_verifier
      Orbit::V2::ProtocolRoot.create(
        project_root: dir,
        project_id: OrbitV2FixtureFactory::PROJECT_ID,
        policy_genesis_ref: genesis_ref
      )
      ready_r, ready_w = IO.pipe
      go_r, go_w = IO.pipe
      out_r, out_w = IO.pipe
      pairs = [
        policy_store_successor_pair(policy, "opolicy_rotated000a", "oassert_policyrotateda"),
        policy_store_successor_pair(policy, "opolicy_rotated000b", "oassert_policyrotatedb")
      ]
      pids = 2.times.map do |index|
        fork do
          ready_r.close
          go_w.close
          out_r.close
          ready_w.write("r")
          ready_w.close
          go_r.read(1)
          child = Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit"))
          begin
            result = child.rotate(
              policy: pairs[index][0],
              assertion: pairs[index][1],
              authority_verifier: verifier
            )
            out_w.write("#{result}\n")
          rescue Orbit::V2::ContractError => error
            out_w.write("error:#{error.code}\n")
          end
          out_w.close
          exit!(0)
        end
      end
      ready_w.close
      go_r.close
      out_w.close
      2.times { ready_r.read(1) }
      ready_r.close
      2.times { go_w.write("g") }
      go_w.close
      outcomes = out_r.read.split("\n").sort
      out_r.close
      pids.each { |pid| Process.wait(pid) }
      assert(
        outcomes == %w[appended error:policy_store_rotation_invalid],
        "snapshot CAS yields exactly one successor, got #{outcomes.inspect}"
      )
      assert(store.records.size == 2, "no fork: exactly one successor transaction")
      winner = store.resolve(pinned_genesis_ref: genesis_ref, authority_verifier: verifier)
      assert(
        %w[opolicy_rotated000a opolicy_rotated000b].include?(
          winner["active_policy"]["policy_revision_id"]
        ),
        "active tip is exactly the single accepted successor"
      )
    end
  end

  def test_policy_store_lineage_fail_closed
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".orbit"))
      path = File.join(dir, ".orbit", Orbit::V2::PolicyStore::POLICY_TRANSACTIONS_FILE)
      policy, assertion = policy_store_genesis_pair
      genesis_ref = {
        "policy_revision_id" => policy["policy_revision_id"],
        "content_digest" => policy["content_digest"]
      }
      successor_a, assertion_a = policy_store_successor_pair(
        policy, "opolicy_rotated000a", "oassert_policyrotateda"
      )
      successor_b, assertion_b = policy_store_successor_pair(
        policy, "opolicy_rotated000b", "oassert_policyrotatedb"
      )

      # A crafted fork — two successors of the same genesis in one log —
      # fails closed on the reader's exact-parent-refs rule.
      tx_record = lambda do |tx_id, parent_digest, policy, assertion|
        payload = { "assertion" => assertion, "policy" => policy }
        record = {
          "schema_version" => "orbit-transaction-log-v1",
          "transaction_id" => tx_id,
          "previous_tip_digest" => parent_digest,
          "content_digest" => "sha256:#{Orbit::V2::CanonicalJSON.sha256(payload)}",
          "payload" => payload
        }
        [record, "sha256:#{Orbit::V2::CanonicalJSON.sha256(record)}"]
      end
      genesis_record, genesis_digest = tx_record.call(policy["policy_revision_id"], nil, policy, assertion)
      record_a, digest_a = tx_record.call(
        successor_a["policy_revision_id"], genesis_digest, successor_a, assertion_a
      )
      # The fork is at the POLICY level: a valid log chain whose second
      # successor's policy parent is the genesis, not record_a.
      record_b, = tx_record.call(
        successor_b["policy_revision_id"], digest_a, successor_b, assertion_b
      )
      write_log_file = lambda do |records|
        File.write(
          path,
          Orbit::V2::CanonicalJSON.dump(
            "schema_version" => "orbit-transaction-log-v1",
            "records" => records,
            "file_digest" => "sha256:#{Orbit::V2::CanonicalJSON.sha256(records)}"
          )
        )
      end
      write_log_file.call([genesis_record, record_a, record_b])
      store = Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit"))
      verifier = OrbitV2FixtureFactory.authority_verifier
      expect_contract_error("policy_store_lineage_invalid") do
        store.resolve(
          pinned_genesis_ref: genesis_ref,
          authority_verifier: verifier
        )
      end

      # A malformed transaction payload (unknown field) fails closed even
      # with all digests recomputed.
      malformed, = tx_record.call(
        successor_a["policy_revision_id"], genesis_digest, successor_a, assertion_a
      )
      malformed["payload"]["authority"] = "not-a-payload-field"
      malformed["content_digest"] =
        "sha256:#{Orbit::V2::CanonicalJSON.sha256(malformed['payload'])}"
      write_log_file.call([genesis_record, malformed])
      expect_contract_error("policy_store_lineage_invalid") do
        store.resolve(
          pinned_genesis_ref: genesis_ref,
          authority_verifier: verifier
        )
      end

      # A missing pinned genesis (store has genesis, pin names a ref the
      # store never committed) fails closed.
      write_log_file.call([genesis_record, record_a])
      missing_pin = {
        "policy_revision_id" => successor_a["policy_revision_id"],
        "content_digest" => successor_a["content_digest"]
      }
      expect_contract_error("policy_store_lineage_invalid") do
        store.resolve(
          pinned_genesis_ref: missing_pin,
          authority_verifier: verifier
        )
      end

      # POLICY_STORE_ROTATION_REQUIRES_VERIFIED_LINEAGE: a pinned store
      # whose genesis issuance cannot be provider-verified (tampered
      # receipt in a digest-consistent crafted file) never authorizes
      # rotation — the in-snapshot resolution fails closed and the store
      # stays unchanged.
      broken_dir = File.join(dir, "broken-provider")
      FileUtils.mkdir_p(File.join(broken_dir, ".orbit"))
      broken_path = File.join(
        broken_dir,
        ".orbit",
        Orbit::V2::PolicyStore::POLICY_TRANSACTIONS_FILE
      )
      broken_assertion = OrbitV2FixtureFactory.deep_copy(assertion)
      broken_assertion.dig("verification_receipt")["receipt"] = "hmac-sha256:#{'0' * 64}"
      broken_record, = tx_record.call(
        policy["policy_revision_id"], nil, policy, broken_assertion
      )
      File.write(
        broken_path,
        Orbit::V2::CanonicalJSON.dump(
          "schema_version" => "orbit-transaction-log-v1",
          "records" => [broken_record],
          "file_digest" => "sha256:#{Orbit::V2::CanonicalJSON.sha256([broken_record])}"
        )
      )
      Orbit::V2::ProtocolRoot.create(
        project_root: broken_dir,
        project_id: OrbitV2FixtureFactory::PROJECT_ID,
        policy_genesis_ref: {
          "policy_revision_id" => policy["policy_revision_id"],
          "content_digest" => policy["content_digest"]
        }
      )
      broken_store = Orbit::V2::PolicyStore.new(
        active_root: File.join(broken_dir, ".orbit")
      )
      expect_contract_error("policy_store_lineage_invalid") do
        broken_store.rotate(
          policy: successor_a,
          assertion: assertion_a,
          authority_verifier: verifier
        )
      end
      assert(
        broken_store.records.size == 1,
        "unverified-lineage rotation left the store unchanged"
      )
    end
  end

  class BlockingAuthorityVerifier
    def initialize(delegate, signal_w, release_r)
      @delegate = delegate
      @signal_w = signal_w
      @release_r = release_r
      @blocked = false
    end

    def verify!(assertion)
      unless @blocked
        @blocked = true
        @signal_w.write("b")
        @release_r.read(1)
      end
      @delegate.verify!(assertion)
    end
  end

  def control_verifiers
    [
      OrbitV2FixtureFactory.authority_verifier,
      OrbitV2FixtureFactory.runtime_identity_verifier,
      OrbitV2FixtureFactory.lifecycle_verifier
    ]
  end

  def control_store_writer_assertion(control_id)
    OrbitV2FixtureFactory.assertion("oassert_#{control_id.delete_prefix('olcontrol_')}writer",
      %w[control.genesis control.checkpoint], "control-plane-writer", authority_scope_ref: control_id)
  end

  def control_store_genesis_records(bundle, task, agent, control_id, assertion, lead: nil)
    control = control_id.delete_prefix("olcontrol_")
    result = OrbitV2FixtureFactory.second_lineage(bundle, control_id: control_id,
      writer_assertion: assertion, agent: agent, task: task,
      logical_lead_id: "olead_#{control}", session_id: "oleadsession_#{control}")
    if lead
      result["session"]["logical_lead_id"] = lead["logical_lead_id"]
      result["genesis"]["logical_lead_refs"] = [{ "logical_lead_id" => lead["logical_lead_id"],
        "content_digest" => lead["content_digest"] }]
      result["genesis"]["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(result["genesis"])
      registry = bundle["control_registries"].last
      registry["genesis_checkpoint_ref"] = { "lead_checkpoint_id" => result["genesis"]["lead_checkpoint_id"],
        "content_digest" => result["genesis"]["content_digest"] }
      registry["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(registry)
    end
    [bundle["control_registries"].last, result["session"], result["genesis"], agent, assertion]
  end

  def control_store_seeded_root(dir, bundle)
    FileUtils.mkdir_p(File.join(dir, ".orbit"))
    policy = bundle["project_policy_revisions"].first
    assertion = OrbitV2FixtureFactory.policy_issuance_assertion(policy, parent_policy: nil,
      assertion_id: "oassert_policygenesis", subject: "project-owner")
    Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit")).genesis(
      policy: policy, assertion: assertion,
      authority_verifier: OrbitV2FixtureFactory.authority_verifier)
    Orbit::V2::ProtocolRoot.create(project_root: dir, project_id: OrbitV2FixtureFactory::PROJECT_ID,
      policy_genesis_ref: { "policy_revision_id" => policy["policy_revision_id"], "content_digest" => policy["content_digest"] })
    [Orbit::V2::ControlStore.new(active_root: File.join(dir, ".orbit")), policy, bundle["task_revisions"].first]
  end

  def control_store_genesis(store, records, verifiers, overrides = {})
    store.genesis(registry: records[0], session: records[1], checkpoint: records[2],
      agent: records[3], assertion: records[4],
      authority_verifier: overrides.fetch(:authority, verifiers[0]),
      runtime_identity_verifier: overrides.fetch(:runtime, verifiers[1]),
      lifecycle_verifier: overrides.fetch(:lifecycle, verifiers[2]))
  end

  def control_store_resolve(store, control_id, verifiers)
    store.resolve(control_id: control_id, authority_verifier: verifiers[0],
      runtime_identity_verifier: verifiers[1], lifecycle_verifier: verifiers[2])
  end

  def test_control_store_genesis
    assert(Orbit::V2::ControlStore.instance_methods(false).sort == %i[checkpoint genesis records resolve],
      "ControlStore exposes exactly its four public seams")
    Dir.mktmpdir do |dir|
      bundle = OrbitV2FixtureFactory.valid_bundle
      store, _policy, task = control_store_seeded_root(dir, bundle)
      vf = control_verifiers
      agent = OrbitV2FixtureFactory.agent("oagent_inc4lead", "lead")
      records = control_store_genesis_records(bundle, task, agent, "olcontrol_inc4main",
        control_store_writer_assertion("olcontrol_inc4main"))
      assert(control_store_genesis(store, records, vf) == :appended, "atomic genesis")
      assert(store.records.size == 1 &&
        store.records.first.keys.sort == %w[agent assertion checkpoint registry session], "one closed payload")
      resolved = control_store_resolve(
        Orbit::V2::ControlStore.new(active_root: File.join(dir, ".orbit")), "olcontrol_inc4main", vf)
      assert(resolved["checkpoint"]["is_genesis"] == true &&
        resolved["session"]["lead_runtime_subject_ref"] == agent.dig("runtime_identity", "runtime_subject_id"),
        "reopen and resolve")
      assert(control_store_genesis(store, records, vf) == :idempotent, "same-content replay")
      altered = OrbitV2FixtureFactory.deep_copy(records[2])
      altered.dig("lead_decision")["reason"] = "different content"
      expect_contract_error("control_store_reuse") do
        store.genesis(registry: records[0], session: records[1], checkpoint: altered,
          agent: records[3], assertion: records[4],
          authority_verifier: vf[0], runtime_identity_verifier: vf[1], lifecycle_verifier: vf[2])
      end
      neg = control_store_genesis_records(bundle, task, OrbitV2FixtureFactory.agent("oagent_inc4neg", "lead"),
        "olcontrol_inc4neg", control_store_writer_assertion("olcontrol_inc4neg"))
      expect_contract_error("control_store_argument_invalid") { control_store_genesis(store, neg, vf, authority: nil) }
      expect_contract_error("control_store_argument_invalid") { control_store_genesis(store, neg, vf, lifecycle: nil) }
      expect_contract_error("control_store_genesis_invalid") { control_store_genesis(store, neg, vf, authority: Orbit::V2::AuthorityVerifier.new) }
      expect_contract_error("control_store_genesis_invalid") { control_store_genesis(store, neg, vf, runtime: Orbit::V2::RuntimeIdentityVerifier.new) }
      expect_contract_error("control_store_genesis_invalid") { control_store_genesis(store, neg, vf, lifecycle: Orbit::V2::LifecycleVerifier.new) }
      reviewer = control_store_genesis_records(bundle, task, OrbitV2FixtureFactory.agent("oagent_inc4reviewer", "reviewer"),
        "olcontrol_inc4reviewer", control_store_writer_assertion("olcontrol_inc4reviewer"))
      expect_contract_error("control_store_genesis_invalid") { control_store_genesis(store, reviewer, vf) }
      expect_contract_error("control_store_argument_invalid") { store.resolve(control_id: "olcontrol_inc4main", authority_verifier: vf[0], runtime_identity_verifier: vf[1], lifecycle_verifier: nil) }
      assert(store.records.size == 1, "invalid authority left the store unchanged")
    end
  end

  def test_control_store_conflicts
    Dir.mktmpdir do |dir|
      bundle = OrbitV2FixtureFactory.valid_bundle
      store, policy, task = control_store_seeded_root(dir, bundle)
      vf = control_verifiers
      verifier = vf[0]
      task2 = OrbitV2FixtureFactory.extra_task(bundle, task_id: "otask_inc4second",
        revision_id: "trev_inc4second_r1", gate_id: "ogreq_inc4second", gate_lineage_id: "ogline_inc4second")["task"]
      agent = OrbitV2FixtureFactory.agent("oagent_inc4lead", "lead")
      agent2 = OrbitV2FixtureFactory.agent("oagent_inc4lead2", "lead")
      main = control_store_genesis_records(bundle, task, agent, "olcontrol_inc4main",
        control_store_writer_assertion("olcontrol_inc4main"))
      assert(control_store_genesis(store, main, vf) == :appended, "first control")
      disjoint = control_store_genesis_records(bundle, task2, agent2, "olcontrol_inc4disjoint",
        control_store_writer_assertion("olcontrol_inc4disjoint"))
      assert(control_store_genesis(store, disjoint, vf) == :appended, "disjoint accepted")
      subject_copy = OrbitV2FixtureFactory.agent("oagent_inc4leadcopy", "lead")
      subject_copy["runtime_identity"]["runtime_subject_id"] = agent.dig("runtime_identity", "runtime_subject_id")
      subject_copy["runtime_identity"]["verification_receipt_ref"] =
        OrbitV2FixtureFactory::FAKE_RUNTIME_IDENTITY_PROVIDER.issue(provider_id: OrbitV2FixtureFactory::RUNTIME_IDENTITY_PROVIDER_ID,
          project_id: OrbitV2FixtureFactory::PROJECT_ID, agent_instance_id: "oagent_inc4leadcopy",
          runtime_subject_id: agent.dig("runtime_identity", "runtime_subject_id"))
      same_subject = control_store_genesis_records(bundle, task2, subject_copy, "olcontrol_inc4samesubject",
        control_store_writer_assertion("olcontrol_inc4samesubject"))
      expect_contract_error("control_store_subject_conflict") do
        control_store_genesis(store, same_subject, vf)
      end
      overlap = control_store_genesis_records(bundle, task,
        OrbitV2FixtureFactory.agent("oagent_inc4lead4", "lead"), "olcontrol_inc4overlap",
        control_store_writer_assertion("olcontrol_inc4overlap"))
      expect_contract_error("control_store_task_conflict") do
        control_store_genesis(store, overlap, vf)
      end
      assert(store.records.size == 2, "conflicting claims left the store unchanged")
      successor, successor_assertion = policy_store_successor_pair(policy, "opolicy_rotated0002", "oassert_policyrotated")
      assert(Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit")).rotate(
        policy: successor, assertion: successor_assertion, authority_verifier: verifier) == :appended, "policy rotates")
      stale = control_store_genesis_records(bundle, task2, agent2, "olcontrol_inc4stale",
        control_store_writer_assertion("olcontrol_inc4stale"))
      expect_contract_error("control_store_genesis_invalid") do
        control_store_genesis(store, stale, vf)
      end
      fresh_bundle = OrbitV2FixtureFactory.deep_copy(bundle)
      fresh_bundle["project_policy_revisions"] = [successor]
      task3 = OrbitV2FixtureFactory.extra_task(fresh_bundle, task_id: "otask_inc4third",
        revision_id: "trev_inc4third_r1", gate_id: "ogreq_inc4third", gate_lineage_id: "ogline_inc4third")["task"]
      fresh = control_store_genesis_records(fresh_bundle, task3,
        OrbitV2FixtureFactory.agent("oagent_inc4lead3", "lead"), "olcontrol_inc4fresh",
        control_store_writer_assertion("olcontrol_inc4fresh"))
      assert(control_store_genesis(store, fresh, vf) == :appended, "fresh tip accepted")
      assert(control_store_resolve(store, "olcontrol_inc4main", vf)
        .dig("checkpoint", "project_policy_revision_ref", "policy_revision_id") ==
        policy["policy_revision_id"], "reader accepts the pinned accepted-policy revision after rotation")
    end
  end

  def test_control_store_concurrency
    Dir.mktmpdir do |dir|
      bundle = OrbitV2FixtureFactory.valid_bundle
      store, policy, task = control_store_seeded_root(dir, bundle)
      vf = control_verifiers
      verifier = vf[0]
      claim = lambda do |index|
        records = control_store_genesis_records(bundle, task,
          OrbitV2FixtureFactory.agent("oagent_inc4claim#{index}", "lead"), "olcontrol_inc4claim",
          control_store_writer_assertion("olcontrol_inc4claim"))
        control_store_genesis(Orbit::V2::ControlStore.new(active_root: File.join(dir, ".orbit")),
          records, vf)
      end
      out_r, out_w = IO.pipe
      pids = 2.times.map do |index|
        fork do
          out_r.close
          begin
            out_w.write("#{claim.call(index)}\n")
          rescue Orbit::V2::ContractError => error
            out_w.write("error:#{error.code}\n")
          end
          out_w.close
          exit!(0)
        end
      end
      out_w.close
      outcomes = out_r.read.split("\n").sort
      out_r.close
      pids.each { |pid| Process.wait(pid) }
      assert(outcomes == %w[appended error:control_store_reuse] && store.records.size == 1,
        "concurrent same-control claims yield exactly one accepted genesis")
      race_task = OrbitV2FixtureFactory.extra_task(bundle, task_id: "otask_inc4race",
        revision_id: "trev_inc4race_r1", gate_id: "ogreq_inc4race", gate_lineage_id: "ogline_inc4race")["task"]
      signal_r, signal_w = IO.pipe
      release_r, release_w = IO.pipe
      rec = control_store_genesis_records(bundle, race_task, OrbitV2FixtureFactory.agent("oagent_inc4race", "lead"),
        "olcontrol_inc4race", control_store_writer_assertion("olcontrol_inc4race"))
      genesis_pid = fork do
        control_store_genesis(Orbit::V2::ControlStore.new(active_root: File.join(dir, ".orbit")),
          rec, vf, authority: BlockingAuthorityVerifier.new(vf[0], signal_w, release_r))
        exit!(0)
      end
      signal_w.close
      release_r.close
      signal_r.read(1)
      signal_r.close
      successor, successor_assertion = policy_store_successor_pair(policy, "opolicy_rotated0002", "oassert_policyrotated")
      rotation_pid = fork do
        Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit")).rotate(
          policy: successor, assertion: successor_assertion, authority_verifier: verifier)
        exit!(0)
      end
      sleep 0.3
      assert(Process.waitpid(rotation_pid, Process::WNOHANG).nil?,
        "rotation cannot commit inside the control genesis lock window")
      release_w.write("g")
      release_w.close
      assert(Process.wait2(genesis_pid).last.success?, "genesis completed")
      assert(Process.wait2(rotation_pid).last.success?, "rotation completed after the window")
      assert(control_store_resolve(store, "olcontrol_inc4race", vf)
        .dig("checkpoint", "project_policy_revision_ref", "policy_revision_id") ==
        policy["policy_revision_id"], "control pinned the policy active inside its locked window")
      assert(Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit")).resolve(
        pinned_genesis_ref: { "policy_revision_id" => policy["policy_revision_id"], "content_digest" => policy["content_digest"] },
        authority_verifier: verifier)["active_policy"]["policy_revision_id"] == "opolicy_rotated0002",
        "rotation then completes after the control window")
    end
  end

  def control_store_checkpoint_records(bundle, policy, records, control_id, checkpoint_id, decision,
                                       lead: nil, unit: nil, predecessor_checkpoint: nil)
    genesis_cp = records[2]
    predecessor_checkpoint ||= genesis_cp
    session = records[1]
    agent = records[3]
    task = bundle["task_revisions"].first
    unit ||= bundle["work_units"].first
    lead = lead || bundle["logical_leads"].find do |candidate|
      candidate["logical_lead_id"] == genesis_cp.dig("logical_lead_refs", 0, "logical_lead_id")
    end
    assertion = OrbitV2FixtureFactory.assertion(
      "oassert_#{checkpoint_id.delete_prefix('olcheckpoint_')}writer",
      %w[control.checkpoint], "control-plane-writer", authority_scope_ref: control_id)
    checkpoint = OrbitV2FixtureFactory.lead_checkpoint(
      checkpoint_id, is_genesis: false,
      predecessor_ref: OrbitV2FixtureFactory.cp_ref(predecessor_checkpoint),
      predecessor_checkpoint: predecessor_checkpoint,
      policy: policy, session: session, agent: agent, logical_lead: lead, task: task,
      writer_action: "control.checkpoint", writer_assertion: assertion, lead_control_id: control_id,
      active_task_ref: OrbitV2FixtureFactory.task_ref(task),
      selected_work_unit_ref: OrbitV2FixtureFactory.work_unit_ref(unit),
      task_queue: [OrbitV2FixtureFactory.task_ref(task)], decision: decision)
    [checkpoint, assertion]
  end

  def control_store_session_transition(bundle, policy, records, control_id, checkpoint_id, decision,
                                       lead: nil, unit: nil, predecessor_checkpoint: nil)
    checkpoint, assertion = control_store_checkpoint_records(
      bundle, policy, records, control_id, checkpoint_id, decision,
      lead: lead, unit: unit, predecessor_checkpoint: predecessor_checkpoint
    )
    genesis_cp = records[2]
    session = records[1]
    agent = records[3]
    ended = OrbitV2FixtureFactory.event("oevent_inc6a_ended", "LeadSessionEnded",
      session.dig("lifecycle_events", -1, "event_digest"),
      "ended_at" => "2026-07-30T01:00:00Z", "status" => "completed", "reason" => "Successor session.")
    prior_session = OrbitV2FixtureFactory.deep_copy(session)
    prior_session["lifecycle_events"] = session["lifecycle_events"] + [ended]
    successor = OrbitV2FixtureFactory.deep_copy(session)
    successor["lead_session_id"] = "oleadsession_inc6asuccessor"
    successor["session_generation"] = 2
    successor["predecessor_lead_session_ref"] = { "lead_session_id" => session["lead_session_id"],
      "session_generation" => 1, "event_id" => ended["event_id"], "event_digest" => ended["event_digest"] }
    successor["lifecycle_events"] = [OrbitV2FixtureFactory.event("oevent_inc6a_successorstarted", "LeadSessionStarted", nil,
      "role" => "lead", "context_generation" => 2, "started_at" => "2026-07-30T01:05:00Z", "status" => "active")]
    transitioned_agent = OrbitV2FixtureFactory.deep_copy(agent)
    transitioned_agent["lifecycle_events"] = agent["lifecycle_events"] + [OrbitV2FixtureFactory.event(
      "oevent_inc6a_agentadv", "AgentContextAdvanced", agent.dig("lifecycle_events", -1, "event_digest"),
      "context_generation" => 2, "recorded_at" => "2026-07-30T01:02:00Z", "reason" => "Successor session context.")]
    checkpoint["active_lead_session_ref"] = { "lead_session_id" => successor["lead_session_id"], "session_generation" => 2 }
    checkpoint["lead_runtime_subject_ref"] = successor["lead_runtime_subject_ref"]
    checkpoint["lead_runtime_subject_assertion_digest"] = successor["lead_runtime_subject_assertion_digest"]
    checkpoint["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(checkpoint)
    [checkpoint, assertion, prior_session, successor, transitioned_agent]
  end

  def test_control_store_checkpoint
    Dir.mktmpdir do |dir|
      bundle = OrbitV2FixtureFactory.valid_bundle
      bundle["logical_leads"].first["logical_lead_id"] = "olead_inc6amain"
      bundle["logical_leads"].first["content_digest"] =
        Orbit::V2::CanonicalJSON.content_digest(bundle["logical_leads"].first)
      store, policy, _task = control_store_seeded_root(dir, bundle)
      vf = control_verifiers
      task_records = task_store_genesis_records(bundle)
      bundle["task_revisions"] = [OrbitV2FixtureFactory.deep_copy(task_records[0])]
      bundle["work_units"] = OrbitV2FixtureFactory.deep_copy(task_records[2])
      bundle["logical_leads"] = [OrbitV2FixtureFactory.deep_copy(task_records[6])]
      task_store = Orbit::V2::TaskStore.new(active_root: File.join(dir, ".orbit"))
      assert(task_store.genesis(task: task_records[0], gate_requirements: task_records[1],
        work_units: task_records[2], change_theses: task_records[3],
        authority_assertions: task_records[4], authorization_records: task_records[5],
        logical_lead: task_records[6], authority_verifier: vf[0]) == :appended, "task definition")
      agent = OrbitV2FixtureFactory.agent("oagent_inc6alead", "lead")
      records = control_store_genesis_records(bundle, task_records[0], agent, "olcontrol_inc6amain",
        control_store_writer_assertion("olcontrol_inc6amain"), lead: task_records[6])
      assert(control_store_genesis(store, records, vf) == :appended, "genesis control")
      selected_unit = bundle["work_units"].fetch(1)
      selection = {
        "state" => "blocked", "action" => "continue", "reason" => "dependency readiness not satisfied"
      }
      checkpoint, assertion = control_store_checkpoint_records(
        bundle, policy, records, "olcontrol_inc6amain", "olcheckpoint_inc6a_selection", selection,
        lead: task_records[6], unit: selected_unit)
      checkpoint["reconcile_trigger"] = {
        "event" => "dispatch_before", "reason" => "Selecting the first task before dispatch."
      }
      checkpoint["next_trigger"] = {
        "event" => "successor_before", "reason" => "Awaiting the dispatch successor boundary."
      }
      checkpoint["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(checkpoint)
      commit = lambda do |cp, as, extra = {}|
        store.checkpoint(checkpoint: cp, assertion: as, authority_verifier: vf[0],
          runtime_identity_verifier: vf[1], lifecycle_verifier: vf[2], **extra)
      end
      assert(commit.call(checkpoint, assertion) == :appended, "successor selection checkpoint appends")
      resolved = control_store_resolve(store, "olcontrol_inc6amain", vf)
      assert(resolved["checkpoints"].size == 1 &&
        resolved["checkpoints"].first["lead_checkpoint_id"] == "olcheckpoint_inc6a_selection",
        "resolve returns the accepted successor checkpoints")
      assert(commit.call(checkpoint, assertion) == :idempotent, "checkpoint replay idempotent")
      stale, stale_assertion = control_store_checkpoint_records(
        bundle, policy, records, "olcontrol_inc6amain", "olcheckpoint_inc6a_stale", selection,
        lead: task_records[6], unit: selected_unit)
      expect_contract_error("control_store_checkpoint_invalid") { commit.call(stale, stale_assertion) }
      second, second_assertion = control_store_checkpoint_records(
        bundle, policy, records, "olcontrol_inc6amain", "olcheckpoint_inc6a_second", selection,
        lead: task_records[6], unit: selected_unit, predecessor_checkpoint: checkpoint)
      second["reconcile_trigger"] = {
        "event" => "successor_before", "reason" => "Observing the successor boundary."
      }
      second["next_trigger"] = {
        "event" => "successor_before", "reason" => "Awaiting a later successor boundary."
      }
      second["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(second)
      assert(commit.call(second, second_assertion) == :appended, "successor extends the accepted tip")
      borrowed = OrbitV2FixtureFactory.deep_copy(checkpoint)
      borrowed.dig("lead_decision")["reason"] = "different content"
      borrowed["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(borrowed)
      expect_contract_error("control_store_reuse") { commit.call(borrowed, assertion) }
      no_selection, no_selection_assertion = control_store_checkpoint_records(
        bundle, policy, records, "olcontrol_inc6amain", "olcheckpoint_inc6a_noselection",
        { "state" => "blocked", "action" => "dispatch", "reason" => "dispatch without selection" },
        lead: task_records[6])
      no_selection["active_task_ref"] = nil
      no_selection["selected_work_unit_ref"] = nil
      no_selection["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(no_selection)
      expect_contract_error("control_store_checkpoint_invalid") { commit.call(no_selection, no_selection_assertion) }
      transition, transition_assertion, prior_session, successor, transitioned_agent =
        control_store_session_transition(bundle, policy, records, "olcontrol_inc6amain",
          "olcheckpoint_inc6a_transition",
          { "state" => "blocked", "action" => "continue", "reason" => "same-lineage session binding accepted" },
          lead: task_records[6], unit: selected_unit, predecessor_checkpoint: second)
      transition["reconcile_trigger"] = {
        "event" => "session_change", "reason" => "Replacing the active LeadSession."
      }
      transition["next_trigger"] = {
        "event" => "successor_before", "reason" => "Awaiting the next successor boundary."
      }
      transition["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(transition)
      mutated_session = OrbitV2FixtureFactory.deep_copy(prior_session)
      mutated_session["durable_context_ref"] = "artifact://other-context"
      expect_contract_error("control_store_checkpoint_invalid") do
        commit.call(transition, transition_assertion,
          prior_session: mutated_session, session: successor, agent: transitioned_agent)
      end
      mutated_agent = OrbitV2FixtureFactory.deep_copy(transitioned_agent)
      mutated_agent.dig("capability_profile")["profile_id"] = "capability-profile:replacement"
      expect_contract_error("control_store_checkpoint_invalid") do
        commit.call(transition, transition_assertion,
          prior_session: prior_session, session: successor, agent: mutated_agent)
      end
      assert(commit.call(transition, transition_assertion,
        prior_session: prior_session, session: successor, agent: transitioned_agent) == :appended,
        "session successor/termination form appends")
      transitioned = control_store_resolve(store, "olcontrol_inc6amain", vf)
      assert(transitioned["checkpoints"].size == 3 &&
        transitioned.dig("checkpoint", "lead_checkpoint_id") == "olcheckpoint_inc6a_transition" &&
        transitioned.dig("session", "lead_session_id") == "oleadsession_inc6asuccessor",
        "resolve returns the transition as the current checkpoint/session tip")
      assert(commit.call(transition, transition_assertion,
        prior_session: prior_session, session: successor, agent: transitioned_agent) == :idempotent,
        "session transition replay is idempotent after full verification")
      assert(store.records.size == 4, "rejected checkpoints and replays leave the store unchanged")
    end
  end

  def test_control_store_lineage_fail_closed
    Dir.mktmpdir do |dir|
      bundle = OrbitV2FixtureFactory.valid_bundle
      store, _policy, task = control_store_seeded_root(dir, bundle)
      vf = control_verifiers
      path = File.join(dir, ".orbit", Orbit::V2::ControlStore::CONTROL_TRANSACTIONS_FILE)
      records = control_store_genesis_records(bundle, task, OrbitV2FixtureFactory.agent("oagent_inc4lead", "lead"),
        "olcontrol_inc4main", control_store_writer_assertion("olcontrol_inc4main"))
      payload = { "assertion" => records[4], "agent" => records[3], "checkpoint" => records[2],
        "registry" => records[0], "session" => records[1] }
      write_file = lambda do |tx_payload|
        record = { "schema_version" => "orbit-transaction-log-v1", "transaction_id" => "olcontrol_inc4main",
          "previous_tip_digest" => nil,
          "content_digest" => "sha256:#{Orbit::V2::CanonicalJSON.sha256(tx_payload)}",
          "payload" => tx_payload }
        File.write(path, Orbit::V2::CanonicalJSON.dump("schema_version" => "orbit-transaction-log-v1",
          "records" => [record], "file_digest" => "sha256:#{Orbit::V2::CanonicalJSON.sha256([record])}"))
      end
      resolve = lambda { control_store_resolve(store, "olcontrol_inc4main", vf) }
      unknown = OrbitV2FixtureFactory.deep_copy(payload)
      unknown["authority"] = "not-a-control-field"
      write_file.call(unknown)
      expect_contract_error("control_store_lineage_invalid") { resolve.call }
      expect_contract_error("control_store_genesis_invalid") do
        control_store_genesis(store, records, vf)
      end
      half = OrbitV2FixtureFactory.deep_copy(payload)
      half.delete("session")
      write_file.call(half)
      expect_contract_error("control_store_lineage_invalid") { resolve.call }
      broken = OrbitV2FixtureFactory.deep_copy(payload)
      broken["checkpoint"]["lead_runtime_subject_ref"] = "runtime-subject:someone-else"
      broken["checkpoint"]["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(broken["checkpoint"])
      write_file.call(broken)
      expect_contract_error("control_store_lineage_invalid") { resolve.call }
      non_increasing = OrbitV2FixtureFactory.deep_copy(payload)
      agent_events = non_increasing["agent"]["lifecycle_events"]
      agent_events << OrbitV2FixtureFactory.event("oevent_inc4lead_adv", "AgentContextAdvanced",
        agent_events[0]["event_digest"], "context_generation" => 2,
        "started_at" => agent_events[0]["recorded_at"], "status" => "active")
      write_file.call(non_increasing)
      expect_contract_error("control_store_lineage_invalid") { resolve.call }
      reused_id = OrbitV2FixtureFactory.deep_copy(payload)
      reused_id["agent"]["lifecycle_events"] = [OrbitV2FixtureFactory.event(
        payload.dig("session", "lifecycle_events", 0, "event_id"), "AgentCreated", nil,
        "role" => "lead", "context_generation" => 1,
        "started_at" => "2026-07-30T00:00:00Z", "status" => "active")]
      write_file.call(reused_id)
      expect_contract_error("control_store_lineage_invalid") { resolve.call }
    end
  end
  def task_store_genesis_records(bundle, task_id: nil, task_revision_id: nil,
                                 gate_id: nil, gate_lineage_id: nil,
                                 extra_gate: false, weak_gate: false)
    task = OrbitV2FixtureFactory.deep_copy(bundle["task_revisions"].first)
    policy = bundle["project_policy_revisions"].last
    task["project_policy_revision_ref"] = { "policy_revision_id" => policy["policy_revision_id"], "content_digest" => policy["content_digest"] }
    task["unresolved_finding_refs"] = []
    task["task_id"] = task_id if task_id
    task["task_revision_id"] = task_revision_id if task_revision_id
    task["gate_requirement_refs"] = [gate_id] if gate_id
    task["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(task)
    gates = bundle["gate_requirements"].map { |g| OrbitV2FixtureFactory.deep_copy(g) }
    if gate_id
      gates.each do |gate|
        gate["gate_requirement_id"] = gate_id
        gate["gate_lineage_id"] = gate_lineage_id
        gate["task_id"] = task["task_id"]
        gate["task_revision_id"] = task["task_revision_id"]
        gate["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(gate)
      end
    end
    units = bundle["work_units"].map { |u| OrbitV2FixtureFactory.deep_copy(u) }
    units.each { |u| u["authority_scope"]["authorization_record_refs"] = [] }
    theses = bundle["change_theses"].map { |t| OrbitV2FixtureFactory.deep_copy(t) }
    if task_id
      id_map = {}
      units.each_with_index { |u, i| id_map[u["work_unit_id"]] = "owu_inc5unit#{i + 1}" }
      units.each do |u|
        u["work_unit_id"] = id_map[u["work_unit_id"]]
        u["task_id"] = task_id
        u["task_revision_id"] = task["task_revision_id"]
        u["parent_work_unit_ref"] = u["parent_work_unit_ref"] && id_map[u["parent_work_unit_ref"]]
        u["depends_on_work_unit_refs"] = Array(u["depends_on_work_unit_refs"]).map { |d| id_map[d] }
        u["authority_scope"]["authorization_record_refs"] = []
      end
      theses.each_with_index do |t, i|
        t["change_thesis_id"] = "othesis_inc5unit#{i + 1}"
        t["task_id"] = task_id
        t["task_revision_id"] = task["task_revision_id"]
        t["work_unit_id"] = id_map[t["work_unit_id"]]
        t["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(t)
      end
      units.each do |u|
        thesis = theses.find { |t| t["work_unit_id"] == u["work_unit_id"] }
        u["initial_change_thesis_ref"] = { "change_thesis_id" => thesis["change_thesis_id"],
          "revision" => 1, "content_digest" => thesis["content_digest"] }
      end
    end
    if extra_gate || weak_gate
      extra = OrbitV2FixtureFactory.deep_copy(gates.first)
      extra["gate_requirement_id"] = "ogreq_inc5extragate"
      extra["gate_lineage_id"] = "ogline_inc5extragate"
      extra["task_id"] = task["task_id"]
      extra["task_revision_id"] = task["task_revision_id"]
      extra["kind"] = weak_gate ? gates.first["kind"] : "test"
      extra["protected"] = weak_gate
      extra["evidence_level"] = "mechanical_check" if weak_gate
      extra["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(extra)
      gates << extra
      task["gate_requirement_refs"] << extra["gate_requirement_id"]
      task["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(task)
    end
    assertions = []
    authorizations = []
    units.each do |unit|
      Array(unit.dig("authority_scope", "allowed_actions")).each do |action|
        built = OrbitV2FixtureFactory.work_authorization(unit, task, action)
        assertions << built["assertion"]
        authorizations << built["record"]
      end
    end
    lead = OrbitV2FixtureFactory.deep_copy(bundle["logical_leads"].first)
    lead["task_id"] = task["task_id"]
    lead["authority_scope_ref"] = policy["policy_revision_id"]
    lead["logical_lead_id"] = "olead_inc5#{task['task_id'].delete_prefix('otask_')}" if task_id
    lead["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(lead)
    [task, gates, units, theses, assertions, authorizations, lead]
  end

  def task_store_seeded_root(dir, bundle)
    FileUtils.mkdir_p(File.join(dir, ".orbit"))
    policy = bundle["project_policy_revisions"].first
    assertion = OrbitV2FixtureFactory.policy_issuance_assertion(policy, parent_policy: nil,
      assertion_id: "oassert_policygenesis", subject: "project-owner")
    Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit")).genesis(
      policy: policy, assertion: assertion,
      authority_verifier: OrbitV2FixtureFactory.authority_verifier)
    Orbit::V2::ProtocolRoot.create(project_root: dir, project_id: OrbitV2FixtureFactory::PROJECT_ID,
      policy_genesis_ref: { "policy_revision_id" => policy["policy_revision_id"], "content_digest" => policy["content_digest"] })
    [Orbit::V2::TaskStore.new(active_root: File.join(dir, ".orbit")), policy]
  end

  def task_store_genesis(store, records, verifier, overrides = {})
    store.genesis(task: records[0], gate_requirements: records[1], work_units: records[2],
      change_theses: records[3], authority_assertions: records[4], authorization_records: records[5],
      logical_lead: records[6], authority_verifier: overrides.fetch(:authority, verifier))
  end

  def task_store_resolve(store, task_id, verifier)
    store.resolve(task_id: task_id, authority_verifier: verifier)
  end

  def test_task_store_genesis
    assert(Orbit::V2::TaskStore.instance_methods(false).sort == %i[genesis records resolve],
      "TaskStore exposes exactly its three public seams")
    Dir.mktmpdir do |dir|
      bundle = OrbitV2FixtureFactory.valid_bundle
      store, _policy = task_store_seeded_root(dir, bundle)
      verifier = OrbitV2FixtureFactory.authority_verifier
      records = task_store_genesis_records(bundle)
      task_id = records[0]["task_id"]
      assert(task_store_genesis(store, records, verifier) == :appended, "atomic task genesis")
      assert(store.records.size == 1 &&
        store.records.first.keys.sort == %w[authority_assertions authorization_records change_theses gate_requirements logical_lead task work_units],
        "one closed payload")
      resolved = task_store_resolve(Orbit::V2::TaskStore.new(active_root: File.join(dir, ".orbit")), task_id, verifier)
      assert(resolved["task"]["task_id"] == task_id && resolved["gate_requirements"].size == 1 &&
        resolved["work_units"].size == 3 && resolved["change_theses"].size == 3 &&
        resolved["authorization_records"].size == 3 &&
        resolved["logical_lead"]["task_id"] == task_id, "reopen and resolve")
      assert(task_store_genesis(store, records, verifier) == :idempotent, "same-content replay")
      altered = OrbitV2FixtureFactory.deep_copy(records[0])
      altered.dig("quality_outcome")["user_problem"] = "different content"
      expect_contract_error("task_store_reuse") do
        store.genesis(task: altered, gate_requirements: records[1], work_units: records[2],
          change_theses: records[3], authority_assertions: records[4],
          authorization_records: records[5], logical_lead: records[6], authority_verifier: verifier)
      end
      expect_contract_error("task_store_argument_invalid") do
        store.genesis(task: records[0], gate_requirements: records[1], work_units: records[2],
          change_theses: records[3], authority_assertions: records[4],
          authorization_records: records[5], logical_lead: records[6], authority_verifier: nil)
      end
      expect_contract_error("task_store_argument_invalid") { store.genesis(task: { "task_id" => 42 }, gate_requirements: records[1], work_units: records[2], change_theses: records[3], authority_assertions: records[4], authorization_records: records[5], logical_lead: records[6], authority_verifier: verifier) }
      expect_contract_error("task_store_genesis_invalid") { task_store_genesis(store, records, Orbit::V2::AuthorityVerifier.new) }
      assert(store.records.size == 1, "invalid authority left the store unchanged")
    end
  end

  def test_task_store_lineage_fail_closed
    Dir.mktmpdir do |dir|
      bundle = OrbitV2FixtureFactory.valid_bundle
      store, policy = task_store_seeded_root(dir, bundle)
      verifier = OrbitV2FixtureFactory.authority_verifier
      records = task_store_genesis_records(bundle)
      task_id = records[0]["task_id"]
      path = File.join(dir, ".orbit", Orbit::V2::TaskStore::TASK_DEFINITIONS_FILE)
      payload = { "authority_assertions" => records[4], "authorization_records" => records[5],
        "change_theses" => records[3], "gate_requirements" => records[1],
        "logical_lead" => records[6], "task" => records[0], "work_units" => records[2] }
      write_file = lambda do |tx_payload|
        record = { "schema_version" => "orbit-transaction-log-v1", "transaction_id" => task_id,
          "previous_tip_digest" => nil,
          "content_digest" => "sha256:#{Orbit::V2::CanonicalJSON.sha256(tx_payload)}",
          "payload" => tx_payload }
        File.write(path, Orbit::V2::CanonicalJSON.dump("schema_version" => "orbit-transaction-log-v1",
          "records" => [record], "file_digest" => "sha256:#{Orbit::V2::CanonicalJSON.sha256([record])}"))
      end
      resolve = lambda { task_store_resolve(store, task_id, verifier) }
      unknown = OrbitV2FixtureFactory.deep_copy(payload)
      unknown["authority"] = "not-a-task-field"
      write_file.call(unknown)
      expect_contract_error("task_store_lineage_invalid") { resolve.call }
      expect_contract_error("task_store_genesis_invalid") { task_store_genesis(store, records, verifier) }
      half = OrbitV2FixtureFactory.deep_copy(payload)
      half.delete("work_units")
      write_file.call(half)
      expect_contract_error("task_store_lineage_invalid") { resolve.call }
      malformed = OrbitV2FixtureFactory.deep_copy(payload)
      malformed["gate_requirements"] = [42]
      write_file.call(malformed)
      expect_contract_error("task_store_lineage_invalid") { resolve.call }
      cycle = OrbitV2FixtureFactory.deep_copy(payload)
      cycle["work_units"][0]["parent_work_unit_ref"] = "owu_implementationtwo"
      cycle["work_units"][1]["parent_work_unit_ref"] = "owu_implementationone"
      cycle["work_units"].each { |u| u["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(u) }
      write_file.call(cycle)
      expect_contract_error("task_store_lineage_invalid") { resolve.call }
      misplaced = OrbitV2FixtureFactory.deep_copy(payload)
      misplaced["work_units"][0]["task_id"] = "otask_someoneelses"
      misplaced["work_units"][0]["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(misplaced["work_units"][0])
      write_file.call(misplaced)
      expect_contract_error("task_store_lineage_invalid") { resolve.call }
      wrong_lead = OrbitV2FixtureFactory.deep_copy(payload)
      wrong_lead["logical_lead"]["task_id"] = "otask_someoneelses"
      wrong_lead["logical_lead"]["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(wrong_lead["logical_lead"])
      write_file.call(wrong_lead)
      expect_contract_error("task_store_lineage_invalid") { resolve.call }
      wrong_scope = OrbitV2FixtureFactory.deep_copy(payload)
      wrong_scope["logical_lead"]["authority_scope_ref"] = "opolicy_someoneelses"
      wrong_scope["logical_lead"]["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(wrong_scope["logical_lead"])
      write_file.call(wrong_scope)
      expect_contract_error("task_store_lineage_invalid") { resolve.call }
      bad_context = OrbitV2FixtureFactory.deep_copy(payload)
      bad_context["logical_lead"]["durable_context_ref"] = "not-an-artifact-uri"
      bad_context["logical_lead"]["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(bad_context["logical_lead"])
      write_file.call(bad_context)
      expect_contract_error("task_store_lineage_invalid") { resolve.call }
      write_file.call(payload)
      assert(resolve.call["task"]["task_id"] == task_id, "valid log restored")
      successor, successor_assertion = policy_store_successor_pair(policy, "opolicy_rotated0002", "oassert_policyrotated")
      assert(Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit")).rotate(
        policy: successor, assertion: successor_assertion, authority_verifier: verifier) == :appended, "policy rotates")
      assert(task_store_genesis(store, records, verifier) == :idempotent,
        "committed replay stays idempotent after rotation")
      stale = task_store_genesis_records(bundle, task_id: "otask_inc5stale",
        task_revision_id: "trev_inc5stale_r1", gate_id: "ogreq_inc5stale", gate_lineage_id: "ogline_inc5stale")
      expect_contract_error("task_store_genesis_invalid") do
        task_store_genesis(store, stale, verifier)
      end
      fresh_bundle = OrbitV2FixtureFactory.deep_copy(bundle)
      fresh_bundle["project_policy_revisions"] = [successor]
      weak = task_store_genesis_records(fresh_bundle, task_id: "otask_inc5weak",
        task_revision_id: "trev_inc5weak_r1", gate_id: "ogreq_inc5weak", gate_lineage_id: "ogline_inc5weak",
        weak_gate: true)
      expect_contract_error("task_store_genesis_invalid") do
        task_store_genesis(store, weak, verifier)
      end
      extra = task_store_genesis_records(fresh_bundle, task_id: "otask_inc5extra",
        task_revision_id: "trev_inc5extra_r1", gate_id: "ogreq_inc5extra", gate_lineage_id: "ogline_inc5extra",
        extra_gate: true)
      assert(task_store_genesis(store, extra, verifier) == :appended,
        "unrelated additional legal gates remain allowed")
    end
  end

  def test_task_store_cross_transaction
    Dir.mktmpdir do |dir|
      bundle = OrbitV2FixtureFactory.valid_bundle
      store, _policy = task_store_seeded_root(dir, bundle)
      verifier = OrbitV2FixtureFactory.authority_verifier
      records = task_store_genesis_records(bundle)
      assert(task_store_genesis(store, records, verifier) == :appended, "first task")
      borrowed_gate = task_store_genesis_records(bundle, task_id: "otask_inc5second",
        task_revision_id: "trev_inc5second_r1")
      expect_contract_error("task_store_genesis_invalid") { task_store_genesis(store, borrowed_gate, verifier) }
      borrowed_thesis = task_store_genesis_records(bundle, task_id: "otask_inc5third",
        task_revision_id: "trev_inc5third_r1", gate_id: "ogreq_inc5third", gate_lineage_id: "ogline_inc5third")
      borrowed_thesis[3].each_with_index do |thesis, index|
        thesis["change_thesis_id"] = records[3][index]["change_thesis_id"]
        thesis["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(thesis)
      end
      expect_contract_error("task_store_genesis_invalid") { task_store_genesis(store, borrowed_thesis, verifier) }
      disjoint = task_store_genesis_records(bundle, task_id: "otask_inc5fourth",
        task_revision_id: "trev_inc5fourth_r1", gate_id: "ogreq_inc5fourth", gate_lineage_id: "ogline_inc5fourth")
      assert(task_store_genesis(store, disjoint, verifier) == :appended &&
        task_store_resolve(store, "otask_inc5fourth", verifier)["task"]["task_id"] == "otask_inc5fourth" &&
        store.records.size == 2, "disjoint second task accepted and resolves; borrowed ids never committed")
    end
  end

  def test_task_store_concurrency
    Dir.mktmpdir do |dir|
      bundle = OrbitV2FixtureFactory.valid_bundle
      store, _policy = task_store_seeded_root(dir, bundle)
      verifier = OrbitV2FixtureFactory.authority_verifier
      records = task_store_genesis_records(bundle)
      second = OrbitV2FixtureFactory.deep_copy(records[0])
      second.dig("quality_outcome")["user_problem"] = "different content"
      second["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(second)
      out_r, out_w = IO.pipe
      pids = [records, [second, records[1], records[2], records[3], records[4], records[5], records[6]]].map do |candidate|
        fork do
          out_r.close
          begin
            out_w.write("#{task_store_genesis(Orbit::V2::TaskStore.new(active_root: File.join(dir, ".orbit")), candidate, verifier)}\n")
          rescue Orbit::V2::ContractError => error
            out_w.write("error:#{error.code}\n")
          end
          out_w.close
          exit!(0)
        end
      end
      out_w.close
      outcomes = out_r.read.split("\n").sort
      out_r.close
      pids.each { |pid| Process.wait(pid) }
      assert(outcomes == %w[appended error:task_store_reuse] && store.records.size == 1,
        "concurrent same-task genesis yields exactly one accepted transaction")
      signal_r, signal_w = IO.pipe
      release_r, release_w = IO.pipe
      race = task_store_genesis_records(bundle, task_id: "otask_inc5race",
        task_revision_id: "trev_inc5race_r1", gate_id: "ogreq_inc5race", gate_lineage_id: "ogline_inc5race")
      genesis_pid = fork do
        task_store_genesis(Orbit::V2::TaskStore.new(active_root: File.join(dir, ".orbit")),
          race, BlockingAuthorityVerifier.new(verifier, signal_w, release_r))
        exit!(0)
      end
      signal_w.close
      release_r.close
      signal_r.read(1)
      signal_r.close
      policy = bundle["project_policy_revisions"].first
      successor, successor_assertion = policy_store_successor_pair(policy, "opolicy_rotated0002", "oassert_policyrotated")
      rotation_pid = fork do
        Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit")).rotate(
          policy: successor, assertion: successor_assertion, authority_verifier: verifier)
        exit!(0)
      end
      sleep 0.3
      assert(Process.waitpid(rotation_pid, Process::WNOHANG).nil?,
        "rotation cannot commit inside the task genesis lock window")
      release_w.write("g")
      release_w.close
      assert(Process.wait2(genesis_pid).last.success?, "genesis completed")
      assert(Process.wait2(rotation_pid).last.success?, "rotation completed after the window")
      assert(task_store_resolve(store, "otask_inc5race", verifier)
        .dig("task", "project_policy_revision_ref", "policy_revision_id") ==
        policy["policy_revision_id"], "task pinned the policy active inside its locked window")
      assert(Orbit::V2::PolicyStore.new(active_root: File.join(dir, ".orbit")).resolve(
        pinned_genesis_ref: { "policy_revision_id" => policy["policy_revision_id"], "content_digest" => policy["content_digest"] },
        authority_verifier: verifier)["active_policy"]["policy_revision_id"] == "opolicy_rotated0002",
        "rotation then completes after the task window")
    end
  end
  def test_protocol_root_preflight
    Dir.mktmpdir do |dir|
      store, policy, = policy_store_seeded_root(dir)
      genesis_ref = {
        "policy_revision_id" => policy["policy_revision_id"],
        "content_digest" => policy["content_digest"]
      }
      verifier = OrbitV2FixtureFactory.authority_verifier
      assert(
        Orbit::V2::ProtocolRoot.create(
          project_root: dir,
          project_id: OrbitV2FixtureFactory::PROJECT_ID,
          policy_genesis_ref: genesis_ref
        ) == :created,
        "marker pins the durable genesis"
      )
      valid_marker_bytes = File.binread(File.join(dir, ".orbit", "protocol.yaml"))
      expected_active_root = File.join(File.realpath(dir), ".orbit")

      # Success: preflight resolves the pinned genesis from the durable
      # policy store itself — caller-supplied policy/assertion hashes are
      # never the source of truth — and returns the canonical real parent
      # directory of the marker.
      assert(
        protocol_root_preflight(dir, verifier) == expected_active_root,
        "preflight resolves the pinned genesis from the durable store"
      )

      # The same physical marker addressed through a symlink alias of the
      # project root resolves to the IDENTICAL active root, never two.
      alias_root = File.join(dir, "alias-project-root")
      File.symlink(File.expand_path(dir), alias_root)
      assert(
        protocol_root_preflight(alias_root, verifier) == expected_active_root,
        "real path and symlink alias resolve to the same canonical active root"
      )
      File.delete(alias_root)

      # A pre-existing .orbit symlink to a sibling directory fails closed
      # BEFORE any file access: create and read both reject with
      # path_invalid, the outside directory receives no marker/lock/staging
      # bytes, and restoring a real in-root .orbit restores normal
      # create/read/preflight.
      outside_orbit = File.join(dir, "outside-orbit")
      FileUtils.mkdir_p(outside_orbit)
      FileUtils.mv(
        File.join(dir, ".orbit"),
        File.join(dir, ".orbit.real")
      )
      File.symlink(outside_orbit, File.join(dir, ".orbit"))
      expect_contract_error("protocol_root_path_invalid") do
        Orbit::V2::ProtocolRoot.create(
          project_root: dir,
          project_id: "oproj_slice0other",
          policy_genesis_ref: {
            "policy_revision_id" => policy["policy_revision_id"],
            "content_digest" => "sha256:#{'d' * 64}"
          }
        )
      end
      expect_contract_error("protocol_root_path_invalid") do
        Orbit::V2::ProtocolRoot.read(project_root: dir)
      end
      expect_contract_error("protocol_root_path_invalid") do
        protocol_root_preflight(dir, verifier)
      end
      assert(
        Dir.children(outside_orbit).empty?,
        "outside .orbit received no marker, lock, or staging entries"
      )
      assert(
        File.file?(File.join(dir, ".orbit.real", "protocol.yaml")),
        "the real in-root marker was preserved untouched"
      )
      File.delete(File.join(dir, ".orbit"))
      FileUtils.mv(
        File.join(dir, ".orbit.real"),
        File.join(dir, ".orbit")
      )
      assert(
        Orbit::V2::ProtocolRoot.create(
          project_root: dir,
          project_id: OrbitV2FixtureFactory::PROJECT_ID,
          policy_genesis_ref: {
            "policy_revision_id" => policy["policy_revision_id"],
            "content_digest" => policy["content_digest"]
          }
        ) == :idempotent,
        "create is valid again after restoring the real in-root .orbit"
      )
      assert(
        Orbit::V2::ProtocolRoot.read(project_root: dir)["project_id"] ==
          OrbitV2FixtureFactory::PROJECT_ID,
        "read is valid again after restoring the real in-root .orbit"
      )
      assert(
        protocol_root_preflight(dir, verifier) == expected_active_root,
        "preflight is valid again after restoring the real in-root .orbit"
      )

      # Missing marker, wrong project, wrong epoch.
      expect_contract_error("protocol_root_missing") do
        protocol_root_preflight(File.join(dir, "absent"), verifier)
      end
      expect_contract_error("protocol_root_project_mismatch") do
        protocol_root_preflight(dir, verifier, project_id: "oproj_slice0other")
      end
      wrong_epoch = OrbitV2FixtureFactory.deep_copy(
        Orbit::V2::ProtocolRoot.read(project_root: dir)
      )
      wrong_epoch["protocol_epoch"] = "orbit-v1"
      wrong_epoch["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(wrong_epoch)
      File.write(
        File.join(dir, ".orbit", "protocol.yaml"),
        YAML.dump(wrong_epoch)
      )
      expect_contract_error("protocol_root_epoch_mismatch") do
        protocol_root_preflight(dir, verifier)
      end
      File.write(File.join(dir, ".orbit", "protocol.yaml"), valid_marker_bytes)

      # Forged marker pin: the marker pins a genesis id+digest the durable
      # store does not hold, so preflight fails closed.
      forged_ref = {
        "policy_revision_id" => policy["policy_revision_id"],
        "content_digest" => "sha256:#{'f' * 64}"
      }
      forged_dir = File.join(dir, "forged")
      policy_store_seeded_root(forged_dir)
      Orbit::V2::ProtocolRoot.create(
        project_root: forged_dir,
        project_id: OrbitV2FixtureFactory::PROJECT_ID,
        policy_genesis_ref: forged_ref
      )
      expect_contract_error("protocol_root_genesis_invalid") do
        protocol_root_preflight(forged_dir, verifier)
      end

      # Marker without a policy store: the pinned genesis is missing.
      nostore_dir = File.join(dir, "no-store")
      FileUtils.mkdir_p(File.join(nostore_dir, ".orbit"))
      Orbit::V2::ProtocolRoot.create(
        project_root: nostore_dir,
        project_id: OrbitV2FixtureFactory::PROJECT_ID,
        policy_genesis_ref: genesis_ref
      )
      expect_contract_error("protocol_root_genesis_invalid") do
        protocol_root_preflight(nostore_dir, verifier)
      end

      # Unreferenced durable genesis without a marker is never selected:
      # preflight fails with a missing marker, not a resolved trust root.
      nomarker_dir = File.join(dir, "no-marker")
      policy_store_seeded_root(nomarker_dir)
      expect_contract_error("protocol_root_missing") do
        protocol_root_preflight(nomarker_dir, verifier)
      end

      # Cross-project genesis: a fully valid durable genesis for project B
      # pinned by a marker claiming project A must fail the exact project
      # binding, never be accepted as A's genesis.
      policy_b, assertion_b = policy_store_other_project_genesis_pair
      cross_dir = File.join(dir, "cross-project")
      FileUtils.mkdir_p(File.join(cross_dir, ".orbit"))
      Orbit::V2::PolicyStore.new(active_root: File.join(cross_dir, ".orbit")).genesis(
        policy: policy_b,
        assertion: assertion_b,
        authority_verifier: verifier
      )
      Orbit::V2::ProtocolRoot.create(
        project_root: cross_dir,
        project_id: "oproj_slice0fixture",
        policy_genesis_ref: {
          "policy_revision_id" => policy_b["policy_revision_id"],
          "content_digest" => policy_b["content_digest"]
        }
      )
      expect_contract_error("protocol_root_genesis_invalid") do
        protocol_root_preflight(cross_dir, verifier)
      end

      # An unconfigured verifier fails closed: stored assertions cannot be
      # provider-verified, so no trust root resolves.
      expect_contract_error("protocol_root_genesis_invalid") do
        protocol_root_preflight(dir, Orbit::V2::AuthorityVerifier.new)
      end

      # Mixed active root fails preflight even with a valid marker+store.
      File.write(File.join(dir, ".orbit", "loop-state.yaml"), "state: v1\n")
      expect_contract_error("protocol_root_mixed_epoch") do
        protocol_root_preflight(dir, verifier)
      end
    end
  end

  def test_protocol_root_concurrent_creators
    Dir.mktmpdir do |dir|
      genesis_ref = {
        "policy_revision_id" => "opolicy_genesis0001",
        "content_digest" => "sha256:#{'a' * 64}"
      }
      ready_r, ready_w = IO.pipe
      go_r, go_w = IO.pipe
      out_r, out_w = IO.pipe
      pids = 2.times.map do
        fork do
          ready_r.close
          go_w.close
          out_r.close
          ready_w.write("r")
          ready_w.close
          go_r.read(1)
          begin
            result = Orbit::V2::ProtocolRoot.create(
              project_root: dir,
              project_id: "oproj_slice0fixture",
              policy_genesis_ref: genesis_ref
            )
            out_w.write("#{result}\n")
          rescue StandardError => error
            out_w.write("error:#{error.class}\n")
          end
          out_w.close
          exit!(0)
        end
      end
      ready_w.close
      go_r.close
      out_w.close
      2.times { ready_r.read(1) }
      ready_r.close
      2.times { go_w.write("g") }
      go_w.close
      outcomes = out_r.read.split("\n").sort
      out_r.close
      pids.each { |pid| Process.wait(pid) }
      assert(
        outcomes == %w[created idempotent],
        "competing creators serialize to exactly one durable marker, got #{outcomes.inspect}"
      )
      assert(
        Orbit::V2::ProtocolRoot.read(project_root: dir)["project_id"] == "oproj_slice0fixture",
        "the single committed marker is readable"
      )
      assert(
        Dir.glob(File.join(dir, ".orbit", "protocol.yaml*")).grep_v(/\.lock\z/).size == 1,
        "exactly one marker file exists, no orphaned staging truth"
      )
    end
  end

  def test_eighth_review_regressions
    empty_authority = OrbitV2FixtureFactory.valid_bundle
    empty_authority.fetch("work_units").each do |unit|
      unit.dig("authority_scope", "authorization_record_refs").clear
      rehash(unit)
    end
    empty_authority.fetch("work_unit_attempts").each do |attempt|
      creation = attempt.dig("events", 0)
      creation.dig(
        "assignment",
        "authority_snapshot",
        "authorization_record_refs"
      ).clear
      OrbitV2FixtureFactory.resign_event(creation)
    end
    refresh_all_evaluation_subjects(empty_authority)
    evaluation = empty_authority.fetch("gate_evaluations").first
    evaluation["verdict"] = "pass"
    evaluation["quality_outcome_verdict"] = "pass"
    evaluation["quality_question_answers"].each { |answer| answer["verdict"] = "pass" }
    evaluation["acceptance_results"].each { |answer| answer["verdict"] = "pass" }
    rehash(evaluation)
    codes = validator.validate(empty_authority).map(&:code)
    assert(
      codes.include?("contract_shape_invalid"),
      "executable WorkUnits and Attempts cannot self-authorize with empty record refs"
    )

    duplicate_runtime = OrbitV2FixtureFactory.valid_bundle
    producer = duplicate_runtime.fetch("agent_instances").find do |agent|
      agent["agent_instance_id"] == "oagent_implementerone"
    end
    reviewer = duplicate_runtime.fetch("agent_instances").find do |agent|
      agent["agent_instance_id"] == "oagent_independentreviewer"
    end
    reviewer["runtime_identity"] =
      OrbitV2FixtureFactory.deep_copy(producer.fetch("runtime_identity"))
    codes = validator.validate(duplicate_runtime).map(&:code)
    assert(
      codes.include?("runtime_identity_receipt_invalid"),
      "runtime identity receipts bind the exact AgentInstance ID"
    )
    OrbitV2FixtureFactory.resign_runtime_identity(reviewer)
    codes = validator.validate(duplicate_runtime).map(&:code)
    assert(
      codes.include?("runtime_identity_duplicate") &&
        codes.include?("independence_violation"),
      "a freshly verified duplicate runtime subject cannot self-review through a new ID"
    )

    empty_implementation = OrbitV2FixtureFactory.valid_bundle
    empty_implementation.fetch("evidence_records").each do |record|
      next unless record["record_kind"] == "implementation"

      record.fetch("implementation_check")["changed_paths"] = []
      record.fetch("implementation_check")["verification_refs"] = []
      rehash(record)
    end
    refresh_evaluation_subject(empty_implementation)
    evaluation = empty_implementation.fetch("gate_evaluations").first
    evaluation["quality_question_answers"].each do |answer|
      answer["verdict"] = "pass"
      answer["evidence_record_refs"] = []
    end
    evaluation["acceptance_results"].each do |answer|
      answer["verdict"] = "pass"
      answer["evidence_record_refs"] = []
    end
    evaluation["verdict"] = "pass"
    evaluation["quality_outcome_verdict"] = "pass"
    rehash(evaluation)
    assert(
      validator.validate(empty_implementation).map(&:code).include?(
        "contract_shape_invalid"
      ),
      "PASS cannot cite empty implementation changes, verification, or answer evidence"
    )

    incompatible_kind = OrbitV2FixtureFactory.valid_bundle
    unit = incompatible_kind.fetch("work_units").find do |candidate|
      candidate["work_unit_id"] == "owu_implementationone"
    end
    unit["work_unit_kind"] = "research"
    rehash(unit)
    refresh_evaluation_subject(incompatible_kind)
    assert(
      validator.validate(incompatible_kind).map(&:code).include?(
        "attempt_assignment_invalid"
      ),
      "WorkUnit kind must be compatible with Attempt purpose"
    )

    terminated_agent = OrbitV2FixtureFactory.valid_bundle
    reviewer = terminated_agent.fetch("agent_instances").find do |agent|
      agent["agent_instance_id"] == "oagent_independentreviewer"
    end
    reviewer["lifecycle_events"] << OrbitV2FixtureFactory.event(
      "oevent_reviewerterminatedearly",
      "AgentTerminated",
      reviewer.fetch("lifecycle_events").last.fetch("event_digest"),
      "ended_at" => "2026-07-30T00:00:30Z",
      "status" => "retired"
    )
    assert(
      validator.validate(terminated_agent).map(&:code).include?(
        "attempt_agent_lifecycle_invalid"
      ),
      "AttemptCreated requires an active AgentInstance at the trusted creation time"
    )

    future_context = OrbitV2FixtureFactory.valid_bundle
    reviewer = future_context.fetch("agent_instances").find do |agent|
      agent["agent_instance_id"] == "oagent_independentreviewer"
    end
    reviewer["lifecycle_events"] << OrbitV2FixtureFactory.event(
      "oevent_reviewercontextafterattempt",
      "AgentContextAdvanced",
      reviewer.fetch("lifecycle_events").last.fetch("event_digest"),
      "context_generation" => 2,
      "recorded_at" => "2026-07-30T00:04:00Z",
      "reason" => "Context was created after the Attempt."
    )
    attempt = future_context.fetch("work_unit_attempts").find do |candidate|
      candidate["attempt_id"] == "oattempt_independentreview"
    end
    creation = attempt.dig("events", 0)
    creation.dig("assignment")["context_generation"] = 2
    old_rule = future_context.fetch("rule_resolution_artifacts").find do |artifact|
      artifact.dig("identity", "attempt_id") == attempt["attempt_id"]
    end
    identity = OrbitV2FixtureFactory.deep_copy(old_rule.fetch("identity"))
    identity["context_generation"] = 2
    new_rule = Orbit::V2::RuleResolution.build(
      identity,
      created_at: old_rule.dig("envelope", "created_at"),
      project_root: ROOT
    )
    future_context["rule_resolution_artifacts"][
      future_context["rule_resolution_artifacts"].index(old_rule)
    ] = new_rule
    creation.dig("assignment")["assigned_rule_resolution_id"] =
      new_rule["resolution_id"]
    OrbitV2FixtureFactory.resign_event(creation)
    submission = future_context.fetch("evidence_records").find do |record|
      record["attempt_id"] == attempt["attempt_id"]
    end
    submission["submitted_rule_resolution_id"] = new_rule["resolution_id"]
    rehash(submission)
    refresh_all_evaluation_subjects(future_context)
    assert(
      validator.validate(future_context).map(&:code).include?(
        "attempt_agent_lifecycle_invalid"
      ),
      "Attempt context generation must exist no later than AttemptCreated"
    )

    positive = OrbitV2FixtureFactory.valid_bundle
    assert(
      positive.fetch("work_units").all? do |unit|
        Array(unit.dig("authority_scope", "authorization_record_refs")).any?
      end &&
        positive.fetch("work_unit_attempts").all? do |attempt|
          Array(
            attempt.dig(
              "events",
              0,
              "assignment",
              "authority_snapshot",
              "authorization_record_refs"
            )
          ).any?
        end,
      "valid WorkUnits and Attempts carry non-empty exact authority provenance"
    )
    assert(
      positive.fetch("work_unit_attempts").all? do |attempt|
        purpose = attempt.dig("events", 0, "assignment", "purpose")
        unit = positive.fetch("work_units").find do |candidate|
          candidate["work_unit_id"] == attempt["work_unit_id"]
        end
        Orbit::V2::WorkAuthority.purpose_allowed_for_kind?(
          purpose,
          unit["work_unit_kind"]
        )
      end,
      "valid Attempt purposes match their WorkUnit kinds"
    )
    assert(
      positive.fetch("evidence_records").select do |record|
        record["record_kind"] == "implementation"
      end.all? do |record|
        implementation_check = record.fetch("implementation_check")
        Array(implementation_check["changed_paths"]).any? &&
          Array(implementation_check["verification_refs"]).any? &&
          Array(record["submission_artifact_refs"]).any? &&
          Array(implementation_check["acceptance_results"]).any? &&
          Array(implementation_check["evidence_requirement_results"]).any?
      end,
      "valid implementation evidence carries complete scope, result, and artifact proof"
    )
  end

  def test_evidence_reference_and_path_scope_regressions
    artifact_ref = lambda do |claim|
      {
        "artifact_ref" => claim.fetch("artifact_ref"),
        "content_digest" => claim.fetch("content_digest")
      }
    end
    cases = [
      {
        "id" => "missing",
        "expected" => "contract_shape_invalid",
        "structural" => false,
        "mutate" => lambda do |record, _change, _verification|
          record.fetch("implementation_check").delete("verification_refs")
        end
      },
      {
        "id" => "empty",
        "expected" => "contract_shape_invalid",
        "structural" => false,
        "mutate" => lambda do |record, _change, _verification|
          record.fetch("implementation_check")["verification_refs"] = []
        end
      },
      {
        "id" => "phantom",
        "expected" => "evidence_reference_invalid",
        "structural" => true,
        "mutate" => lambda do |record, _change, _verification|
          phantom = {
            "artifact_ref" => "artifact://phantom/unresolvable",
            "content_digest" => OrbitV2FixtureFactory.digest_for("phantom-artifact")
          }
          record.dig("implementation_check", "scope_match")["evidence_refs"] =
            [phantom]
        end
      },
      {
        "id" => "wrong-kind",
        "expected" => "evidence_reference_invalid",
        "structural" => true,
        "mutate" => lambda do |record, change, _verification|
          record.fetch("implementation_check")["verification_refs"] =
            [artifact_ref.call(change)]
        end
      },
      {
        "id" => "stale-digest",
        "expected" => "evidence_reference_invalid",
        "structural" => true,
        "mutate" => lambda do |record, _change, verification|
          stale = artifact_ref.call(verification)
          stale["content_digest"] = OrbitV2FixtureFactory.digest_for("stale")
          record.fetch("implementation_check")["verification_refs"] = [stale]
        end
      },
      {
        "id" => "verification-claim-path",
        "expected" => "evidence_reference_invalid",
        "exact" => true,
        "structural" => true,
        "mutate" => lambda do |_record, _change, verification|
          verification["paths"] = ["lib/orbit/v2/validator.rb"]
        end
      },
      {
        "id" => "duplicate-identity",
        "expected" => "evidence_reference_invalid",
        "structural" => true,
        "mutate" => lambda do |record, change, _verification|
          duplicate = OrbitV2FixtureFactory.deep_copy(change)
          duplicate["content_digest"] = OrbitV2FixtureFactory.digest_for("other-bytes")
          record.fetch("submission_artifact_refs") << duplicate
        end
      },
      {
        "id" => "noncanonical-order",
        "expected" => "evidence_reference_invalid",
        "structural" => true,
        "mutate" => lambda do |record, _change, _verification|
          record.fetch("submission_artifact_refs").reverse!
        end
      },
      {
        "id" => "unauthorized-path",
        "expected" => "implementation_path_unauthorized",
        "structural" => true,
        "mutate" => lambda do |record, change, _verification|
          path = "contracts/orbit-v2/contract.yaml"
          change["paths"] = [path]
          record.fetch("implementation_check")["changed_paths"] = [path]
        end
      },
      {
        "id" => "unproven-path",
        "expected" => "implementation_path_unauthorized",
        "structural" => true,
        "mutate" => lambda do |record, _change, _verification|
          record.fetch("implementation_check")["changed_paths"] = [
            "lib/orbit/v2/evidence_contract.rb"
          ]
        end
      },
      {
        "id" => "absolute-path",
        "expected" => "implementation_path_unauthorized",
        "structural" => true,
        "mutate" => lambda do |record, change, _verification|
          path = "/lib/orbit/v2/validator.rb"
          change["paths"] = [path]
          record.fetch("implementation_check")["changed_paths"] = [path]
        end
      },
      {
        "id" => "traversal-path",
        "expected" => "implementation_path_unauthorized",
        "structural" => true,
        "mutate" => lambda do |record, change, _verification|
          path = "lib/orbit/v2/../v1.rb"
          change["paths"] = [path]
          record.fetch("implementation_check")["changed_paths"] = [path]
        end
      },
      {
        "id" => "empty-segment",
        "expected" => "implementation_path_unauthorized",
        "structural" => true,
        "mutate" => lambda do |record, change, _verification|
          path = "lib//orbit/v2.rb"
          change["paths"] = [path]
          record.fetch("implementation_check")["changed_paths"] = [path]
        end
      },
      {
        "id" => "prefix-trap",
        "expected" => "implementation_path_unauthorized",
        "structural" => true,
        "mutate" => lambda do |record, change, _verification|
          path = "lib/orbit/v20/not-v2.rb"
          change["paths"] = [path]
          record.fetch("implementation_check")["changed_paths"] = [path]
        end
      }
    ]

    cases.each do |item|
      bundle = OrbitV2FixtureFactory.valid_bundle
      record = bundle.fetch("evidence_records").find do |candidate|
        candidate["work_unit_id"] == "owu_implementationone"
      end
      claims = record.fetch("submission_artifact_refs")
      change = claims.find { |claim| claim["artifact_kind"] == "change" }
      verification = claims.find do |claim|
        claim["artifact_kind"] == "verification"
      end
      item.fetch("mutate").call(record, change, verification)
      rehash(record)
      refresh_evaluation_subject(bundle)
      assert_structure_valid(bundle, item.fetch("id")) if item.fetch("structural")
      codes = validator.validate(bundle).map(&:code)
      valid_codes = if item["exact"]
        codes == [item.fetch("expected")]
      else
        codes.include?(item.fetch("expected"))
      end
      assert(
        valid_codes,
        "#{item.fetch("id")} mutation must fail through #{item.fetch("expected")}, got #{codes.uniq.sort.join(",")}"
      )
    end

    outside_code_surface = OrbitV2FixtureFactory.valid_bundle
    task = outside_code_surface.fetch("task_revisions").first
    unit = outside_code_surface.fetch("work_units").find do |candidate|
      candidate["work_unit_id"] == "owu_implementationone"
    end
    record = outside_code_surface.fetch("evidence_records").find do |candidate|
      candidate["work_unit_id"] == unit["work_unit_id"] &&
        candidate["record_kind"] == "implementation"
    end
    target_path = "docs/outside-canonical-code-surface.rb"
    unit.dig("authority_scope")["writable_paths"] = ["docs"]
    refresh_work_authorizations(outside_code_surface, task)
    change_claim = record.fetch("submission_artifact_refs").find do |claim|
      claim["artifact_kind"] == "change"
    end
    change_claim["paths"] = [target_path]
    record.fetch("implementation_check")["changed_paths"] = [target_path]
    rehash(record)
    refresh_evaluation_subject(outside_code_surface)
    assert_structure_valid(outside_code_surface, "outside-code-surface")
    codes = validator.validate(outside_code_surface).map(&:code)
    assert(
      codes == ["implementation_path_unauthorized"],
      "path inside WorkUnit authority and change claim but outside CodeSurface must fail only path closure, got #{codes.uniq.sort.join(",")}"
    )
  end

  # Slice 3 increment 1: EvidenceRequirement.verification_class pairs exactly
  # with each implementation result verification_use, and every result
  # evidence ref must resolve to a compatible record-owned ArtifactClaim kind.
  # Pair mismatches and incompatible kinds fail closed through the public
  # Validator; missing or unknown enum values fail at contract shape. Free
  # text is never inspected.
  def test_evidence_requirement_class_use_pairing
    assert(
      validator.validate(OrbitV2FixtureFactory.evidence_classification_bundle).empty?,
      "one implementation record closes all three verification classes through separate paired results"
    )
    claim_ref = lambda do |claim|
      { "artifact_ref" => claim["artifact_ref"], "content_digest" => claim["content_digest"] }
    end
    result_for = lambda do |record, requirement_id|
      record.dig("implementation_check", "evidence_requirement_results").find do |candidate|
        candidate["evidence_requirement_id"] == requirement_id
      end
    end
    claim_for = lambda do |record, suffix|
      record["submission_artifact_refs"].find do |candidate|
        candidate["artifact_ref"].end_with?(suffix)
      end
    end
    cases = [
      {
        "id" => "regression-closed-by-acceptance-proof",
        "expected" => "evidence_requirement_pair_invalid",
        "mutate" => lambda do |record|
          result_for.call(record, "evreq_contract_test")["verification_use"] = "acceptance_proof_evidence"
        end
      },
      {
        "id" => "acceptance-closed-by-permanent-test",
        "expected" => "evidence_requirement_pair_invalid",
        "mutate" => lambda do |record|
          result_for.call(record, "evreq_acceptance_proof")["verification_use"] = "permanent_test_evidence"
        end
      },
      {
        "id" => "audit-evidence-counted-as-regression",
        "expected" => "evidence_requirement_pair_invalid",
        "mutate" => lambda do |record|
          result_for.call(record, "evreq_contract_test")["verification_use"] = "audit_record_evidence"
        end
      },
      {
        "id" => "permanent-evidence-on-report-claim",
        "expected" => "evidence_reference_invalid",
        "mutate" => lambda do |record|
          report = claim_for.call(record, "report/evreq_release_audit")
          result_for.call(record, "evreq_contract_test")["evidence_refs"] = [claim_ref.call(report)]
        end
      },
      {
        "id" => "audit-evidence-on-verification-claim",
        "expected" => "evidence_reference_invalid",
        "mutate" => lambda do |record|
          verification = claim_for.call(record, "/verification")
          result_for.call(record, "evreq_release_audit")["evidence_refs"] = [claim_ref.call(verification)]
        end
      },
      {
        "id" => "acceptance-evidence-on-verification-claim",
        "expected" => "evidence_reference_invalid",
        "mutate" => lambda do |record|
          verification = claim_for.call(record, "/verification")
          result_for.call(record, "evreq_acceptance_proof")["evidence_refs"] = [claim_ref.call(verification)]
        end
      }
    ]
    cases.each do |item|
      bundle = OrbitV2FixtureFactory.evidence_classification_bundle
      record = bundle["evidence_records"].find do |candidate|
        candidate["work_unit_id"] == "owu_implementationone"
      end
      item.fetch("mutate").call(record)
      rehash(record)
      refresh_evaluation_subject(bundle)
      assert_structure_valid(bundle, item.fetch("id"))
      codes = validator.validate(bundle).map(&:code)
      assert(
        codes == [item.fetch("expected")],
        "#{item.fetch("id")} must fail closed through #{item.fetch("expected")}, got #{codes.uniq.sort.join(",")}"
      )
    end

    shape_cases = {
      "missing-verification-use" => lambda do |record|
        result_for.call(record, "evreq_contract_test").delete("verification_use")
      end,
      "unknown-verification-use" => lambda do |record|
        result_for.call(record, "evreq_contract_test")["verification_use"] = "one_off_snapshot"
      end,
      "missing-verification-class" => lambda do |task|
        requirement = task["evidence_requirements"].find do |candidate|
          candidate["evidence_requirement_id"] == "evreq_contract_test"
        end
        requirement.delete("verification_class")
      end,
      "unknown-verification-class" => lambda do |task|
        requirement = task["evidence_requirements"].find do |candidate|
          candidate["evidence_requirement_id"] == "evreq_contract_test"
        end
        requirement["verification_class"] = "one_off_snapshot"
      end
    }
    shape_cases.each do |id, mutate|
      bundle = OrbitV2FixtureFactory.evidence_classification_bundle
      record = bundle["evidence_records"].find do |candidate|
        candidate["work_unit_id"] == "owu_implementationone"
      end
      target = id.include?("class") ? bundle["task_revisions"].first : record
      mutate.call(target)
      rehash(target)
      refresh_evaluation_subject(bundle)
      codes = validator.validate(bundle).map(&:code)
      assert(
        codes.include?("contract_shape_invalid"),
        "#{id} must fail closed at contract shape, got #{codes.uniq.sort.join(",")}"
      )
    end
  end

  # Slice 3 increment 2: RuleResolution immutable history plus exact
  # Attempt/Evidence identity binding. Stored artifacts validate against
  # their own canonical identity (no filesystem re-read), authoring always
  # hashes current rule bytes, and assigned/submitted resolutions must
  # exact-match the Attempt's immutable assignment — existence or a matching
  # ID string is never enough.
  def test_rule_resolution_immutable_history_and_binding
    # 1. Authoring-vs-stored mechanics through the public RuleResolution seam:
    #    deterministic order/created_at independence, history-safe validation
    #    after rule bytes change, and a new ID for the changed rule.
    Dir.mktmpdir("orbit-v2-rule-mechanics") do |root|
      FileUtils.mkdir_p(File.join(root, "rules"))
      base_file = File.join(root, "rules/base.md")
      extra_file = File.join(root, "rules/extra.md")
      File.write(base_file, "base v1\n")
      File.write(extra_file, "extra v1\n")
      sha = lambda do |file|
        "sha256:#{Digest::SHA256.file(file).hexdigest}"
      end
      identity = {
        "identity_schema" => "orbit-rule-resolution-identity-v1",
        "protocol_epoch" => "orbit-v2",
        "project_id" => "oproj_mechanics0001",
        "task_id" => "otask_mechanics0001",
        "task_revision_id" => "trev_mechanics0001",
        "work_unit_id" => "owu_mechanics0001",
        "attempt_id" => "oattempt_mechanics01",
        "resolved_role" => "coder",
        "agent_instance_id" => "oagent_mechanics01",
        "context_generation" => 1,
        "required_rules" => [
          { "rule_id" => "base", "path" => "rules/base.md", "content_sha256" => sha.call(base_file), "relation" => "baseline" },
          { "rule_id" => "extra", "path" => "rules/extra.md", "content_sha256" => sha.call(extra_file), "relation" => "supplements" }
        ]
      }
      first = Orbit::V2::RuleResolution.build(
        identity,
        created_at: "2026-07-30T00:00:00Z",
        project_root: root
      )
      reordered = identity.merge("required_rules" => identity["required_rules"].reverse)
      repeated = Orbit::V2::RuleResolution.build(
        reordered,
        created_at: "2099-01-01T00:00:00Z",
        project_root: root
      )
      assert(
        repeated["resolution_id"] == first["resolution_id"],
        "rule discovery order and envelope created_at are excluded from canonical identity"
      )
      Orbit::V2::RuleResolution.validate!(first, project_root: root)
      File.write(base_file, "base v2\n")
      Orbit::V2::RuleResolution.validate!(first, project_root: root)
      assert(true, "stored artifact stays valid with its old rule hashes after the file changes")
      updated = OrbitV2FixtureFactory.deep_copy(identity)
      updated["required_rules"][0]["content_sha256"] = sha.call(base_file)
      changed = Orbit::V2::RuleResolution.build(
        updated,
        created_at: "2026-07-30T00:00:01Z",
        project_root: root
      )
      assert(
        changed["resolution_id"] != first["resolution_id"],
        "a changed rule produces a new resolution ID"
      )
      Orbit::V2::RuleResolution.validate!(changed, project_root: root)
      FileUtils.rm_f([base_file, extra_file])
      Orbit::V2::RuleResolution.validate!(first, project_root: root)
      Orbit::V2::RuleResolution.validate!(changed, project_root: root)
      assert(
        true,
        "stored history stays valid with its old rule hashes after its rule files disappear"
      )
      mismatched_project = OrbitV2FixtureFactory.deep_copy(first)
      mismatched_project["project_id"] = "oproj_otherproject1"
      expect_contract_error("rule_resolution_identity_mismatch") do
        Orbit::V2::RuleResolution.validate!(mismatched_project, project_root: root)
      end
    end

    # 2. A changed rule cannot be attributed to the old Attempt: the new
    #    artifact exists and is internally valid, the record's submitted ID
    #    is rewritten to it, yet accepted evidence fails closed.
    bundle = OrbitV2FixtureFactory.valid_bundle
    artifact = bundle["rule_resolution_artifacts"].find do |candidate|
      candidate.dig("identity", "attempt_id") == "oattempt_implementationone"
    end
    identity = OrbitV2FixtureFactory.deep_copy(artifact.fetch("identity"))
    rule = identity["required_rules"].first
    Dir.mktmpdir("orbit-v2-rule-bytes") do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(rule["path"])))
      updated_bytes = "#{File.read(File.join(ROOT, rule["path"]))}\n# slice3-inc2 changed rule bytes\n"
      File.write(File.join(root, rule["path"]), updated_bytes)
      identity["required_rules"][0]["content_sha256"] =
        "sha256:#{Digest::SHA256.hexdigest(updated_bytes)}"
      changed = Orbit::V2::RuleResolution.build(
        identity,
        created_at: "2026-07-30T00:09:00Z",
        project_root: root
      )
      bundle["rule_resolution_artifacts"] << changed
      record = bundle["evidence_records"].find do |candidate|
        candidate["work_unit_id"] == "owu_implementationone"
      end
      record["submitted_rule_resolution_id"] = changed["resolution_id"]
      rehash(record)
      refresh_evaluation_subject(bundle)
      codes = validator.validate(bundle).map(&:code)
      assert(
        codes == ["rule_resolution_identity_mismatch"],
        "submitting the changed-rule artifact for the old Attempt must be rejected, got #{codes.uniq.sort.join(",")}"
      )
    end

    # 3. Reviewer/tester reuse of an implementation resolution fails even
    #    after every dependent checkpoint/evidence ref is consistently
    #    resealed against the reused identity.
    bundle = OrbitV2FixtureFactory.valid_bundle
    review = bundle["work_unit_attempts"].find do |candidate|
      candidate["attempt_id"] == "oattempt_independentreview"
    end
    impl_rule = bundle["rule_resolution_artifacts"].find do |candidate|
      candidate.dig("identity", "attempt_id") == "oattempt_implementationone"
    end
    policy = bundle["project_policy_revisions"].first
    review.dig("events", 0, "assignment")["assigned_rule_resolution_id"] =
      impl_rule["resolution_id"]
    OrbitV2FixtureFactory.resign_event_chain(review)
    checkpoints = bundle["lead_checkpoints"]
    dispatch_index = checkpoints.index do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_terminal_impltwo"
    end
    dispatch = checkpoints[dispatch_index]
    observation = checkpoints[dispatch_index + 1]
    proposal = dispatch.dig("delivery_progress", "supporting_refs").find do |ref|
      ref["kind"] == "rule_resolution"
    end
    proposal["id"] = impl_rule["resolution_id"]
    proposal["digest"] = impl_rule["identity_sha256"]
    observation["current_or_terminal_attempt_ref"] =
      OrbitV2FixtureFactory.attempt_event_ref([review], review["attempt_id"], 0)
    checkpoints[dispatch_index] = OrbitV2FixtureFactory.reseal_checkpoint(
      dispatch,
      policy: policy,
      predecessor_checkpoint: checkpoints[dispatch_index - 1]
    )
    OrbitV2FixtureFactory.repin_lineage_tail(bundle, dispatch_index + 1)
    submission = bundle["evidence_records"].find do |candidate|
      candidate["record_kind"] == "evaluator_submission"
    end
    submission["submitted_rule_resolution_id"] = impl_rule["resolution_id"]
    rehash(submission)
    codes = validator.validate(bundle).map(&:code)
    assert(
      codes.uniq.sort == ["rule_resolution_identity_mismatch"],
      "reviewer reuse of an implementation resolution must fail through exact identity binding, got #{codes.uniq.sort.join(",")}"
    )

    # 4. Identity mismatches for attempt/role/agent/context fail closed through
    #    internally valid content-addressed artifacts: each patched identity is
    #    rebuilt via the public RuleResolution.build seam, assigned to the
    #    original Attempt, and submitted by its EvidenceRecord, so the exact
    #    binding helper is the only place the patched field can be rejected.
    {
      "attempt" => { "attempt_id" => "oattempt_implementationtwo" },
      "role" => { "resolved_role" => "reviewer" },
      "agent" => { "agent_instance_id" => "oagent_implementertwo" },
      "context" => { "context_generation" => 2 }
    }.each do |name, patch|
      bundle = OrbitV2FixtureFactory.valid_bundle
      attempt = bundle["work_unit_attempts"].find do |candidate|
        candidate["attempt_id"] == "oattempt_implementationone"
      end
      base = bundle["rule_resolution_artifacts"].find do |candidate|
        candidate.dig("identity", "attempt_id") == "oattempt_implementationone"
      end
      identity = OrbitV2FixtureFactory.deep_copy(base.fetch("identity"))
      patch.each { |field, value| identity[field] = value }
      forged = Orbit::V2::RuleResolution.build(
        identity,
        created_at: base.dig("envelope", "created_at"),
        project_root: ROOT
      )
      bundle["rule_resolution_artifacts"] << forged
      attempt.dig("events", 0, "assignment")["assigned_rule_resolution_id"] =
        forged["resolution_id"]
      OrbitV2FixtureFactory.resign_event_chain(attempt)
      record = bundle["evidence_records"].find do |candidate|
        candidate["work_unit_id"] == "owu_implementationone"
      end
      record["submitted_rule_resolution_id"] = forged["resolution_id"]
      rehash(record)
      refresh_evaluation_subject(bundle)
      codes = validator.validate(bundle).map(&:code)
      assert(
        codes.include?("rule_resolution_identity_mismatch"),
        "#{name} identity mismatch must fail closed through the exact binding, got #{codes.uniq.sort.join(",")}"
      )
    end
  end

  # Slice 4 increment 1: Finding typed basis and active-policy-derived
  # disposition/closure. Blocking is never agent-writable; the active policy
  # mapping derives it, closure consumes that mapping, and an unadjudicated
  # newly_discovered_risk escalates through deterministic LeadControl replay.
  def test_finding_typed_basis_and_disposition
    escalate_decision = { "state" => "needs_user", "action" => "escalate", "reason" => "newly discovered risk requires risk-owner/user adjudication" }.freeze
    continue_decision = { "state" => "blocked", "action" => "continue", "reason" => "authoritative change observed" }.freeze
    append_finding = lambda do |bundle, basis, id = nil|
      evaluation = bundle["gate_evaluations"].first
      finding = OrbitV2FixtureFactory.deep_copy(bundle["findings"].first)
      finding["finding_id"] = id || "ofinding_#{basis}"
      finding["basis"] = basis
      finding["supersedes_finding_id"] = nil
      finding["body"] = "Typed #{basis} probe finding."
      rehash(finding)
      evaluation["finding_refs"] = Array(evaluation["finding_refs"]) + [finding["finding_id"]]
      rehash(evaluation)
      bundle["findings"] << finding
      finding
    end
    resolve_finding = lambda do |bundle, finding|
      source = bundle["gate_evaluations"].first
      followup = OrbitV2FixtureFactory.deep_copy(source)
      followup["gate_evaluation_id"] = "ogeval_slice0riskfollowup"
      followup["verdict"] = "pass"
      followup["quality_outcome_verdict"] = "pass"
      followup["quality_question_answers"].each { |answer| answer["verdict"] = "pass" }
      followup["acceptance_results"].each { |answer| answer["verdict"] = "pass" }
      followup["counterexample_cases"] = []
      followup["finding_refs"] = []
      followup["supersedes_gate_evaluation_id"] = source["gate_evaluation_id"]
      rehash(followup)
      bundle["gate_evaluations"] << followup
      resolution = OrbitV2FixtureFactory.deep_copy(bundle["finding_resolutions"].first)
      resolution["finding_resolution_id"] = "ofres_#{finding["finding_id"].delete_prefix("ofinding_")}_resolved"
      resolution["finding_id"] = finding["finding_id"]
      resolution.delete("authorization_record_ref")
      resolution["resolution"] = "addressed"
      resolution["issuer_attempt_id"] = "oattempt_independentreview"
      resolution["issuer_submission_record_id"] = "oevr_independentreview"
      resolution["source_finding_ref"] = { "finding_id" => finding["finding_id"], "content_digest" => finding["content_digest"] }
      resolution["source_gate_evaluation_ref"] = { "gate_evaluation_id" => source["gate_evaluation_id"], "content_digest" => source["content_digest"] }
      resolution["resolving_gate_evaluation_ref"] = { "gate_evaluation_id" => followup["gate_evaluation_id"], "content_digest" => followup["content_digest"] }
      resolution["supporting_record_refs"] = ["oevr_implementationone"]
      resolution["proposal_evidence_record_id"] = "oevr_implementationone"
      rehash(resolution)
      bundle["finding_resolutions"] << resolution
    end

    # 1. Both blocking classes stay valid (policy-derived blocking).
    %w[contract_violation regression].each do |basis|
      bundle = OrbitV2FixtureFactory.valid_bundle
      bundle["findings"].first["basis"] = basis
      rehash(bundle["findings"].first)
      assert(validator.validate(bundle).empty?, "#{basis} unresolved finding keeps the existing closure path valid")
    end
    bundle = OrbitV2FixtureFactory.valid_bundle
    hardening = append_finding.call(bundle, "hardening_opportunity")
    OrbitV2FixtureFactory.append_finding_change_checkpoint(bundle, hardening, continue_decision, preserve_attempt: true)
    assert(validator.validate(bundle).empty?, "introducing a hardening finding replays to an ordinary non-preemptive continue")
    mutated = OrbitV2FixtureFactory.valid_bundle
    hardening = append_finding.call(mutated, "hardening_opportunity")
    OrbitV2FixtureFactory.append_finding_change_checkpoint(mutated, hardening, continue_decision, preserve_attempt: true)
    checkpoint = mutated["lead_checkpoints"].last
    predecessor = mutated["lead_checkpoints"][-2]
    unit = mutated["work_units"].find { |candidate| candidate["work_unit_id"] == "owu_implementationone" }
    checkpoint["selected_work_unit_ref"] = OrbitV2FixtureFactory.work_unit_ref(unit)
    checkpoint["assessments"] = OrbitV2FixtureFactory.checkpoint_assessments(checkpoint["active_task_ref"], checkpoint["selected_work_unit_ref"], checkpoint["current_or_terminal_attempt_ref"])
    mutated["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(checkpoint, policy: mutated["project_policy_revisions"].last, predecessor_checkpoint: predecessor)
    codes = validator.validate(mutated).map(&:code)
    assert(codes.include?("checkpoint_selection_invalid"), "a hardening observation switching the selected WorkUnit must be rejected, got #{codes.uniq.sort.join(",")}")

    # 3. A newly_discovered_risk replays to needs_user/escalate.
    bundle = OrbitV2FixtureFactory.valid_bundle
    risk = append_finding.call(bundle, "newly_discovered_risk")
    OrbitV2FixtureFactory.append_finding_change_checkpoint(bundle, risk, escalate_decision)
    assert(validator.validate(bundle).empty?, "unadjudicated risk introduction derives needs_user/escalate deterministically")

    # 4. A forged blocked/continue path for the same risk fails replay.
    bundle = OrbitV2FixtureFactory.valid_bundle
    risk = append_finding.call(bundle, "newly_discovered_risk")
    OrbitV2FixtureFactory.append_finding_change_checkpoint(bundle, risk, continue_decision)
    codes = validator.validate(bundle).map(&:code)
    assert(
      codes.uniq.sort == ["checkpoint_decision_replay_invalid"],
      "forged blocked/continue on an unadjudicated risk must fail replay, got #{codes.uniq.sort.join(",")}"
    )

    # 5. An unadjudicated risk without checkpoint provenance fails closed.
    bundle = OrbitV2FixtureFactory.valid_bundle
    append_finding.call(bundle, "newly_discovered_risk")
    codes = validator.validate(bundle).map(&:code)
    assert(codes.include?("finding_risk_unobserved"), "an unpinned risk finding must fail closed, got #{codes.uniq.sort.join(",")}")

    # 6. Future resolutions never rewrite history; only an exact-pinning
    #    authority_change successor resumes.
    bundle = OrbitV2FixtureFactory.valid_bundle
    risk = append_finding.call(bundle, "newly_discovered_risk")
    OrbitV2FixtureFactory.append_finding_change_checkpoint(bundle, risk, escalate_decision)
    escalation_id = bundle["lead_checkpoints"].last["lead_checkpoint_id"]
    escalation_digest = bundle["lead_checkpoints"].last["content_digest"]
    assert(validator.validate(bundle).empty?, "unadjudicated risk checkpoint validates before any resolution exists")
    resolve_finding.call(bundle, risk)
    escalation_after = bundle["lead_checkpoints"].find { |cp| cp["lead_checkpoint_id"] == escalation_id }
    assert(escalation_after["content_digest"] == escalation_digest, "appending a resolution leaves the historical checkpoint byte-identical")
    assert(validator.validate(bundle).empty?, "a later resolution cannot invalidate the accepted needs_user checkpoint")
    OrbitV2FixtureFactory.append_authority_change_resume_checkpoint(bundle, bundle["finding_resolutions"].last)
    assert(validator.validate(bundle).empty?, "an authority_change checkpoint exact-pinning the resolution resumes deterministically")
    bundle = OrbitV2FixtureFactory.valid_bundle
    risk = append_finding.call(bundle, "newly_discovered_risk")
    resolve_finding.call(bundle, risk)
    OrbitV2FixtureFactory.append_finding_change_checkpoint(bundle, risk, escalate_decision, resolution: bundle["finding_resolutions"].last)
    codes = validator.validate(bundle).map(&:code)
    assert(codes.include?("checkpoint_decision_replay_invalid"), "escalating despite a pinned resolution fails replay")

    # 7. Unrelated/partial/non-authority successors cannot close the risk stop.
    resume_rejects = {
      "unrelated" => lambda do |bundle, _risk|
        OrbitV2FixtureFactory.append_authority_change_resume_checkpoint(bundle, bundle["finding_resolutions"].first)
      end,
      "hardening_successor" => lambda do |bundle, _risk|
        hardening = append_finding.call(bundle, "hardening_opportunity")
        OrbitV2FixtureFactory.append_finding_change_checkpoint(bundle, hardening, continue_decision)
      end,
      "partial" => lambda do |bundle, risk|
        second = append_finding.call(bundle, "newly_discovered_risk", "ofinding_riskpartial")
        checkpoint = bundle["lead_checkpoints"].last
        %w[delivery_progress assurance_progress].each do |field|
          checkpoint[field]["supporting_refs"] << { "kind" => "finding", "id" => second["finding_id"], "digest" => second["content_digest"] }
        end
        policy = bundle["project_policy_revisions"].last
        bundle["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(checkpoint, policy: policy, predecessor_checkpoint: bundle["lead_checkpoints"][-2])
        resolve_finding.call(bundle, risk)
        OrbitV2FixtureFactory.append_authority_change_resume_checkpoint(bundle, bundle["finding_resolutions"].last)
      end
    }
    resume_rejects.each do |name, mutate|
      bundle = OrbitV2FixtureFactory.valid_bundle
      risk = append_finding.call(bundle, "newly_discovered_risk")
      OrbitV2FixtureFactory.append_finding_change_checkpoint(bundle, risk, escalate_decision)
      mutate.call(bundle, risk)
      codes = validator.validate(bundle).map(&:code)
      assert(codes.include?("checkpoint_trigger_invalid"), "#{name} successor must be rejected, got #{codes.uniq.sort.join(",")}")
    end

    # Public predecessor-first regressions: policy/retry after a risk stop replay frozen.
    predecessor_first = lambda do |mutate|
      bundle = OrbitV2FixtureFactory.valid_bundle
      add_policy_successor(bundle)
      risk = append_finding.call(bundle, "newly_discovered_risk")
      OrbitV2FixtureFactory.append_finding_change_checkpoint(bundle, risk, escalate_decision)
      tip = bundle["lead_checkpoints"].last
      checkpoint = OrbitV2FixtureFactory.deep_copy(tip)
      checkpoint["lead_checkpoint_id"] = "olcheckpoint_authoritychange_bypass"
      checkpoint["predecessor_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(tip)
      checkpoint["reconcile_trigger"] = { "event" => "authority_change", "reason" => "Bypass probe." }
      checkpoint["next_trigger"] = { "event" => "successor_before", "reason" => "Awaiting the successor boundary." }
      checkpoint["lead_decision"] = { "state" => "blocked", "action" => "continue", "reason" => "authoritative change observed" }
      mutate.call(checkpoint, bundle)
      bundle["lead_checkpoints"] << OrbitV2FixtureFactory.reseal_checkpoint(checkpoint, policy: bundle["project_policy_revisions"].last, predecessor_checkpoint: tip)
      Orbit::V2::LeadControl.reconcile(
        { "bundle" => bundle, "lead_control_id" => OrbitV2FixtureFactory::CONTROL_ID,
          "lead_checkpoint_ref" => OrbitV2FixtureFactory.cp_ref(bundle["lead_checkpoints"].last) },
        "authority_change"
      )
    end
    policy_only = predecessor_first.call(lambda do |checkpoint, bundle|
      checkpoint["project_policy_revision_ref"] = OrbitV2FixtureFactory.policy_ref(bundle["project_policy_revisions"].first)
    end)
    assert(policy_only["state"] == "frozen", "a policy-only authority_change after a risk stop must replay frozen, got #{policy_only.inspect}")
    override_only = predecessor_first.call(lambda do |checkpoint, _bundle|
      checkpoint["retry_override_ref"] = { "authorization_record_ref" => "oauthz_findingwaiver" }
    end)
    assert(override_only["state"] == "frozen", "a retry-override authority_change after a risk stop must replay frozen, got #{override_only.inspect}")
    # 8. Blocked/warning assessment layers cannot mask the mandatory escalation.

    {
      "blocked" => { "status" => "blocked", "decision" => { "state" => "blocked", "action" => "continue", "reason" => "external blockage in assessment layers: task_queue" } },
      "warning" => { "status" => "warning", "decision" => { "state" => "frozen", "action" => "freeze", "reason" => "control anomaly in assessment layers: task_queue" } }
    }.each do |name, variant|
      bundle = OrbitV2FixtureFactory.valid_bundle
      risk = append_finding.call(bundle, "newly_discovered_risk")
      OrbitV2FixtureFactory.append_finding_change_checkpoint(bundle, risk, escalate_decision)
      checkpoint = bundle["lead_checkpoints"].last
      checkpoint.dig("assessments", "task_queue")["status"] = variant["status"]
      checkpoint["lead_decision"] = variant["decision"]
      checkpoint["next_trigger"] = { "event" => "successor_before", "reason" => "Awaiting the successor boundary." }
      bundle["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(
        checkpoint,
        policy: bundle["project_policy_revisions"].last,
        predecessor_checkpoint: bundle["lead_checkpoints"][-2]
      )
      codes = validator.validate(bundle).map(&:code)
      assert(codes.include?("checkpoint_decision_replay_invalid"), "a #{name} assessment layer cannot mask the mandatory risk escalation")
    end
    # 9. Public LeadControl.reconcile fails closed for a nonexistent ref.

    missing = Orbit::V2::LeadControl.reconcile(
      {
        "bundle" => OrbitV2FixtureFactory.valid_bundle,
        "lead_control_id" => OrbitV2FixtureFactory::CONTROL_ID,
        "lead_checkpoint_ref" => { "lead_checkpoint_id" => "olcheckpoint_missing", "content_digest" => "sha256:#{'0' * 64}" }
      },
      "attempt_created"
    )
    assert(
      missing == { "state" => "frozen", "action" => "freeze", "reason" => "authoritative facts missing or checkpoint not accepted" },
      "public reconcile with a nonexistent checkpoint ref must fail closed deterministically"
    )
  end

  # Slice 4 inc 2: one-way C_pending -> independent budget GateEvaluation ->
  # immediate successor C_reviewed consumption; all identity/scope/status/
  # freshness/evaluator independence failures close through public seams.
  def test_budget_assessment_consumer_closure
    continue_decision = { "state" => "blocked", "action" => "continue", "reason" => "authoritative change observed" }.freeze
    frozen_decision = { "state" => "frozen", "action" => "freeze", "reason" => "independent budget review rejected: replan required" }.freeze
    dispatch_decision = { "state" => "blocked", "action" => "dispatch", "reason" => "dispatch authorized" }.freeze
    build_reviewed_bundle = lambda do |outcome:, select_budget_gate: true, with_result: true, pending_statuses: nil, adjustment: false, mixed: false|
      reviewed_budget_bundle(
        outcome: outcome,
        select_budget_gate: select_budget_gate,
        with_result: with_result,
        pending_statuses: pending_statuses,
        adjustment: adjustment,
        mixed: mixed,
        continue_decision: continue_decision,
        frozen_decision: frozen_decision,
        dispatch_decision: dispatch_decision
      )
    end
    accepted_bundle = build_reviewed_bundle.call(outcome: "accepted")
    assert(validator.validate(accepted_bundle).empty?, "accepted budget review consumption validates end to end")
    pending_binding = accepted_bundle["lead_checkpoints"][-2]["effective_budget_bindings"].first
    reviewed_binding = accepted_bundle["lead_checkpoints"][-1]["effective_budget_bindings"].first
    assert(
      Orbit::V2::ControlAuthority.binding_digest(pending_binding) != Orbit::V2::ControlAuthority.binding_digest(reviewed_binding) &&
        Orbit::V2::ControlAuthority.budget_review_subject_projection_digest(pending_binding) == Orbit::V2::ControlAuthority.budget_review_subject_projection_digest(reviewed_binding),
      "successor differs in complete digest only through the review result fields"
    )
    [{}, { mixed: true }].each { |options| assert(validator.validate(build_reviewed_bundle.call(options.merge(outcome: "accepted", adjustment: true))).empty?, "the budget_change proposal consumes its exact gate review and the one typed transition dispatches#{options.empty? ? "" : " with mixed metrics"}") }
    assert(validator.validate(build_reviewed_bundle.call(pending_statuses: { "test_count" => "verified" }, outcome: "accepted")).empty?, "accepted review unlocks the verified path")
    assert(validator.validate(build_reviewed_bundle.call(outcome: "rejected")).empty?, "rejected budget review consumption replays frozen deterministically")
    # A bare budget_change trigger with no typed payload proves no delta.
    bare = build_reviewed_bundle.call(outcome: "accepted", adjustment: true)
    index = bare["lead_checkpoints"].index { |candidate| candidate["lead_checkpoint_id"] == "olcheckpoint_budgetproposal" }
    proposal = bare["lead_checkpoints"][index]
    %w[test_budget_adjust budget_adjustment_digest].each { |field| proposal[field] = nil }
    bare["lead_checkpoints"][index] = OrbitV2FixtureFactory.reseal_checkpoint(proposal, policy: bare["project_policy_revisions"].first, predecessor_checkpoint: bare["lead_checkpoints"][index - 1])
    codes = validator.validate(bare).map(&:code)
    assert(codes.include?("checkpoint_trigger_invalid"), "a bare budget_change trigger with no payload fails the delta proof")
    forged = build_reviewed_bundle.call(outcome: "rejected")
    checkpoint = forged["lead_checkpoints"].last
    checkpoint["lead_decision"] = continue_decision
    forged["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(checkpoint, policy: forged["project_policy_revisions"].first, predecessor_checkpoint: forged["lead_checkpoints"][-2], bindings: checkpoint["effective_budget_bindings"])
    codes = validator.validate(forged).map(&:code)
    assert(codes.include?("checkpoint_decision_replay_invalid"), "forged continue on a rejected review must fail replay")
    codes = validator.validate(OrbitV2FixtureFactory.adjustment_bundle(mode: :unverified_adjust)).map(&:code)
    assert(codes.include?("checkpoint_budget_invalid"), "pending unverified measurements still cannot unlock the lead_adjustment path")
    wrong_ref = build_reviewed_bundle.call(outcome: "accepted", adjustment: true)
    reviewed = wrong_ref["lead_checkpoints"].last
    reviewed["effective_budget_bindings"][0]["lead_adjustment_source"]["inherited_checkpoint_ref"] = { "lead_checkpoint_id" => "olcheckpoint_slice0successor", "content_digest" => wrong_ref["lead_checkpoints"][-2]["content_digest"] }
    wrong_ref["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(reviewed, policy: wrong_ref["project_policy_revisions"].first, predecessor_checkpoint: wrong_ref["lead_checkpoints"][-2], bindings: reviewed["effective_budget_bindings"])
    codes = validator.validate(wrong_ref).map(&:code)
    assert(codes.include?("budget_assessment_invalid"), "a wrong inherited ref on the adjustment transition must fail through budget_assessment_invalid")

    reinherit = build_reviewed_bundle.call(outcome: "accepted", adjustment: true)
    reviewed = reinherit["lead_checkpoints"].last
    stale = OrbitV2FixtureFactory.deep_copy(reviewed)
    stale["lead_checkpoint_id"] = "olcheckpoint_budgetstale"
    stale["predecessor_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(reviewed)
    %w[delivery_progress assurance_progress].each { |field| stale[field]["predecessor_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(reviewed) }
    bindings = OrbitV2FixtureFactory.default_budget_bindings(policy: reinherit["project_policy_revisions"].first, predecessor_checkpoint: reviewed, active_task_ref: stale["active_task_ref"], selected_work_unit_ref: stale["selected_work_unit_ref"], measurements_by_scope: { "work_unit_lineage" => reviewed["effective_budget_bindings"][0]["measurements"], "task_lineage" => reviewed["effective_budget_bindings"][1]["measurements"] })
    reinherit["lead_checkpoints"] << OrbitV2FixtureFactory.reseal_checkpoint(stale, policy: reinherit["project_policy_revisions"].first, predecessor_checkpoint: reviewed, bindings: bindings)

    codes = validator.validate(reinherit).map(&:code)
    assert(codes.include?("budget_assessment_invalid"), "re-inheriting the old accepted review across the provenance change must fail through budget_assessment_invalid")

    mutated = build_reviewed_bundle.call(outcome: "accepted", adjustment: true)
    index = mutated["lead_checkpoints"].index { |candidate| candidate["lead_checkpoint_id"] == "olcheckpoint_budgetproposal" }
    proposal = mutated["lead_checkpoints"][index]
    proposal["effective_budget_bindings"][0]["lead_adjustment_source"]["mode"] = "inherited"
    mutated["lead_checkpoints"][index] = OrbitV2FixtureFactory.reseal_checkpoint(proposal, policy: mutated["project_policy_revisions"].first, predecessor_checkpoint: mutated["lead_checkpoints"][index - 1], bindings: proposal["effective_budget_bindings"])
    reviewed = mutated["lead_checkpoints"].last
    reviewed["predecessor_lead_checkpoint_ref"] = mutated["lead_checkpoints"][index].slice("lead_checkpoint_id", "content_digest")
    reviewed["effective_budget_bindings"][0]["lead_adjustment_source"]["inherited_checkpoint_ref"] = reviewed["predecessor_lead_checkpoint_ref"]
    reviewed = mutated["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(reviewed, policy: mutated["project_policy_revisions"].first, predecessor_checkpoint: mutated["lead_checkpoints"][index], bindings: reviewed["effective_budget_bindings"])
    decision = Orbit::V2::LeadControl.reconcile({ "bundle" => mutated, "lead_control_id" => OrbitV2FixtureFactory::CONTROL_ID, "lead_checkpoint_ref" => { "lead_checkpoint_id" => reviewed["lead_checkpoint_id"], "content_digest" => reviewed["content_digest"] } }, "gate_change")
    assert(decision["action"] == "continue", "a predecessor that is not mode=current must replay continue, never dispatch")
    # 4-8. Discriminating negative table.
    mutate_result = lambda do |bundle, patch|
      patch.each do |field, value|
        bundle["gate_evaluations"].last["budget_assessment_result"][field] = value
      end
      rehash(bundle["gate_evaluations"].last)
      reseal_consuming(bundle, bundle["lead_checkpoints"].last, evaluation: bundle["gate_evaluations"].last)

    end
    {
      "ordinary-evaluation" => lambda do |bundle|
        checkpoint = bundle["lead_checkpoints"].last
        ref = { "gate_evaluation_id" => "ogeval_slice0review", "content_digest" => bundle["gate_evaluations"].first["content_digest"] }
        %w[test_count test_code_lines].each do |metric|
          checkpoint["effective_budget_bindings"][0]["measurements"][metric]["unverified_assessment"]["review_gate_evaluation_ref"] = ref
        end
        reseal_consuming(bundle, checkpoint)
      end,
      "missing-selector" => lambda { |bundle| },
      "self-circular" => lambda do |bundle|
        checkpoint = bundle["lead_checkpoints"].last
        bundle["gate_evaluations"].last["budget_assessment_result"]["assessed_checkpoint_ref"] =
          OrbitV2FixtureFactory.cp_ref(checkpoint)
        rehash(bundle["gate_evaluations"].last)
        reseal_consuming(bundle, checkpoint, evaluation: bundle["gate_evaluations"].last)
      end,
      "stale-projection" => lambda do |bundle|
        checkpoint = bundle["lead_checkpoints"].last
        %w[test_count test_code_lines].each do |metric|
          checkpoint["effective_budget_bindings"][0]["measurements"][metric]["unverified_assessment"]["lead_reason_code"] = "drifted reason"
        end

        reseal_consuming(bundle, checkpoint)
      end,
      "outcome-mismatch" => lambda { |bundle| mutate_result.call(bundle, { "outcome" => "rejected" }) },
      "wrong-digest" => lambda { |bundle| mutate_result.call(bundle, { "assessed_effective_budget_binding_digest" => "sha256:#{'0' * 64}" }) },
      "scope-mismatch" => lambda { |bundle| mutate_result.call(bundle, { "scope" => "task_lineage" }) },
      "status-mismatch" => lambda { |bundle| mutate_result.call(bundle, { "metric_statuses" => { "test_count" => "unverified", "test_code_lines" => "verified" } }) },
      "missing-result" => lambda { |bundle| },
      "wrong-control" => lambda { |bundle| mutate_result.call(bundle, { "lead_control_id" => "olcontrol_wrongcontrol" }) }
    }.each do |name, mutate|
      bundle = build_reviewed_bundle.call(outcome: "accepted", select_budget_gate: name != "missing-selector", with_result: name != "missing-result")

      mutate.call(bundle)
      codes = validator.validate(bundle).map(&:code)
      assert(
        codes.include?("budget_assessment_invalid"),
        "#{name} must fail through budget_assessment_invalid, got #{codes.uniq.sort.join(",")}"
      )
    end
    # 9. The evaluator must be independent of the assessed checkpoint lead writer.
    bundle = build_reviewed_bundle.call(outcome: "accepted")
    pending = bundle["lead_checkpoints"][-2]
    pending["lead_agent_instance_ref"] = { "agent_instance_id" => "oagent_independentreviewer" }
    bundle["lead_checkpoints"][-2] = OrbitV2FixtureFactory.reseal_checkpoint(pending, policy: bundle["project_policy_revisions"].first, predecessor_checkpoint: bundle["lead_checkpoints"][-3], bindings: pending["effective_budget_bindings"])
    evaluation = bundle["gate_evaluations"].last
    evaluation["budget_assessment_result"]["assessed_checkpoint_ref"] =
      OrbitV2FixtureFactory.cp_ref(bundle["lead_checkpoints"][-2])
    rehash(evaluation)
    review = bundle["lead_checkpoints"].last
    review["predecessor_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(bundle["lead_checkpoints"][-2])
    reseal_consuming(bundle, review, evaluation: evaluation)
    codes = validator.validate(bundle).map(&:code)

    assert(codes.include?("budget_assessment_invalid"), "a non-independent budget evaluator must fail closed")
  end

  # Slice 5 increment 1: the deterministic AggregateOutcome projection.
  # derive(bundle, task_revision_id, validator:) enforces a mechanically
  # narrow validated-input boundary: only the historical stale-subject error
  # (code+path predicate) is tolerated, so invalid evaluator
  # provenance/independence, authorization, resolution authority, and
  # non-currentness can never produce closed=true, while a create-only
  # GateEvaluation made stale by later subject changes stays stored and is
  # excluded.
  def test_aggregate_outcome_projection
    derive = lambda do |bundle|
      Orbit::V2::AggregateOutcome.derive(
        bundle,
        OrbitV2FixtureFactory::TASK_REVISION_ID,
        validator: validator
      )
    end
    make_pass_bundle = lambda do
      bundle = OrbitV2FixtureFactory.valid_bundle
      evaluation = bundle["gate_evaluations"].first
      evaluation["verdict"] = "pass"
      evaluation["quality_outcome_verdict"] = "pass"
      evaluation["acceptance_results"].each { |result| result["verdict"] = "pass" }
      rehash(evaluation)
      bundle
    end

    # 1. A unique current evaluation decides its gate: pass closes, fail opens.
    pass_bundle = make_pass_bundle.call
    assert(validator.validate(pass_bundle).empty?, "pass bundle must validate")
    pass_outcome = derive.call(pass_bundle)
    pass_result = pass_outcome["gate_results"].first
    assert(pass_outcome["closed"] == true, "a unique current pass closes the gate")
    assert(pass_result["status"] == "passed", "gate status is passed")
    assert(
      pass_result["gate_evaluation_ref"] == {
        "gate_evaluation_id" => "ogeval_slice0review",
        "content_digest" => pass_bundle["gate_evaluations"].first["content_digest"]
      },
      "the deciding evaluation ref is exact"
    )
    assert(
      pass_outcome["task_revision_ref"] == {
        "task_revision_id" => OrbitV2FixtureFactory::TASK_REVISION_ID,
        "content_digest" => pass_bundle["task_revisions"].first["content_digest"]
      } &&
        pass_outcome["project_policy_revision_ref"] ==
          OrbitV2FixtureFactory.policy_ref(pass_bundle["project_policy_revisions"].first),
      "task and policy refs are exact"
    )
    assert(pass_outcome["unresolved_blocking_finding_refs"].empty?, "a resolved finding does not block")
    fail_outcome = derive.call(OrbitV2FixtureFactory.valid_bundle)
    assert(fail_outcome["gate_results"].first["status"] == "not_passed", "a current fail is not_passed")
    assert(fail_outcome["closed"] == false, "a fail stays open")

    # 2. A task with no evaluation yet is missing and open (Validator-accepted).
    missing_bundle = OrbitV2FixtureFactory.valid_bundle
    task = missing_bundle["task_revisions"].first
    task["unresolved_finding_refs"] = []
    rehash(task)
    rebind_checkpoint_refs(missing_bundle, task: task)
    refresh_work_authorizations(missing_bundle, task)
    missing_bundle["gate_evaluations"] = []
    missing_bundle["findings"] = []
    missing_bundle["finding_resolutions"] = []
    assert(validator.validate(missing_bundle).empty?, "a not-yet-evaluated task must validate")
    missing_outcome = derive.call(missing_bundle)
    assert(missing_outcome["gate_results"].first["status"] == "missing", "no evaluation is missing")
    assert(missing_outcome["closed"] == false, "missing does not close")

    # 3. A historical stale evaluation stays stored but excluded: the
    #    create-only GateEvaluation no longer matches the CURRENT subject,
    #    the Validator emits only subject_stale, and derive returns
    #    missing/open instead of rejecting the historical fact set.
    stale_bundle = make_pass_bundle.call
    extra_record = OrbitV2FixtureFactory.deep_copy(stale_bundle["evidence_records"].first)
    extra_record["evidence_record_id"] = "oevr_implementationoneextra"
    rehash(extra_record)
    stale_bundle["evidence_records"] << extra_record
    stale_errors = validator.validate(stale_bundle)
    assert(
      stale_errors.map(&:code) == ["subject_stale"] &&
        stale_errors.first.path == "gate_evaluations.ogeval_slice0review.subject",
      "appending accepted evidence makes only the old evaluation subject-stale"
    )
    stale_outcome = derive.call(stale_bundle)
    assert(stale_outcome["gate_results"].first["status"] == "missing", "the stale evaluation is excluded")
    assert(stale_outcome["closed"] == false, "a stale-only gate stays open")

    # 4. Current evaluation selection is structural: the supersedes lineage
    #    tip decides, and a fork of two current tips is ambiguous independent
    #    of array order.
    followup_bundle = OrbitV2FixtureFactory.valid_bundle
    add_followup_evaluation(followup_bundle)
    assert(validator.validate(followup_bundle).empty?, "superseding followup bundle must validate")
    followup_outcome = derive.call(followup_bundle)
    assert(
      followup_outcome["gate_results"].first["gate_evaluation_ref"]["gate_evaluation_id"] ==
        "ogeval_slice0followupreview",
      "the supersedes tip decides the gate"
    )
    assert(followup_outcome["gate_results"].first["status"] == "passed", "the tip pass is passed")
    assert(followup_outcome["closed"] == true, "a tip pass with a resolved finding closes")

    fork_bundle = OrbitV2FixtureFactory.valid_bundle
    fork_evaluation = OrbitV2FixtureFactory.deep_copy(fork_bundle["gate_evaluations"].first)
    fork_evaluation["gate_evaluation_id"] = "ogeval_slice0fork"
    fork_evaluation["finding_refs"] = []
    fork_evaluation["supersedes_gate_evaluation_id"] = nil
    rehash(fork_evaluation)
    fork_bundle["gate_evaluations"] << fork_evaluation
    assert(validator.validate(fork_bundle).empty?, "a fork is a validator-accepted state")
    fork_outcome = derive.call(fork_bundle)
    assert(fork_outcome["gate_results"].first["status"] == "ambiguous", "a fork is ambiguous")
    assert(fork_outcome["closed"] == false, "ambiguous does not close")
    reversed_bundle = OrbitV2FixtureFactory.deep_copy(fork_bundle)
    reversed_bundle["gate_evaluations"].reverse!
    assert(
      derive.call(reversed_bundle)["content_digest"] == fork_outcome["content_digest"],
      "fork projection is order independent"
    )

    # 5. Policy-derived disposition drives closure: unresolved blocking
    #    findings and unadjudicated risks block; hardening never blocks.
    unresolved_bundle = OrbitV2FixtureFactory.valid_bundle
    unresolved_bundle["finding_resolutions"] = []
    assert(
      validator.validate(unresolved_bundle).empty?,
      "an unresolved blocking finding with a failing evaluation is accepted"
    )
    unresolved_outcome = derive.call(unresolved_bundle)
    assert(unresolved_outcome["closed"] == false, "an unresolved blocking finding blocks closure")
    finding = unresolved_bundle["findings"].first
    assert(
      unresolved_outcome["unresolved_blocking_finding_refs"] == [
        { "finding_id" => finding["finding_id"], "content_digest" => finding["content_digest"] }
      ],
      "blocking finding ref is exact"
    )

    hardening_bundle = make_pass_bundle.call
    hardening_bundle["findings"].first["basis"] = "hardening_opportunity"
    rehash(hardening_bundle["findings"].first)
    hardening_bundle["finding_resolutions"] = []
    assert(validator.validate(hardening_bundle).empty?, "hardening without resolution must validate")
    hardening_outcome = derive.call(hardening_bundle)
    assert(hardening_outcome["closed"] == true, "hardening stays nonblocking")
    assert(hardening_outcome["unresolved_blocking_finding_refs"].empty?, "no blocking refs")

    risk_bundle = make_pass_bundle.call
    risk = OrbitV2FixtureFactory.deep_copy(risk_bundle["findings"].first)
    risk["finding_id"] = "ofinding_aggregate_risk"
    risk["basis"] = "newly_discovered_risk"
    risk["supersedes_finding_id"] = nil
    risk["body"] = "Unadjudicated risk probe."
    rehash(risk)
    risk_bundle["gate_evaluations"].first["finding_refs"] =
      Array(risk_bundle["gate_evaluations"].first["finding_refs"]) + [risk["finding_id"]]
    rehash(risk_bundle["gate_evaluations"].first)
    risk_bundle["findings"] << risk
    OrbitV2FixtureFactory.append_finding_change_checkpoint(
      risk_bundle,
      risk,
      {
        "state" => "needs_user",
        "action" => "escalate",
        "reason" => "newly discovered risk requires risk-owner/user adjudication"
      }
    )
    assert(
      validator.validate(risk_bundle).empty?,
      "an unadjudicated risk with checkpoint provenance must validate"
    )
    risk_outcome = derive.call(risk_bundle)
    assert(risk_outcome["closed"] == false, "an unadjudicated risk blocks closure")
    assert(
      risk_outcome["unresolved_adjudication_required_finding_refs"] == [
        { "finding_id" => risk["finding_id"], "content_digest" => risk["content_digest"] }
      ],
      "adjudication-required finding ref is exact"
    )

    # 6. Repeat recomputation is byte-identical; any change to a validated
    #    bundle source changes source/content digests.
    base_outcome = derive.call(OrbitV2FixtureFactory.valid_bundle)
    assert(
      derive.call(OrbitV2FixtureFactory.valid_bundle) == base_outcome,
      "repeat recomputation is byte-identical"
    )
    assert(
      Orbit::V2::CanonicalJSON.digest_excluding(base_outcome, "content_digest") ==
        base_outcome["content_digest"],
      "content_digest covers the whole outcome"
    )
    changed_bundle = OrbitV2FixtureFactory.valid_bundle
    changed_bundle["repository_snapshot"]["commit_sha"] = "b" * 40
    refresh_evaluation_subject(changed_bundle)
    assert(validator.validate(changed_bundle).empty?, "refreshed snapshot bundle must validate")
    changed_outcome = derive.call(changed_bundle)
    assert(
      changed_outcome["source_digest"] != base_outcome["source_digest"],
      "a source change changes source_digest"
    )
    assert(
      changed_outcome["content_digest"] != base_outcome["content_digest"],
      "a source change changes content_digest"
    )
    assert(
      changed_outcome["gate_results"].first["status"] == "not_passed",
      "the refreshed evaluation still decides"
    )

    # 7. The source manifest is complete and unique: exactly one protocol
    #    root, exactly one entry per task/policy revision, no duplicate
    #    (kind, id), and the authority/provenance sources are included.
    manifest = base_outcome["source_manifest"]
    kinds = manifest.group_by { |entry| entry["kind"] }
    assert(kinds.fetch("protocol_root", []).length == 1, "exactly one protocol_root")
    assert(kinds.fetch("task_revision", []).length == 1, "exactly one task_revision")
    assert(
      kinds.fetch("project_policy_revision", []).length == 1,
      "exactly one project_policy_revision"
    )
    assert(
      manifest.map { |entry| [entry["kind"], entry["id"]] }.uniq.length == manifest.length,
      "manifest has no duplicate (kind, id)"
    )
    %w[
      agent_instance authority_assertion authorization_record
      rule_resolution_artifact lead_checkpoint
    ].each do |kind|
      assert(kinds.key?(kind), "manifest includes #{kind} sources")
    end

    # 8. Invalid authority cannot project: removing every AuthorizationRecord
    #    fails closed instead of returning closed=true.
    stripped_bundle = make_pass_bundle.call
    stripped_bundle["authorization_records"] = []
    expect_contract_error("aggregate_outcome_invalid") { derive.call(stripped_bundle) }

    # 9. Invalid evaluator independence cannot project: the evaluator's
    #    runtime identity is replaced with the implementation producer's,
    #    which the Validator rejects; derive fails closed instead of
    #    returning closed=true or a cache identity.
    swapped_bundle = make_pass_bundle.call
    reviewer = swapped_bundle["agent_instances"].find do |agent|
      agent["agent_instance_id"] == "oagent_independentreviewer"
    end
    producer = swapped_bundle["agent_instances"].find do |agent|
      agent["agent_instance_id"] == "oagent_implementerone"
    end
    reviewer["runtime_identity"] = OrbitV2FixtureFactory.deep_copy(producer["runtime_identity"])
    expect_contract_error("aggregate_outcome_invalid") { derive.call(swapped_bundle) }

    # 10. Non-currentness beyond the historical-subject carve-out still
    #     rejects: stale GateRequirement digest, stale active-policy
    #     authority, and malformed subject all fail closed.
    stale_requirement = make_pass_bundle.call
    stale_requirement["gate_evaluations"].first["gate_requirement_content_digest"] =
      "sha256:#{"0" * 64}"
    rehash(stale_requirement["gate_evaluations"].first)
    expect_contract_error("aggregate_outcome_invalid") { derive.call(stale_requirement) }

    stale_policy = OrbitV2FixtureFactory.valid_bundle
    add_policy_successor(stale_policy)
    assert(
      validator.validate(stale_policy).map(&:code).include?("subject_stale"),
      "a rotated task governed by its old policy is stale at the authority path"
    )
    expect_contract_error("aggregate_outcome_invalid") { derive.call(stale_policy) }

    malformed_subject = make_pass_bundle.call
    malformed_subject["gate_evaluations"].first["subject"]["evidence_record_refs"] = []
    rehash(malformed_subject["gate_evaluations"].first)
    expect_contract_error("aggregate_outcome_invalid") { derive.call(malformed_subject) }
  end

  # Slice 5 increment 2: the three responsibility-scoped context projections.
  # Each seam shares the AggregateOutcome validated-input boundary (including
  # the historical `.subject` staleness allowance), is role-fixed (never a
  # label), and emits a canonical, order-independent, role-scoped manifest.
  def test_context_projection
    lead_seam = lambda do |bundle|
      Orbit::V2::ContextProjection.lead(bundle, OrbitV2FixtureFactory::CONTROL_ID, validator: validator)
    end
    work_seam = lambda do |bundle|
      Orbit::V2::ContextProjection.work_agent(bundle, "oattempt_implementationone", validator: validator)
    end
    evaluator_seam = lambda do |bundle|
      Orbit::V2::ContextProjection.evaluator(bundle, "oattempt_independentreview", validator: validator)
    end

    # 1. The lead projection exposes the control registry, the unique
    #    accepted checkpoint tip, the active task/policy, and the current
    #    AggregateOutcome, with a complete role-scoped manifest.
    lead = lead_seam.call(OrbitV2FixtureFactory.valid_bundle)
    assert(lead["context_kind"] == "lead", "lead context kind")
    assert(
      lead["subject_ref"]["lead_control_id"] == OrbitV2FixtureFactory::CONTROL_ID &&
        lead["subject_ref"]["content_digest"].is_a?(String),
      "lead subject ref is the exact registry"
    )
    assert(
      lead["active_checkpoint_ref"]["lead_checkpoint_id"] == "olcheckpoint_slice0successor",
      "tip is the unique accepted checkpoint"
    )
    assert(lead["aggregate_outcome"]["closed"] == false, "lead carries the current aggregate outcome")
    assert(lead["task_queue"].is_a?(Array) && lead["active_task_ref"].is_a?(Hash), "queue and selection are exact")
    lead_manifest = lead["source_manifest"]
    assert(
      lead_manifest.map { |entry| [entry["kind"], entry["id"]] }.uniq.length == lead_manifest.length,
      "lead manifest has no duplicate (kind, id)"
    )
    lead_kinds = lead_manifest.group_by { |entry| entry["kind"] }
    %w[control_registry task_revision project_policy_revision].each do |kind|
      assert(lead_kinds.fetch(kind, []).length == 1, "lead manifest has exactly one #{kind}")
    end
    assert(
      lead_kinds.fetch("lead_checkpoint", []).length ==
        OrbitV2FixtureFactory.valid_bundle["lead_checkpoints"].length,
      "lead manifest covers every embedded aggregate outcome checkpoint dependency"
    )
    assert(
      lead_kinds.fetch("work_unit_attempt", []).length == 4 &&
        lead_kinds.fetch("work_unit", []).length == 3,
      "lead manifest covers the active roster and WorkUnit graph"
    )

    # 2. The work-agent projection is strictly scoped to one implementation
    #    Attempt and its exact task/unit/rules/thesis/checkpoint pins.
    work = work_seam.call(OrbitV2FixtureFactory.valid_bundle)
    assert(work["context_kind"] == "work_agent", "work agent context kind")
    attempt = OrbitV2FixtureFactory.valid_bundle["work_unit_attempts"].find do |candidate|
      candidate["attempt_id"] == "oattempt_implementationone"
    end
    assert(
      work["subject_ref"] == {
        "attempt_id" => "oattempt_implementationone",
        "creation_event_digest" => attempt.dig("events", 0, "event_digest")
      },
      "work agent subject ref is the exact attempt"
    )
    assert(work["assignment"]["purpose"] == "implementation", "immutable assignment purpose")
    assert(work["assigned_rule_resolution"]["resolution_id"].start_with?("rr-sha256-"), "assigned rules artifact")
    assert(work["dispatch_checkpoint_ref"]["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone", "dispatch pin")
    assert(
      work["effective_verification_plan_digest"].is_a?(String) &&
        work["closure_basis_digest"].is_a?(String) && work["plan_basis_source_refs"].is_a?(Hash),
      "plan and basis digests and their exact source refs are pinned"
    )
    work_kinds = work["source_manifest"].group_by { |entry| entry["kind"] }
    assert(
      work_kinds.keys.sort == %w[
        change_thesis lead_checkpoint project_policy_revision rule_resolution_artifact
        task_revision work_unit work_unit_attempt
      ],
      "work agent manifest is exactly its role scope"
    )

    # 3. The evaluator projection exposes the TaskRevision contract, current
    #    canonical subjects, criteria, findings, and plan/basis pins — scoped
    #    to the gate kinds its immutable assignment purpose authorizes.
    evaluator = evaluator_seam.call(OrbitV2FixtureFactory.valid_bundle)
    assert(evaluator["context_kind"] == "evaluator", "evaluator context kind")
    subject = evaluator["subjects"].first["subject"]
    assert(subject["task_revision_ref"]["task_revision_id"] == OrbitV2FixtureFactory::TASK_REVISION_ID, "subject pins the task revision")
    assert(evaluator["evaluation_criteria"].first["questions"].length == 1, "criteria questions")
    assert(evaluator["findings"].length == 1 && evaluator["finding_resolutions"].length == 1, "relevant findings and resolutions")
    assert(evaluator["gate_evaluation_refs"] == [{
      "gate_evaluation_id" => "ogeval_slice0review",
      "content_digest" => OrbitV2FixtureFactory.valid_bundle["gate_evaluations"].first["content_digest"],
      "current" => true
    }], "current evaluation ref is marked current")
    evaluator_kinds = evaluator["source_manifest"].group_by { |entry| entry["kind"] }

    # 3b. A review evaluator never sees another gate kind: a valid task with
    #     an additional test-kind GateRequirement keeps the test context out
    #     of the review evaluator's subjects, criteria, refs, and manifest.
    multi_kind_bundle = OrbitV2FixtureFactory.valid_bundle
    test_gate = OrbitV2FixtureFactory.deep_copy(multi_kind_bundle["gate_requirements"].first)
    test_gate["gate_requirement_id"] = "ogreq_testcontext"
    test_gate["gate_lineage_id"] = "ogline_testcontext"
    test_gate["kind"] = "test"
    test_gate["parent_gate_requirement_ref"] = nil
    rehash(test_gate)
    multi_kind_task = multi_kind_bundle["task_revisions"].first
    multi_kind_task["gate_requirement_refs"] =
      Array(multi_kind_task["gate_requirement_refs"]) + [test_gate["gate_requirement_id"]]
    rehash(multi_kind_task)
    multi_kind_bundle["gate_requirements"] << test_gate
    rebind_checkpoint_refs(multi_kind_bundle, task: multi_kind_task)
    refresh_work_authorizations(multi_kind_bundle, multi_kind_task)
    refresh_evaluation_subject(multi_kind_bundle)
    assert(validator.validate(multi_kind_bundle).empty?, "multi-kind task must validate")
    scoped = evaluator_seam.call(multi_kind_bundle)
    assert(
      scoped["subjects"].map { |entry| entry["gate_requirement_ref"]["gate_requirement_id"] } ==
        [OrbitV2FixtureFactory::GATE_ID] &&
        scoped["evaluation_criteria"].map { |entry| entry["gate_requirement_ref"]["gate_requirement_id"] } ==
          [OrbitV2FixtureFactory::GATE_ID],
      "review evaluator sees only its review-gate subject and criteria"
    )
    assert(
      scoped["source_manifest"].none? { |entry| entry["id"] == "ogreq_testcontext" },
      "review evaluator manifest excludes the test gate"
    )

    # 4. The role is fixed by the seam: wrong-purpose and unknown refs fail
    #    closed instead of relabeling.
    expect_contract_error("context_projection_invalid") do
      Orbit::V2::ContextProjection.work_agent(OrbitV2FixtureFactory.valid_bundle, "oattempt_independentreview", validator: validator)
    end
    expect_contract_error("context_projection_invalid") do
      Orbit::V2::ContextProjection.evaluator(OrbitV2FixtureFactory.valid_bundle, "oattempt_implementationone", validator: validator)
    end
    expect_contract_error("context_projection_invalid") do
      Orbit::V2::ContextProjection.work_agent(OrbitV2FixtureFactory.valid_bundle, "oattempt_missing", validator: validator)
    end

    # 5. No role leaks another role's data: the work-agent context carries no
    #    gate/evidence/finding sources and no other attempts; the evaluator
    #    context carries no lead/agent/session sources or thesis prose.
    assert(
      (work_kinds.keys & %w[evidence_record gate_evaluation gate_requirement finding finding_resolution lead_session agent_instance control_registry]).empty? &&
        work["source_manifest"].count { |entry| entry["kind"] == "work_unit_attempt" } == 1,
      "work agent context excludes other roles' sources and attempts"
    )
    assert(
      (evaluator_kinds.keys & %w[lead_session agent_instance control_registry]).empty? &&
        !evaluator.key?("change_thesis"),
      "evaluator context has no lead/agent sources or thesis prose"
    )
    assert(
      evaluator["subjects"].first["subject"]["implementation_attempt_refs"].all? do |ref|
        ref.keys.sort == %w[attempt_id creation_event_digest]
      end,
      "subject carries exact refs only"
    )

    # 6. Historical stale GateEvaluations stay stored but are marked stale in
    #    current lead/evaluator gate context; the history is not rejected and
    #    the lead source digest follows the embedded outcome's sources.
    stale_bundle = OrbitV2FixtureFactory.valid_bundle
    stale_bundle["gate_evaluations"].first["verdict"] = "pass"
    stale_bundle["gate_evaluations"].first["quality_outcome_verdict"] = "pass"
    stale_bundle["gate_evaluations"].first["acceptance_results"].each { |result| result["verdict"] = "pass" }
    rehash(stale_bundle["gate_evaluations"].first)
    extra_record = OrbitV2FixtureFactory.deep_copy(stale_bundle["evidence_records"].first)
    extra_record["evidence_record_id"] = "oevr_implementationoneextra"
    rehash(extra_record)
    stale_bundle["evidence_records"] << extra_record
    assert(
      validator.validate(stale_bundle).map(&:code) == ["subject_stale"],
      "appended accepted evidence makes only the old evaluation subject-stale"
    )
    stale_lead = lead_seam.call(stale_bundle)
    assert(
      stale_lead["gate_evaluation_refs"].first["current"] == false &&
        stale_lead["aggregate_outcome"]["gate_results"].first["status"] == "missing",
      "lead context marks the stale evaluation non-current and the gate missing"
    )
    assert(
      stale_lead["source_digest"] != lead["source_digest"],
      "lead source digest covers the embedded aggregate outcome's sources"
    )
    assert(
      evaluator_seam.call(stale_bundle)["gate_evaluation_refs"].first["current"] == false,
      "evaluator context marks the stale evaluation non-current"
    )

    # 7. Missing or inconsistent plan/basis pins fail closed.
    no_plan = OrbitV2FixtureFactory.valid_bundle
    no_plan["lead_checkpoints"].find { |cp| cp["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone" }
         .delete("effective_verification_plan_digest")
    expect_contract_error("aggregate_outcome_invalid") { work_seam.call(no_plan) }
    bad_plan = OrbitV2FixtureFactory.valid_bundle
    bad_dispatch = bad_plan["lead_checkpoints"].find { |cp| cp["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone" }
    bad_dispatch["closure_basis_digest"] = "sha256:#{"0" * 64}"
    expect_contract_error("aggregate_outcome_invalid") { work_seam.call(bad_plan) }

    # 8. Every projection is order independent.
    reversed_bundle = OrbitV2FixtureFactory.valid_bundle
    reversed_bundle["work_unit_attempts"].reverse!
    reversed_bundle["gate_evaluations"].reverse!
    reversed_bundle["findings"].reverse!
    assert(lead_seam.call(reversed_bundle)["content_digest"] == lead["content_digest"], "lead is order independent")
    assert(work_seam.call(reversed_bundle)["content_digest"] == work["content_digest"], "work agent is order independent")
    assert(evaluator_seam.call(reversed_bundle)["content_digest"] == evaluator["content_digest"], "evaluator is order independent")

    # 9. Role-scoped source-digest sensitivity: unrelated sources never
    #    perturb the narrower projections; exposed source changes always do.
    unrelated_bundle = OrbitV2FixtureFactory.valid_bundle
    extra_submission = OrbitV2FixtureFactory.deep_copy(
      unrelated_bundle["evidence_records"].find { |record| record["record_kind"] == "evaluator_submission" }
    )
    extra_submission["evidence_record_id"] = "oevr_independentreviewextra"
    rehash(extra_submission)
    unrelated_bundle["evidence_records"] << extra_submission
    assert(validator.validate(unrelated_bundle).empty?, "an unrelated extra submission keeps the bundle valid")
    assert(
      work_seam.call(unrelated_bundle)["content_digest"] == work["content_digest"] &&
        evaluator_seam.call(unrelated_bundle)["content_digest"] == evaluator["content_digest"],
      "an unrelated bundle change perturbs neither narrower projection"
    )

    changed_task_bundle = OrbitV2FixtureFactory.valid_bundle
    task = changed_task_bundle["task_revisions"].first
    task["goal"] = "A changed goal must not change the work agent's role scope."
    rehash(task)
    rebind_checkpoint_refs(changed_task_bundle, task: task)
    refresh_work_authorizations(changed_task_bundle, task)
    refresh_evaluation_subject(changed_task_bundle)
    assert(validator.validate(changed_task_bundle).empty?, "changed task bundle must validate")
    assert(
      work_seam.call(changed_task_bundle)["content_digest"] != work["content_digest"],
      "an exposed source change perturbs the work agent projection"
    )

    changed_snapshot_bundle = OrbitV2FixtureFactory.valid_bundle
    changed_snapshot_bundle["repository_snapshot"]["commit_sha"] = "b" * 40
    refresh_evaluation_subject(changed_snapshot_bundle)
    assert(validator.validate(changed_snapshot_bundle).empty?, "refreshed snapshot bundle must validate")
    assert(
      evaluator_seam.call(changed_snapshot_bundle)["content_digest"] != evaluator["content_digest"],
      "an exposed subject source change perturbs the evaluator projection"
    )

    # 10. Invalid authority/independence rejects every seam through the
    #     shared projection-validation boundary.
    stripped_bundle = OrbitV2FixtureFactory.valid_bundle
    stripped_bundle["authorization_records"] = []
    [lead_seam, work_seam, evaluator_seam].each do |seam|
      expect_contract_error("aggregate_outcome_invalid") { seam.call(stripped_bundle) }
    end
    swapped_bundle = OrbitV2FixtureFactory.valid_bundle
    reviewer = swapped_bundle["agent_instances"].find { |agent| agent["agent_instance_id"] == "oagent_independentreviewer" }
    producer = swapped_bundle["agent_instances"].find { |agent| agent["agent_instance_id"] == "oagent_implementerone" }
    reviewer["runtime_identity"] = OrbitV2FixtureFactory.deep_copy(producer["runtime_identity"])
    [lead_seam, work_seam, evaluator_seam].each do |seam|
      expect_contract_error("aggregate_outcome_invalid") { seam.call(swapped_bundle) }
    end
  end

  # Slice 5 increment 3: the pure deterministic Typed RelationshipView.
  # derive(bundle, validator:) shares the projection-validation boundary,
  # emits canonical typed nodes/edges for the ADR-003 chains, keeps
  # candidate_edges mechanically empty, and never lets a stale evaluation
  # become a current/closing relation.
  def test_relationship_view
    derive = lambda do |bundle|
      Orbit::V2::RelationshipView.derive(bundle, validator: validator)
    end
    edge_kinds = lambda do |view|
      view["derived_edges"].group_by { |edge| edge["kind"] }
    end
    edge_count = lambda do |kinds, kind|
      kinds.fetch(kind, []).length
    end
    edge_between = lambda do |kinds, kind, source_id, target_id|
      kinds.fetch(kind, []).any? do |edge|
        edge["source"]["id"] == source_id && edge["target"]["id"] == target_id
      end
    end
    base = derive.call(OrbitV2FixtureFactory.valid_bundle)
    kinds = edge_kinds.call(base)

    # 1. Protocol/policy/task/unit/gate chains carry exact identities.
    assert(
      edge_count.call(kinds, "protocol_root_pins_policy_genesis") == 1 &&
        edge_between.call(kinds, "protocol_root_pins_policy_genesis", "oproj_slice0fixture", "opolicy_genesis0001"),
      "protocol root pins the exact policy genesis"
    )
    assert(edge_count.call(kinds, "policy_parent_lineage") == 0, "genesis policy has no parent edge")
    assert(
      edge_count.call(kinds, "task_revision_governed_by_policy") == 1 &&
        edge_between.call(kinds, "task_revision_governed_by_policy", "trev_slice0contract_r1", "opolicy_genesis0001"),
      "task revision pins its exact policy"
    )
    assert(edge_count.call(kinds, "task_revision_owns_work_unit") == 3, "task owns its WorkUnit graph")
    assert(
      edge_count.call(kinds, "task_revision_requires_gate") == 1 &&
        edge_between.call(kinds, "task_revision_requires_gate", "trev_slice0contract_r1", "ogreq_slice0review"),
      "task requires its exact gate"
    )
    assert(
      edge_count.call(kinds, "work_unit_parent") == 2 &&
        edge_between.call(kinds, "work_unit_parent", "owu_independentreview", "owu_implementationone"),
      "WorkUnit parent refs are exact"
    )
    assert(
      edge_count.call(kinds, "work_unit_depends_on") == 3 &&
        edge_between.call(kinds, "work_unit_depends_on", "owu_independentreview", "owu_implementationtwo"),
      "WorkUnit dependency refs are exact"
    )
    assert(
      edge_count.call(kinds, "work_unit_pins_initial_thesis") == 3 &&
        edge_between.call(kinds, "work_unit_pins_initial_thesis", "owu_implementationone", "othesis_implementationone@1"),
      "WorkUnit pins its immutable initial thesis"
    )

    # 2. Control/checkpoint/session chains and queue/selection refs.
    checkpoints = OrbitV2FixtureFactory.valid_bundle["lead_checkpoints"]
    assert(
      edge_count.call(kinds, "control_registry_has_genesis_checkpoint") == 1 &&
        edge_count.call(kinds, "control_registry_owns_task") == 1,
      "registry pins genesis checkpoint and owned task"
    )
    assert(
      edge_count.call(kinds, "lead_checkpoint_under_control") == checkpoints.length,
      "every checkpoint belongs to its control"
    )
    assert(
      edge_count.call(kinds, "lead_checkpoint_queues_task_revision") == checkpoints.length &&
        checkpoints.all? do |cp|
          Array(cp["task_queue"]).all? do |queued|
            edge_between.call(kinds, "lead_checkpoint_queues_task_revision", cp["lead_checkpoint_id"], queued["task_revision_id"])
          end
        end,
      "every checkpoint task queue ref is represented exactly"
    )
    assert(
      edge_count.call(kinds, "lead_checkpoint_active_task") ==
        checkpoints.count { |cp| cp["active_task_ref"].is_a?(Hash) } &&
        edge_count.call(kinds, "lead_checkpoint_selected_work_unit") ==
          checkpoints.count { |cp| cp["selected_work_unit_ref"].is_a?(Hash) } &&
        edge_count.call(kinds, "lead_checkpoint_tracks_attempt") ==
          checkpoints.count { |cp| cp["current_or_terminal_attempt_ref"].is_a?(Hash) },
      "checkpoint selection and attempt refs are exact"
    )
    assert(
      edge_count.call(kinds, "lead_session_belongs_to_control") == 2 &&
        edge_count.call(kinds, "lead_session_binds_runtime_subject") == 2,
      "sessions bind their control and provider-verified runtime subject"
    )
    assert(
      base["nodes"].count { |node| node["kind"] == "runtime_subject" } == 1,
      "shared runtime subject dedupes to one node"
    )

    # 3. Attempt/evidence/artifact-claim chains.
    %w[
      work_unit_attempt_belongs_to_unit work_unit_attempt_belongs_to_task
      work_unit_attempt_under_control work_unit_attempt_uses_agent
      work_unit_attempt_uses_thesis work_unit_attempt_uses_rule_resolution
      work_unit_attempt_dispatched_by work_unit_has_attempt
    ].each do |kind|
      assert(edge_count.call(kinds, kind) == 4, "#{kind} covers every attempt")
    end
    assert(
      edge_between.call(kinds, "work_unit_attempt_uses_agent", "oattempt_implementationone", "oagent_implementerone") &&
        edge_between.call(kinds, "work_unit_attempt_dispatched_by", "oattempt_implementationone", "olcheckpoint_dispatch_implone") &&
        edge_between.call(kinds, "work_unit_has_attempt", "owu_implementationone", "oattempt_implementationonesuccessor"),
      "attempt pins its exact agent, dispatch checkpoint, and owning unit"
    )
    assert(
      edge_count.call(kinds, "evidence_record_produced_by_attempt") == 3 &&
        edge_count.call(kinds, "evidence_record_submits_rule_resolution") == 3,
      "evidence records bind their producing attempt and submitted rules"
    )
    assert(
      edge_count.call(kinds, "evidence_record_supports_change_thesis") == 2,
      "implementation evidence structurally supports its thesis"
    )
    assert(
      edge_count.call(kinds, "evidence_record_claims_artifact") == 5 &&
        base["nodes"].count { |node| node["kind"] == "artifact_claim" } == 5 &&
        base["nodes"].select { |node| node["kind"] == "artifact_claim" }.all? { |node| node["id"].include?("::") },
      "every submission artifact claim is a unique per-record node and edge"
    )
    # Cross-record artifact reuse is valid and collision-safe: two records
    # may reuse the same artifact URI with different digests; claim nodes
    # stay per-record and edges stay exact.
    reuse_bundle = OrbitV2FixtureFactory.valid_bundle
    reuse_submission = OrbitV2FixtureFactory.deep_copy(
      reuse_bundle["evidence_records"].find { |record| record["record_kind"] == "evaluator_submission" }
    )
    reuse_submission["evidence_record_id"] = "oevr_independentreviewreuse"
    reuse_submission["submission_artifact_refs"].first["content_digest"] = "sha256:#{"1" * 64}"
    rehash(reuse_submission)
    reuse_bundle["evidence_records"] << reuse_submission
    assert(validator.validate(reuse_bundle).empty?, "cross-record artifact reuse must validate")
    reuse_view = derive.call(reuse_bundle)
    reuse_claims = reuse_view["nodes"].select { |node| node["kind"] == "artifact_claim" }
    assert(
      reuse_claims.length == 6 &&
        reuse_claims.count { |node| node["artifact_ref"] == "artifact://oevr_independentreview/report" } == 2 &&
        reuse_claims.select { |node| node["artifact_ref"] == "artifact://oevr_independentreview/report" }
                    .map { |node| node["content_digest"] }.uniq.length == 2 &&
        reuse_claims.any? { |node| node["id"].start_with?("oevr_independentreviewreuse::") },
      "reused artifact URIs produce distinct per-record claim nodes with exact digests"
    )
    assert(
      reuse_view["derived_edges"].count { |edge| edge["kind"] == "evidence_record_claims_artifact" } == 6,
      "every claim edge stays exact under artifact reuse"
    )

    # 4. Gate/finding/resolution chains with exact subject refs and current
    #    flags.
    assert(
      edge_count.call(kinds, "gate_evaluation_requires_gate") == 1 &&
        edge_count.call(kinds, "gate_evaluation_evaluated_by_attempt") == 1 &&
        edge_count.call(kinds, "gate_evaluation_submitted_by_record") == 1,
      "gate evaluation binds its exact requirement, evaluator, and submission"
    )
    %w[
      gate_evaluation_subject_task_revision gate_evaluation_subject_repository_snapshot
      gate_evaluation_subject_code_surface
    ].each do |kind|
      assert(edge_count.call(kinds, kind) == 1, "#{kind} is exact")
    end
    assert(
      edge_count.call(kinds, "gate_evaluation_subject_work_unit") == 2 &&
        edge_count.call(kinds, "gate_evaluation_subject_implementation_attempt") == 2 &&
        edge_count.call(kinds, "gate_evaluation_subject_evidence_record") == 2,
      "subject pins its exact implementation units, attempts, and evidence"
    )
    assert(
      edge_count.call(kinds, "gate_evaluation_reports_finding") == 1 &&
        edge_count.call(kinds, "finding_reported_by_gate_evaluation") == 1 &&
        edge_count.call(kinds, "finding_resolution_resolves_finding") == 1,
      "finding and resolution chains are exact"
    )
    assert(
      base["nodes"].find { |node| node["kind"] == "gate_evaluation" }["current"] == true,
      "the current evaluation node is marked current"
    )

    # 5. Canonical recompute and order independence.
    assert(derive.call(OrbitV2FixtureFactory.valid_bundle) == base, "repeat recomputation is byte-identical")
    assert(
      Orbit::V2::CanonicalJSON.digest_excluding(base, "content_digest") == base["content_digest"],
      "content_digest covers the whole view"
    )
    assert(
      base["nodes"] == base["nodes"].sort_by { |node| [node["kind"], node["id"]] } &&
        base["derived_edges"] == base["derived_edges"].sort_by { |edge| [edge["kind"], edge["source"]["kind"], edge["source"]["id"], edge["target"]["kind"], edge["target"]["id"]] },
      "nodes and edges are canonically sorted"
    )
    reversed_bundle = OrbitV2FixtureFactory.valid_bundle
    reversed_bundle["work_unit_attempts"].reverse!
    reversed_bundle["evidence_records"].reverse!
    reversed_bundle["gate_evaluations"].reverse!
    assert(
      derive.call(reversed_bundle)["content_digest"] == base["content_digest"],
      "unrelated array order never changes the view"
    )

    # 6. Historical stale evaluations stay stored with their edges but are
    #    marked non-current and never become closing relations.
    stale_bundle = OrbitV2FixtureFactory.valid_bundle
    stale_bundle["gate_evaluations"].first["verdict"] = "pass"
    stale_bundle["gate_evaluations"].first["quality_outcome_verdict"] = "pass"
    stale_bundle["gate_evaluations"].first["acceptance_results"].each { |result| result["verdict"] = "pass" }
    rehash(stale_bundle["gate_evaluations"].first)
    extra_record = OrbitV2FixtureFactory.deep_copy(stale_bundle["evidence_records"].first)
    extra_record["evidence_record_id"] = "oevr_implementationoneextra"
    rehash(extra_record)
    stale_bundle["evidence_records"] << extra_record
    assert(
      validator.validate(stale_bundle).map(&:code) == ["subject_stale"],
      "appended accepted evidence makes only the old evaluation subject-stale"
    )
    stale_view = derive.call(stale_bundle)
    stale_evaluation_node = stale_view["nodes"].find { |node| node["kind"] == "gate_evaluation" }
    assert(stale_evaluation_node["current"] == false, "the historical evaluation is marked non-current")
    assert(
      edge_kinds.call(stale_view)["gate_evaluation_subject_work_unit"].length == 2,
      "the historical evaluation keeps its stored subject edges"
    )
    assert(
      !stale_view["nodes"].any? { |node| node["kind"] == "gate_evaluation" && node["current"] },
      "no stale evaluation becomes a current relation"
    )

    # 7. Candidate edges are mechanically isolated: the contract has no
    #    candidate fact source, so the section is always empty and any
    #    attempted candidate input is rejected by the shared boundary.
    assert(base["candidate_edges"] == [], "candidate section is explicitly empty")
    candidate_bundle = OrbitV2FixtureFactory.valid_bundle
    candidate_bundle["candidate_relations"] = [{ "kind" => "candidate", "source" => "x", "target" => "y" }]
    expect_contract_error("aggregate_outcome_invalid") { derive.call(candidate_bundle) }

    # 8. Invalid authority/independence/refs fail closed through the public
    #    seam.
    stripped_bundle = OrbitV2FixtureFactory.valid_bundle
    stripped_bundle["authorization_records"] = []
    expect_contract_error("aggregate_outcome_invalid") { derive.call(stripped_bundle) }
    swapped_bundle = OrbitV2FixtureFactory.valid_bundle
    reviewer = swapped_bundle["agent_instances"].find { |agent| agent["agent_instance_id"] == "oagent_independentreviewer" }
    producer = swapped_bundle["agent_instances"].find { |agent| agent["agent_instance_id"] == "oagent_implementerone" }
    reviewer["runtime_identity"] = OrbitV2FixtureFactory.deep_copy(producer["runtime_identity"])
    expect_contract_error("aggregate_outcome_invalid") { derive.call(swapped_bundle) }
    phantom_gate = OrbitV2FixtureFactory.valid_bundle
    phantom_gate["task_revisions"].first["gate_requirement_refs"] = ["ogreq_missing"]
    expect_contract_error("aggregate_outcome_invalid") { derive.call(phantom_gate) }

    # 9. Any exposed source change invalidates the digests.
    changed_bundle = OrbitV2FixtureFactory.valid_bundle
    changed_bundle["repository_snapshot"]["commit_sha"] = "b" * 40
    refresh_evaluation_subject(changed_bundle)
    assert(validator.validate(changed_bundle).empty?, "refreshed snapshot bundle must validate")
    changed_view = derive.call(changed_bundle)
    assert(
      changed_view["source_digest"] != base["source_digest"] &&
        changed_view["content_digest"] != base["content_digest"],
      "a snapshot change invalidates the view digests"
    )
    appended_bundle = OrbitV2FixtureFactory.valid_bundle
    extra_submission = OrbitV2FixtureFactory.deep_copy(
      appended_bundle["evidence_records"].find { |record| record["record_kind"] == "evaluator_submission" }
    )
    extra_submission["evidence_record_id"] = "oevr_independentreviewextra"
    rehash(extra_submission)
    appended_bundle["evidence_records"] << extra_submission
    assert(validator.validate(appended_bundle).empty?, "an extra submission keeps the bundle valid")
    assert(
      derive.call(appended_bundle)["source_digest"] != base["source_digest"],
      "an appended exposed source invalidates the view digests"
    )

    # 10. Duplicate prevention: node and edge identities are unique on the
    #     canonical graph.
    node_identities = base["nodes"].map { |node| [node["kind"], node["id"]] }
    edge_identities = base["derived_edges"].map do |edge|
      [edge["kind"], edge["source"]["kind"], edge["source"]["id"], edge["target"]["kind"], edge["target"]["id"]]
    end
    assert(
      node_identities.uniq.length == node_identities.length &&
        edge_identities.uniq.length == edge_identities.length,
      "the view emits no duplicate node or edge identity"
    )
  end

  # Slice 5 increment 4: the agent-independent digest and two-layer budget
  # projection. derive(bundle, validator:) recomputes every checkpoint's
  # plan/basis/adjustment digests byte-identical through ControlAuthority
  # and projects the two cumulative budget scopes in fixed order without
  # ever summing checkpoints.
  def test_budget_projection
    derive = lambda do |bundle|
      Orbit::V2::BudgetProjection.derive(bundle, validator: validator)
    end
    view_for = lambda do |bundle, checkpoint_id|
      derive.call(bundle)["checkpoint_views"].find do |view|
        view["lead_checkpoint_ref"]["lead_checkpoint_id"] == checkpoint_id
      end
    end
    relationship = lambda do |bundle|
      Orbit::V2::RelationshipView.derive(bundle, validator: validator)
    end

    # 1. Every accepted checkpoint projects byte-identical digests, the two
    #    cumulative scopes in fixed order, and exact source refs/manifest.
    base_bundle = OrbitV2FixtureFactory.valid_bundle
    base_projection = derive.call(base_bundle)
    base_views = base_projection["checkpoint_views"]
    assert(base_views.length == 9, "one view per accepted checkpoint")
    assert(
      base_views == base_views.sort_by { |view| view["lead_checkpoint_ref"]["lead_checkpoint_id"] },
      "views are canonically ordered"
    )
    base_views.each do |view|
      checkpoint = base_bundle["lead_checkpoints"].find do |candidate|
        candidate["lead_checkpoint_id"] == view["lead_checkpoint_ref"]["lead_checkpoint_id"]
      end
      assert(
        view["budget_scopes"].map { |scope| scope["budget_scope_type"] } ==
          %w[work_unit_lineage task_lineage] &&
          view["budget_scopes"].all? do |scope|
            scope["measurements"].map { |row| row["metric"] } == %w[test_count test_code_lines]
          end &&
          view["budget_scopes"].each_with_index.all? do |scope, index|
            scope["binding_digest"] == Orbit::V2::ControlAuthority.binding_digest(
              checkpoint["effective_budget_bindings"][index]
            )
          end,
        "budget scopes are the two fixed scopes with exact binding digests and metric order"
      )
      assert(
        view["effective_verification_plan_digest"].is_a?(String) &&
          view["closure_basis_digest"].is_a?(String) &&
          !view.key?("budget_adjustment_digest") &&
          view["source_refs"].keys.sort == %w[
            assigned_rule_resolution_ref change_thesis_ref project_policy_revision_ref
            selected_work_unit_ref task_revision_ref
          ] &&
          Orbit::V2::CanonicalJSON.digest_excluding(view, "content_digest") == view["content_digest"] &&
          view["source_digest"] ==
            "sha256:#{Orbit::V2::CanonicalJSON.sha256(view["source_manifest"])}" &&
          view["source_manifest"].map { |entry| [entry["kind"], entry["id"]] }.uniq.length ==
            view["source_manifest"].length,
        "plan/basis digests project, adjustment is absent, and view digests cover the complete manifest"
      )
    end

    # 2. Verified measurements expose deterministic within/over against the
    #    binding's effective ceilings; unverified measurements are never
    #    zero or within-budget, and each view reads its own cumulative
    #    snapshot (checkpoints are never summed).
    over_bundle = OrbitV2FixtureFactory.valid_bundle
    tip = over_bundle["lead_checkpoints"].last
    task = over_bundle["task_revisions"].first
    unit = over_bundle["work_units"].find { |c| c["work_unit_id"] == tip.dig("selected_work_unit_ref", "work_unit_id") }
    policy = over_bundle["project_policy_revisions"].first
    wu_measurements = OrbitV2FixtureFactory.attested_measurements(
      over_bundle, usage_count: 12, usage_lines: 400, task: task, unit: unit, policy: policy, scope: "work_unit_lineage"
    )
    task_measurements = OrbitV2FixtureFactory.attested_measurements(
      over_bundle, usage_count: 25, usage_lines: 700, task: task, unit: unit, policy: policy, scope: "task_lineage"
    )
    pinned_attempt = over_bundle["work_unit_attempts"].find do |attempt|
      attempt["attempt_id"] == tip.dig("current_or_terminal_attempt_ref", "attempt_id")
    end
    resolution = over_bundle["rule_resolution_artifacts"].find do |artifact|
      artifact["resolution_id"] == pinned_attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id")
    end
    bindings = OrbitV2FixtureFactory.default_budget_bindings(
      policy: policy,
      predecessor_checkpoint: over_bundle["lead_checkpoints"][-2],
      active_task_ref: tip["active_task_ref"],
      selected_work_unit_ref: tip["selected_work_unit_ref"],
      measurements_by_scope: { "work_unit_lineage" => wu_measurements, "task_lineage" => task_measurements }
    )
    over_bundle["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(
      tip,
      policy: policy,
      predecessor_checkpoint: over_bundle["lead_checkpoints"][-2],
      bindings: bindings,
      attempt: pinned_attempt,
      resolution: resolution
    )
    assert(validator.validate(over_bundle).empty?, "attested over/within budget bundle must validate")
    over_tip_id = OrbitV2FixtureFactory.valid_bundle["lead_checkpoints"].last["lead_checkpoint_id"]
    over_tip = view_for.call(over_bundle, over_tip_id)
    assert(
      over_tip["budget_scopes"][0]["measurements"].map { |row| [row["verified"], row["budget_status"], row["usage"]] } ==
        [[true, "over", 12], [true, "over", 400]] &&
        over_tip["budget_scopes"][1]["measurements"].map { |row| [row["verified"], row["budget_status"], row["usage"]] } ==
          [[true, "within", 25], [true, "within", 700]],
      "work_unit usage over and task usage within the effective ceilings are deterministic"
    )
    predecessor_rows = view_for.call(over_bundle, OrbitV2FixtureFactory.valid_bundle["lead_checkpoints"][-2]["lead_checkpoint_id"])["budget_scopes"][0]["measurements"]
    assert(
      predecessor_rows.all? { |row| row["verified"] == false && row["budget_status"] == "unverified_pending" } &&
        predecessor_rows.none? { |row| row.key?("usage") },
      "unverified pending measurements are never zero or within-budget"
    )
    assert(
      derive.call(over_bundle)["checkpoint_views"].count { |view| view["budget_scopes"][0]["measurements"][0]["usage"] == 12 } == 1,
      "the attested usage belongs to exactly its own checkpoint snapshot"
    )

    # 3. budget_adjustment_digest projects iff the current typed adjustment
    #    exists, byte-identical to the canonical payload digest.
    adjust_bundle = OrbitV2FixtureFactory.adjustment_bundle(mode: :valid)
    adjusted_checkpoint = adjust_bundle["lead_checkpoints"].find do |checkpoint|
      checkpoint["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone"
    end
    adjusted_view = view_for.call(adjust_bundle, "olcheckpoint_dispatch_implone")
    assert(
      adjusted_view["budget_adjustment_digest"] ==
        Orbit::V2::ControlAuthority.budget_adjustment_digest(adjusted_checkpoint["test_budget_adjust"]),
      "the adjusted checkpoint projects the canonical adjustment digest"
    )
    assert(
      derive.call(adjust_bundle)["checkpoint_views"].all? do |view|
        view["lead_checkpoint_ref"]["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone" ||
          !view.key?("budget_adjustment_digest")
      end,
      "every other checkpoint omits the adjustment digest"
    )

    # 4. A legitimate budget source change always changes source_digest: two
    #    valid resealed bundles differing only in the unverified assessments'
    #    lead_reason_code produce different checkpoint/binding/source digests.
    build_reasoned = lambda do |reason|
      bundle = OrbitV2FixtureFactory.valid_bundle
      tip = bundle["lead_checkpoints"].last
      policy = bundle["project_policy_revisions"].first
      measurements = OrbitV2FixtureFactory.unverified_pending_measurements(lead_reason_code: reason)
      bindings = OrbitV2FixtureFactory.default_budget_bindings(
        policy: policy,
        predecessor_checkpoint: bundle["lead_checkpoints"][-2],
        active_task_ref: tip["active_task_ref"],
        selected_work_unit_ref: tip["selected_work_unit_ref"],
        measurements: measurements
      )
      pinned_attempt = bundle["work_unit_attempts"].find do |attempt|
        attempt["attempt_id"] == tip.dig("current_or_terminal_attempt_ref", "attempt_id")
      end
      resolution = bundle["rule_resolution_artifacts"].find do |artifact|
        artifact["resolution_id"] == pinned_attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id")
      end
      bundle["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(
        tip,
        policy: policy,
        predecessor_checkpoint: bundle["lead_checkpoints"][-2],
        bindings: bindings,
        attempt: pinned_attempt,
        resolution: resolution
      )
      bundle
    end
    reasoned_tip = OrbitV2FixtureFactory.valid_bundle["lead_checkpoints"].last["lead_checkpoint_id"]
    reasoned_a = build_reasoned.call("Reason alpha.")
    reasoned_b = build_reasoned.call("Reason beta.")
    view_a = view_for.call(reasoned_a, reasoned_tip)
    view_b = view_for.call(reasoned_b, reasoned_tip)
    assert(
      validator.validate(reasoned_a).empty? && validator.validate(reasoned_b).empty? &&
        view_a["lead_checkpoint_ref"]["content_digest"] != view_b["lead_checkpoint_ref"]["content_digest"] &&
        view_a["budget_scopes"][0]["binding_digest"] != view_b["budget_scopes"][0]["binding_digest"] &&
        view_a["source_digest"] != view_b["source_digest"],
      "a legitimate budget source change changes the view source digest"
    )
    assert(
      view_a["source_manifest"].any? { |entry| entry["kind"] == "budget_binding" } &&
        view_a["source_manifest"].any? { |entry| entry["kind"] == "lead_checkpoint" },
      "the source manifest covers checkpoint and binding identities"
    )
    # An unresealed source mutation still fails closed at the boundary.
    mutated_digest = OrbitV2FixtureFactory.valid_bundle
    mutated_digest["lead_checkpoints"].last["effective_verification_plan_digest"] = "sha256:#{"0" * 64}"
    expect_contract_error("aggregate_outcome_invalid") { derive.call(mutated_digest) }

    # 5. An accepted budget review is a valid bundle and the relationship
    #    view derives it without rejecting itself: both unverified metrics
    #    canonically share one review ref, so exactly one review edge is
    #    emitted per binding; rejected is safe by the same rule. The bundle
    #    is built by the shared Slice 4 reviewed_budget_bundle business path.
    accepted_bundle = reviewed_budget_bundle(outcome: "accepted")
    assert(validator.validate(accepted_bundle).empty?, "accepted budget review consumption validates end to end")
    accepted_review_edges = relationship.call(accepted_bundle)["derived_edges"].select do |edge|
      edge["kind"] == "budget_binding_uses_review" &&
        edge["source"]["id"] == "olcheckpoint_budgetreviewed::work_unit_lineage"
    end
    assert(
      accepted_review_edges.length == 1 &&
        accepted_review_edges.first["target"]["id"] == "ogeval_budgetassessment" &&
        accepted_review_edges.first["target"]["content_digest"] ==
          accepted_bundle["gate_evaluations"].find { |e| e["gate_evaluation_id"] == "ogeval_budgetassessment" }["content_digest"],
      "the accepted review emits exactly one exact review relation per binding"
    )
    rejected_bundle = reviewed_budget_bundle(outcome: "rejected")
    assert(validator.validate(rejected_bundle).empty?, "rejected budget review consumption validates end to end")
    rejected_review_edges = relationship.call(rejected_bundle)["derived_edges"].select do |edge|
      edge["kind"] == "budget_binding_uses_review" &&
        edge["source"]["id"] == "olcheckpoint_budgetreviewed::work_unit_lineage"
    end
    assert(rejected_review_edges.length == 1, "the rejected review emits exactly one review relation")

    # 6. The typed digest chains on the adjustment bundle: the adjustment
    #    digest points to its exact policy/predecessor provenance, bindings
    #    link to their current/inherited adjustment identity, and the plan/
    #    closure rule sources carry the exact identity_sha256 (never the
    #    artifact object digest).
    adjust_view = relationship.call(adjust_bundle)
    adjust_kinds = adjust_view["derived_edges"].group_by { |edge| edge["kind"] }
    adjustment_digest = adjusted_checkpoint["budget_adjustment_digest"]
    assert(
      adjust_view["nodes"].any? { |node| node["kind"] == "budget_adjustment_digest" && node["id"] == adjustment_digest } &&
        adjust_kinds.fetch("lead_checkpoint_derives_adjustment_digest", []).any? do |edge|
          edge["source"]["id"] == "olcheckpoint_dispatch_implone" && edge["target"]["id"] == adjustment_digest
        end &&
        adjust_kinds.fetch("budget_adjustment_digest_policy_source", []).any? do |edge|
          edge["source"]["id"] == adjustment_digest && edge["target"]["kind"] == "project_policy_revision"
        end &&
        adjust_kinds.fetch("budget_adjustment_digest_predecessor_source", []).any? do |edge|
          edge["source"]["id"] == adjustment_digest && edge["target"]["id"] == "olcheckpoint_genesis_slice0"
        end &&
        adjust_kinds.fetch("budget_adjustment_digest_predecessor_binding", []).any? do |edge|
          edge["source"]["id"] == adjustment_digest &&
            edge["target"]["id"] == "olcheckpoint_genesis_slice0::work_unit_lineage" &&
            edge["target"]["content_digest"] == adjusted_checkpoint.dig("test_budget_adjust", "predecessor_binding_digest")
        end,
      "the adjustment digest points to its exact policy, predecessor checkpoint, and predecessor binding"
    )
    adjustment_links = adjust_kinds.fetch("budget_binding_uses_adjustment_digest", []).select do |edge|
      edge["source"]["id"] == "olcheckpoint_dispatch_implone::work_unit_lineage"
    end
    assert(
      adjustment_links.length == 1 && adjustment_links.first["target"]["id"] == adjustment_digest &&
        adjust_kinds.fetch("budget_binding_inherited_checkpoint_source", []).any? do |edge|
          edge["source"]["id"].start_with?("olcheckpoint_") && edge["target"]["kind"] == "lead_checkpoint"
        end,
      "bindings link to their current/inherited adjustment identity and provenance"
    )
    plan_rule_edges = adjust_kinds.fetch("effective_verification_plan_digest_rule_source", []).select do |edge|
      edge["source"]["id"].start_with?("olcheckpoint_dispatch_implone::")
    end
    rule_artifact = base_bundle["rule_resolution_artifacts"][0]
    assert(
      plan_rule_edges.length == 1 &&
        plan_rule_edges.first["target"]["kind"] == "rule_identity" &&
        plan_rule_edges.first["target"]["content_digest"] == rule_artifact["identity_sha256"] &&
        plan_rule_edges.first["target"]["content_digest"] != rule_artifact["content_digest"] &&
        adjust_kinds.fetch("closure_basis_digest_rule_source", []).any? do |edge|
          edge["target"]["kind"] == "rule_identity" && edge["target"]["content_digest"] == rule_artifact["identity_sha256"]
        end,
      "plan and closure rule sources carry the exact identity_sha256, not the artifact object digest"
    )
    assert(
      adjust_kinds.keys.none? { |kind| kind.start_with?("lead_checkpoint_plan_") } &&
        adjust_view["candidate_edges"] == [],
      "no generic mislabeled plan edges remain and candidate edges stay non-authoritative"
    )

    # 7. Adjustment supporting provenance: schema-authorized
    #    test_budget_adjust.supporting_refs resolve exactly through the
    #    shared boundary, project in the source manifest with collision-safe
    #    event identity, and derive as typed supporting edges.
    task_ref = OrbitV2FixtureFactory.task_ref(base_bundle["task_revisions"].first)
    supported_bundle = OrbitV2FixtureFactory.adjustment_bundle(
      mode: :valid,
      supporting_refs: [{ "kind" => "task_revision", "id" => task_ref["task_revision_id"], "digest" => task_ref["content_digest"] }]
    )
    assert(
      validator.validate(supported_bundle).empty?,
      "an exact TaskRevision supporting ref validates end to end"
    )
    supported_view = view_for.call(supported_bundle, "olcheckpoint_dispatch_implone")
    assert(
      supported_view["source_manifest"].any? do |entry|
        entry["kind"] == "task_revision" && entry["id"] == task_ref["task_revision_id"]
      end,
      "the supported adjustment manifest carries the exact TaskRevision source"
    )
    supported_edges = relationship.call(supported_bundle)["derived_edges"].select do |edge|
      edge["kind"] == "budget_adjustment_digest_supporting_source" &&
        edge["target"]["kind"] == "task_revision"
    end
    assert(supported_edges.length == 1, "the adjustment digest derives its exact supporting TaskRevision edge")
    forged_bundle = OrbitV2FixtureFactory.adjustment_bundle(
      mode: :valid,
      supporting_refs: [{ "kind" => "task_revision", "id" => "trev_nonexistent_support", "digest" => "sha256:#{"0" * 64}" }]
    )
    assert(
      validator.validate(forged_bundle).map(&:code).include?("checkpoint_supporting_ref_invalid"),
      "a nonexistent supporting TaskRevision ref fails closed in the Validator"
    )
    expect_contract_error("aggregate_outcome_invalid") { derive.call(forged_bundle) }
    expect_contract_error("aggregate_outcome_invalid") { relationship.call(forged_bundle) }
    mismatched_bundle = OrbitV2FixtureFactory.adjustment_bundle(
      mode: :valid,
      supporting_refs: [{ "kind" => "task_revision", "id" => task_ref["task_revision_id"], "digest" => "sha256:#{"0" * 64}" }]
    )
    assert(
      validator.validate(mismatched_bundle).map(&:code).include?("checkpoint_supporting_ref_invalid"),
      "a digest-mismatched supporting TaskRevision ref fails closed"
    )
    expect_contract_error("aggregate_outcome_invalid") { derive.call(mismatched_bundle) }
    lead_agent = base_bundle["agent_instances"].find { |agent| agent["agent_instance_id"] == "oagent_logicalleadmain" }
    events = lead_agent["lifecycle_events"].first(2)
    event_bundle = OrbitV2FixtureFactory.adjustment_bundle(
      mode: :valid,
      supporting_refs: events.map do |event|
        { "kind" => "agent_event", "id" => lead_agent["agent_instance_id"], "event_id" => event["event_id"], "digest" => event["event_digest"] }
      end
    )
    assert(validator.validate(event_bundle).empty?, "two exact events from one agent validate")
    event_entries = view_for.call(event_bundle, "olcheckpoint_dispatch_implone")["source_manifest"].select do |entry|
      entry["kind"] == "agent_event"
    end
    assert(
      event_entries.length == 2 &&
        event_entries.map { |entry| entry["id"] }.uniq.length == 2 &&
        event_entries.all? { |entry| entry["id"].include?("::") },
      "event sources keep owner::event_id identity and never collide"
    )
    # Duplicate exact supporting refs are schema-legal; the view dedupes
    # them instead of rejecting the bundle.
    support_ref = {
      "kind" => "task_revision",
      "id" => task_ref["task_revision_id"],
      "digest" => task_ref["content_digest"]
    }
    duplicate_bundle = OrbitV2FixtureFactory.adjustment_bundle(
      mode: :valid,
      supporting_refs: [support_ref, OrbitV2FixtureFactory.deep_copy(support_ref)]
    )
    assert(validator.validate(duplicate_bundle).empty?, "duplicate supporting refs validate")
    assert(
      relationship.call(duplicate_bundle)["derived_edges"].count do |edge|
        edge["kind"] == "budget_adjustment_digest_supporting_source" &&
          edge["target"]["kind"] == "task_revision"
      end == 1,
      "duplicate exact supporting refs emit exactly one support edge"
    )
    # Exact unverified-assessment lead_supporting_refs are binding sources
    # and derive as typed binding-support edges.
    lead_support_bundle = OrbitV2FixtureFactory.valid_bundle
    lead_tip = lead_support_bundle["lead_checkpoints"].last
    lead_policy = lead_support_bundle["project_policy_revisions"].first
    lead_measurements = OrbitV2FixtureFactory.unverified_pending_measurements(
      lead_supporting_refs: [support_ref]
    )
    lead_bindings = OrbitV2FixtureFactory.default_budget_bindings(
      policy: lead_policy,
      predecessor_checkpoint: lead_support_bundle["lead_checkpoints"][-2],
      active_task_ref: lead_tip["active_task_ref"],
      selected_work_unit_ref: lead_tip["selected_work_unit_ref"],
      measurements: lead_measurements
    )
    lead_attempt = lead_support_bundle["work_unit_attempts"].find do |attempt|
      attempt["attempt_id"] == lead_tip.dig("current_or_terminal_attempt_ref", "attempt_id")
    end
    lead_resolution = lead_support_bundle["rule_resolution_artifacts"].find do |artifact|
      artifact["resolution_id"] == lead_attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id")
    end
    lead_support_bundle["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(
      lead_tip,
      policy: lead_policy,
      predecessor_checkpoint: lead_support_bundle["lead_checkpoints"][-2],
      bindings: lead_bindings,
      attempt: lead_attempt,
      resolution: lead_resolution
    )
    assert(validator.validate(lead_support_bundle).empty?, "lead supporting refs validate")
    lead_support_edges = relationship.call(lead_support_bundle)["derived_edges"].select do |edge|
      edge["kind"] == "budget_binding_uses_supporting_source" &&
        edge["source"]["id"] == "#{lead_tip["lead_checkpoint_id"]}::work_unit_lineage"
    end
    assert(
      lead_support_edges.length == 1 &&
        lead_support_edges.first["target"]["kind"] == "task_revision" &&
        lead_support_edges.first["target"]["id"] == support_ref["id"],
      "shared lead supporting refs emit exactly one typed binding-support edge"
    )
    # Two distinct exact same-owner events in lead_supporting_refs never
    # collide in the budget projection source manifest.
    lead_event_measurements = OrbitV2FixtureFactory.unverified_pending_measurements(
      lead_supporting_refs: events.map do |event|
        {
          "kind" => "agent_event",
          "id" => lead_agent["agent_instance_id"],
          "event_id" => event["event_id"],
          "digest" => event["event_digest"]
        }
      end.sort_by { |ref| [ref["kind"], ref["id"], ref["digest"]].join("\u0000") }
    )
    lead_event_bundle = OrbitV2FixtureFactory.valid_bundle
    event_tip = lead_event_bundle["lead_checkpoints"].last
    event_bindings = OrbitV2FixtureFactory.default_budget_bindings(
      policy: lead_event_bundle["project_policy_revisions"].first,
      predecessor_checkpoint: lead_event_bundle["lead_checkpoints"][-2],
      active_task_ref: event_tip["active_task_ref"],
      selected_work_unit_ref: event_tip["selected_work_unit_ref"],
      measurements: lead_event_measurements
    )
    event_attempt = lead_event_bundle["work_unit_attempts"].find do |attempt|
      attempt["attempt_id"] == event_tip.dig("current_or_terminal_attempt_ref", "attempt_id")
    end
    event_resolution = lead_event_bundle["rule_resolution_artifacts"].find do |artifact|
      artifact["resolution_id"] == event_attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id")
    end
    lead_event_bundle["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(
      event_tip,
      policy: lead_event_bundle["project_policy_revisions"].first,
      predecessor_checkpoint: lead_event_bundle["lead_checkpoints"][-2],
      bindings: event_bindings,
      attempt: event_attempt,
      resolution: event_resolution
    )
    assert(validator.validate(lead_event_bundle).empty?, "two same-owner lead supporting events validate")
    lead_event_entries = view_for.call(lead_event_bundle, event_tip["lead_checkpoint_id"])["source_manifest"].select do |entry|
      entry["kind"] == "agent_event"
    end
    assert(
      lead_event_entries.length == 2 &&
        lead_event_entries.map { |entry| entry["id"] }.uniq.length == 2 &&
        lead_event_entries.all? { |entry| entry["id"].start_with?("oagent_logicalleadmain::") },
      "distinct same-owner lead supporting events keep owner::event_id manifest identity"
    )

    # 8. Deletion/rebuild equivalence, repeat recomputation, and order
    #    independence.
    assert(
      derive.call(base_bundle) == base_projection &&
        Orbit::V2::CanonicalJSON.digest_excluding(base_projection, "content_digest") ==
          base_projection["content_digest"],
      "repeat recomputation is byte-identical and self-consistent"
    )
    reversed_bundle = OrbitV2FixtureFactory.valid_bundle
    reversed_bundle["lead_checkpoints"].reverse!
    reversed_bundle["work_unit_attempts"].reverse!
    assert(
      derive.call(reversed_bundle)["content_digest"] == base_projection["content_digest"],
      "unrelated array order never changes the projection"
    )

    # 9. Invalid authority/independence fail closed through the public seam.
    stripped_bundle = OrbitV2FixtureFactory.valid_bundle
    stripped_bundle["authorization_records"] = []
    expect_contract_error("aggregate_outcome_invalid") { derive.call(stripped_bundle) }
    swapped_bundle = OrbitV2FixtureFactory.valid_bundle
    reviewer = swapped_bundle["agent_instances"].find { |agent| agent["agent_instance_id"] == "oagent_independentreviewer" }
    producer = swapped_bundle["agent_instances"].find { |agent| agent["agent_instance_id"] == "oagent_implementerone" }
    reviewer["runtime_identity"] = OrbitV2FixtureFactory.deep_copy(producer["runtime_identity"])
    expect_contract_error("aggregate_outcome_invalid") { derive.call(swapped_bundle) }
  end

  # Shared Slice 4 inc 2 business path: one-way C_pending -> independent
  # budget GateEvaluation -> immediate successor C_reviewed consumption.
  # Both the consumer-closure tests and the Slice 5 budget projection tests
  # drive the identical real acceptance path through this helper.
  def reviewed_budget_bundle(
    outcome:,
    select_budget_gate: true,
    with_result: true,
    pending_statuses: nil,
    adjustment: false,
    mixed: false,
    continue_decision: { "state" => "blocked", "action" => "continue", "reason" => "authoritative change observed" },
    frozen_decision: { "state" => "frozen", "action" => "freeze", "reason" => "independent budget review rejected: replan required" },
    dispatch_decision: { "state" => "blocked", "action" => "dispatch", "reason" => "dispatch authorized" }
  )
    bundle = OrbitV2FixtureFactory.valid_bundle
    task = bundle["task_revisions"].first
    gate = if select_budget_gate
      budget_gate = OrbitV2FixtureFactory.deep_copy(bundle["gate_requirements"].first)
      budget_gate["gate_requirement_id"] = "ogreq_budgetassessment"
      budget_gate["gate_lineage_id"] = "ogline_budgetassessment"
      budget_gate["subject_selector"]["budget_assessment_required"] = true
      rehash(budget_gate)
      task["gate_requirement_refs"] = Array(task["gate_requirement_refs"]) + [budget_gate["gate_requirement_id"]]
      rehash(task)
      rebind_checkpoint_refs(bundle, task: task)
      refresh_work_authorizations(bundle, task)
      bundle["gate_requirements"] << budget_gate
      refresh_evaluation_subject(bundle)
      budget_gate
    else
      bundle["gate_requirements"].first
    end
    if adjustment
      policy = bundle["project_policy_revisions"].first
      tip = bundle["lead_checkpoints"].last
      payload = { "budget_scope_type" => "work_unit_lineage", "project_policy_revision_ref" => OrbitV2FixtureFactory.policy_ref(policy), "predecessor_lead_checkpoint_ref" => OrbitV2FixtureFactory.cp_ref(tip), "predecessor_binding_digest" => Orbit::V2::ControlAuthority.binding_digest(tip["effective_budget_bindings"].first), "old_effective_budget" => { "test_count" => tip["effective_budget_bindings"].first["effective_test_count"], "test_code_lines" => tip["effective_budget_bindings"].first["effective_test_code_lines"] }, "new_effective_budget" => { "test_count" => 15, "test_code_lines" => 450 }, "supporting_refs" => [] }
      proposal = OrbitV2FixtureFactory.deep_copy(tip)
      proposal["lead_checkpoint_id"] = "olcheckpoint_budgetproposal"
      proposal["predecessor_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(tip)
      proposal["current_or_terminal_attempt_ref"] = nil
      proposal["assessments"] = OrbitV2FixtureFactory.checkpoint_assessments(proposal["active_task_ref"], proposal["selected_work_unit_ref"], nil)
      proposal["reconcile_trigger"] = { "event" => "budget_change", "reason" => "Proposed budget adjustment pending independent review." }
      proposal["next_trigger"] = { "event" => "gate_change", "reason" => "Awaiting the independent budget review." }
      proposal["lead_decision"] = { "state" => "blocked", "action" => "continue", "reason" => "budget adjustment proposed pending independent review" }
      %w[delivery_progress assurance_progress].each { |field| proposal[field] = OrbitV2FixtureFactory.checkpoint_progress("not_assessed").merge("predecessor_lead_checkpoint_ref" => proposal["predecessor_lead_checkpoint_ref"], "supporting_refs" => []) }
      wu_measurements = OrbitV2FixtureFactory.unverified_pending_measurements
      if mixed
        unit = bundle["work_units"].find { |candidate| candidate["work_unit_id"] == proposal.dig("selected_work_unit_ref", "work_unit_id") }
        attested = OrbitV2FixtureFactory.attested_measurements(bundle, usage_count: 3, usage_lines: 30, task: task, unit: unit, policy: policy, scope: "work_unit_lineage")
        wu_measurements = OrbitV2FixtureFactory.deep_copy(wu_measurements).merge("test_count" => attested["test_count"])
      end
      bindings = OrbitV2FixtureFactory.default_budget_bindings(policy: policy, predecessor_checkpoint: tip, active_task_ref: proposal["active_task_ref"], selected_work_unit_ref: proposal["selected_work_unit_ref"], budget_adjustment: payload, measurements_by_scope: { "work_unit_lineage" => wu_measurements, "task_lineage" => OrbitV2FixtureFactory.unverified_pending_measurements })
      bundle["lead_checkpoints"] << OrbitV2FixtureFactory.reseal_checkpoint(proposal, policy: policy, predecessor_checkpoint: tip, bindings: bindings, budget_adjustment: payload)
    end
    pending = bundle["lead_checkpoints"].last
    if pending_statuses
      unit = bundle["work_units"].find { |candidate| candidate["work_unit_id"] == pending.dig("selected_work_unit_ref", "work_unit_id") }
      attested = OrbitV2FixtureFactory.attested_measurements(bundle, usage_count: 3, usage_lines: 30, task: task, unit: unit, policy: bundle["project_policy_revisions"].first, scope: "work_unit_lineage")
      mixed = OrbitV2FixtureFactory.deep_copy(pending["effective_budget_bindings"].first["measurements"])
      pending_statuses.each { |metric, status| mixed[metric] = status == "verified" ? attested[metric] : OrbitV2FixtureFactory.unverified_pending_measurements[metric] }
      pinned_attempt = (ref = pending["current_or_terminal_attempt_ref"]) && bundle["work_unit_attempts"].find { |a| a["attempt_id"] == ref["attempt_id"] }
      resolution = pinned_attempt && bundle["rule_resolution_artifacts"].find { |r| r["resolution_id"] == pinned_attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id") }
      pending_bindings = OrbitV2FixtureFactory.default_budget_bindings(policy: bundle["project_policy_revisions"].first, predecessor_checkpoint: bundle["lead_checkpoints"][-2], active_task_ref: pending["active_task_ref"], selected_work_unit_ref: pending["selected_work_unit_ref"], measurements_by_scope: { "work_unit_lineage" => mixed, "task_lineage" => pending["effective_budget_bindings"][1]["measurements"] })
      bundle["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(pending, policy: bundle["project_policy_revisions"].first, predecessor_checkpoint: bundle["lead_checkpoints"][-2], bindings: pending_bindings, attempt: pinned_attempt, resolution: resolution)
      pending = bundle["lead_checkpoints"].last
    end
    source = bundle["gate_evaluations"].first
    evaluation = OrbitV2FixtureFactory.deep_copy(source)
    evaluation["gate_evaluation_id"] = "ogeval_budgetassessment"
    evaluation["gate_requirement_id"] = gate["gate_requirement_id"]
    evaluation["gate_requirement_content_digest"] = gate["content_digest"]
    evaluation["supersedes_gate_evaluation_id"] = nil
    evaluation["finding_refs"] = []
    subject = Orbit::V2::EvaluationSubject.select(
      gate_requirement: gate,
      task_revision: task,
      work_units: bundle["work_units"],
      attempts: bundle["work_unit_attempts"],
      evidence_records: bundle["evidence_records"],
      repository_snapshot: bundle["repository_snapshot"],
      code_surface: bundle["code_surface"]
    )
    assessed_binding = pending["effective_budget_bindings"].find do |candidate|
      candidate["budget_scope_type"] == "work_unit_lineage"
    end
    projection = Orbit::V2::ControlAuthority.budget_review_subject_projection_digest(assessed_binding)
    subject["budget_review_subject_projection"] = projection
    rehash_subject(subject)
    evaluation["subject"] = subject
    if with_result
      evaluation["budget_assessment_result"] = {
        "assessed_checkpoint_ref" => OrbitV2FixtureFactory.cp_ref(pending),
        "assessed_effective_budget_binding_digest" =>
          Orbit::V2::ControlAuthority.binding_digest(assessed_binding),
        "lead_control_id" => pending["lead_control_id"],
        "scope" => "work_unit_lineage",
        "metric_statuses" => {
          "test_count" => assessed_binding.dig("measurements", "test_count", "status"),
          "test_code_lines" => assessed_binding.dig("measurements", "test_code_lines", "status")
        },
        "outcome" => outcome
      }
    end
    rehash(evaluation)
    bundle["gate_evaluations"] << evaluation

    reviewed = OrbitV2FixtureFactory.deep_copy(pending)
    reviewed["lead_checkpoint_id"] = "olcheckpoint_budgetreviewed"
    reviewed["predecessor_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(pending)
    reviewed["current_or_terminal_attempt_ref"] = nil
    reviewed["assessments"] = OrbitV2FixtureFactory.checkpoint_assessments(reviewed["active_task_ref"], reviewed["selected_work_unit_ref"], nil)
    gate_ref = { "kind" => "gate_evaluation", "id" => evaluation["gate_evaluation_id"], "digest" => evaluation["content_digest"] }
    proposal_refs = [gate_ref]
    if adjustment
      unit = bundle["work_units"].find { |candidate| candidate["work_unit_id"] == reviewed.dig("selected_work_unit_ref", "work_unit_id") }
      thesis = bundle["change_theses"].find { |candidate| candidate["work_unit_id"] == unit["work_unit_id"] }
      review_attempt = bundle["work_unit_attempts"].find { |candidate| candidate["attempt_id"] == "oattempt_independentreview" }
      rule = bundle["rule_resolution_artifacts"].find { |candidate| candidate["resolution_id"] == review_attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id") }
      proposal_refs << { "kind" => "change_thesis", "id" => thesis["change_thesis_id"], "digest" => thesis["content_digest"] }
      proposal_refs << { "kind" => "rule_resolution", "id" => rule["resolution_id"], "digest" => rule["identity_sha256"] }
    end
    reviewed["delivery_progress"] = OrbitV2FixtureFactory.checkpoint_progress("not_assessed").merge("predecessor_lead_checkpoint_ref" => reviewed["predecessor_lead_checkpoint_ref"], "supporting_refs" => proposal_refs)
    reviewed["assurance_progress"] = OrbitV2FixtureFactory.checkpoint_progress("not_assessed").merge("predecessor_lead_checkpoint_ref" => reviewed["predecessor_lead_checkpoint_ref"], "supporting_refs" => [gate_ref])
    reviewed["reconcile_trigger"] = { "event" => "gate_change", "reason" => "Independent budget review consumed." }
    reviewed["next_trigger"] = outcome == "accepted" && adjustment ?
      { "event" => "attempt_created", "reason" => "Awaiting the dispatched Attempt creation." } :
      { "event" => "successor_before", "reason" => "Awaiting the successor boundary." }
    reviewed["lead_decision"] = outcome == "rejected" ? frozen_decision : (adjustment ? dispatch_decision : continue_decision)
    reviewed["budget_adjustment_digest"] = nil
    reviewed["test_budget_adjust"] = nil
    reviewed_measurements = OrbitV2FixtureFactory.deep_copy(assessed_binding["measurements"])
    disposition = outcome == "accepted" ? "proceed_after_independent_review" : "replan_after_independent_rejection"
    ref = { "gate_evaluation_id" => evaluation["gate_evaluation_id"], "content_digest" => evaluation["content_digest"] }
    %w[test_count test_code_lines].each do |metric|
      next if reviewed_measurements[metric]["status"] == "verified"

      reviewed_measurements[metric]["unverified_assessment"]["review_status"] = outcome
      reviewed_measurements[metric]["unverified_assessment"]["lead_disposition"] = disposition
      reviewed_measurements[metric]["unverified_assessment"]["review_gate_evaluation_ref"] = ref
    end
    reviewed_bindings = OrbitV2FixtureFactory.default_budget_bindings(
      policy: bundle["project_policy_revisions"].first,
      predecessor_checkpoint: pending,
      active_task_ref: reviewed["active_task_ref"],
      selected_work_unit_ref: reviewed["selected_work_unit_ref"],
      measurements_by_scope: {
        "work_unit_lineage" => reviewed_measurements,
        "task_lineage" => OrbitV2FixtureFactory.unverified_pending_measurements
      }
    )
    reviewed = OrbitV2FixtureFactory.reseal_checkpoint(
      reviewed,
      policy: bundle["project_policy_revisions"].first,
      predecessor_checkpoint: pending,
      bindings: reviewed_bindings
    )
    bundle["lead_checkpoints"] << reviewed
    bundle
  end

  # Slice 5 increment 5: the pure derived CodeSurface construction seam.
  # derive(repository_snapshot:, paths:) builds the exact
  # derived_code_surface contract object with the single canonical digest
  # rule shared by EvaluationSubject; no filesystem reads, no writer.
  def test_code_surface
    derive = lambda do |snapshot, paths|
      Orbit::V2::CodeSurface.derive(repository_snapshot: snapshot, paths: paths)
    end
    base = OrbitV2FixtureFactory.valid_bundle
    snapshot = base["repository_snapshot"]
    paths = base["code_surface"]["paths"]

    # 1. Valid derivation produces the exact derived_code_surface shape with
    #    the single canonical digest rule; the seam exposes exactly one
    #    public construction method.
    assert(
      Orbit::V2::CodeSurface.methods(false).sort == [:derive],
      "the CodeSurface seam exposes exactly one public construction method"
    )
    surface = derive.call(snapshot, paths)
    assert(
      surface == {
        "kind" => "derived_code_surface",
        "derivation_version" => "orbit-code-surface-v1",
        "repository_tree_digest" => snapshot["tree_digest"],
        "paths" => paths,
        "code_surface_digest" => Orbit::V2::EvaluationSubject.code_surface_digest(
          derivation_version: "orbit-code-surface-v1",
          repository_tree_digest: snapshot["tree_digest"],
          paths: paths
        )
      },
      "derived surface matches the exact contract shape and canonical digest rule"
    )

    # 2. Rebuilding from the same snapshot+paths is byte-identical; input
    #    order and duplicates are not silently canonicalized — the contract's
    #    canonical-set invariant fails closed instead.
    assert(
      derive.call(snapshot, paths) == surface,
      "rebuilding from the same snapshot and paths is byte-identical"
    )
    expect_contract_error("derived_input_invalid") { derive.call(snapshot, paths.reverse) }
    expect_contract_error("derived_input_invalid") { derive.call(snapshot, paths + [paths.first]) }
    # The returned surface copies its inputs deeply enough: in-place
    # mutation of an input path string after derive leaves the output paths,
    # element identity, and digest consistent.
    mutable_paths = paths.map(&:dup)
    mutated_surface = derive.call(snapshot, mutable_paths)
    mutable_paths.first << "/mutated"
    assert(
      mutated_surface["paths"] == paths &&
        !mutated_surface["paths"].first.equal?(mutable_paths.first) &&
        mutated_surface["paths"].none? { |path| path.include?("/mutated") } &&
        Orbit::V2::ProjectionPrimitives.code_surface_digest(
          derivation_version: "orbit-code-surface-v1",
          repository_tree_digest: snapshot["tree_digest"],
          paths: mutated_surface["paths"]
        ) == mutated_surface["code_surface_digest"],
      "mutating an input path string after derive leaves output paths, identity, and digest consistent"
    )

    # 3. A tree digest or canonical path-set change changes the surface
    #    digest.
    assert(
      derive.call(snapshot.merge("tree_digest" => "sha256:#{"1" * 64}"), paths)["code_surface_digest"] !=
        surface["code_surface_digest"],
      "a tree digest change changes the surface digest"
    )
    extended_paths = (paths + ["contracts/orbit-v2/contract.yaml"]).sort
    assert(
      derive.call(snapshot, extended_paths)["code_surface_digest"] != surface["code_surface_digest"],
      "a canonical path-set change changes the surface digest"
    )

    # 4. Invalid snapshot and non-canonical path sets fail closed.
    invalid_inputs = {
      "unknown field" => lambda { derive.call(snapshot.merge("untrusted_extra" => "accepted"), paths) },
      "missing kind" => lambda { derive.call(snapshot.reject { |key, _| key == "kind" }, paths) },
      "bad commit sha" => lambda { derive.call(snapshot.merge("commit_sha" => "z" * 40), paths) },
      "bad tree digest" => lambda { derive.call(snapshot.merge("tree_digest" => "sha256:nothex"), paths) },
      "empty paths" => lambda { derive.call(snapshot, []) },
      "absolute path" => lambda { derive.call(snapshot, ["/lib/orbit/v2"]) },
      "traversal path" => lambda { derive.call(snapshot, ["lib/orbit/v2/../v1"]) },
      "empty segment" => lambda { derive.call(snapshot, ["lib//orbit/v2"]) },
      "backslash path" => lambda { derive.call(snapshot, ["lib\\orbit\\v2"]) }
    }
    invalid_inputs.each_value do |probe|
      expect_contract_error("derived_input_invalid") { probe.call }
    end

    # 5. The seam is the single construction rule: a surface derived by the
    #    public seam is the accepted canonical CodeSurface of a bundle, and
    #    EvaluationSubject preserves its established error paths.
    integration = OrbitV2FixtureFactory.deep_copy(base)
    integration["code_surface"] = surface
    assert(validator.validate(integration).empty?, "the derived surface is the accepted canonical CodeSurface")
    bad_path_bundle = OrbitV2FixtureFactory.deep_copy(base)
    bad_path_bundle["code_surface"]["paths"] = ["lib/orbit/v2/../v1"]
    bad_path_errors = validator.validate(bad_path_bundle)
    assert(
      bad_path_errors.any? { |error| error.code == "derived_input_invalid" && error.path == "code_surface" },
      "an invalid stored CodeSurface path set fails at the code_surface path"
    )
    # Direct EvaluationSubject probes preserve the established error paths
    # (the bundle-level snapshot shape is schema-closed, so the semantic
    # repository_snapshot path is exercised through the public select seam).
    select_with = lambda do |repository_snapshot:, code_surface:|
      Orbit::V2::EvaluationSubject.select(
        gate_requirement: base["gate_requirements"].first,
        task_revision: base["task_revisions"].first,
        work_units: base["work_units"],
        attempts: base["work_unit_attempts"],
        evidence_records: base["evidence_records"],
        repository_snapshot: repository_snapshot,
        code_surface: code_surface
      )
    end
    bad_snapshot_error = begin
      select_with.call(
        repository_snapshot: snapshot.merge("untrusted_extra" => "accepted"),
        code_surface: base["code_surface"]
      )
      nil
    rescue Orbit::V2::ContractError => error
      error
    end
    assert(
      bad_snapshot_error && bad_snapshot_error.code == "derived_input_invalid" &&
        bad_snapshot_error.path == "repository_snapshot",
      "an invalid repository snapshot fails at the repository_snapshot path"
    )
    bad_surface_error = begin
      select_with.call(
        repository_snapshot: snapshot,
        code_surface: base["code_surface"].merge("paths" => ["lib/orbit/v2/../v1"])
      )
      nil
    rescue Orbit::V2::ContractError => error
      error
    end
    assert(
      bad_surface_error && bad_surface_error.code == "derived_input_invalid" &&
        bad_surface_error.path == "code_surface",
      "an invalid stored CodeSurface path set fails at the code_surface path"
    )
  end

  # Slice 5 increment 6: the pure structural integrity/drift audit
  # projection. derive(bundle, validator:) shares the projection-validation
  # boundary and emits four mechanically frozen sections.
  def test_integrity_audit
    derive = lambda do |bundle|
      Orbit::V2::IntegrityAudit.derive(bundle, validator: validator)
    end
    base = OrbitV2FixtureFactory.valid_bundle
    audit = derive.call(base)

    # 1. A clean canonical bundle reports nothing in any section and the
    #    audit is canonical and deterministic.
    assert(
      audit["drifted_gate_evaluations"] == [] &&
        audit["orphan_code_surface_paths"] == [] &&
        audit["stale_evidence_records"] == [] &&
        audit["unresolved_findings"] == [],
      "the clean canonical bundle reports no drift, orphans, stale evidence, or unresolved findings"
    )
    assert(
      audit["schema_version"] == "orbit-integrity-audit-v1" &&
        audit["protocol_epoch"] == "orbit-v2" &&
        audit["project_id"] == OrbitV2FixtureFactory::PROJECT_ID,
      "the audit carries schema/protocol/project identity"
    )
    assert(
      derive.call(base) == audit &&
        Orbit::V2::CanonicalJSON.digest_excluding(audit, "content_digest") == audit["content_digest"] &&
        audit["source_manifest"].any? { |entry| entry["kind"] == "gate_evaluation" },
      "the audit is byte-identical on rebuild, self-consistent, and carries the complete source manifest"
    )

    # 2. A historical stale evaluation is reported with exact stored and
    #    current subject digests; current evaluations stay absent.
    stale_bundle = OrbitV2FixtureFactory.valid_bundle
    stale_bundle["gate_evaluations"].first["verdict"] = "pass"
    stale_bundle["gate_evaluations"].first["quality_outcome_verdict"] = "pass"
    stale_bundle["gate_evaluations"].first["acceptance_results"].each { |result| result["verdict"] = "pass" }
    rehash(stale_bundle["gate_evaluations"].first)
    extra_record = OrbitV2FixtureFactory.deep_copy(stale_bundle["evidence_records"].first)
    extra_record["evidence_record_id"] = "oevr_implementationoneextra"
    rehash(extra_record)
    stale_bundle["evidence_records"] << extra_record
    assert(
      validator.validate(stale_bundle).map(&:code) == ["subject_stale"],
      "appended accepted evidence makes only the old evaluation subject-stale"
    )
    drifted = derive.call(stale_bundle)["drifted_gate_evaluations"]
    stored_digest = stale_bundle["gate_evaluations"].first.dig("subject", "subject_digest")
    current_subject = Orbit::V2::EvaluationSubject.select(
      gate_requirement: stale_bundle["gate_requirements"].first,
      task_revision: stale_bundle["task_revisions"].first,
      work_units: stale_bundle["work_units"],
      attempts: stale_bundle["work_unit_attempts"],
      evidence_records: stale_bundle["evidence_records"],
      repository_snapshot: stale_bundle["repository_snapshot"],
      code_surface: stale_bundle["code_surface"]
    )
    assert(
      drifted.length == 1 &&
        drifted.first["gate_evaluation_ref"]["gate_evaluation_id"] == "ogeval_slice0review" &&
        drifted.first["stored_subject_digest"] == stored_digest &&
        drifted.first["current_subject_digest"] == current_subject["subject_digest"] &&
        stale_bundle["gate_evaluations"].first["content_digest"] ==
          drifted.first["gate_evaluation_ref"]["content_digest"],
      "the historical evaluation is drifted with exact stored and current subject digests"
    )

    # 3. A valid extra CodeSurface path is exactly one orphan; segment-aware
    #    parent/child overlap is not a false positive.
    orphan_bundle = OrbitV2FixtureFactory.valid_bundle
    orphan_bundle["code_surface"] = Orbit::V2::CodeSurface.derive(
      repository_snapshot: orphan_bundle["repository_snapshot"],
      paths: (orphan_bundle["code_surface"]["paths"] + ["docs/open", "contracts"]).sort
    )
    refresh_evaluation_subject(orphan_bundle)
    assert(validator.validate(orphan_bundle).empty?, "the extended surface bundle must validate")
    assert(
      derive.call(orphan_bundle)["orphan_code_surface_paths"] == ["docs/open"],
      "only the uncovered surface path is orphaned; parent/child overlap is not a false positive"
    )

    # 4. A revision-2 ChangeThesis makes revision-1 implementation evidence
    #    stale with the exact stored and current thesis refs; evaluator
    #    submissions are excluded. Clean tip-pinned absence is covered by
    #    scenario 1 (an in-place rewrite is Validator-blocked; see below).
    stale_evidence_bundle = OrbitV2FixtureFactory.valid_bundle
    thesis = stale_evidence_bundle["change_theses"].find do |candidate|
      candidate["change_thesis_id"] == "othesis_implementationone"
    end
    thesis2 = OrbitV2FixtureFactory.deep_copy(thesis)
    thesis2["revision"] = 2
    rehash(thesis2)
    stale_evidence_bundle["change_theses"] << thesis2
    assert(validator.validate(stale_evidence_bundle).empty?, "a contiguous revision-2 thesis validates")
    stale_records = derive.call(stale_evidence_bundle)["stale_evidence_records"]
    assert(
      stale_records.length == 1 &&
        stale_records.first["evidence_record_ref"]["evidence_record_id"] == "oevr_implementationone" &&
        stale_records.first["stored_change_thesis_ref"]["revision"] == 1 &&
        stale_records.first["current_change_thesis_ref"] == {
          "change_thesis_id" => "othesis_implementationone",
          "content_digest" => thesis2["content_digest"],
          "revision" => 2
        },
      "the revision-1 implementation record is stale against the accepted tip; the evaluator submission is excluded"
    )
    # Tip-pinned records are absent (scenario 1 proves the clean case); an
    # in-place record rewrite to a new tip is Validator-blocked because the
    # Slice 2 dispatch contract requires the AttemptCreated assignment to
    # equal the dispatch's authorized proposal, so staleness always follows
    # the validated lineage.

    # 5. Unresolved blocking, adjudication-required, and nonblocking
    #    findings are classified from the active policy; a valid resolution
    #    tip removes the finding.
    unresolved_bundle = OrbitV2FixtureFactory.valid_bundle
    evaluation = unresolved_bundle["gate_evaluations"].first
    append_finding = lambda do |id, basis|
      finding = OrbitV2FixtureFactory.deep_copy(unresolved_bundle["findings"].first)
      finding["finding_id"] = id
      finding["basis"] = basis
      finding["supersedes_finding_id"] = nil
      finding["body"] = "Typed #{basis} audit probe."
      rehash(finding)
      evaluation["finding_refs"] = Array(evaluation["finding_refs"]) + [finding["finding_id"]]
      rehash(evaluation)
      unresolved_bundle["findings"] << finding
      finding
    end
    hardening = append_finding.call("ofinding_hardening_audit", "hardening_opportunity")
    risk = append_finding.call("ofinding_risk_audit", "newly_discovered_risk")
    OrbitV2FixtureFactory.append_finding_change_checkpoint(
      unresolved_bundle,
      risk,
      {
        "state" => "needs_user",
        "action" => "escalate",
        "reason" => "newly discovered risk requires risk-owner/user adjudication"
      }
    )
    unresolved_bundle["finding_resolutions"] = []
    assert(validator.validate(unresolved_bundle).empty?, "the typed-finding bundle must validate")
    unresolved = derive.call(unresolved_bundle)["unresolved_findings"]
    assert(
      unresolved.map { |entry| [entry["finding_ref"]["finding_id"], entry["disposition"]] }.sort ==
        [
          ["ofinding_hardening_audit", "nonblocking"],
          ["ofinding_risk_audit", "adjudication_required"],
          ["ofinding_slice0example", "blocking"]
        ],
      "blocking, adjudication-required, and nonblocking findings classify from the active policy"
    )
    waiver = OrbitV2FixtureFactory.deep_copy(
      OrbitV2FixtureFactory.valid_bundle["finding_resolutions"].first
    )
    unresolved_bundle["finding_resolutions"] << waiver
    assert(
      validator.validate(unresolved_bundle).empty? &&
        derive.call(unresolved_bundle)["unresolved_findings"].length == 2,
      "a valid resolution tip removes the blocking finding"
    )

    # 6. Array order never changes the audit; any exposed source change
    #    invalidates the digests.
    reversed_bundle = OrbitV2FixtureFactory.valid_bundle
    reversed_bundle["work_unit_attempts"].reverse!
    reversed_bundle["evidence_records"].reverse!
    reversed_bundle["findings"].reverse!
    assert(
      derive.call(reversed_bundle)["content_digest"] == audit["content_digest"],
      "unrelated array order never changes the audit"
    )
    changed_bundle = OrbitV2FixtureFactory.valid_bundle
    changed_bundle["repository_snapshot"]["commit_sha"] = "b" * 40
    refresh_evaluation_subject(changed_bundle)
    assert(validator.validate(changed_bundle).empty?, "refreshed snapshot bundle must validate")
    changed_audit = derive.call(changed_bundle)
    assert(
      changed_audit["source_digest"] != audit["source_digest"] &&
        changed_audit["content_digest"] != audit["content_digest"],
      "a participating source change invalidates the audit digests"
    )

    # 7. Invalid authority/independence fails closed through the public
    #    seam.
    stripped_bundle = OrbitV2FixtureFactory.valid_bundle
    stripped_bundle["authorization_records"] = []
    expect_contract_error("aggregate_outcome_invalid") { derive.call(stripped_bundle) }
    swapped_bundle = OrbitV2FixtureFactory.valid_bundle
    reviewer = swapped_bundle["agent_instances"].find { |agent| agent["agent_instance_id"] == "oagent_independentreviewer" }
    producer = swapped_bundle["agent_instances"].find { |agent| agent["agent_instance_id"] == "oagent_implementerone" }
    reviewer["runtime_identity"] = OrbitV2FixtureFactory.deep_copy(producer["runtime_identity"])
    expect_contract_error("aggregate_outcome_invalid") { derive.call(swapped_bundle) }
  end

  def reseal_consuming(bundle, checkpoint, evaluation: nil)
    if evaluation
      ref = { "gate_evaluation_id" => evaluation["gate_evaluation_id"], "content_digest" => evaluation["content_digest"] }
      %w[test_count test_code_lines].each do |metric|
        measurement = checkpoint["effective_budget_bindings"][0]["measurements"][metric]
        measurement["unverified_assessment"]["review_gate_evaluation_ref"] = ref if measurement["status"] == "unverified"
      end
      supporting = { "kind" => "gate_evaluation", "id" => evaluation["gate_evaluation_id"], "digest" => evaluation["content_digest"] }
      %w[delivery_progress assurance_progress].each { |field| checkpoint[field]["supporting_refs"] = [supporting] }
    end
    bundle["lead_checkpoints"][-1] = OrbitV2FixtureFactory.reseal_checkpoint(
      checkpoint,
      policy: bundle["project_policy_revisions"].first,
      predecessor_checkpoint: bundle["lead_checkpoints"][-2],
      bindings: checkpoint["effective_budget_bindings"]
    )
  end

  def test_v1_inventory

    inventory = YAML.safe_load(
      File.read(File.join(ROOT, "contracts/orbit-v2/legacy-v1-writer-reader-inventory.yaml")),
      aliases: false
    )
    entries = inventory.fetch("surfaces")
    actual = entries.map { |entry| entry.fetch("path") }.sort
    expected = %w[README.md install.sh package.json scripts/orbit tests/orbit_test.sh uninstall.sh]
    expected.concat(Dir.glob(File.join(ROOT, "lib/orbit/*.rb")).map { |path| relative(path) })
    expected.concat(Dir.glob(File.join(ROOT, "skills/orbit/**/*")).select { |path| File.file?(path) }.map { |path| relative(path) })
    expected.concat(Dir.glob(File.join(ROOT, "tests/fixtures/*")).select { |path| File.file?(path) }.map { |path| relative(path) })
    expected.concat(
      Dir.glob(File.join(ROOT, "tests/parts/*.sh"))
         .reject { |path| File.basename(path) == "28_orbit_v2_slice0_contracts.sh" }
         .map { |path| relative(path) }
    )
    expected.sort!
    assert(actual.uniq.length == actual.length, "v1 inventory paths unique")
    assert(actual == expected, "v1 inventory must exactly cover frozen reader/writer roots")
    assert(
      entries.all? do |entry|
        %w[path surface_kind access_modes v1_semantic slice6_disposition].all? do |field|
          value = entry[field]
          value.is_a?(Array) ? value.any? : !value.to_s.empty?
        end
      end,
      "every v1 inventory entry carries migration classification and disposition"
    )
  end

  def test_slice_isolation
    runtime_paths = Dir.glob(File.join(ROOT, "lib/orbit/*.rb")) + [File.join(ROOT, "scripts/orbit")]
    forbidden_imports = runtime_paths.select do |path|
      File.read(path).match?(/orbit\/v2|Orbit::V2/)
    end
    assert(forbidden_imports.empty?, "v1 runtime must not import isolated v2 contracts")
    assert(!File.exist?(File.join(ROOT, ".orbit/protocol.yaml")), "Slice 0 must not activate ProtocolRoot")
  end

  def mutate(id, bundle)
    case id
    when "unsupported_task_schema"
      bundle["task_revisions"][0]["schema_version"] = "orbit-task-v1"
      rehash(bundle["task_revisions"][0])
    when "mixed_epoch"
      bundle["protocol_epoch"] = "orbit-v1"
    when "missing_protocol_root"
      bundle["protocol_root"] = nil
    when "forged_genesis_ref"
      bundle["protocol_root"]["project_policy_genesis_ref"]["content_digest"] = digest_for("forged")
      rehash(bundle["protocol_root"])
    when "missing_bootstrap_authority"
      bundle["authority_assertions"].delete_at(0)
    when "genesis_self_grant"
      assertion = bundle["authority_assertions"][0]
      assertion["verification_receipt"]["receipt"] = "hmac-sha256:#{'0' * 64}"
    when "policy_lineage_fork"
      base = bundle["project_policy_revisions"][0]
      %w[opolicy_childforkone opolicy_childforktwo].each do |id_value|
        child = OrbitV2FixtureFactory.deep_copy(base)
        child["policy_revision_id"] = id_value
        child["parent_policy_revision_id"] = base["policy_revision_id"]
        rehash(child)
        bundle["project_policy_revisions"] << child
      end
    when "policy_rotation_without_parent_grant"
      parent = bundle["project_policy_revisions"].first
      parent["authority_grants"].reject! { |grant| grant["action"] == "policy.rotate" }
      reissue_genesis_policy(bundle)
      prepare_for_policy_rotation(bundle)
      add_policy_successor(bundle)
    when "policy_issuance_candidate_replay"
      prepare_for_policy_rotation(bundle)
      candidate = add_policy_successor(bundle)
      candidate["authority_grants"] << {
        "action" => "project.escalate",
        "required_external_grant" => "project.escalate"
      }
      rehash(candidate)
    when "policy_same_id_assertion_replacement"
      policy = bundle["project_policy_revisions"].first
      bundle["authority_assertions"][0] =
        OrbitV2FixtureFactory.policy_issuance_assertion(
          policy,
          parent_policy: nil,
          assertion_id: policy["authorization_source_ref"],
          subject: "replacement-project-owner",
          issued_at: "2026-07-30T00:00:00Z"
        )
    when "duplicate_policy_authority_action"
      policy = bundle["project_policy_revisions"].first
      policy["authority_grants"] << {
        "action" => "finding.waive",
        "required_external_grant" => "risk.admin"
      }
      reissue_genesis_policy(bundle)
    when "forged_authorization"
      authorization = bundle["authorization_records"][0]
      authorization["authorization_assertion_digest"] = digest_for("forged-authorization")
      rehash(authorization)
    when "task_second_root"
      add_task_revision_clone(
        bundle,
        id: "trev_slice0contract_secondroot",
        revision_number: 2,
        parent_id: nil
      )
    when "task_duplicate_genesis"
      add_task_revision_clone(
        bundle,
        id: "trev_slice0contract_duplicategenesis",
        revision_number: 1,
        parent_id: nil
      )
    when "task_orphan_parent"
      add_task_revision_clone(
        bundle,
        id: "trev_slice0contract_orphan",
        revision_number: 2,
        parent_id: "trev_slice0contract_phantomparent"
      )
    when "task_parent_cycle"
      id = "trev_slice0contract_selfcycle"
      add_task_revision_clone(
        bundle,
        id: id,
        revision_number: 2,
        parent_id: id
      )
    when "task_skipped_revision"
      add_task_revision_clone(
        bundle,
        id: "trev_slice0contract_skipped",
        revision_number: 3,
        parent_id: bundle["task_revisions"].first["task_revision_id"]
      )
    when "task_revision_fork"
      parent_id = bundle["task_revisions"].first["task_revision_id"]
      add_task_revision_clone(
        bundle,
        id: "trev_slice0contract_forkone",
        revision_number: 2,
        parent_id: parent_id
      )
      add_task_revision_clone(
        bundle,
        id: "trev_slice0contract_forktwo",
        revision_number: 2,
        parent_id: parent_id
      )
    when "protected_revision_hop"
      parent = bundle["task_revisions"][0]
      child = OrbitV2FixtureFactory.deep_copy(parent)
      child["task_revision_id"] = "trev_slice0contract_r2"
      child["revision_number"] = 2
      child["parent_task_revision_id"] = parent["task_revision_id"]
      child["gate_requirement_refs"] = []
      rehash(child)
      bundle["task_revisions"] << child
    when "child_reuses_parent_gate"
      successor = add_task_successor(bundle)
      successor.fetch("task")["gate_requirement_refs"] =
        [OrbitV2FixtureFactory::GATE_ID]
      rehash(successor.fetch("task"))
      bundle["gate_requirements"].delete(successor.fetch("gate"))
    when "stale_policy_protected_authorization"
      parent_policy = bundle["project_policy_revisions"].first
      prepare_for_policy_rotation(bundle)
      active_policy = add_policy_successor(bundle, protected_change_grant: false)
      add_authorized_protected_successor(
        bundle,
        authorization_policy: parent_policy,
        candidate_policy: active_policy
      )
    when "nonprotected_gate_lineage_without_parent"
      successor = add_task_successor(bundle)
      parent_gate = bundle["gate_requirements"].first
      child_gate = successor.fetch("gate")
      parent_gate["protected"] = false
      rehash(parent_gate)
      child_gate["protected"] = false
      child_gate["parent_gate_requirement_ref"] = nil
      rehash(child_gate)
    when "phantom_protected_change_authorization_genesis"
      task = bundle["task_revisions"].first
      task["protected_change_authorization_ref"] = "oauthz_phantomprotectedchange"
      rehash(task)
    when "phantom_protected_change_authorization_successor"
      successor = add_task_successor(bundle)
      task = successor.fetch("task")
      task["protected_change_authorization_ref"] = "oauthz_phantomprotectedchange"
      rehash(task)
    when "protected_change_cross_task_replay"
      protected = add_authorized_protected_successor(bundle)
      authorization = protected.fetch("authorization")
      authorization.dig("protected_change_envelope")["task_id"] =
        "otask_unrelatedcontract"
      rehash_envelope(authorization.fetch("protected_change_envelope"))
      rehash(authorization)
    when "protected_change_cross_revision_replay"
      protected = add_authorized_protected_successor(bundle)
      authorization = protected.fetch("authorization")
      authorization["subject_ref"] = "trev_unrelatedcandidate"
      rehash(authorization)
    when "protected_change_changed_diff_replay"
      protected = add_authorized_protected_successor(bundle)
      gate = protected.fetch("gate")
      gate.dig("subject_selector", "work_unit_refs") << "owu_implementationone"
      rehash(gate)
    when "freeform_gate_waiver"
      gate = bundle["gate_requirements"][0]
      gate["waiver_policy"]["mode"] = "lead_approval"
      rehash(gate)
    when "mutable_work_unit_status"
      bundle["work_units"][0]["status"] = "done"
      rehash(bundle["work_units"][0])
    when "mutable_attempt_status"
      bundle["work_unit_attempts"][0]["status"] = "done"
    when "missing_attempt_start_source"
      creation = bundle["work_unit_attempts"][0]["events"][0]
      creation.delete("started_at")
      rehash_named(creation, "event_digest")
    when "forged_attempt_authority_snapshot"
      creation = bundle["work_unit_attempts"][0]["events"][0]
      creation["assignment"]["authority_snapshot"]["project_policy_revision_ref"]["content_digest"] =
        digest_for("forged-policy-snapshot")
      rehash_named(creation, "event_digest")
    when "stale_active_attempt_after_policy_rotation"
      add_policy_successor(bundle)
    when "repeated_attempt_created"
      attempt = bundle["work_unit_attempts"][0]
      repeated = OrbitV2FixtureFactory.deep_copy(attempt["events"][0])
      repeated["event_id"] = "oevent_repeatedattemptcreation"
      repeated["previous_event_digest"] = attempt["events"].last["event_digest"]
      rehash_named(repeated, "event_digest")
      attempt["events"] << repeated
    when "replacement_assignment_event"
      attempt = bundle["work_unit_attempts"][0]
      created = attempt["events"][0]
      attempt["events"] << OrbitV2FixtureFactory.event(
        "oevent_replacementassignmentcompleted",
        "AttemptCompleted",
        created["event_digest"],
        "assignment" => created["assignment"].merge(
          "agent_instance_id" => "oagent_implementertwo"
        ),
        "ended_at" => "2026-07-30T01:00:00Z",
        "status" => "completed"
      )
    when "multiple_attempt_terminal_events"
      attempt = bundle["work_unit_attempts"][0]
      completed = OrbitV2FixtureFactory.event(
        "oevent_attemptfirstterminal",
        "AttemptCompleted",
        attempt["events"][0]["event_digest"],
        "ended_at" => "2026-07-30T01:00:00Z",
        "status" => "completed"
      )
      failed = OrbitV2FixtureFactory.event(
        "oevent_attemptsecondterminal",
        "AttemptFailed",
        completed["event_digest"],
        "ended_at" => "2026-07-30T01:01:00Z",
        "status" => "failed",
        "failure_signal" => {
          "test_or_check_id" => "test-orbit-contract-suite",
          "signal_subject_id" => "signal:owu_implementationone",
          "normalized_failure_code" => "contract-validation-failure"
        }
      )
      attempt["events"].concat([completed, failed])
    when "agent_event_after_terminal"
      agent = bundle["agent_instances"][1]
      terminated = OrbitV2FixtureFactory.event(
        "oevent_agentterminal",
        "AgentTerminated",
        agent["lifecycle_events"][0]["event_digest"],
        "ended_at" => "2026-07-30T01:00:00Z",
        "status" => "retired"
      )
      advanced = OrbitV2FixtureFactory.event(
        "oevent_agentpostterminalcontext",
        "AgentContextAdvanced",
        terminated["event_digest"],
        "context_generation" => 2,
        "reason" => "This event must not follow termination."
      )
      agent["lifecycle_events"].concat([terminated, advanced])
    when "lead_session_event_after_terminal"
      session = bundle["lead_sessions"][0]
      ended = OrbitV2FixtureFactory.event(
        "oevent_leadsessionfirstterminal",
        "LeadSessionEnded",
        session["lifecycle_events"][0]["event_digest"],
        "ended_at" => "2026-07-30T01:00:00Z",
        "status" => "completed"
      )
      repeated = OrbitV2FixtureFactory.event(
        "oevent_leadsessionsecondterminal",
        "LeadSessionEnded",
        ended["event_digest"],
        "ended_at" => "2026-07-30T01:01:00Z",
        "status" => "superseded"
      )
      session["lifecycle_events"].concat([ended, repeated])
    when "lifecycle_event_id_reuse_across_streams"
      bundle.dig("work_unit_attempts", 1, "events", 0)["event_id"] =
        bundle.dig("work_unit_attempts", 0, "events", 0, "event_id")
      rehash_named(bundle.dig("work_unit_attempts", 1, "events", 0), "event_digest")
    when "lifecycle_chronology_inverted"
      attempt = bundle["work_unit_attempts"].first
      created = attempt["events"].first
      created["started_at"] = "2026-07-30T02:00:00Z"
      created["recorded_at"] = created["started_at"]
      OrbitV2FixtureFactory.resign_event(created)
      attempt["events"] << OrbitV2FixtureFactory.event(
        "oevent_invertedchronologycompleted",
        "AttemptCompleted",
        created["event_digest"],
        "ended_at" => "2026-07-30T01:00:00Z",
        "status" => "completed"
      )
    when "cross_task_implementation_subject"
      attempt = bundle["work_unit_attempts"][0]
      attempt["task_id"] = "otask_unrelatedcontract"
      artifact = bundle["rule_resolution_artifacts"][0]
      identity = OrbitV2FixtureFactory.deep_copy(artifact["identity"])
      identity["task_id"] = attempt["task_id"]
      rebuilt = Orbit::V2::RuleResolution.build(
        identity,
        created_at: artifact.dig("envelope", "created_at"),
        project_root: ROOT
      )
      bundle["rule_resolution_artifacts"][0] = rebuilt
      attempt.dig("events", 0, "assignment")["assigned_rule_resolution_id"] =
        rebuilt["resolution_id"]
      rehash_named(attempt.dig("events", 0), "event_digest")
      record = bundle["evidence_records"][0]
      record["task_id"] = attempt["task_id"]
      record["submitted_rule_resolution_id"] = rebuilt["resolution_id"]
      rehash(record)
    when "evaluator_agent_self_role"
      agent = bundle["agent_instances"].find do |candidate|
        candidate["agent_instance_id"] == "oagent_independentreviewer"
      end
      agent.dig("lifecycle_events", 0)["role"] = "coder"
      rehash_named(agent.dig("lifecycle_events", 0), "event_digest")
      agent["capability_profile"] = {
        "profile_id" => "capability-profile:coder",
        "capabilities" => ["coder.execute"]
      }
      agent["permission_profile"] = {
        "profile_id" => "permission-profile:coder",
        "permissions" => ["work_unit.read"]
      }
    when "phantom_initial_change_thesis"
      unit = bundle["work_units"][0]
      unit["initial_change_thesis_ref"] = {
        "change_thesis_id" => "othesis_phantomreference",
        "revision" => 1,
        "content_digest" => digest_for("phantom-thesis")
      }
      rehash(unit)
      refresh_evaluation_subject(bundle)
    when "stale_initial_change_thesis"
      unit = bundle["work_units"][0]
      unit["initial_change_thesis_ref"]["content_digest"] = digest_for("stale-thesis")
      rehash(unit)
      refresh_evaluation_subject(bundle)
    when "cross_unit_attempt_thesis"
      attempt = bundle["work_unit_attempts"][0]
      other = bundle["change_theses"][1]
      thesis_ref = {
        "change_thesis_id" => other["change_thesis_id"],
        "revision" => other["revision"],
        "content_digest" => other["content_digest"]
      }
      attempt.dig("events", 0, "assignment")["change_thesis_ref"] = thesis_ref
      rehash_named(attempt.dig("events", 0), "event_digest")
      record = bundle["evidence_records"][0]
      record.dig("implementation_check")["change_thesis_ref"] = thesis_ref
      rehash(record)
      refresh_evaluation_subject(bundle)
    when "unlinked_attempt_thesis_successor"
      initial = bundle["change_theses"][0]
      successor = OrbitV2FixtureFactory.deep_copy(initial)
      successor["revision"] = 3
      successor["root_cause_status"] = "hypothesis"
      rehash(successor)
      bundle["change_theses"] << successor
      thesis_ref = {
        "change_thesis_id" => successor["change_thesis_id"],
        "revision" => successor["revision"],
        "content_digest" => successor["content_digest"]
      }
      attempt = bundle["work_unit_attempts"][0]
      attempt.dig("events", 0, "assignment")["change_thesis_ref"] = thesis_ref
      rehash_named(attempt.dig("events", 0), "event_digest")
      record = bundle["evidence_records"][0]
      record.dig("implementation_check")["change_thesis_ref"] = thesis_ref
      rehash(record)
      refresh_evaluation_subject(bundle)
    when "evaluator_evidence_verdict"
      record = bundle["evidence_records"].find { |candidate| candidate["record_kind"] == "evaluator_submission" }
      record["verdict"] = "pass"
      rehash(record)
    when "evidence_id_reuse"
      duplicate = OrbitV2FixtureFactory.deep_copy(bundle["evidence_records"][0])
      duplicate["implementation_check"]["changed_paths"] = ["other.rb"]
      rehash(duplicate)
      bundle["evidence_records"] << duplicate
    when "evaluation_id_reuse"
      duplicate = OrbitV2FixtureFactory.deep_copy(bundle["gate_evaluations"][0])
      duplicate["verdict"] = "pass"
      rehash(duplicate)
      bundle["gate_evaluations"] << duplicate
    when "subject_incomplete"
      evaluation = bundle["gate_evaluations"][0]
      evaluation["subject"]["implementation_attempt_refs"] = []
      rehash_subject(evaluation["subject"])
      rehash(evaluation)
    when "stale_repository_snapshot"
      bundle["repository_snapshot"]["commit_sha"] = "b" * 40
      bundle["repository_snapshot"]["tree_digest"] = digest_for("new-tree")
      bundle["code_surface"]["repository_tree_digest"] = bundle["repository_snapshot"]["tree_digest"]
      bundle["code_surface"]["code_surface_digest"] = Orbit::V2::EvaluationSubject.code_surface_digest(
        derivation_version: bundle["code_surface"]["derivation_version"],
        repository_tree_digest: bundle["code_surface"]["repository_tree_digest"],
        paths: bundle["code_surface"]["paths"]
      )
    when "forged_code_surface_digest"
      bundle["code_surface"]["code_surface_digest"] = digest_for("forged-code-surface")
    when "new_implementation_stales_old_evaluation"
      add_new_implementation(bundle)
    when "self_review_any_subject_producer"
      attempt = bundle["work_unit_attempts"].find do |candidate|
        candidate.dig("events", 0, "assignment", "purpose") == "review"
      end
      attempt["events"][0]["assignment"]["agent_instance_id"] = "oagent_implementerone"
    when "rule_resolution_hash_tamper"
      rule = bundle["rule_resolution_artifacts"][0]["identity"]["required_rules"][0]
      rule["path"] = "skills/orbit/references/runtime/core-operating-model.md"
      rule["content_sha256"] = "sha256:#{Digest::SHA256.file(File.join(ROOT, rule["path"])).hexdigest}"
    when "unknown_question_answer"
      evaluation = bundle["gate_evaluations"][0]
      evaluation["quality_question_answers"][0]["question_id"] = "question_unknowncontract"
      rehash(evaluation)
    when "free_text_waiver_issuer"
      resolution = bundle["finding_resolutions"][0]
      resolution["issuer"] = "lead-main"
      rehash(resolution)
    when "forged_waiver_record"
      resolution = bundle["finding_resolutions"][0]
      resolution["authorization_record_ref"] = "oauthz_nonexistentrecord"
      rehash(resolution)
    when "addressed_without_authorized_confirmer"
      resolution = bundle["finding_resolutions"][0]
      proposal = bundle["evidence_records"].first
      resolution.delete("authorization_record_ref")
      resolution["resolution"] = "addressed"
      resolution["issuer_attempt_id"] = proposal["attempt_id"]
      resolution["issuer_submission_record_id"] = proposal["evidence_record_id"]
      evaluation = bundle["gate_evaluations"].first
      resolution["source_finding_ref"] = {
        "finding_id" => bundle["findings"].first["finding_id"],
        "content_digest" => bundle["findings"].first["content_digest"]
      }
      resolution["source_gate_evaluation_ref"] = {
        "gate_evaluation_id" => evaluation["gate_evaluation_id"],
        "content_digest" => evaluation["content_digest"]
      }
      resolution["resolving_gate_evaluation_ref"] = {
        "gate_evaluation_id" => evaluation["gate_evaluation_id"],
        "content_digest" => evaluation["content_digest"]
      }
      resolution["proposal_evidence_record_id"] = proposal["evidence_record_id"]
      resolution["supporting_record_refs"] = [proposal["evidence_record_id"]]
      rehash(resolution)
    when "unbound_finding_resolution_issuer"
      unused = add_unused_reviewer(bundle)
      resolution = bundle["finding_resolutions"][0]
      resolution.delete("authorization_record_ref")
      resolution["resolution"] = "disproved"
      resolution["issuer_attempt_id"] = unused.fetch("attempt_id")
      resolution["issuer_submission_record_id"] = unused.fetch("submission_id")
      evaluation = bundle["gate_evaluations"].first
      resolution["source_finding_ref"] = {
        "finding_id" => bundle["findings"].first["finding_id"],
        "content_digest" => bundle["findings"].first["content_digest"]
      }
      resolution["source_gate_evaluation_ref"] = {
        "gate_evaluation_id" => evaluation["gate_evaluation_id"],
        "content_digest" => evaluation["content_digest"]
      }
      resolution["resolving_gate_evaluation_ref"] = {
        "gate_evaluation_id" => evaluation["gate_evaluation_id"],
        "content_digest" => evaluation["content_digest"]
      }
      resolution["supporting_record_refs"] = ["oevr_implementationone"]
      rehash(resolution)
    when "stale_finding_resolution_evaluation_ref"
      make_evaluator_resolution(bundle, "disproved")
      resolution = bundle["finding_resolutions"].first
      resolution["resolving_gate_evaluation_ref"]["content_digest"] =
        digest_for("stale-resolution-evaluation")
      rehash(resolution)
    when "cross_gate_finding_resolution_evaluation"
      other = add_cross_gate_finding(bundle)
      make_evaluator_resolution(
        bundle,
        "disproved",
        evaluation_id: other.fetch("evaluation_id")
      )
    when "circular_finding_resolution_evaluation"
      resolution = bundle["finding_resolutions"].first
      evaluation = bundle["gate_evaluations"].first
      finding = bundle["findings"].first
      resolution.delete("authorization_record_ref")
      resolution["resolution"] = "disproved"
      resolution["issuer_attempt_id"] = evaluation["evaluator_attempt_id"]
      resolution["issuer_submission_record_id"] =
        evaluation["evaluator_submission_record_id"]
      resolution["source_finding_ref"] = {
        "finding_id" => finding["finding_id"],
        "content_digest" => finding["content_digest"]
      }
      resolution["source_gate_evaluation_ref"] = {
        "gate_evaluation_id" => evaluation["gate_evaluation_id"],
        "content_digest" => evaluation["content_digest"]
      }
      resolution["resolving_gate_evaluation_ref"] =
        OrbitV2FixtureFactory.deep_copy(resolution["source_gate_evaluation_ref"])
      resolution["supporting_record_refs"] = ["oevr_implementationone"]
      rehash(resolution)
    when "waived_with_evaluator_provenance"
      resolution = bundle["finding_resolutions"].first
      evaluation = bundle["gate_evaluations"].first
      resolution["issuer_attempt_id"] = evaluation["evaluator_attempt_id"]
      resolution["issuer_submission_record_id"] =
        evaluation["evaluator_submission_record_id"]
      resolution["resolving_gate_evaluation_ref"] = {
        "gate_evaluation_id" => evaluation["gate_evaluation_id"],
        "content_digest" => evaluation["content_digest"]
      }
      rehash(resolution)
    when "addressed_with_waiver_provenance"
      make_evaluator_resolution(bundle, "addressed")
      resolution = bundle["finding_resolutions"].first
      resolution["authorization_record_ref"] = "oauthz_findingwaiver"
      rehash(resolution)
    when "disproved_with_proposal_provenance"
      make_evaluator_resolution(bundle, "disproved")
      resolution = bundle["finding_resolutions"].first
      resolution["proposal_evidence_record_id"] = "oevr_implementationone"
      rehash(resolution)
    when "phantom_finding_resolution_support"
      make_evaluator_resolution(bundle, "disproved")
      resolution = bundle["finding_resolutions"].first
      resolution["supporting_record_refs"] = ["oevr_phantomsupport"]
      rehash(resolution)
    when "waived_with_supporting_record"
      resolution = bundle["finding_resolutions"].first
      resolution["supporting_record_refs"] = ["oevr_phantomsupport"]
      rehash(resolution)
    when "phantom_finding_refs"
      phantom_id = "ofinding_phantomreference"
      task = bundle["task_revisions"][0]
      task["unresolved_finding_refs"] = [phantom_id]
      rehash(task)
      evaluation = bundle["gate_evaluations"][0]
      evaluation["finding_refs"] = [phantom_id]
      bundle["findings"] = []
      bundle["finding_resolutions"] = []
      refresh_evaluation_subject(bundle)
    when "cross_gate_finding_supersedes"
      other = add_cross_gate_finding(bundle)
      finding = bundle["findings"].first
      finding["supersedes_finding_id"] = other.fetch("finding_id")
      rehash(finding)
    when "phantom_related_finding"
      finding = bundle["findings"].first
      finding["related_finding_refs"] = ["ofinding_phantomrelated"]
      rehash(finding)
    when "self_related_finding"
      finding = bundle["findings"].first
      finding["related_finding_refs"] = [finding["finding_id"]]
      rehash(finding)
    when "finding_supersedes_cycle"
      add_same_gate_finding_cycle(bundle)
    when "phantom_related_evidence"
      record = bundle["evidence_records"].first
      record["related_evidence_record_refs"] = ["oevr_phantomrelated"]
      rehash(record)
      refresh_evaluation_subject(bundle)
    when "evidence_supersedes_cycle"
      record = bundle["evidence_records"].first
      related = OrbitV2FixtureFactory.deep_copy(record)
      related["evidence_record_id"] = "oevr_implementationcycle"
      record["supersedes_evidence_record_id"] = related["evidence_record_id"]
      related["supersedes_evidence_record_id"] = record["evidence_record_id"]
      rehash(record)
      rehash(related)
      bundle["evidence_records"] << related
      refresh_evaluation_subject(bundle)
    when "phantom_related_gate_evaluation"
      evaluation = bundle["gate_evaluations"].first
      evaluation["related_gate_evaluation_refs"] = ["ogeval_phantomrelated"]
      rehash(evaluation)
    when "cross_gate_related_gate_evaluation"
      other = add_cross_gate_finding(bundle)
      evaluation = bundle["gate_evaluations"].first
      evaluation["related_gate_evaluation_refs"] = [other.fetch("evaluation_id")]
      rehash(evaluation)
    when "gate_evaluation_supersedes_cycle"
      evaluation = bundle["gate_evaluations"].first
      related = OrbitV2FixtureFactory.deep_copy(evaluation)
      related["gate_evaluation_id"] = "ogeval_slice0reviewcycle"
      related["finding_refs"] = []
      evaluation["supersedes_gate_evaluation_id"] = related["gate_evaluation_id"]
      related["supersedes_gate_evaluation_id"] = evaluation["gate_evaluation_id"]
      rehash(evaluation)
      rehash(related)
      bundle["gate_evaluations"] << related
    when "missing_blocking_finding_resolution"
      bundle["finding_resolutions"] = []
      evaluation = bundle["gate_evaluations"].first
      evaluation["verdict"] = "pass"
      evaluation["quality_outcome_verdict"] = "pass"
      evaluation["acceptance_results"].each { |result| result["verdict"] = "pass" }
      rehash(evaluation)
    when "finding_id_reuse"
      duplicate = OrbitV2FixtureFactory.deep_copy(bundle["findings"][0])
      duplicate["body"] = "Overwritten finding body."
      rehash(duplicate)
      bundle["findings"] << duplicate
    when "finding_resolution_id_reuse"
      duplicate = OrbitV2FixtureFactory.deep_copy(bundle["finding_resolutions"][0])
      duplicate["supersedes_finding_resolution_id"] =
        duplicate["finding_resolution_id"]
      rehash(duplicate)
      bundle["finding_resolutions"] << duplicate
    when "missing_gate_verdict"
      evaluation = bundle["gate_evaluations"][0]
      evaluation.delete("verdict")
      rehash(evaluation)
    when "invalid_gate_verdict"
      evaluation = bundle["gate_evaluations"][0]
      evaluation["verdict"] = "looks_good"
      rehash(evaluation)
    when "invalid_answer_verdict"
      evaluation = bundle["gate_evaluations"][0]
      evaluation["quality_question_answers"][0]["verdict"] = "looks_good"
      rehash(evaluation)
    when "missing_task_goal"
      task = bundle["task_revisions"][0]
      task.delete("goal")
      rehash(task)
    when "nested_rule_epoch"
      artifact = bundle["rule_resolution_artifacts"][0]
      artifact["identity"]["protocol_epoch"] = "orbit-v1"
    when "review_gate_via_test_attempt"
      creation = bundle["work_unit_attempts"].find do |attempt|
        attempt["attempt_id"] == "oattempt_independentreview"
      end.fetch("events").first
      creation["assignment"]["purpose"] = "test"
      creation["assignment"]["resolved_role"] = "tester"
      rehash_named(creation, "event_digest")
    when "review_gate_via_unrelated_task"
      attempt = bundle["work_unit_attempts"].find do |candidate|
        candidate["attempt_id"] == "oattempt_independentreview"
      end
      attempt["task_id"] = "otask_unrelatedcontract"
    when "task_authority_cross_action"
      task = bundle["task_revisions"].first
      task["authority_grant_refs"] = ["oauthz_findingwaiver"]
      rehash(task)
      refresh_evaluation_subject(bundle)
    when "work_unit_authority_cross_action"
      unit = bundle["work_units"].first
      unit.dig("authority_scope", "authorization_record_refs") << "oauthz_findingwaiver"
      rehash(unit)
      refresh_all_evaluation_subjects(bundle)
    when "attempt_authority_cross_action"
      creation = bundle.dig("work_unit_attempts", 0, "events", 0)
      creation.dig(
        "assignment",
        "authority_snapshot",
        "authorization_record_refs"
      ) << "oauthz_findingwaiver"
      OrbitV2FixtureFactory.resign_event(creation)
      refresh_all_evaluation_subjects(bundle)
    when "empty_work_authorization"
      bundle["work_units"].each do |unit|
        unit.dig("authority_scope", "authorization_record_refs").clear
        rehash(unit)
      end
      bundle["work_unit_attempts"].each do |attempt|
        creation = attempt.dig("events", 0)
        creation.dig(
          "assignment",
          "authority_snapshot",
          "authorization_record_refs"
        ).clear
        OrbitV2FixtureFactory.resign_event(creation)
      end
      refresh_all_evaluation_subjects(bundle)
    when "duplicate_verified_runtime_identity"
      producer = bundle["agent_instances"].find do |agent|
        agent["agent_instance_id"] == "oagent_implementerone"
      end
      reviewer = bundle["agent_instances"].find do |agent|
        agent["agent_instance_id"] == "oagent_independentreviewer"
      end
      reviewer["runtime_identity"]["provider_id"] =
        producer.dig("runtime_identity", "provider_id")
      reviewer["runtime_identity"]["runtime_subject_id"] =
        producer.dig("runtime_identity", "runtime_subject_id")
      OrbitV2FixtureFactory.resign_runtime_identity(reviewer)
    when "empty_implementation_proof"
      bundle["evidence_records"].each do |record|
        next unless record["record_kind"] == "implementation"

        record.dig("implementation_check", "changed_paths").clear
        record.dig("implementation_check", "verification_refs").clear
        record["submission_artifact_refs"].clear
        rehash(record)
      end
      bundle["gate_evaluations"].each do |evaluation|
        (
          Array(evaluation["quality_question_answers"]) +
          Array(evaluation["acceptance_results"])
        ).each { |answer| answer["evidence_record_refs"].clear }
        rehash(evaluation)
      end
    when "incompatible_work_kind_purpose"
      unit = bundle["work_units"].find do |candidate|
        candidate["work_unit_id"] == "owu_implementationone"
      end
      unit["work_unit_kind"] = "research"
      rehash(unit)
      refresh_all_evaluation_subjects(bundle)
    when "attempt_after_agent_termination"
      reviewer = bundle["agent_instances"].find do |agent|
        agent["agent_instance_id"] == "oagent_independentreviewer"
      end
      reviewer["lifecycle_events"] << OrbitV2FixtureFactory.event(
        "oevent_reviewerterminatedbeforeattempt",
        "AgentTerminated",
        reviewer.dig("lifecycle_events", -1, "event_digest"),
        "ended_at" => "2026-07-30T00:00:30Z",
        "status" => "retired"
      )
    when "weak_same_kind_protected_gate"
      add_gate_requirement(
        bundle,
        kind: "review",
        gate_id: "ogreq_slice0weakreview",
        lineage_id: "ogline_slice0weakreview",
        evidence_level: "mechanical_check",
        independence: "same_agent_allowed"
      )
    when "work_unit_multiple_roots"
      unit = bundle["work_units"].find do |candidate|
        candidate["work_unit_id"] == "owu_implementationtwo"
      end
      unit["parent_work_unit_ref"] = nil
      rehash(unit)
      refresh_all_evaluation_subjects(bundle)
    when "work_unit_parent_cycle"
      implementation = bundle["work_units"].find do |candidate|
        candidate["work_unit_id"] == "owu_implementationtwo"
      end
      review = bundle["work_units"].find do |candidate|
        candidate["work_unit_id"] == "owu_independentreview"
      end
      implementation["parent_work_unit_ref"] = review["work_unit_id"]
      review["parent_work_unit_ref"] = implementation["work_unit_id"]
      rehash(implementation)
      rehash(review)
      refresh_all_evaluation_subjects(bundle)
    when "work_unit_dependency_cycle"
      implementation = bundle["work_units"].find do |candidate|
        candidate["work_unit_id"] == "owu_implementationtwo"
      end
      review = bundle["work_units"].find do |candidate|
        candidate["work_unit_id"] == "owu_independentreview"
      end
      implementation["depends_on_work_unit_refs"] =
        (implementation["depends_on_work_unit_refs"] + [review["work_unit_id"]]).uniq
      rehash(implementation)
      refresh_all_evaluation_subjects(bundle)
    when "work_unit_cross_revision_edge"
      child = add_task_revision_clone(
        bundle,
        id: "trev_slice0contract_r2",
        revision_number: 2,
        parent_id: "trev_slice0contract_r1"
      )
      source_unit = bundle["work_units"][1]
      source_thesis = bundle["change_theses"].find do |candidate|
        candidate["work_unit_id"] == source_unit["work_unit_id"]
      end
      thesis = OrbitV2FixtureFactory.deep_copy(source_thesis)
      thesis["change_thesis_id"] = "othesis_crossrevisionedge"
      thesis["work_unit_id"] = "owu_crossrevisionchild"
      thesis["task_revision_id"] = child["task_revision_id"]
      rehash(thesis)
      unit = OrbitV2FixtureFactory.deep_copy(source_unit)
      unit["work_unit_id"] = "owu_crossrevisionchild"
      unit["task_revision_id"] = child["task_revision_id"]
      unit["parent_work_unit_ref"] = "owu_implementationone"
      unit["depends_on_work_unit_refs"] = []
      unit["input_refs"] = ["task-revision://#{child["task_revision_id"]}"]
      unit.dig("authority_scope", "authorization_record_refs").clear
      unit["initial_change_thesis_ref"] = {
        "change_thesis_id" => thesis["change_thesis_id"],
        "revision" => 1,
        "content_digest" => thesis["content_digest"]
      }
      bundle["change_theses"] << thesis
      bundle["work_units"] << unit
      authorization = OrbitV2FixtureFactory.work_authorization(
        unit,
        child,
        "work.implement"
      )
      bundle["authority_assertions"] << authorization.fetch("assertion")
      bundle["authorization_records"] << authorization.fetch("record")
    when "work_unit_dependency_not_ready"
      bundle["work_unit_attempts"].each do |attempt|
        next unless attempt["work_unit_id"] == "owu_implementationone"

        attempt["events"].pop if attempt.fetch("events").length > 1
      end
    when "attempt_interval_overlap"
      impl2 = bundle["work_unit_attempts"].find { |c| c["attempt_id"] == "oattempt_implementationtwo" }
      impl2.dig("events", 0)["started_at"] = "2026-07-30T00:01:40Z"
      impl2.dig("events", 0)["recorded_at"] = impl2.dig("events", 0, "started_at")
      OrbitV2FixtureFactory.resign_event_chain(impl2)
    when "attempt_predecessor_cross_work_unit"
      attempt = bundle["work_unit_attempts"].find do |candidate|
        candidate["attempt_id"] == "oattempt_implementationtwo"
      end
      attempt["predecessor_work_unit_attempt_ref"] = "oattempt_implementationone"
    when "attempt_dispatch_ref_reuse"
      first = bundle["work_unit_attempts"].find do |candidate|
        candidate["attempt_id"] == "oattempt_implementationone"
      end
      attempt = bundle["work_unit_attempts"].find do |candidate|
        candidate["attempt_id"] == "oattempt_implementationtwo"
      end
      attempt["dispatch_lead_checkpoint_ref"] =
        first["dispatch_lead_checkpoint_ref"]
    when "missing_change_thesis_genesis"
      thesis = bundle["change_theses"].first
      thesis["revision"] = 2
      rehash(thesis)
      thesis_ref = {
        "change_thesis_id" => thesis["change_thesis_id"],
        "revision" => thesis["revision"],
        "content_digest" => thesis["content_digest"]
      }
      unit = bundle["work_units"].find do |candidate|
        candidate["work_unit_id"] == thesis["work_unit_id"]
      end
      unit["initial_change_thesis_ref"] = thesis_ref
      rehash(unit)
      attempt = bundle["work_unit_attempts"].find do |candidate|
        candidate["work_unit_id"] == thesis["work_unit_id"]
      end
      attempt.dig("events", 0, "assignment")["change_thesis_ref"] = thesis_ref
      rehash_named(attempt.dig("events", 0), "event_digest")
      record = bundle["evidence_records"].find do |candidate|
        candidate["attempt_id"] == attempt["attempt_id"]
      end
      record.dig("implementation_check")["change_thesis_ref"] = thesis_ref
      rehash(record)
      refresh_evaluation_subject(bundle)
    else
      raise "unknown invalid fixture #{id}"
    end
    bundle
  end

  def add_new_implementation(bundle)
    unit = bundle["work_units"][0]
    thesis = bundle["change_theses"].find { |candidate| candidate["work_unit_id"] == unit["work_unit_id"] }
    identity = OrbitV2FixtureFactory.deep_copy(bundle["rule_resolution_artifacts"][0]["identity"])
    identity["attempt_id"] = "oattempt_implementationthree"
    identity["agent_instance_id"] = "oagent_implementertwo"
    rule = Orbit::V2::RuleResolution.build(
      identity,
      created_at: "2026-07-30T02:00:00Z",
      project_root: ROOT
    )
    attempt = OrbitV2FixtureFactory.attempt(
      identity["attempt_id"],
      unit["work_unit_id"],
      identity["agent_instance_id"],
      identity["resolved_role"],
      "implementation",
      thesis,
      rule["resolution_id"],
      3,
      bundle["project_policy_revisions"][0]["content_digest"],
      authorization_record_refs:
        unit.dig("authority_scope", "authorization_record_refs")
    )
    OrbitV2FixtureFactory.append_dispatch_checkpoint(bundle, attempt: attempt, unit: unit)
    evidence = OrbitV2FixtureFactory.implementation_evidence(
      "oevr_implementationthree",
      attempt,
      rule,
      unit["initial_change_thesis_ref"],
      ["lib/orbit/v2/new-contract.rb"]
    )
    bundle["rule_resolution_artifacts"] << rule
    bundle["work_unit_attempts"] << attempt
    bundle["evidence_records"] << evidence
  end

  def add_task_revision_clone(bundle, id:, revision_number:, parent_id:)
    task = OrbitV2FixtureFactory.deep_copy(bundle["task_revisions"].first)
    task["task_revision_id"] = id
    task["revision_number"] = revision_number
    task["parent_task_revision_id"] = parent_id
    task["gate_requirement_refs"] = []
    task["protected_change_authorization_ref"] = nil
    rehash(task)
    bundle["task_revisions"] << task
    task
  end

  def add_task_successor(bundle, selector_scope: "task_wide")
    parent = bundle["task_revisions"].first
    parent_gate = bundle["gate_requirements"].first
    child_gate = OrbitV2FixtureFactory.deep_copy(parent_gate)
    child_gate["gate_requirement_id"] = "ogreq_slice0review_r2"
    child_gate["task_revision_id"] = "trev_slice0contract_r2"
    child_gate["parent_gate_requirement_ref"] = {
      "gate_requirement_id" => parent_gate["gate_requirement_id"],
      "content_digest" => parent_gate["content_digest"]
    }
    child_gate.dig("subject_selector", "scope").replace(selector_scope)
    rehash(child_gate)

    child = OrbitV2FixtureFactory.deep_copy(parent)
    child["task_revision_id"] = child_gate["task_revision_id"]
    child["revision_number"] = 2
    child["parent_task_revision_id"] = parent["task_revision_id"]
    child["gate_requirement_refs"] = [child_gate["gate_requirement_id"]]
    child["protected_change_authorization_ref"] = nil
    rehash(child)
    bundle["gate_requirements"] << child_gate
    bundle["task_revisions"] << child
    { "task" => child, "gate" => child_gate }
  end

  def add_cross_revision_resolution(bundle, outcome)
    successor = add_task_successor(bundle)
    child = successor.fetch("task")
    child_gate = successor.fetch("gate")
    child["unresolved_finding_refs"] = []
    rehash(child)

    specifications = [
      {
        "unit_id" => "owu_revisiontwoimplementation",
        "thesis_id" => "othesis_revisiontwoimplementation",
        "kind" => "implementation",
        "source_unit" => bundle["work_units"][0],
        "source_thesis" => bundle["change_theses"][0]
      },
      {
        "unit_id" => "owu_revisiontwoevaluation",
        "thesis_id" => "othesis_revisiontwoevaluation",
        "kind" => "evaluation",
        "source_unit" => bundle["work_units"][2],
        "source_thesis" => bundle["change_theses"][2]
      }
    ]
    child_theses = specifications.map do |specification|
      thesis = OrbitV2FixtureFactory.deep_copy(specification.fetch("source_thesis"))
      thesis["change_thesis_id"] = specification.fetch("thesis_id")
      thesis["task_revision_id"] = child["task_revision_id"]
      thesis["work_unit_id"] = specification.fetch("unit_id")
      rehash(thesis)
      thesis
    end
    child_units = specifications.each_with_index.map do |specification, index|
      unit = OrbitV2FixtureFactory.deep_copy(specification.fetch("source_unit"))
      thesis = child_theses[index]
      unit["work_unit_id"] = specification.fetch("unit_id")
      unit["task_revision_id"] = child["task_revision_id"]
      unit["parent_work_unit_ref"] =
        if index.zero?
          nil
        else
          specifications.first.fetch("unit_id")
        end
      unit["depends_on_work_unit_refs"] =
        if index.zero?
          []
        else
          [specifications.first.fetch("unit_id")]
        end
      unit["input_refs"] = ["task-revision://#{child["task_revision_id"]}"]
      unit["output_refs"] = ["work-unit-output://#{unit["work_unit_id"]}"]
      unit.dig("authority_scope", "authorization_record_refs").clear
      unit["initial_change_thesis_ref"] = {
        "change_thesis_id" => thesis["change_thesis_id"],
        "revision" => 1,
        "content_digest" => thesis["content_digest"]
      }
      rehash(unit)
      unit
    end
    child_authorizations = child_units.flat_map do |unit|
      Array(unit.dig("authority_scope", "allowed_actions")).map do |action|
        OrbitV2FixtureFactory.work_authorization(unit, child, action)
      end
    end
    bundle["authority_assertions"].concat(
      child_authorizations.map { |authorization| authorization.fetch("assertion") }
    )
    bundle["authorization_records"].concat(
      child_authorizations.map { |authorization| authorization.fetch("record") }
    )
    bundle["change_theses"].concat(child_theses)
    bundle["work_units"].concat(child_units)

    attempt_specs = [
      {
        "attempt_id" => "oattempt_revisiontwoimplementation",
        "agent_id" => "oagent_implementertwo",
        "role" => "coder",
        "purpose" => "implementation",
        "unit" => child_units[0],
        "thesis" => child_theses[0],
        "source_rule" => bundle["rule_resolution_artifacts"][0]
      },
      {
        "attempt_id" => "oattempt_revisiontwoevaluation",
        "agent_id" => "oagent_independentreviewer",
        "role" => "reviewer",
        "purpose" => "review",
        "unit" => child_units[1],
        "thesis" => child_theses[1],
        "source_rule" => bundle["rule_resolution_artifacts"][2]
      }
    ]
    child_attempts = []
    child_rules = []
    attempt_specs.each_with_index do |specification, index|
      identity = OrbitV2FixtureFactory.deep_copy(
        specification.fetch("source_rule").fetch("identity")
      )
      identity["task_revision_id"] = child["task_revision_id"]
      identity["work_unit_id"] = specification.fetch("unit")["work_unit_id"]
      identity["attempt_id"] = specification.fetch("attempt_id")
      identity["agent_instance_id"] = specification.fetch("agent_id")
      identity["resolved_role"] = specification.fetch("role")
      rule = Orbit::V2::RuleResolution.build(
        identity,
        created_at: "2026-07-30T05:00:0#{index}Z",
        project_root: ROOT
      )
      attempt = OrbitV2FixtureFactory.attempt(
        specification.fetch("attempt_id"),
        specification.fetch("unit")["work_unit_id"],
        specification.fetch("agent_id"),
        specification.fetch("role"),
        specification.fetch("purpose"),
        specification.fetch("thesis"),
        rule["resolution_id"],
        index + 5,
        bundle["project_policy_revisions"].first["content_digest"],
        task_revision_id: child["task_revision_id"],
        authorization_record_refs: specification.fetch("unit")
          .dig("authority_scope", "authorization_record_refs"),
        started_at: index.zero? ? "2026-07-30T00:05:00Z" : "2026-07-30T00:06:00Z"
      )
      bundle["work_unit_attempts"] << attempt
      OrbitV2FixtureFactory.append_dispatch_checkpoint(bundle, attempt: attempt, unit: specification.fetch("unit"), task: child,
        pin_attempt_id: index.zero? ? nil : child_attempts.first["attempt_id"])
      if index.zero?
        attempt["events"] << OrbitV2FixtureFactory.event(
          "oevent_revisiontwoimplementationcompleted",
          "AttemptCompleted",
          attempt.dig("events", 0, "event_digest"),
          "ended_at" => "2026-07-30T00:05:30Z",
          "status" => "completed"
        )
      end
      child_rules << rule
      child_attempts << attempt
    end
    base_review = bundle["work_unit_attempts"].find do |candidate|
      candidate["attempt_id"] == "oattempt_independentreview"
    end
    if base_review && base_review.fetch("events").length == 1
      base_review["events"] << OrbitV2FixtureFactory.event(
        "oevent_revisiontwosupersedesreview",
        "AttemptCompleted",
        base_review.fetch("events").last.fetch("event_digest"),
        "ended_at" => "2026-07-30T00:03:30Z",
        "status" => "completed"
      )
    end
    implementation = OrbitV2FixtureFactory.implementation_evidence(
      "oevr_revisiontwoimplementation",
      child_attempts[0],
      child_rules[0],
      child_units[0]["initial_change_thesis_ref"],
      ["lib/orbit/v2/validator.rb"],
      acceptance_recorded_at: "2026-07-30T00:05:30Z"
    )
    submission = OrbitV2FixtureFactory.evaluator_submission(
      "oevr_revisiontwoevaluation",
      child_attempts[1],
      child_rules[1],
      acceptance_recorded_at: "2026-07-30T00:06:30Z"
    )
    child_evidence = [implementation, submission]
    bundle["rule_resolution_artifacts"].concat(child_rules)
    bundle["evidence_records"].concat(child_evidence)

    subject = Orbit::V2::EvaluationSubject.select(
      gate_requirement: child_gate,
      task_revision: child,
      work_units: bundle["work_units"],
      attempts: bundle["work_unit_attempts"],
      evidence_records: bundle["evidence_records"],
      repository_snapshot: bundle["repository_snapshot"],
      code_surface: bundle["code_surface"]
    )
    source_evaluation = bundle["gate_evaluations"].first
    evaluation = OrbitV2FixtureFactory.deep_copy(source_evaluation)
    evaluation["gate_evaluation_id"] = "ogeval_revisiontwofollowup"
    evaluation["gate_requirement_id"] = child_gate["gate_requirement_id"]
    evaluation["gate_requirement_content_digest"] = child_gate["content_digest"]
    evaluation["evaluator_attempt_id"] = child_attempts[1]["attempt_id"]
    evaluation["evaluator_submission_record_id"] = submission["evidence_record_id"]
    evaluation["subject"] = subject
    evaluation["verdict"] = "pass"
    evaluation["quality_outcome_verdict"] = "pass"
    evaluation["quality_question_answers"].each do |answer|
      answer["verdict"] = "pass"
      answer["evidence_record_refs"] = [implementation["evidence_record_id"]]
    end
    evaluation["acceptance_results"].each do |answer|
      answer["verdict"] = "pass"
      answer["evidence_record_refs"] = [implementation["evidence_record_id"]]
    end
    evaluation["counterexample_cases"] = []
    evaluation["confirmed"] = ["The descendant revision addresses the inherited Finding."]
    evaluation["missing"] = []
    evaluation["coverage"] = {
      "summary" => "The descendant implementation WorkUnit is fully evaluated.",
      "covered_work_unit_refs" => [child_units[0]["work_unit_id"]],
      "uncovered_work_unit_refs" => [],
      "evidence_record_refs" => [implementation["evidence_record_id"]]
    }
    evaluation["residual_risk"] = "No residual risk remains for the inherited Finding."
    evaluation["finding_refs"] = []
    evaluation["supersedes_gate_evaluation_id"] =
      source_evaluation["gate_evaluation_id"]
    rehash(evaluation)
    bundle["gate_evaluations"] << evaluation

    finding = bundle["findings"].first
    resolution = bundle["finding_resolutions"].first
    resolution.delete("authorization_record_ref")
    resolution["resolution"] = outcome
    resolution["issuer_attempt_id"] = child_attempts[1]["attempt_id"]
    resolution["issuer_submission_record_id"] = submission["evidence_record_id"]
    resolution["source_finding_ref"] = {
      "finding_id" => finding["finding_id"],
      "content_digest" => finding["content_digest"]
    }
    resolution["source_gate_evaluation_ref"] = {
      "gate_evaluation_id" => source_evaluation["gate_evaluation_id"],
      "content_digest" => source_evaluation["content_digest"]
    }
    resolution["resolving_gate_evaluation_ref"] = {
      "gate_evaluation_id" => evaluation["gate_evaluation_id"],
      "content_digest" => evaluation["content_digest"]
    }
    resolution["supporting_record_refs"] = [implementation["evidence_record_id"]]
    if outcome == "addressed"
      resolution["proposal_evidence_record_id"] = implementation["evidence_record_id"]
    end
    rehash(resolution)
  end

  def add_authorized_protected_successor(
    bundle,
    authorization_policy: nil,
    candidate_policy: nil
  )
    successor = add_task_successor(bundle, selector_scope: "selected_work_units")
    child = successor.fetch("task")
    child_gate = successor.fetch("gate")
    candidate_policy ||= bundle["project_policy_revisions"].last
    authorization_policy ||= candidate_policy
    child["project_policy_revision_ref"] = {
      "policy_revision_id" => candidate_policy["policy_revision_id"],
      "content_digest" => candidate_policy["content_digest"]
    }
    authorization_id = "oauthz_protectedchange_r2"
    child["protected_change_authorization_ref"] = authorization_id
    rehash(child)

    parent = bundle["task_revisions"].first
    parent_gate = bundle["gate_requirements"].first
    change_digest = Orbit::V2::ProtectedChange.diff_digest(
      parent_task: parent,
      candidate_task: child,
      parent_gates: [parent_gate],
      candidate_gates: [child_gate]
    )
    assertion = OrbitV2FixtureFactory.assertion(
      "oassert_protectedchange_r2",
      ["task.protected_contract.change"],
      "project-owner",
      authority_scope_ref: change_digest
    )
    policy = authorization_policy
    receipt = assertion.fetch("verification_receipt")
    envelope = {
      "schema_version" => "orbit-protected-change-authorization-v1",
      "project_id" => child["project_id"],
      "task_id" => child["task_id"],
      "parent_task_revision_ref" => {
        "task_revision_id" => parent["task_revision_id"],
        "content_digest" => parent["content_digest"]
      },
      "candidate_task_revision_ref" => {
        "task_revision_id" => child["task_revision_id"],
        "content_digest" => child["content_digest"]
      },
      "protected_change_digest" => change_digest,
      "authority_source_revision_ref" => {
        "provider_id" => assertion["provider_id"],
        "receipt_id" => receipt["receipt_id"],
        "assertion_id" => assertion["assertion_id"],
        "assertion_digest" => assertion["assertion_digest"]
      },
      "issuer_authority_ref" => {
        "assertion_id" => assertion["assertion_id"],
        "assertion_digest" => assertion["assertion_digest"]
      },
      "project_policy_revision_ref" => {
        "policy_revision_id" => policy["policy_revision_id"],
        "content_digest" => policy["content_digest"]
      },
      "decision" => "approved",
      "issued_at" => receipt["issued_at"]
    }
    rehash_envelope(envelope)
    authorization = OrbitV2FixtureFactory.digested(
      "schema_version" => "orbit-authorization-record-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => child["project_id"],
      "authorization_record_id" => authorization_id,
      "project_policy_revision_id" => policy["policy_revision_id"],
      "action" => "task.protected_contract.change",
      "subject_ref" => child["task_revision_id"],
      "authorization_source_ref" => assertion["assertion_id"],
      "authorization_assertion_digest" => assertion["assertion_digest"],
      "protected_change_envelope" => envelope
    )
    bundle["authority_assertions"] << assertion
    bundle["authorization_records"] << authorization
    successor.merge("assertion" => assertion, "authorization" => authorization)
  end

  def add_policy_successor(bundle, protected_change_grant: true, rotation_grant: true)
    parent = bundle["project_policy_revisions"].last
    revision_number = bundle["project_policy_revisions"].length + 1
    assertion_id = "oassert_policyrotation_r#{revision_number}"
    policy = OrbitV2FixtureFactory.deep_copy(parent)
    policy["policy_revision_id"] = format("opolicy_revision%04d", revision_number)
    policy["parent_policy_revision_id"] = parent["policy_revision_id"]
    policy["authorization_source_ref"] = assertion_id
    issued_at = format("2026-07-30T%02d:00:00Z", revision_number + 5)
    required_grant = Array(parent["authority_grants"]).find do |grant|
      grant["action"] == "policy.rotate"
    end&.fetch("required_external_grant", nil) || "policy.rotate"
    policy["authorization_assertion_digest"] =
      OrbitV2FixtureFactory.policy_issuance_assertion_digest(
        assertion_id: assertion_id,
        required_grant: required_grant,
        subject: "project-owner",
        issued_at: issued_at
      )
    unless protected_change_grant
      policy["authority_grants"] = Array(policy["authority_grants"]).reject do |grant|
        grant["action"] == "task.protected_contract.change"
      end
    end
    unless rotation_grant
      policy["authority_grants"] = Array(policy["authority_grants"]).reject do |grant|
        grant["action"] == "policy.rotate"
      end
    end
    rehash(policy)
    assertion = OrbitV2FixtureFactory.policy_issuance_assertion(
      policy,
      parent_policy: parent,
      assertion_id: assertion_id,
      subject: "project-owner",
      issued_at: issued_at
    )
    bundle["authority_assertions"] << assertion
    bundle["project_policy_revisions"] << policy
    rebind_checkpoint_for_policy_rotation(bundle, policy, revision_number)
    policy
  end

  def rebind_checkpoint_for_policy_rotation(bundle, policy, revision_number)
    tip = bundle["lead_checkpoints"].last
    # The tip is an observation checkpoint with the same continue/attempt_created
    # decision shape; the rotation checkpoint re-pins it under the new policy.
    rebind = OrbitV2FixtureFactory.deep_copy(tip)
    rebind["lead_checkpoint_id"] = format("olcheckpoint_policyrotation_r%04d", revision_number)
    rebind["predecessor_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(tip)
    rebind["project_policy_revision_ref"] = OrbitV2FixtureFactory.policy_ref(policy)
    rebind["writer_authority_provenance"] = OrbitV2FixtureFactory.writer_provenance(policy, "control.checkpoint",
      bundle["authority_assertions"].find { |candidate| candidate["assertion_id"] == "oassert_controlwriter" })
    rebind["current_or_terminal_attempt_ref"] = OrbitV2FixtureFactory.attempt_event_ref(bundle["work_unit_attempts"], "oattempt_independentreview")
    %w[delivery_progress assurance_progress].each { |field| rebind[field]["predecessor_lead_checkpoint_ref"] = rebind["predecessor_lead_checkpoint_ref"] }
    attempt = bundle["work_unit_attempts"].find { |candidate| candidate["attempt_id"] == "oattempt_independentreview" }
    resolution = bundle["rule_resolution_artifacts"].find do |candidate|
      candidate["resolution_id"] == attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id")
    end
    rebind = OrbitV2FixtureFactory.reseal_checkpoint(
      rebind,
      policy: policy,
      predecessor_checkpoint: tip,
      attempt: attempt,
      resolution: resolution
    )
    bundle["lead_checkpoints"] << rebind
  end

  def reissue_genesis_policy(bundle)
    policy = bundle["project_policy_revisions"].first
    rehash(policy)
    assertion_id = policy["authorization_source_ref"]
    assertion = OrbitV2FixtureFactory.policy_issuance_assertion(
      policy,
      parent_policy: nil,
      assertion_id: assertion_id,
      subject: "project-owner"
    )
    index = bundle["authority_assertions"].index do |candidate|
      candidate["assertion_id"] == assertion_id
    end
    bundle["authority_assertions"][index] = assertion

    root = bundle["protocol_root"]
    root["project_policy_genesis_ref"] = {
      "policy_revision_id" => policy["policy_revision_id"],
      "content_digest" => policy["content_digest"]
    }
    rehash(root)

    updated_tasks = []
    bundle["task_revisions"].each do |task|
      next unless task.dig("project_policy_revision_ref", "policy_revision_id") ==
                  policy["policy_revision_id"]

      task["project_policy_revision_ref"]["content_digest"] = policy["content_digest"]
      rehash(task)
      updated_tasks << task
    end
    updated_tasks.each { |task| refresh_work_authorizations(bundle, task) }
    bundle["work_unit_attempts"].each do |attempt|
      creation = attempt.fetch("events").first
      policy_ref = creation.dig(
        "assignment",
        "authority_snapshot",
        "project_policy_revision_ref"
      )
      next unless policy_ref &&
                  policy_ref["policy_revision_id"] == policy["policy_revision_id"]

      policy_ref["content_digest"] = policy["content_digest"]
      OrbitV2FixtureFactory.resign_event_chain(attempt)
    end
    refresh_all_evaluation_subjects(bundle)
    policy
  end

  def add_task_authority(bundle, action:, subject_override: nil)
    task = bundle["task_revisions"].first
    authorization_id = "oauthz_taskriskdelegate"
    task["authority_grant_refs"] = [authorization_id]
    rehash(task)
    rebind_checkpoint_refs(bundle, task: task)
    scope = subject_override || Orbit::V2::TaskAuthority.scope_digest(task)
    assertion = OrbitV2FixtureFactory.assertion(
      "oassert_taskriskdelegate",
      [action],
      "project-owner",
      authority_scope_ref: scope
    )
    authorization = OrbitV2FixtureFactory.digested(
      "schema_version" => "orbit-authorization-record-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => task["project_id"],
      "authorization_record_id" => authorization_id,
      "project_policy_revision_id" =>
        task.dig("project_policy_revision_ref", "policy_revision_id"),
      "action" => action,
      "subject_ref" => scope,
      "authorization_source_ref" => assertion["assertion_id"],
      "authorization_assertion_digest" => assertion["assertion_digest"]
    )
    bundle["authority_assertions"] << assertion
    bundle["authorization_records"] << authorization
    refresh_work_authorizations(bundle, task)
    refresh_evaluation_subject(bundle)
    authorization
  end

  def refresh_work_authorizations(bundle, task)
    units = bundle["work_units"].select do |unit|
      unit["task_revision_id"] == task["task_revision_id"]
    end
    old_record_ids = units.flat_map do |unit|
      Array(unit.dig("authority_scope", "authorization_record_refs"))
    end
    old_records = bundle["authorization_records"].select do |record|
      old_record_ids.include?(record["authorization_record_id"]) &&
        Orbit::V2::WorkAuthority.action?(record["action"])
    end
    old_assertion_ids = old_records.map { |record| record["authorization_source_ref"] }
    bundle["authorization_records"].reject! do |record|
      old_records.include?(record)
    end
    bundle["authority_assertions"].reject! do |assertion|
      old_assertion_ids.include?(assertion["assertion_id"])
    end

    authorizations = units.flat_map do |unit|
      unit.dig("authority_scope", "authorization_record_refs").clear
      Array(unit.dig("authority_scope", "allowed_actions")).map do |action|
        OrbitV2FixtureFactory.work_authorization(unit, task, action)
      end
    end
    bundle["authority_assertions"].concat(
      authorizations.map { |authorization| authorization.fetch("assertion") }
    )
    bundle["authorization_records"].concat(
      authorizations.map { |authorization| authorization.fetch("record") }
    )
    units.each do |unit|
      bundle["work_unit_attempts"].select do |attempt|
        attempt["work_unit_id"] == unit["work_unit_id"]
      end.each do |attempt|
        creation = attempt.dig("events", 0)
        action = Orbit::V2::WorkAuthority.action_for_purpose(
          creation.dig("assignment", "purpose")
        )
        refs = Array(unit.dig("authority_scope", "authorization_record_refs")).select do |record_id|
          bundle["authorization_records"].any? do |record|
            record["authorization_record_id"] == record_id &&
              record["action"] == action
          end
        end
        creation.dig(
          "assignment",
          "authority_snapshot",
          "authorization_record_refs"
        ).replace(refs)
        OrbitV2FixtureFactory.resign_event_chain(attempt)
      end
    end
    units.each { |unit| rebind_checkpoint_refs(bundle, unit: unit) }
  end

  def add_work_authority(bundle, unit_index: 0, purpose: "implementation", subject_override: nil)
    unit = bundle["work_units"][unit_index]
    task = bundle["task_revisions"].find do |candidate|
      candidate["task_revision_id"] == unit["task_revision_id"]
    end
    action = Orbit::V2::WorkAuthority.action_for_purpose(purpose)
    policy = bundle["project_policy_revisions"].find do |candidate|
      candidate["policy_revision_id"] ==
        task.dig("project_policy_revision_ref", "policy_revision_id")
    end
    unless Array(policy["authority_grants"]).any? { |grant| grant["action"] == action }
      policy["authority_grants"] << {
        "action" => action,
        "required_external_grant" => action
      }
      reissue_genesis_policy(bundle)
      task = bundle["task_revisions"].find do |candidate|
        candidate["task_revision_id"] == unit["task_revision_id"]
      end
    end
    scope = subject_override ||
      Orbit::V2::WorkAuthority.scope_digest(unit, task, action)
    suffix = unit["work_unit_id"].delete_prefix("owu_")
    authorization_id = "oauthz_#{suffix}_#{purpose}"
    assertion = OrbitV2FixtureFactory.assertion(
      "oassert_#{suffix}_#{purpose}",
      [action],
      "project-owner",
      authority_scope_ref: scope
    )
    authorization = OrbitV2FixtureFactory.digested(
      "schema_version" => "orbit-authorization-record-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => unit["project_id"],
      "authorization_record_id" => authorization_id,
      "project_policy_revision_id" => policy["policy_revision_id"],
      "action" => action,
      "subject_ref" => scope,
      "authorization_source_ref" => assertion["assertion_id"],
      "authorization_assertion_digest" => assertion["assertion_digest"]
    )
    bundle["authority_assertions"] << assertion
    bundle["authorization_records"] << authorization
    unit.dig("authority_scope", "authorization_record_refs") << authorization_id
    rehash(unit)
    bundle["work_unit_attempts"].each do |candidate|
      next unless candidate["work_unit_id"] == unit["work_unit_id"] &&
                  candidate.dig("events", 0, "assignment", "purpose") == purpose

      candidate.dig(
        "events",
        0,
        "assignment",
        "authority_snapshot",
        "authorization_record_refs"
      ) << authorization_id
      OrbitV2FixtureFactory.resign_event_chain(candidate)
    end
    rebind_checkpoint_refs(bundle, unit: unit)
    refresh_all_evaluation_subjects(bundle)
    authorization
  end

  def add_gate_requirement(
    bundle,
    kind:,
    gate_id:,
    lineage_id:,
    evidence_level:,
    independence:,
    insert_first: false,
    protected: true,
    selector_scope: "task_wide",
    work_unit_refs: []
  )
    gate = OrbitV2FixtureFactory.deep_copy(bundle["gate_requirements"].first)
    gate["gate_requirement_id"] = gate_id
    gate["gate_lineage_id"] = lineage_id
    gate["kind"] = kind
    gate["evidence_level"] = evidence_level
    gate["independence"] = independence
    gate["protected"] = protected
    gate["subject_selector"]["scope"] = selector_scope
    gate["subject_selector"]["work_unit_refs"] = work_unit_refs
    rehash(gate)
    task = bundle["task_revisions"].first
    if insert_first
      task["gate_requirement_refs"].unshift(gate_id)
    else
      task["gate_requirement_refs"] << gate_id
    end
    rehash(task)
    rebind_checkpoint_refs(bundle, task: task)
    refresh_work_authorizations(bundle, task)
    bundle["gate_requirements"] << gate
    refresh_evaluation_subject(bundle)
    gate
  end

  def prepare_for_policy_rotation(bundle)
    task = bundle["task_revisions"].first
    task["unresolved_finding_refs"] = []
    rehash(task)
    refresh_work_authorizations(bundle, task)
    rebind_checkpoint_refs(bundle, task: task)
    bundle["gate_evaluations"] = []
    bundle["findings"] = []
    bundle["finding_resolutions"] = []
    terminalize_attempts(bundle)
  end

  # Re-pin registry/checkpoint task refs and dependent digests after a fixture
  def rebind_checkpoint_refs(bundle, task: nil, unit: nil)
    task_ref = task && OrbitV2FixtureFactory.task_ref(task)
    attempts = bundle["work_unit_attempts"].to_h { |attempt| [attempt["attempt_id"], attempt] }
    repin = lambda do |ref|
      next ref unless ref && (attempt = attempts[ref["attempt_id"]])
      event = attempt["events"].find { |candidate| candidate["event_id"] == ref["event_id"] }
      event && { "attempt_id" => ref["attempt_id"], "event_id" => event["event_id"], "event_digest" => event["event_digest"] }
    end
    bundle["lead_checkpoints"].each_with_index do |checkpoint, index|
      checkpoint["task_queue"] = [task_ref] if task_ref
      checkpoint["active_task_ref"] = task_ref if task_ref && checkpoint["active_task_ref"]
      if unit && (selected = checkpoint["selected_work_unit_ref"]) && selected["work_unit_id"] == unit["work_unit_id"]
        checkpoint["selected_work_unit_ref"] = {
          "work_unit_id" => unit["work_unit_id"],
          "content_digest" => unit["content_digest"]
        }
      end
      checkpoint["current_or_terminal_attempt_ref"] =
        repin.call(checkpoint["current_or_terminal_attempt_ref"]) if checkpoint["current_or_terminal_attempt_ref"]
      %w[delivery_progress assurance_progress].each do |field|
        measured = checkpoint.dig(field, "measured_terminal_attempt_ref")
        updated = repin.call(measured)
        checkpoint[field]["measured_terminal_attempt_ref"] = updated if measured
        next unless updated && measured
        Array(checkpoint.dig(field, "supporting_refs")).each do |ref|
          next unless ref["kind"] == "attempt_event" && ref["id"] == measured["attempt_id"]
          ref["event_id"] = updated["event_id"]
          ref["digest"] = updated["event_digest"]
        end
      end
      if index.positive?
        predecessor_ref = OrbitV2FixtureFactory.cp_ref(bundle["lead_checkpoints"][index - 1])
        checkpoint["predecessor_lead_checkpoint_ref"] = predecessor_ref
        checkpoint["delivery_progress"]["predecessor_lead_checkpoint_ref"] = predecessor_ref
        checkpoint["assurance_progress"]["predecessor_lead_checkpoint_ref"] = predecessor_ref
      end
      policy = bundle["project_policy_revisions"].find do |candidate|
        candidate["policy_revision_id"] == checkpoint.dig("project_policy_revision_ref", "policy_revision_id")
      end
      pinned_attempt = (ref = checkpoint["current_or_terminal_attempt_ref"]) && attempts[ref["attempt_id"]]
      resolution = pinned_attempt && bundle["rule_resolution_artifacts"].find do |candidate|
        candidate["resolution_id"] ==
          pinned_attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id")
      end
      resealed = OrbitV2FixtureFactory.reseal_checkpoint(
        checkpoint,
        policy: policy,
        predecessor_checkpoint: index.positive? ? bundle["lead_checkpoints"][index - 1] : nil,
        attempt: pinned_attempt,
        resolution: resolution
      )
      bundle["lead_checkpoints"][index] = resealed
      checkpoint = resealed
    end
    checkpoints = bundle["lead_checkpoints"].to_h { |cp| [cp["lead_checkpoint_id"], cp] }
    bundle["work_unit_attempts"].each do |attempt|
      ref = attempt["dispatch_lead_checkpoint_ref"]
      next unless ref && checkpoints[ref["lead_checkpoint_id"]]

      attempt["dispatch_lead_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(checkpoints[ref["lead_checkpoint_id"]])
    end
    return unless task_ref

    bundle["control_registries"].each do |registry|
      registry["owned_task_refs"] = [task_ref]
      genesis = bundle["lead_checkpoints"].find { |checkpoint| checkpoint["lead_checkpoint_id"] == registry.dig("genesis_checkpoint_ref", "lead_checkpoint_id") }
      registry["genesis_checkpoint_ref"] = OrbitV2FixtureFactory.cp_ref(genesis) if genesis
      rehash(registry)
    end
  end

  def terminalize_attempts(bundle)
    bundle["work_unit_attempts"].each_with_index do |attempt, index|
      next if attempt.fetch("events").length > 1

      attempt["events"] << OrbitV2FixtureFactory.event(
        "oevent_#{attempt["attempt_id"].delete_prefix("oattempt_")}_completed",
        "AttemptCompleted",
        attempt.dig("events", 0, "event_digest"),
        "ended_at" => "2026-07-30T06:00:0#{index}Z",
        "status" => "completed"
      )
    end
  end

  def rehash_envelope(envelope)
    envelope["envelope_digest"] = Orbit::V2::ProtectedChange.envelope_digest(envelope)
  end

  def refresh_all_evaluation_subjects(bundle)
    bundle["gate_evaluations"].each do |evaluation|
      requirement = bundle["gate_requirements"].find do |gate|
        gate["gate_requirement_id"] == evaluation["gate_requirement_id"]
      end
      task = bundle["task_revisions"].find do |candidate|
        candidate["task_revision_id"] == requirement["task_revision_id"]
      end
      evaluation["subject"] = Orbit::V2::EvaluationSubject.select(
        gate_requirement: requirement,
        task_revision: task,
        work_units: bundle["work_units"],
        attempts: bundle["work_unit_attempts"],
        evidence_records: bundle["evidence_records"],
        repository_snapshot: bundle["repository_snapshot"],
        code_surface: bundle["code_surface"]
      )
      rehash(evaluation)
    end
  end

  def add_unused_reviewer(bundle)
    base_attempt = bundle["work_unit_attempts"].find do |candidate|
      candidate["attempt_id"] == "oattempt_independentreview"
    end
    base_rule = bundle["rule_resolution_artifacts"].find do |candidate|
      candidate.dig("identity", "attempt_id") == base_attempt["attempt_id"]
    end
    if base_attempt.fetch("events").length == 1
      base_attempt["events"] << OrbitV2FixtureFactory.event(
        "oevent_independentreviewsuperseded",
        "AttemptCompleted",
        base_attempt.fetch("events").last.fetch("event_digest"),
        "ended_at" => "2026-07-30T00:03:30Z",
        "status" => "completed"
      )
    end
    identity = OrbitV2FixtureFactory.deep_copy(base_rule.fetch("identity"))
    identity["attempt_id"] = "oattempt_unusedreviewer"
    rule = Orbit::V2::RuleResolution.build(
      identity,
      created_at: "2026-07-30T04:00:00Z",
      project_root: ROOT
    )
    thesis = bundle["change_theses"].find do |candidate|
      candidate["work_unit_id"] == base_attempt["work_unit_id"]
    end
    unit = bundle["work_units"].find do |candidate|
      candidate["work_unit_id"] == base_attempt["work_unit_id"]
    end
    attempt = OrbitV2FixtureFactory.attempt(
      identity["attempt_id"],
      base_attempt["work_unit_id"],
      identity["agent_instance_id"],
      identity["resolved_role"],
      "review",
      thesis,
      rule["resolution_id"],
      4,
      bundle["project_policy_revisions"].first["content_digest"],
      authorization_record_refs:
        unit.dig("authority_scope", "authorization_record_refs"),
      predecessor_work_unit_attempt_ref: base_attempt["attempt_id"],
      started_at: "2026-07-30T00:04:00Z"
    )
    OrbitV2FixtureFactory.append_dispatch_checkpoint(bundle, attempt: attempt, unit: unit, pin_attempt_id: base_attempt["attempt_id"])
    submission = OrbitV2FixtureFactory.evaluator_submission(
      "oevr_unusedreviewer",
      attempt,
      rule,
      acceptance_recorded_at: "2026-07-30T00:04:30Z"
    )
    bundle["rule_resolution_artifacts"] << rule
    bundle["work_unit_attempts"] << attempt
    bundle["evidence_records"] << submission
    {
      "attempt_id" => attempt["attempt_id"],
      "submission_id" => submission["evidence_record_id"]
    }
  end

  def add_cross_gate_finding(bundle)
    task = bundle["task_revisions"].first
    original_gate = bundle["gate_requirements"].first
    gate = OrbitV2FixtureFactory.deep_copy(original_gate)
    gate["gate_requirement_id"] = "ogreq_slice0otherreview"
    gate["gate_lineage_id"] = "ogline_slice0otherreview"
    rehash(gate)
    bundle["gate_requirements"] << gate
    task["gate_requirement_refs"] << gate["gate_requirement_id"]
    rehash(task)
    refresh_evaluation_subject(bundle)

    evaluation = OrbitV2FixtureFactory.deep_copy(bundle["gate_evaluations"].first)
    evaluation["gate_evaluation_id"] = "ogeval_slice0otherreview"
    evaluation["gate_requirement_id"] = gate["gate_requirement_id"]
    evaluation["gate_requirement_content_digest"] = gate["content_digest"]
    evaluation["subject"] = Orbit::V2::EvaluationSubject.select(
      gate_requirement: gate,
      task_revision: task,
      work_units: bundle["work_units"],
      attempts: bundle["work_unit_attempts"],
      evidence_records: bundle["evidence_records"],
      repository_snapshot: bundle["repository_snapshot"],
      code_surface: bundle["code_surface"]
    )
    finding = OrbitV2FixtureFactory.deep_copy(bundle["findings"].first)
    finding["finding_id"] = "ofinding_othergatelineage"
    finding["gate_evaluation_id"] = evaluation["gate_evaluation_id"]
    finding["basis"] = "hardening_opportunity"
    finding["supersedes_finding_id"] = nil
    rehash(finding)
    evaluation["finding_refs"] = [finding["finding_id"]]
    evaluation["supersedes_gate_evaluation_id"] = nil
    rehash(evaluation)
    bundle["gate_evaluations"] << evaluation
    bundle["findings"] << finding
    {
      "gate_id" => gate["gate_requirement_id"],
      "evaluation_id" => evaluation["gate_evaluation_id"],
      "finding_id" => finding["finding_id"]
    }
  end

  def add_same_gate_finding_cycle(bundle)
    evaluation = bundle["gate_evaluations"].first
    original = bundle["findings"].first
    related = OrbitV2FixtureFactory.deep_copy(original)
    related["finding_id"] = "ofinding_samegatecycle"
    related["basis"] = "hardening_opportunity"
    original["supersedes_finding_id"] = related["finding_id"]
    related["supersedes_finding_id"] = original["finding_id"]
    evaluation["finding_refs"] << related["finding_id"]
    rehash(original)
    rehash(related)
    rehash(evaluation)
    bundle["findings"] << related
  end

  def make_evaluator_resolution(bundle, outcome, evaluation_id: nil)
    source = bundle["gate_evaluations"].first
    resolving =
      if evaluation_id
        bundle["gate_evaluations"].find do |candidate|
          candidate["gate_evaluation_id"] == evaluation_id
        end
      else
        add_followup_evaluation(bundle)
      end
    resolution = bundle["finding_resolutions"].first
    resolution.delete("authorization_record_ref")
    resolution["resolution"] = outcome
    resolution["issuer_attempt_id"] = resolving["evaluator_attempt_id"]
    resolution["issuer_submission_record_id"] =
      resolving["evaluator_submission_record_id"]
    finding = bundle["findings"].first
    resolution["source_finding_ref"] = {
      "finding_id" => finding["finding_id"],
      "content_digest" => finding["content_digest"]
    }
    resolution["source_gate_evaluation_ref"] = {
      "gate_evaluation_id" => source["gate_evaluation_id"],
      "content_digest" => source["content_digest"]
    }
    resolution["resolving_gate_evaluation_ref"] = {
      "gate_evaluation_id" => resolving["gate_evaluation_id"],
      "content_digest" => resolving["content_digest"]
    }
    resolution["supporting_record_refs"] = ["oevr_implementationone"]
    if outcome == "addressed"
      resolution["proposal_evidence_record_id"] = "oevr_implementationone"
    else
      resolution.delete("proposal_evidence_record_id")
    end
    rehash(resolution)
  end

  def add_followup_evaluation(bundle)
    existing = bundle["gate_evaluations"].find do |evaluation|
      evaluation["gate_evaluation_id"] == "ogeval_slice0followupreview"
    end
    return existing if existing

    issuer = add_unused_reviewer(bundle)
    source = bundle["gate_evaluations"].first
    followup = OrbitV2FixtureFactory.deep_copy(source)
    followup["gate_evaluation_id"] = "ogeval_slice0followupreview"
    followup["evaluator_attempt_id"] = issuer.fetch("attempt_id")
    followup["evaluator_submission_record_id"] = issuer.fetch("submission_id")
    followup["verdict"] = "pass"
    followup["quality_outcome_verdict"] = "pass"
    followup["quality_question_answers"].each { |answer| answer["verdict"] = "pass" }
    followup["acceptance_results"].each { |answer| answer["verdict"] = "pass" }
    followup["counterexample_cases"] = []
    followup["confirmed"] = ["The implementation evidence resolves the source Finding."]
    followup["missing"] = []
    followup["residual_risk"] = "No residual risk remains for the source Finding."
    followup["finding_refs"] = []
    followup["supersedes_gate_evaluation_id"] = source["gate_evaluation_id"]
    rehash(followup)
    bundle["gate_evaluations"] << followup
    followup
  end

  def rehash(document)
    document["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(document)
  end

  def refresh_evaluation_subject(bundle)
    evaluation = bundle.fetch("gate_evaluations").first
    evaluation["subject"] = Orbit::V2::EvaluationSubject.select(
      gate_requirement: bundle.fetch("gate_requirements").first,
      task_revision: bundle.fetch("task_revisions").first,
      work_units: bundle.fetch("work_units"),
      attempts: bundle.fetch("work_unit_attempts"),
      evidence_records: bundle.fetch("evidence_records"),
      repository_snapshot: bundle.fetch("repository_snapshot"),
      code_surface: bundle.fetch("code_surface")
    )
    rehash(evaluation)
  end

  def test_rule_symlink_alias(identity)
    Dir.mktmpdir("orbit-v2-rule-root") do |root|
      FileUtils.mkdir_p(File.join(root, "rules"))
      File.write(File.join(root, "rules/base.md"), "base rule\n")
      File.symlink("base.md", File.join(root, "rules/alias.md"))
      digest = "sha256:#{Digest::SHA256.file(File.join(root, "rules/base.md")).hexdigest}"
      alias_identity = OrbitV2FixtureFactory.deep_copy(identity)
      alias_identity["required_rules"] = [
        {
          "rule_id" => "base",
          "path" => "rules/base.md",
          "content_sha256" => digest,
          "relation" => "baseline"
        },
        {
          "rule_id" => "alias",
          "path" => "rules/alias.md",
          "content_sha256" => digest,
          "relation" => "supplements"
        }
      ]
      expect_contract_error("rule_resolution_duplicate") do
        Orbit::V2::RuleResolution.build(
          alias_identity,
          created_at: "2026-07-30T00:00:00Z",
          project_root: root
        )
      end
    end
  end

  def rehash_named(document, field)
    document[field] = Orbit::V2::CanonicalJSON.digest_excluding(
      document,
      field,
      "created_at",
      "accepted_at",
      "envelope"
    )
  end

  def rehash_subject(subject)
    identity = subject.reject { |key, _value| key == "subject_digest" }
    subject["subject_digest"] = "sha256:#{Orbit::V2::CanonicalJSON.sha256(identity)}"
  end

  def digest_for(value)
    "sha256:#{Digest::SHA256.hexdigest(value)}"
  end

  def deep_contains_closed_object?(value)
    case value
    when Hash
      value["additionalProperties"] == false ||
        value.values.any? { |child| deep_contains_closed_object?(child) }
    when Array
      value.any? { |child| deep_contains_closed_object?(child) }
    else
      false
    end
  end

  def relative(path)
    path.delete_prefix("#{ROOT}/")
  end

  def assert_structure_valid(bundle, label)
    errors = Orbit::V2::SchemaCatalog.structure_errors("contract_bundle", bundle)
    assert(
      errors.empty?,
      "#{label} must remain schema-valid, got #{errors.map(&:code).uniq.sort.join(",")}"
    )
  end

  def expect_contract_error(code)
    yield
    raise "expected #{code}"
  rescue Orbit::V2::ContractError => error
    assert(error.code == code, "expected #{code}, got #{error.code}")
  end

  def assert(condition, message)
    raise "ASSERTION FAILED: #{message}" unless condition

    @assertions += 1
  end

  def validator
    Orbit::V2::Validator.new(
      project_root: ROOT,
      authority_verifier: OrbitV2FixtureFactory.authority_verifier,
      lifecycle_verifier: OrbitV2FixtureFactory.lifecycle_verifier,
      runtime_identity_verifier:
        OrbitV2FixtureFactory.runtime_identity_verifier
    )
  end
end

OrbitV2ContractTest.run if $PROGRAM_NAME == __FILE__
