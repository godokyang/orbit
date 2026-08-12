# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "yaml"

require_relative "../../../lib/orbit/v2/canonical_json"
require_relative "../../../lib/orbit/v2/errors"
require_relative "../../../lib/orbit/v2/gate_strength"
require_relative "../../../lib/orbit/v2/immutable_store"
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
    test_slice1_retry_does_not_invalidate_dispatch
    test_authority_graph_regressions
    test_policy_issuance_and_stale_authority_regressions
    test_policy_assertion_pinning
    test_lifecycle_writer_and_chronology
    test_task_and_work_authority_and_gate_aggregation
    test_eighth_review_regressions
    test_evidence_reference_and_path_scope_regressions
    test_immutable_stores(valid_bundle)
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
        "status" => "failed"
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
    bundle["work_unit_attempts"].concat(child_attempts)
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
    session = bundle["lead_sessions"].first
    agent = bundle["agent_instances"].find { |candidate| candidate["agent_instance_id"] == session["agent_instance_id"] }
    logical_lead = bundle["logical_leads"].first
    task = bundle["task_revisions"].first
    writer_assertion = bundle["authority_assertions"].find { |candidate| candidate["assertion_id"] == "oassert_controlwriter" }
    rebind = OrbitV2FixtureFactory.lead_checkpoint(
      format("olcheckpoint_policyrotation_r%04d", revision_number),
      is_genesis: false,
      predecessor_ref: { "lead_checkpoint_id" => tip["lead_checkpoint_id"], "content_digest" => tip["content_digest"] },
      policy: policy,
      session: session,
      agent: agent,
      logical_lead: logical_lead,
      task: task,
      writer_action: "control.checkpoint",
      writer_assertion: writer_assertion
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
    rebind_control_task_refs(bundle, task)
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
    rebind_control_task_refs(bundle, task)
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
    rebind_control_task_refs(bundle, task)
    bundle["gate_evaluations"] = []
    bundle["findings"] = []
    bundle["finding_resolutions"] = []
    terminalize_attempts(bundle)
  end

  # Re-pin registry/checkpoint task refs and dependent digests after a fixture
  # helper rehashes the TaskRevision they project.
  def rebind_control_task_refs(bundle, task)
    task_ref = { "task_id" => task["task_id"], "task_revision_id" => task["task_revision_id"], "content_digest" => task["content_digest"] }
    bundle["lead_checkpoints"].each do |checkpoint|
      checkpoint["task_queue"] = [task_ref]
    end
    bundle["lead_checkpoints"].each_with_index do |checkpoint, index|
      if index.positive?
        prior = bundle["lead_checkpoints"][index - 1]
        checkpoint["predecessor_lead_checkpoint_ref"] = {
          "lead_checkpoint_id" => prior["lead_checkpoint_id"],
          "content_digest" => prior["content_digest"]
        }
      end
      rehash(checkpoint)
    end
    bundle["control_registries"].each do |registry|
      registry["owned_task_refs"] = [task_ref]
      genesis = bundle["lead_checkpoints"].find { |checkpoint| checkpoint["lead_checkpoint_id"] == registry.dig("genesis_checkpoint_ref", "lead_checkpoint_id") }
      if genesis
        registry["genesis_checkpoint_ref"] = {
          "lead_checkpoint_id" => genesis["lead_checkpoint_id"],
          "content_digest" => genesis["content_digest"]
        }
      end
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
    finding["blocking"] = false
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
    related["blocking"] = false
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
