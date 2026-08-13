# frozen_string_literal: true

require "openssl"

require_relative "../../../lib/orbit/v2/authority_verifier"
require_relative "../../../lib/orbit/v2/canonical_json"
require_relative "../../../lib/orbit/v2/control_authority"
require_relative "../../../lib/orbit/v2/evaluation_subject"
require_relative "../../../lib/orbit/v2/lifecycle_verifier"
require_relative "../../../lib/orbit/v2/policy_issuance"
require_relative "../../../lib/orbit/v2/rule_resolution"
require_relative "../../../lib/orbit/v2/runtime_identity_verifier"
require_relative "../../../lib/orbit/v2/schema_catalog"
require_relative "../../../lib/orbit/v2/work_authority"

module OrbitV2FixtureFactory
  module_function

  PROJECT_ID = "oproj_slice0fixture"
  POLICY_ID = "opolicy_genesis0001"
  TASK_ID = "otask_slice0contract"
  TASK_REVISION_ID = "trev_slice0contract_r1"
  GATE_ID = "ogreq_slice0review"
  GATE_LINEAGE_ID = "ogline_slice0review"
  FINDING_ID = "ofinding_slice0example"
  CONTROL_ID = "olcontrol_slice0main"
  DISPATCH_DECISION = { "state" => "blocked", "action" => "dispatch", "reason" => "dispatch authorized" }.freeze
  GENESIS_CHECKPOINT_ID = "olcheckpoint_genesis_slice0"
  SUCCESSOR_CHECKPOINT_ID = "olcheckpoint_slice0successor"
  ROOT = File.expand_path("../../..", __dir__)
  AUTHORITY_PROVIDER_ID = "fixture.user-authority"
  LIFECYCLE_PROVIDER_ID = "fixture.lifecycle-writer"
  RUNTIME_IDENTITY_PROVIDER_ID = "fixture.runtime-identity"
  DEFAULT_EVIDENCE_REQUIREMENTS = [
    {
      "evidence_requirement_id" => "evreq_contract_test",
      "text" => "Contract tests pass.",
      "verification_class" => "regression"
    }
  ].freeze
  DEFAULT_EVIDENCE_RESULTS = [
    { "evidence_requirement_id" => "evreq_contract_test", "verification_use" => "permanent_test_evidence" }
  ].freeze
  CLASSIFICATION_EVIDENCE_REQUIREMENTS = [
    {
      "evidence_requirement_id" => "evreq_contract_test",
      "text" => "Permanent regression contract tests pass.",
      "verification_class" => "regression"
    },
    {
      "evidence_requirement_id" => "evreq_release_audit",
      "text" => "The release audit records the reviewed change.",
      "verification_class" => "release_audit"
    },
    {
      "evidence_requirement_id" => "evreq_acceptance_proof",
      "text" => "The acceptance proof demonstrates the outcome.",
      "verification_class" => "acceptance_evidence"
    }
  ].freeze
  VERIFICATION_CLASS_USES = {
    "regression" => "permanent_test_evidence",
    "release_audit" => "audit_record_evidence",
    "acceptance_evidence" => "acceptance_proof_evidence"
  }.freeze

  class FakeAuthorityProvider
    SECRET = "orbit-v2-slice0-fixture-provider-secret"

    def issue(assertion, receipt_id:, issued_at: "2026-07-30T00:00:00Z")
      body = {
        "schema_version" => Orbit::V2::AuthorityVerifier::RECEIPT_SCHEMA,
        "provider_id" => assertion["provider_id"],
        "receipt_id" => receipt_id,
        "project_id" => assertion["project_id"],
        "assertion_id" => assertion["assertion_id"],
        "assertion_digest" => assertion["assertion_digest"],
        "issuer_kind" => assertion["issuer_kind"],
        "issuer_subject" => assertion["issuer_subject"],
        "authority_scope_ref" => assertion["authority_scope_ref"],
        "grants" => assertion["grants"],
        "issued_at" => issued_at
      }
      body.merge("receipt" => signature(body))
    end

    def verify(receipt:, assertion_digest:, project_id:, assertion_id:)
      return false unless receipt["assertion_digest"] == assertion_digest &&
                          receipt["project_id"] == project_id &&
                          receipt["assertion_id"] == assertion_id

      actual = receipt["receipt"].to_s
      expected = signature(receipt.reject { |key, _value| key == "receipt" })
      secure_equal?(actual, expected)
    end

    private

    def signature(body)
      "hmac-sha256:#{OpenSSL::HMAC.hexdigest("SHA256", SECRET, Orbit::V2::CanonicalJSON.dump(body))}"
    end

    def secure_equal?(left, right)
      return false unless left.bytesize == right.bytesize

      left.bytes.zip(right.bytes).reduce(0) { |difference, (a, b)| difference | (a ^ b) }.zero?
    end
  end

  class FakeLifecycleProvider
    SECRET = "orbit-v2-slice0-fixture-lifecycle-secret"

    def issue(event, project_id:)
      body = {
        "schema_version" => Orbit::V2::LifecycleVerifier::RECEIPT_SCHEMA,
        "provider_id" => LIFECYCLE_PROVIDER_ID,
        "receipt_id" => "olreceipt_#{event.fetch("event_id").delete_prefix("oevent_")}",
        "project_id" => project_id,
        "event_id" => event.fetch("event_id"),
        "event_type" => event.fetch("event_type"),
        "event_digest" => event.fetch("event_digest"),
        "recorded_at" => event.fetch("recorded_at")
      }
      body.merge("receipt" => signature(body))
    end

    def verify(receipt:, event_digest:, project_id:, event_id:, recorded_at:)
      return false unless receipt["event_digest"] == event_digest &&
                          receipt["project_id"] == project_id &&
                          receipt["event_id"] == event_id &&
                          receipt["recorded_at"] == recorded_at

      actual = receipt["receipt"].to_s
      expected = signature(receipt.reject { |key, _value| key == "receipt" })
      secure_equal?(actual, expected)
    end

    private

    def signature(body)
      "hmac-sha256:#{OpenSSL::HMAC.hexdigest("SHA256", SECRET, Orbit::V2::CanonicalJSON.dump(body))}"
    end

    def secure_equal?(left, right)
      return false unless left.bytesize == right.bytesize

      left.bytes.zip(right.bytes).reduce(0) { |difference, (a, b)| difference | (a ^ b) }.zero?
    end
  end

  class FakeRuntimeIdentityProvider
    SECRET = "orbit-v2-slice0-fixture-runtime-identity-secret"

    def issue(provider_id:, project_id:, agent_instance_id:, runtime_subject_id:)
      signature(
        "provider_id" => provider_id,
        "project_id" => project_id,
        "agent_instance_id" => agent_instance_id,
        "runtime_subject_id" => runtime_subject_id
      )
    end

    def verify(
      verification_receipt_ref:,
      provider_id:,
      project_id:,
      agent_instance_id:,
      runtime_subject_id:
    )
      expected = issue(
        provider_id: provider_id,
        project_id: project_id,
        agent_instance_id: agent_instance_id,
        runtime_subject_id: runtime_subject_id
      )
      secure_equal?(verification_receipt_ref.to_s, expected)
    end

    private

    def signature(body)
      "hmac-sha256:#{OpenSSL::HMAC.hexdigest(
        "SHA256",
        SECRET,
        Orbit::V2::CanonicalJSON.dump(body)
      )}"
    end

    def secure_equal?(left, right)
      return false unless left.bytesize == right.bytesize

      left.bytes.zip(right.bytes).reduce(0) do |difference, (a, b)|
        difference | (a ^ b)
      end.zero?
    end
  end

  FAKE_AUTHORITY_PROVIDER = FakeAuthorityProvider.new
  FAKE_LIFECYCLE_PROVIDER = FakeLifecycleProvider.new
  FAKE_RUNTIME_IDENTITY_PROVIDER = FakeRuntimeIdentityProvider.new

  def authority_verifier
    Orbit::V2::AuthorityVerifier.new(
      providers: { AUTHORITY_PROVIDER_ID => FAKE_AUTHORITY_PROVIDER }
    )
  end

  def lifecycle_verifier
    Orbit::V2::LifecycleVerifier.new(
      providers: { LIFECYCLE_PROVIDER_ID => FAKE_LIFECYCLE_PROVIDER }
    )
  end
  def runtime_identity_verifier
    Orbit::V2::RuntimeIdentityVerifier.new(
      providers: {
        RUNTIME_IDENTITY_PROVIDER_ID => FAKE_RUNTIME_IDENTITY_PROVIDER
      }
    )
  end

  def valid_bundle(evidence_requirements: DEFAULT_EVIDENCE_REQUIREMENTS)
    policy_assertion_id = "oassert_policygenesis"
    policy_assertion_digest = policy_issuance_assertion_digest(
      assertion_id: policy_assertion_id,
      required_grant: "policy.genesis",
      subject: "project-owner",
      issued_at: "2026-07-30T00:00:00Z"
    )
    policy = digested(
      "schema_version" => "orbit-project-policy-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "policy_revision_id" => POLICY_ID,
      "parent_policy_revision_id" => nil,
      "authorization_source_ref" => policy_assertion_id,
      "authorization_assertion_digest" => policy_assertion_digest,
      "protected_gate_minimums" => [
        {
          "gate_kind" => "review",
          "evidence_level" => "outcome_quality",
          "independence" => "independent_evaluator"
        }
      ],
      "finding_disposition" => {
        "contract_violation" => "blocking",
        "regression" => "blocking",
        "newly_discovered_risk" => "adjudication_required",
        "hardening_opportunity" => "nonblocking"
      },
      "authority_grants" => [
        {
          "action" => "finding.waive",
          "required_external_grant" => "finding.waive"
        },
        {
          "action" => "task.protected_contract.change",
          "required_external_grant" => "task.protected_contract.change"
        },
        {
          "action" => "policy.rotate",
          "required_external_grant" => "policy.rotate"
        },
        {
          "action" => "task.risk_authority.delegate",
          "required_external_grant" => "task.risk_authority.delegate"
        },
        {
          "action" => "work.implement",
          "required_external_grant" => "work.implement"
        },
        {
          "action" => "gate.review.evaluate",
          "required_external_grant" => "gate.review.evaluate"
        },
        {
          "action" => "control.genesis",
          "required_external_grant" => "control.genesis"
        },
        {
          "action" => "control.checkpoint",
          "required_external_grant" => "control.checkpoint"
        },
        {
          "action" => "task.retry.override",
          "required_external_grant" => "task.retry.override"
        },
        {
          "action" => "test.budget.override",
          "required_external_grant" => "test.budget.override"
        },
        {
          "action" => "control.fallback.authorize",
          "required_external_grant" => "control.fallback.authorize"
        },
        {
          "action" => "control.checkpoint_due.observe",
          "required_external_grant" => "control.checkpoint_due.observe"
        },
        {
          "action" => "test.measurement.attest",
          "required_external_grant" => "test.measurement.attest"
        }
      ],
      "orchestration_policy" => {
        "wall_clock_fallback" => {
          "interval_seconds" => 3600,
          "upper_bound_seconds" => 86400
        },
        "test_budget" => {
          "work_unit_lineage" => {
            "default_test_count" => 10,
            "default_test_code_lines" => 300,
            "lead_ceiling_test_count" => 20,
            "lead_ceiling_test_code_lines" => 600
          },
          "task_lineage" => {
            "default_test_count" => 30,
            "default_test_code_lines" => 900,
            "lead_ceiling_test_count" => 60,
            "lead_ceiling_test_code_lines" => 1800
          }
        }
      }
    )
    assertions = [
      policy_issuance_assertion(
        policy,
        parent_policy: nil,
        assertion_id: policy_assertion_id,
        subject: "project-owner"
      ),
      assertion(
        "oassert_findingwaiver",
        %w[finding.waive],
        "risk-owner"
      ),
      assertion(
        "oassert_controlwriter",
        %w[control.genesis control.checkpoint],
        "control-plane-writer",
        authority_scope_ref: CONTROL_ID
      )
    ]
    waiver = digested(
      "schema_version" => "orbit-authorization-record-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "authorization_record_id" => "oauthz_findingwaiver",
      "project_policy_revision_id" => POLICY_ID,
      "action" => "finding.waive",
      "subject_ref" => FINDING_ID,
      "authorization_source_ref" => assertions[1]["assertion_id"],
      "authorization_assertion_digest" => assertions[1]["assertion_digest"]
    )

    task = digested(
      "schema_version" => "orbit-task-v2",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "task_id" => TASK_ID,
      "task_revision_id" => TASK_REVISION_ID,
      "revision_number" => 1,
      "parent_task_revision_id" => nil,
      "project_policy_revision_ref" => ref("policy_revision_id", POLICY_ID, policy["content_digest"]),
      "goal" => "Freeze an isolated and reviewable Orbit v2 contract.",
      "non_goals" => [
        "Do not activate Orbit v2 runtime commands."
      ],
      "quality_outcome" => {
        "user_problem" => "Later slices need one fail-closed contract foundation.",
        "desired_property" => "Invalid authority and stale evaluation are rejected.",
        "measurable_thresholds" => ["Every frozen authority object validates."],
        "invalid_completions" => ["An agent-authored bootstrap assertion is accepted."]
      },
      "acceptance" => [
        { "acceptance_id" => "acc_contract_valid", "text" => "The contract bundle validates." }
      ],
      "source_requirements" => [
        { "source_requirement_id" => "src_adr_contract", "text" => "ADR contract is preserved." }
      ],
      "evidence_requirements" => deep_copy(evidence_requirements),
      "task_questions" => [
        { "question_id" => "question_contract_quality", "text" => "Does the contract prevent stale approval?" }
      ],
      "gate_requirement_refs" => [GATE_ID],
      "authority_grant_refs" => [],
      "protected_change_authorization_ref" => nil,
      "unresolved_finding_refs" => [FINDING_ID]
    )
    gate = digested(
      "schema_version" => "orbit-gate-requirement-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "gate_requirement_id" => GATE_ID,
      "gate_lineage_id" => GATE_LINEAGE_ID,
      "parent_gate_requirement_ref" => nil,
      "task_id" => TASK_ID,
      "task_revision_id" => TASK_REVISION_ID,
      "kind" => "review",
      "protected" => true,
      "evidence_level" => "outcome_quality",
      "independence" => "independent_evaluator",
      "acceptance_refs" => ["acc_contract_valid"],
      "required_question_refs" => ["question_contract_quality"],
      "subject_selector" => {
        "scope" => "task_wide",
        "work_unit_kind" => "implementation",
        "work_unit_refs" => [],
        "implementation_attempt_policy" => "all_accepted_contributors_to_snapshot",
        "evidence_record_policy" => "all_accepted_required_evidence_for_selected_attempts",
        "freshness" => "exact_current_subject"
      },
      "waiver_policy" => {
        "mode" => "finding_resolution_only",
        "required_authorization_action" => "finding.waive",
        "risk_authority_source" => "project_policy_or_task_authorization"
      }
    )

    requirement_refs = evidence_requirements.map do |requirement|
      requirement["evidence_requirement_id"]
    end.sort
    units, theses = make_units_and_theses(evidence_requirement_refs: requirement_refs)
    work_authorizations = units.flat_map do |unit|
      Array(unit.dig("authority_scope", "allowed_actions")).map do |action|
        work_authorization(unit, task, action)
      end
    end
    assertions.concat(work_authorizations.map { |authorization| authorization.fetch("assertion") })
    agents = [
      agent("oagent_logicalleadmain", "lead"),
      agent("oagent_implementerone", "coder"),
      agent("oagent_implementertwo", "coder"),
      agent("oagent_independentreviewer", "reviewer")
    ]
    logical_leads = [
      digested(
        "schema_version" => "orbit-agent-runtime-v1",
        "protocol_epoch" => "orbit-v2",
        "project_id" => PROJECT_ID,
        "object_type" => "logical_lead",
        "logical_lead_id" => "olead_slice0contract",
        "task_id" => TASK_ID,
        "authority_scope_ref" => POLICY_ID,
        "durable_context_ref" => "artifact://slice0/durable-lead-context"
      )
    ]
    old_session = lead_session(logical_leads.first, agents.first)
    old_session["lifecycle_events"] << event("oevent_oldsessionended", "LeadSessionEnded",
      old_session.dig("lifecycle_events", 0, "event_digest"),
      "ended_at" => "2026-07-30T00:05:00Z", "status" => "completed", "reason" => "Replaced by successor.")
    agents.first["lifecycle_events"] << event("oevent_leadcontextadvanced", "AgentContextAdvanced",
      agents.first.dig("lifecycle_events", 0, "event_digest"),
      "context_generation" => 2, "recorded_at" => "2026-07-30T00:05:30Z", "reason" => "Successor session context.")
    successor_session = deep_copy(old_session)
    successor_session["lead_session_id"] = "oleadsession_successor"
    successor_session["session_generation"] = 2
    successor_session["lifecycle_events"] = [event("oevent_successorsessionstarted", "LeadSessionStarted", nil,
      "role" => "lead", "context_generation" => 2, "started_at" => "2026-07-30T00:06:00Z", "status" => "active")]
    successor_session["predecessor_lead_session_ref"] = {
      "lead_session_id" => old_session["lead_session_id"], "session_generation" => 1,
      "event_id" => old_session.dig("lifecycle_events", 1, "event_id"),
      "event_digest" => old_session.dig("lifecycle_events", 1, "event_digest")
    }
    lead_sessions = [old_session, successor_session]
    writer_assertion = assertions[2]
    genesis_checkpoint = lead_checkpoint(
      GENESIS_CHECKPOINT_ID,
      is_genesis: true,
      predecessor_ref: nil,
      policy: policy,
      session: old_session,
      agent: agents.first,
      logical_lead: logical_leads.first,
      task: task,
      writer_action: "control.genesis",
      writer_assertion: writer_assertion
    )
    attempts = []
    resolutions = []
    attempt_specs = [
      ["oattempt_implementationone", "owu_implementationone", "oagent_implementerone", "coder", "implementation", nil, "2026-07-30T00:01:00Z", "2026-07-30T00:01:30Z"],
      ["oattempt_implementationonesuccessor", "owu_implementationone", "oagent_implementerone", "coder", "implementation", "oattempt_implementationone", "2026-07-30T00:01:45Z", "2026-07-30T00:01:50Z"],
      ["oattempt_implementationtwo", "owu_implementationtwo", "oagent_implementertwo", "coder", "implementation", nil, "2026-07-30T00:02:00Z", "2026-07-30T00:02:30Z"],
      ["oattempt_independentreview", "owu_independentreview", "oagent_independentreviewer", "reviewer", "review", nil, "2026-07-30T00:03:00Z", nil]
    ]
    attempt_specs.each_with_index do |(attempt_id, unit_id, agent_id, role, purpose, predecessor_ref, started_at, terminal_ended_at), index|
      thesis = theses.find { |candidate| candidate["work_unit_id"] == unit_id }
      assigned_unit = units.find { |candidate| candidate["work_unit_id"] == unit_id }
      identity = {
        "identity_schema" => "orbit-rule-resolution-identity-v1",
        "protocol_epoch" => "orbit-v2",
        "project_id" => PROJECT_ID,
        "task_id" => TASK_ID,
        "task_revision_id" => TASK_REVISION_ID,
        "work_unit_id" => unit_id,
        "attempt_id" => attempt_id,
        "resolved_role" => role,
        "agent_instance_id" => agent_id,
        "context_generation" => 1,
        "required_rules" => [
          {
            "rule_id" => "rule_#{role}_contract",
            "path" => rule_path(role),
            "content_sha256" => rule_digest(role),
            "relation" => "baseline"
          }
        ]
      }
      resolution = Orbit::V2::RuleResolution.build(
        identity,
        created_at: "2026-07-30T00:00:0#{index}Z",
        project_root: ROOT
      )
      resolutions << resolution
      created_attempt = attempt(
        attempt_id,
        unit_id,
        agent_id,
        role,
        purpose,
        thesis,
        resolution["resolution_id"],
        index,
        policy["content_digest"],
        authorization_record_refs:
          assigned_unit.dig("authority_scope", "authorization_record_refs"),
        predecessor_work_unit_attempt_ref: predecessor_ref,
        dispatch_lead_checkpoint_ref: nil,
        started_at: started_at
      )
      if terminal_ended_at
        created_attempt["events"] << event(
          "oevent_#{attempt_id.delete_prefix("oattempt_")}_completed",
          "AttemptCompleted",
          created_attempt.dig("events", 0, "event_digest"),
          "ended_at" => terminal_ended_at,
          "status" => "completed"
        )
      end
      attempts << created_attempt
    end

    dispatch_checkpoints = []
    predecessor_checkpoint = genesis_checkpoint
    # One dispatch checkpoint per attempt; later ones pin the previous terminal.
    attempts.each_with_index do |created_attempt, index|
      previous = index.zero? ? nil : attempts[index - 1]
      unit = units.find { |candidate| candidate["work_unit_id"] == created_attempt["work_unit_id"] }
      attempt_ref = previous && attempt_event_ref(attempts, previous["attempt_id"])
      cp_id = index.zero? ? "olcheckpoint_dispatch_implone" : "olcheckpoint_terminal_impl#{previous["attempt_id"].delete_prefix("oattempt_implementation")}"
      proposed_thesis = theses.find { |candidate| candidate["work_unit_id"] == unit["work_unit_id"] }
      checkpoint = lead_checkpoint(
        cp_id,
        is_genesis: false,
        predecessor_ref: cp_ref(predecessor_checkpoint),
        policy: policy,
        session: old_session,
        agent: agents.first,
        logical_lead: logical_leads.first,
        task: task,
        writer_action: "control.checkpoint",
        writer_assertion: writer_assertion,
        active_task_ref: task_ref(task),
        selected_work_unit_ref: work_unit_ref(unit),
        attempt_ref: attempt_ref,
        unit: unit,
        predecessor_checkpoint: predecessor_checkpoint,
        proposed_thesis_ref: {
          "change_thesis_id" => proposed_thesis["change_thesis_id"],
          "content_digest" => proposed_thesis["content_digest"]
        },
        proposed_rule_ref: pinned_rule_ref(created_attempt, resolutions[index]),
        delivery: checkpoint_progress(previous ? "changed" : "not_assessed", measured: previous && attempt_ref),
        assurance: checkpoint_progress(previous ? "changed" : "not_assessed", measured: previous && attempt_ref),
        decision: DISPATCH_DECISION,
        reconcile_trigger: attempt_ref && { "event" => "attempt_terminal", "reason" => "Terminal observation authorizes the successor dispatch." }
      )
      dispatch_checkpoints << checkpoint
      created_attempt["dispatch_lead_checkpoint_ref"] = cp_ref(checkpoint)
      # The immediate successor observes the exact AttemptCreated event.
      last = index == attempts.length - 1
      dispatch_checkpoints << observation_checkpoint(checkpoint, created_attempt,
        session: last ? successor_session : nil, cp_id: last ? SUCCESSOR_CHECKPOINT_ID : nil,
        policy: policy, resolution: resolutions[index])
      predecessor_checkpoint = dispatch_checkpoints.last
    end
    control_registries = [control_registry(policy: policy, genesis_checkpoint: genesis_checkpoint, task: task,
      writer_assertion: writer_assertion)]
    all_checkpoints = [genesis_checkpoint, *dispatch_checkpoints]

    requirement_results = evidence_requirements.map do |requirement|
      {
        "evidence_requirement_id" => requirement["evidence_requirement_id"],
        "verification_use" => VERIFICATION_CLASS_USES.fetch(requirement["verification_class"])
      }
    end
    evidence = [
      implementation_evidence(
        "oevr_implementationone",
        attempts[0],
        resolutions[0],
        units[0]["initial_change_thesis_ref"],
        ["lib/orbit/v2/validator.rb"],
        evidence_results: requirement_results
      ),
      implementation_evidence(
        "oevr_implementationtwo",
        attempts[2],
        resolutions[2],
        units[1]["initial_change_thesis_ref"],
        ["contracts/orbit-v2/contract.yaml"]
      ),
      evaluator_submission(
        "oevr_independentreview",
        attempts[3],
        resolutions[3],
        acceptance_recorded_at: "2026-07-30T00:03:30Z"
      )
    ]
    snapshot = {
      "kind" => "git",
      "commit_sha" => "a" * 40,
      "tree_digest" => digest_for("repository-tree")
    }
    code_surface_paths = ["contracts/orbit-v2", "lib/orbit/v2"]
    code_surface = {
      "kind" => "derived_code_surface",
      "derivation_version" => "orbit-code-surface-v1",
      "repository_tree_digest" => snapshot["tree_digest"],
      "code_surface_digest" => Orbit::V2::EvaluationSubject.code_surface_digest(
        derivation_version: "orbit-code-surface-v1",
        repository_tree_digest: snapshot["tree_digest"],
        paths: code_surface_paths
      ),
      "paths" => code_surface_paths
    }
    subject = Orbit::V2::EvaluationSubject.select(
      gate_requirement: gate,
      task_revision: task,
      work_units: units,
      attempts: attempts,
      evidence_records: evidence,
      repository_snapshot: snapshot,
      code_surface: code_surface
    )
    evaluation = digested(
      "schema_version" => "orbit-gate-evaluation-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "gate_evaluation_id" => "ogeval_slice0review",
      "gate_requirement_id" => GATE_ID,
      "gate_requirement_content_digest" => gate["content_digest"],
      "evaluator_attempt_id" => attempts[3]["attempt_id"],
      "evaluator_submission_record_id" => evidence[2]["evidence_record_id"],
      "subject" => subject,
      "verdict" => "fail",
      "quality_outcome_verdict" => "fail",
      "quality_question_answers" => [
        {
          "question_id" => "question_contract_quality",
          "verdict" => "pass",
          "evidence_record_refs" => evidence.first(2).map { |record| record["evidence_record_id"] }
        }
      ],
      "acceptance_results" => [
        {
          "acceptance_id" => "acc_contract_valid",
          "verdict" => "fail",
          "evidence_record_refs" => evidence.first(2).map { |record| record["evidence_record_id"] }
        }
      ],
      "counterexample_cases" => ["A malformed bundle bypasses the contract."],
      "confirmed" => ["The selected subject is complete."],
      "assumed" => [],
      "missing" => [],
      "coverage" => {
        "summary" => "All implementation WorkUnits and evidence records were evaluated.",
        "covered_work_unit_refs" => units.first(2).map { |unit| unit["work_unit_id"] },
        "uncovered_work_unit_refs" => [],
        "evidence_record_refs" => evidence.first(2).map { |record| record["evidence_record_id"] }
      },
      "residual_risk" => "The example finding remains blocking until resolved.",
      "finding_refs" => [FINDING_ID],
      "supersedes_gate_evaluation_id" => nil
    )
    finding = digested(
      "schema_version" => "orbit-finding-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "finding_id" => FINDING_ID,
      "gate_evaluation_id" => evaluation["gate_evaluation_id"],
      "severity" => "P1",
      "basis" => "contract_violation",
      "body" => "Example unresolved contract concern.",
      "source_evidence_record_refs" => [
        evidence[0]["evidence_record_id"],
        evidence[2]["evidence_record_id"]
      ],
      "supersedes_finding_id" => nil
    )
    resolution = digested(
      "schema_version" => "orbit-finding-resolution-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "finding_resolution_id" => "ofres_slice0examplewaiver",
      "finding_id" => FINDING_ID,
      "resolution" => "waived",
      "authorization_record_ref" => waiver["authorization_record_id"],
      "supporting_record_refs" => [],
      "supersedes_finding_resolution_id" => nil
    )
    root = digested(
      "schema_version" => "orbit-protocol-root-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "project_policy_genesis_ref" => ref(
        "policy_revision_id",
        POLICY_ID,
        policy["content_digest"]
      )
    )

    {
      "schema_version" => "orbit-v2-contract-bundle-v1",
      "protocol_epoch" => "orbit-v2",
      "protocol_root" => root,
      "authority_assertions" => assertions,
      "authorization_records" => [
        waiver,
        *work_authorizations.map { |authorization| authorization.fetch("record") }
      ],
      "project_policy_revisions" => [policy],
      "task_revisions" => [task],
      "gate_requirements" => [gate],
      "work_units" => units,
      "change_theses" => theses,
      "agent_instances" => agents,
      "logical_leads" => logical_leads,
      "lead_sessions" => lead_sessions,
      "control_registries" => control_registries,
      "lead_checkpoints" => all_checkpoints,
      "work_unit_attempts" => attempts,
      "rule_resolution_artifacts" => resolutions,
      "evidence_records" => evidence,
      "gate_evaluations" => [evaluation],
      "findings" => [finding],
      "finding_resolutions" => [resolution],
      "repository_snapshot" => snapshot,
      "code_surface" => code_surface
    }
  end
  # Slice 4 increment 1: append a finding_change observation checkpoint that
  # introduces the given Finding (already appended to the bundle and reported
  # by its GateEvaluation). The stored decision is deterministic-replay
  # checked: needs_user/escalate for an unadjudicated newly_discovered_risk,
  # blocked/continue otherwise. Digests are resealed against the current tip.
  def append_observation_checkpoint(bundle, suffix, supporting_refs, reconcile:, next_event:, decision:, reason:, preserve_attempt: false)
    tip = bundle["lead_checkpoints"].last
    policy = bundle["project_policy_revisions"].last
    checkpoint = deep_copy(tip)
    checkpoint["lead_checkpoint_id"] = "olcheckpoint_#{suffix}"
    checkpoint["predecessor_lead_checkpoint_ref"] = cp_ref(tip)
    checkpoint["current_or_terminal_attempt_ref"] = nil unless preserve_attempt
    checkpoint["assessments"] = checkpoint_assessments(
      checkpoint["active_task_ref"], checkpoint["selected_work_unit_ref"],
      preserve_attempt ? checkpoint["current_or_terminal_attempt_ref"] : nil
    )
    %w[delivery_progress assurance_progress].each do |field|
      checkpoint[field] = checkpoint_progress("not_assessed").merge(
        "predecessor_lead_checkpoint_ref" => checkpoint["predecessor_lead_checkpoint_ref"],
        "supporting_refs" => deep_copy(supporting_refs)
      )
    end
    checkpoint["reconcile_trigger"] = { "event" => reconcile, "reason" => reason }
    checkpoint["next_trigger"] = {
      "event" => next_event,
      "reason" => next_event == "authority_change" ? "Awaiting risk-owner/user adjudication." : "Awaiting the successor boundary."
    }
    checkpoint["lead_decision"] = deep_copy(decision)
    bundle["lead_checkpoints"] <<
      reseal_checkpoint(checkpoint, policy: policy, predecessor_checkpoint: tip)
    bundle
  end

  # Slice 4 increment 1: introduce a Finding through an exact finding_change
  # observation; may exact-pin the adjudicating FindingResolution. The stored
  # decision is deterministic-replay checked.
  def append_finding_change_checkpoint(bundle, finding, decision, resolution: nil, preserve_attempt: false)
    refs = [
      { "kind" => "finding", "id" => finding["finding_id"], "digest" => finding["content_digest"] }
    ]
    if resolution
      refs << {
        "kind" => "finding_resolution",
        "id" => resolution["finding_resolution_id"],
        "digest" => resolution["content_digest"]
      }
    end
    append_observation_checkpoint(
      bundle,
      "findingchange_#{finding["finding_id"].delete_prefix("ofinding_")}",
      refs,
      reconcile: "finding_change",
      next_event: decision["action"] == "escalate" ? "authority_change" : "successor_before",
      decision: decision,
      reason: "A new Finding was recorded.",
      preserve_attempt: preserve_attempt
    )
  end

  # A needs_user risk stop resumes only when a successor authority_change
  # checkpoint exact-pins the authorized FindingResolution ref.
  def append_authority_change_resume_checkpoint(bundle, resolution)
    append_observation_checkpoint(
      bundle,
      "authoritychange_#{resolution["finding_resolution_id"].delete_prefix("ofres_")}",
      [{
        "kind" => "finding_resolution",
        "id" => resolution["finding_resolution_id"],
        "digest" => resolution["content_digest"]
      }],
      reconcile: "authority_change",
      next_event: "successor_before",
      decision: {
        "state" => "blocked",
        "action" => "continue",
        "reason" => "authoritative change observed"
      },
      reason: "The authorized FindingResolution adjudicated the escalated risk."
    )
  end
  # Slice 3 increment 1 scenario: one implementation record closes all three
  # verification classes through separate paired evidence requirement results.
  def evidence_classification_bundle
    valid_bundle(evidence_requirements: CLASSIFICATION_EVIDENCE_REQUIREMENTS)
  end

  # Increment 3 helpers: a second open control lineage cloned from the base
  # fixture objects with fresh IDs, and the minimal release/acquire transfer
  # bundle (the base lineage is stripped to the authority/task substrate; the
  # transfer ends at the accepted acquire).
  TRANSFER_CONTROL_ID = "olcontrol_slice0transfertarget"

  def extra_task(bundle, task_id:, revision_id:, gate_id:, gate_lineage_id:)
    gate = deep_copy(bundle["gate_requirements"].first)
    gate["gate_requirement_id"] = gate_id
    gate["gate_lineage_id"] = gate_lineage_id
    gate["task_id"] = task_id
    gate["task_revision_id"] = revision_id
    gate["parent_gate_requirement_ref"] = nil
    gate = digested(gate)
    bundle["gate_requirements"] << gate
    task = deep_copy(bundle["task_revisions"].first)
    task["task_id"] = task_id
    task["task_revision_id"] = revision_id
    task["gate_requirement_refs"] = [gate_id]
    task["authority_grant_refs"] = []
    task["unresolved_finding_refs"] = []
    task["protected_change_authorization_ref"] = nil
    task = digested(task)
    bundle["task_revisions"] << task
    { "task" => task, "gate" => gate }
  end

  def second_lineage(
    bundle,
    control_id:,
    writer_assertion:,
    agent:,
    task:,
    logical_lead_id:,
    session_id:,
    queue: nil,
    predecessor_session_ref: nil,
    started_at: "2026-07-30T00:00:00Z"
  )
    policy = bundle["project_policy_revisions"].first
    lead = deep_copy(bundle["logical_leads"].first)
    lead["logical_lead_id"] = logical_lead_id
    lead["task_id"] = task["task_id"]
    lead = digested(lead)
    session = lead_session(lead, agent)
    session["lead_session_id"] = session_id
    session["lead_control_id"] = control_id
    session["task_id"] = task["task_id"]
    session["task_revision_id"] = task["task_revision_id"]
    session["predecessor_lead_session_ref"] = predecessor_session_ref
    session["lifecycle_events"] = [
      event(
        "oevent_#{session_id.delete_prefix("oleadsession_")}_started",
        "LeadSessionStarted",
        nil,
        "role" => "lead",
        "context_generation" => 1,
        "started_at" => started_at,
        "status" => "active"
      )
    ]
    genesis = lead_checkpoint(
      "olcheckpoint_genesis_#{control_id.delete_prefix("olcontrol_")}",
      is_genesis: true,
      predecessor_ref: nil,
      policy: policy,
      session: session,
      agent: agent,
      logical_lead: lead,
      task: task,
      lead_control_id: control_id,
      task_queue: queue,
      writer_action: "control.genesis",
      writer_assertion: writer_assertion
    )
    registry = control_registry(
      policy: policy,
      genesis_checkpoint: genesis,
      task: task,
      writer_assertion: writer_assertion
    )
    registry["lead_control_id"] = control_id
    registry["owned_task_refs"] = queue if queue
    bundle["logical_leads"] << lead
    bundle["lead_sessions"] << session
    bundle["control_registries"] << digested(registry)
    bundle["lead_checkpoints"] << genesis
    { "lead" => lead, "session" => session, "genesis" => genesis }
  end

  # One minimal transfer fixture for every transfer mutation: control A owns
  # [main, kept] from genesis and releases the main task; control B owns
  # [target] and acquires the main task with exact provenance. The base
  # fixture's lineage, attempts, and graphs are stripped; the transfer stops
  # at the accepted acquire.
  # One transfer fixture for every transfer mutation: control A (the base
  # lineage) claims [main, kept] from genesis, works the main task to a
  # terminal round, then releases it; control B owns [target], acquires the
  # main task with exact provenance, and continues its work through a
  # cross-control successor Attempt (the Inc3 same-control-successor
  # exception). terminalize_review: false leaves the review Attempt open so
  # the release carries a non-terminal Attempt.
  def transfer_bundle(terminalize_review: true)
    bundle = valid_bundle
    policy = bundle["project_policy_revisions"].first
    writer_a = bundle["authority_assertions"].find do |candidate|
      candidate["assertion_id"] == "oassert_controlwriter"
    end
    writer_b = assertion(
      "oassert_controlwriter_b",
      %w[control.genesis control.checkpoint],
      "control-plane-writer",
      authority_scope_ref: TRANSFER_CONTROL_ID
    )
    bundle["authority_assertions"] << writer_b
    kept = extra_task(
      bundle,
      task_id: "otask_slice0transferkeep",
      revision_id: "trev_slice0transferkeep_r1",
      gate_id: "ogreq_slice0transferkeep",
      gate_lineage_id: "ogline_slice0transferkeep"
    )
    target = extra_task(
      bundle,
      task_id: "otask_slice0transfertarget",
      revision_id: "trev_slice0transfertarget_r1",
      gate_id: "ogreq_slice0transfertarget",
      gate_lineage_id: "ogline_slice0transfertarget"
    )
    main_task = bundle["task_revisions"].first
    main_unit = bundle["work_units"].find do |candidate|
      candidate["work_unit_id"] == "owu_implementationone"
    end
    if terminalize_review
      review = bundle["work_unit_attempts"].find { |c| c["attempt_id"] == "oattempt_independentreview" }
      review["events"] << event(
        "oevent_reviewtransferterminal",
        "AttemptCompleted",
        review.dig("events", 0, "event_digest"),
        "ended_at" => "2026-07-30T00:03:30Z",
        "status" => "completed"
      )
    end
    agent_b = agent("oagent_transferlead", "lead")
    bundle["agent_instances"] << agent_b

    # A claims [main, kept] from genesis; rebuild every A checkpoint queue
    # projection and every dependent digest/ref.
    queue = [task_ref(main_task), task_ref(kept["task"])]
    checkpoints = bundle["lead_checkpoints"]
    checkpoints.each { |checkpoint| checkpoint["task_queue"] = deep_copy(queue) }
    checkpoints.each_with_index do |checkpoint, index|
      if index.positive?
        checkpoint["predecessor_lead_checkpoint_ref"] = cp_ref(checkpoints[index - 1])
        %w[delivery_progress assurance_progress].each do |field|
          checkpoint[field]["predecessor_lead_checkpoint_ref"] =
            checkpoint["predecessor_lead_checkpoint_ref"]
        end
      end
      checkpoints[index] = digested(checkpoint)
    end
    registry_a = bundle["control_registries"].find { |r| r["lead_control_id"] == CONTROL_ID }
    registry_a["owned_task_refs"] = deep_copy(queue)
    registry_a["genesis_checkpoint_ref"] = cp_ref(checkpoints.first)
    bundle["control_registries"][bundle["control_registries"].index(registry_a)] = digested(registry_a)
    bundle["work_unit_attempts"].each do |attempt|
      ref = attempt["dispatch_lead_checkpoint_ref"]
      next unless ref.is_a?(Hash)

      dispatch = checkpoints.find { |c| c["lead_checkpoint_id"] == ref["lead_checkpoint_id"] }
      attempt["dispatch_lead_checkpoint_ref"] = cp_ref(dispatch) if dispatch
    end

    kept_lead = deep_copy(bundle["logical_leads"].first)
    kept_lead["logical_lead_id"] = "olead_slice0transferkeep"
    kept_lead["task_id"] = kept["task"]["task_id"]
    kept_lead = digested(kept_lead)
    bundle["logical_leads"] << kept_lead
    session_a = bundle["lead_sessions"].find { |s| s["lead_session_id"] == "oleadsession_successor" }
    release_a = lead_checkpoint(
      "olcheckpoint_transferrelease_a",
      is_genesis: false,
      predecessor_ref: cp_ref(checkpoints.last),
      predecessor_checkpoint: checkpoints.last,
      policy: policy,
      session: session_a,
      agent: bundle["agent_instances"].first,
      logical_lead: kept_lead,
      task: kept["task"],
      lead_control_id: CONTROL_ID,
      writer_action: "control.checkpoint",
      writer_assertion: writer_a,
      task_queue: [task_ref(kept["task"])],
      decision: { "state" => "blocked", "action" => "release", "reason" => "task ownership released" },
      reconcile_trigger: { "event" => "task_release", "reason" => "Relinquish the main task." },
      next_trigger: { "event" => "successor_before", "reason" => "Awaiting the next control event." }
    )
    bundle["lead_checkpoints"] << release_a

    lineage_b = second_lineage(
      bundle,
      control_id: TRANSFER_CONTROL_ID,
      writer_assertion: writer_b,
      agent: agent_b,
      task: target["task"],
      logical_lead_id: "olead_slice0transfertarget",
      session_id: "oleadsession_slice0transfertarget",
      started_at: "2026-07-30T00:10:00Z"
    )
    acquire_b = lead_checkpoint(
      "olcheckpoint_transferacquire_b",
      is_genesis: false,
      predecessor_ref: cp_ref(lineage_b["genesis"]),
      predecessor_checkpoint: lineage_b["genesis"],
      policy: policy,
      session: lineage_b["session"],
      agent: agent_b,
      logical_lead: lineage_b["lead"],
      task: main_task,
      lead_control_id: TRANSFER_CONTROL_ID,
      writer_action: "control.checkpoint",
      writer_assertion: writer_b,
      task_queue: [task_ref(target["task"]), task_ref(main_task)],
      task_transfer_acquire: {
        "released_checkpoint_ref" => cp_ref(release_a),
        "released_lead_control_id" => CONTROL_ID,
        "task_ref" => task_ref(main_task)
      },
      decision: { "state" => "blocked", "action" => "acquire", "reason" => "task ownership acquired" },
      reconcile_trigger: { "event" => "task_acquire", "reason" => "Acquire the main task from A." },
      next_trigger: { "event" => "dispatch_before", "reason" => "Awaiting dispatch." }
    )
    bundle["lead_checkpoints"] << acquire_b
    predecessor = bundle["work_unit_attempts"].find do |candidate|
      candidate["attempt_id"] == "oattempt_implementationonesuccessor"
    end
    thesis = bundle["change_theses"].find do |candidate|
      candidate["work_unit_id"] == main_unit["work_unit_id"]
    end
    base_rule = bundle["rule_resolution_artifacts"].find do |candidate|
      candidate.dig("identity", "attempt_id") == "oattempt_implementationonesuccessor"
    end
    identity = deep_copy(base_rule["identity"])
    identity["attempt_id"] = "oattempt_slice0transfersuccessor"
    rule = Orbit::V2::RuleResolution.build(
      identity,
      created_at: "2026-07-30T00:12:00Z",
      project_root: ROOT
    )
    bundle["rule_resolution_artifacts"] << rule
    dispatch_b = lead_checkpoint(
      "olcheckpoint_transferdispatch_b",
      is_genesis: false,
      predecessor_ref: cp_ref(acquire_b),
      predecessor_checkpoint: acquire_b,
      policy: policy,
      session: lineage_b["session"],
      agent: agent_b,
      logical_lead: lineage_b["lead"],
      task: main_task,
      lead_control_id: TRANSFER_CONTROL_ID,
      writer_action: "control.checkpoint",
      writer_assertion: writer_b,
      task_queue: [task_ref(target["task"]), task_ref(main_task)],
      active_task_ref: task_ref(main_task),
      selected_work_unit_ref: work_unit_ref(main_unit),
      proposed_thesis_ref: {
        "change_thesis_id" => thesis["change_thesis_id"],
        "content_digest" => thesis["content_digest"]
      },
      proposed_rule_ref: pinned_rule_ref(nil, rule),
      decision: DISPATCH_DECISION,
      reconcile_trigger: { "event" => "dispatch_before", "reason" => "Dispatch the transferred work unit." },
      next_trigger: { "event" => "attempt_created", "reason" => "Awaiting creation." }
    )
    bundle["lead_checkpoints"] << dispatch_b
    attempt_b = attempt(
      "oattempt_slice0transfersuccessor",
      main_unit["work_unit_id"],
      "oagent_implementerone",
      "coder",
      "implementation",
      thesis,
      rule["resolution_id"],
      9,
      policy["content_digest"],
      task_id: main_task["task_id"],
      task_revision_id: main_task["task_revision_id"],
      authorization_record_refs: main_unit.dig("authority_scope", "authorization_record_refs"),
      lead_control_id: TRANSFER_CONTROL_ID,
      predecessor_work_unit_attempt_ref: predecessor["attempt_id"],
      dispatch_lead_checkpoint_ref: cp_ref(dispatch_b),
      started_at: "2026-07-30T00:12:00Z"
    )
    bundle["work_unit_attempts"] << attempt_b
    bundle["lead_checkpoints"] << observation_checkpoint(
      dispatch_b,
      attempt_b,
      session: lineage_b["session"],
      cp_id: "olcheckpoint_transfercreated_b",
      policy: policy,
      resolution: rule
    )
    bundle
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def digested(document)
    document.merge("content_digest" => Orbit::V2::CanonicalJSON.content_digest(document))
  end

  def assertion(
    id,
    grants,
    subject,
    authority_scope_ref: nil,
    policy_issuance_envelope: nil,
    asserted_at: "2026-07-30T00:00:00Z"
  )
    document = {
      "schema_version" => "orbit-authority-assertion-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "assertion_id" => id,
      "issuer_kind" => "user",
      "issuer_subject" => subject,
      "provider_id" => AUTHORITY_PROVIDER_ID,
      "authority_scope_ref" => authority_scope_ref ||
        (grants.include?("policy.genesis") ? PROJECT_ID : POLICY_ID),
      "grants" => grants,
      "asserted_at" => asserted_at
    }
    document["policy_issuance_envelope"] = policy_issuance_envelope if policy_issuance_envelope
    document["assertion_digest"] = Orbit::V2::AuthorityVerifier.assertion_digest(document)
    document["verification_receipt"] = FAKE_AUTHORITY_PROVIDER.issue(
      document,
      receipt_id: receipt_id_for(id),
      issued_at: asserted_at
    )
    document
  end

  def policy_issuance_assertion(
    policy,
    parent_policy:,
    assertion_id:,
    subject:,
    issued_at: nil
  )
    receipt_id = receipt_id_for(assertion_id)
    issued_at ||= parent_policy ? "2026-07-30T07:00:00Z" : "2026-07-30T00:00:00Z"
    required_grant =
      if parent_policy
        matches = Array(parent_policy["authority_grants"]).select do |candidate|
          candidate["action"] == "policy.rotate"
        end
        matches.length == 1 ? matches.first["required_external_grant"] : "policy.rotate"
      else
        "policy.genesis"
      end
    assertion_digest = policy_issuance_assertion_digest(
      assertion_id: assertion_id,
      required_grant: required_grant,
      subject: subject,
      issued_at: issued_at
    )
    envelope = Orbit::V2::PolicyIssuance.build_envelope(
      candidate_policy: policy,
      parent_policy: parent_policy,
      assertion_id: assertion_id,
      assertion_digest: assertion_digest,
      provider_id: AUTHORITY_PROVIDER_ID,
      receipt_id: receipt_id,
      issued_at: issued_at
    )
    assertion(
      assertion_id,
      [required_grant],
      subject,
      authority_scope_ref: envelope["envelope_digest"],
      policy_issuance_envelope: envelope,
      asserted_at: issued_at
    )
  end

  def policy_issuance_assertion_digest(
    assertion_id:,
    required_grant:,
    subject:,
    issued_at:
  )
    Orbit::V2::AuthorityVerifier.assertion_digest(
      "schema_version" => "orbit-authority-assertion-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "assertion_id" => assertion_id,
      "issuer_kind" => "user",
      "issuer_subject" => subject,
      "provider_id" => AUTHORITY_PROVIDER_ID,
      "authority_scope_ref" => "policy-issuance-scope-pending",
      "grants" => [required_grant],
      "asserted_at" => issued_at
    )
  end

  def receipt_id_for(assertion_id)
    "oareceipt_#{assertion_id.delete_prefix("oassert_")}"
  end

  def make_units_and_theses(evidence_requirement_refs: ["evreq_contract_test"])
    specifications = [
      ["owu_implementationone", "othesis_implementationone", "implementation", "Implement validator contracts."],
      ["owu_implementationtwo", "othesis_implementationtwo", "implementation", "Implement schema contracts."],
      ["owu_independentreview", "othesis_independentreview", "evaluation", "Evaluate the selected subject."]
    ]
    theses = specifications.map do |unit_id, thesis_id, _kind, summary|
      digested(
        "schema_version" => "orbit-change-thesis-v1",
        "protocol_epoch" => "orbit-v2",
        "project_id" => PROJECT_ID,
        "change_thesis_id" => thesis_id,
        "revision" => 1,
        "task_id" => TASK_ID,
        "task_revision_id" => TASK_REVISION_ID,
        "work_unit_id" => unit_id,
        "observed_problem" => summary,
        "root_cause_status" => "confirmed",
        "system_property" => "The contract has one authoritative representation.",
        "smallest_sufficient_mechanism" => "Create one immutable contract object.",
        "expected_benefit" => "Ambiguous authority is rejected.",
        "introduced_cost" => "More explicit references.",
        "blast_radius" => ["contracts/orbit-v2"],
        "disconfirming_evidence" => ["A valid bypass fixture."]
      )
    end
    units = specifications.map do |unit_id, thesis_id, kind, summary|
      thesis = theses.find { |candidate| candidate["change_thesis_id"] == thesis_id }
      digested(
        "schema_version" => "orbit-work-unit-v1",
        "protocol_epoch" => "orbit-v2",
        "project_id" => PROJECT_ID,
        "work_unit_id" => unit_id,
        "task_id" => TASK_ID,
        "task_revision_id" => TASK_REVISION_ID,
        "work_unit_kind" => kind,
        "parent_work_unit_ref" =>
          (unit_id == "owu_implementationone" ? nil : "owu_implementationone"),
        "depends_on_work_unit_refs" => {
          "owu_implementationone" => [],
          "owu_implementationtwo" => ["owu_implementationone"]
        }.fetch(unit_id, ["owu_implementationone", "owu_implementationtwo"]),
        "objective" => summary,
        "scope" => summary,
          "authority_scope" => {
            "allowed_actions" => [
              kind == "evaluation" ? "gate.review.evaluate" : "work.implement"
            ],
            "forbidden_actions" => ["task.goal.write", "gate.waive"],
            "authorization_record_refs" => [],
            "writable_paths" =>
              if unit_id == "owu_implementationone"
                ["lib/orbit/v2"]
              elsif unit_id == "owu_implementationtwo"
                ["contracts/orbit-v2"]
              else
                []
              end
        },
        "input_refs" => ["task-revision://#{TASK_REVISION_ID}"],
        "output_refs" => ["work-unit-output://#{unit_id}"],
        "stop_conditions" => ["Stop when acceptance evidence is complete or authority is insufficient."],
        "acceptance_refs" => ["acc_contract_valid"],
        "evidence_requirement_refs" =>
          unit_id == "owu_implementationone" ? evidence_requirement_refs : ["evreq_contract_test"],
        "source_requirement_refs" => ["src_adr_contract"],
        "initial_change_thesis_ref" => ref(
          "change_thesis_id",
          thesis_id,
          thesis["content_digest"]
        ).merge("revision" => 1)
      )
    end
    [units, theses]
  end

  def work_authorization(unit, task, action)
    suffix = unit.fetch("work_unit_id").delete_prefix("owu_")
    action_token = action.delete(".")
    scope = Orbit::V2::WorkAuthority.scope_digest(unit, task, action)
    authority_assertion = assertion(
      "oassert_#{suffix}_#{action_token}",
      [action],
      "project-owner",
      authority_scope_ref: scope
    )
    record_id = "oauthz_#{suffix}_#{action_token}"
    record = digested(
      "schema_version" => "orbit-authorization-record-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => unit.fetch("project_id"),
      "authorization_record_id" => record_id,
      "project_policy_revision_id" =>
        task.dig("project_policy_revision_ref", "policy_revision_id"),
      "action" => action,
      "subject_ref" => scope,
      "authorization_source_ref" => authority_assertion.fetch("assertion_id"),
      "authorization_assertion_digest" =>
        authority_assertion.fetch("assertion_digest")
    )
    unit.dig("authority_scope", "authorization_record_refs") << record_id
    unit["content_digest"] = Orbit::V2::CanonicalJSON.content_digest(unit)
    { "assertion" => authority_assertion, "record" => record }
  end

  def agent(id, role)
    profiles = {
      "lead" => {
        "capability" => "task.orchestrate",
        "permission" => "task_revision.propose"
      },
      "coder" => {
        "capability" => "coder.execute",
        "permission" => "work_unit.write"
      },
      "reviewer" => {
        "capability" => "review.evaluate",
        "permission" => "gate.review.submit"
      },
      "tester" => {
        "capability" => "test.execute",
        "permission" => "gate.test.submit"
      },
      "adjudicator" => {
        "capability" => "adjudication.evaluate",
        "permission" => "finding.resolve"
      },
      "researcher" => {
        "capability" => "research.execute",
        "permission" => "work_unit.read"
      },
      "release" => {
        "capability" => "release.evaluate",
        "permission" => "gate.release.submit"
      }
    }
    profile = profiles.fetch(role)
    event = event(
      "oevent_#{id.delete_prefix("oagent_")}_created",
      "AgentCreated",
      nil,
      "role" => role,
      "context_generation" => 1,
      "started_at" => "2026-07-30T00:00:00Z",
      "status" => "active"
    )
    runtime_subject_id = "runtime-subject:#{id}"
    {
      "schema_version" => "orbit-agent-runtime-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "object_type" => "agent_instance",
      "agent_instance_id" => id,
      "runtime_identity" => {
        "provider_id" => RUNTIME_IDENTITY_PROVIDER_ID,
        "runtime_subject_id" => runtime_subject_id,
        "verification_receipt_ref" => FAKE_RUNTIME_IDENTITY_PROVIDER.issue(
          provider_id: RUNTIME_IDENTITY_PROVIDER_ID,
          project_id: PROJECT_ID,
          agent_instance_id: id,
          runtime_subject_id: runtime_subject_id
        )
      },
      "capability_profile" => {
        "profile_id" => "capability-profile:#{role}",
        "capabilities" => [profile.fetch("capability")]
      },
      "permission_profile" => {
        "profile_id" => "permission-profile:#{role}",
        "permissions" => [profile.fetch("permission")]
      },
      "lifecycle_events" => [event]
    }
  end

  def lead_session(logical_lead, agent)
    lifecycle = event(
      "oevent_slice0leadsessionstarted",
      "LeadSessionStarted",
      nil,
      "role" => "lead",
      "context_generation" => 1,
      "started_at" => "2026-07-30T00:00:00Z",
      "status" => "active"
    )
    {
      "schema_version" => "orbit-agent-runtime-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "object_type" => "lead_session",
      "lead_session_id" => "oleadsession_slice0contract",
      "logical_lead_id" => logical_lead["logical_lead_id"],
      "agent_instance_id" => agent["agent_instance_id"],
      "task_id" => TASK_ID,
      "task_revision_id" => TASK_REVISION_ID,
      "session_generation" => 1,
      "durable_context_ref" => logical_lead["durable_context_ref"],
      "lead_control_id" => CONTROL_ID,
      "lead_runtime_subject_ref" => agent.dig("runtime_identity", "runtime_subject_id"),
      "lead_runtime_subject_assertion_digest" => digest_for(
        agent.dig("runtime_identity", "verification_receipt_ref")
      ),
      "predecessor_lead_session_ref" => nil,
      "lifecycle_events" => [lifecycle]
    }
  end

  def lead_checkpoint(
    id,
    is_genesis:,
    predecessor_ref:,
    policy:,
    session:,
    agent:,
    logical_lead:,
    task:,
    writer_action:, writer_assertion:,
    lead_control_id: CONTROL_ID,
    active_task_ref: nil, selected_work_unit_ref: nil, attempt_ref: nil,
    task_queue: nil, task_transfer_acquire: nil,
    delivery: nil, assurance: nil, decision: nil, reconcile_trigger: nil, next_trigger: nil,
    unit: nil, attempt: nil, resolution: nil,
    proposed_thesis_ref: nil, proposed_rule_ref: nil,
    predecessor_checkpoint: nil, measurements: nil,
    budget_adjustment: nil,
    wall_clock_fallback: nil,
    checkpoint_due_observation_ref: nil,
    fingerprint_identity_basis: nil, fingerprint: nil, fingerprint_supporting_provenance: nil,
    retry_override_ref: nil
  )
    bindings = default_budget_bindings(
      policy: policy,
      measurements: measurements,
      budget_adjustment: budget_adjustment,
      predecessor_checkpoint: predecessor_checkpoint,
      active_task_ref: active_task_ref,
      selected_work_unit_ref: selected_work_unit_ref
    )
    adjustment_digest =
      budget_adjustment && Orbit::V2::ControlAuthority.budget_adjustment_digest(budget_adjustment)
    basis_task_ref = active_task_ref || (task_queue && task_queue.first) || task_ref(task)
    basis_unit_ref = selected_work_unit_ref || (unit && work_unit_ref(unit))
    observation_basis = reconcile_trigger.is_a?(Hash) && reconcile_trigger["event"] == "attempt_created"
    rule_ref = proposed_rule_ref
    rule_ref = pinned_rule_ref(attempt, resolution) if observation_basis && rule_ref.nil?
    thesis_ref = proposed_thesis_ref
    if observation_basis && thesis_ref.nil? && attempt
      thesis_ref = attempt.dig("events", 0, "assignment", "change_thesis_ref")
    end
    plan_digest = Orbit::V2::ControlAuthority.effective_verification_plan_digest(
      policy_ref: policy_ref(policy),
      task_revision_ref: basis_task_ref,
      assigned_rule_resolution_ref: rule_ref,
      effective_budget_bindings: bindings
    )
    closure_digest = Orbit::V2::ControlAuthority.closure_basis_digest(
      task_revision_ref: basis_task_ref,
      work_unit_ref: basis_unit_ref,
      change_thesis_ref: thesis_ref,
      assigned_rule_resolution_ref: rule_ref,
      effective_verification_plan_digest: plan_digest
    )
    delivery_progress = (delivery || checkpoint_progress("not_assessed")).merge(
      "predecessor_lead_checkpoint_ref" => predecessor_ref
    )
    # The dispatch-time proposal IS part of the checkpoint's exact supporting
    # provenance: the successor's ChangeThesis and RuleResolution are frozen
    # here, never chosen later by the Attempt.
    proposal_refs = []
    if proposed_thesis_ref.is_a?(Hash)
      proposal_refs << {
        "kind" => "change_thesis",
        "id" => proposed_thesis_ref["change_thesis_id"],
        "digest" => proposed_thesis_ref["content_digest"]
      }
    end
    if proposed_rule_ref.is_a?(Hash)
      proposal_refs << {
        "kind" => "rule_resolution",
        "id" => proposed_rule_ref["resolution_id"],
        "digest" => proposed_rule_ref["identity_sha256"]
      }
    end
    unless proposal_refs.empty?
      delivery_progress = delivery_progress.merge(
        "supporting_refs" => Array(delivery_progress["supporting_refs"]) + proposal_refs
      )
    end
    digested(
      "schema_version" => "orbit-lead-checkpoint-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "object_type" => "lead_checkpoint",
      "lead_checkpoint_id" => id,
      "lead_control_id" => lead_control_id,
      "is_genesis" => is_genesis,
      "predecessor_lead_checkpoint_ref" => predecessor_ref,
      "project_policy_revision_ref" => policy_ref(policy),
      "lead_agent_instance_ref" => { "agent_instance_id" => agent["agent_instance_id"] },
      "active_lead_session_ref" => session_ref(session),
      "lead_runtime_subject_ref" => session["lead_runtime_subject_ref"],
      "lead_runtime_subject_assertion_digest" => session["lead_runtime_subject_assertion_digest"],
      "logical_lead_refs" => [
        ref("logical_lead_id", logical_lead["logical_lead_id"], logical_lead["content_digest"])
      ],
      "task_queue" => task_queue || [task_ref(task)],
      "task_transfer_acquire" => task_transfer_acquire,
      "active_task_ref" => active_task_ref,
      "selected_work_unit_ref" => selected_work_unit_ref,
      "current_or_terminal_attempt_ref" => attempt_ref,
      "assessments" => checkpoint_assessments(active_task_ref, selected_work_unit_ref, attempt_ref),
      "delivery_progress" => delivery_progress,
      "assurance_progress" => (assurance || checkpoint_progress("not_assessed")).merge(
        "predecessor_lead_checkpoint_ref" => predecessor_ref
      ),
      "effective_budget_bindings" => bindings,
      "budget_adjustment_digest" => adjustment_digest,
      "test_budget_adjust" => budget_adjustment,
      "effective_verification_plan_digest" => plan_digest,
      "closure_basis_digest" => closure_digest,
      "wall_clock_fallback" => wall_clock_fallback,
      "checkpoint_due_observation_ref" => checkpoint_due_observation_ref,
      "fingerprint_identity_basis" => fingerprint_identity_basis,
      "fingerprint" => fingerprint,
      "fingerprint_supporting_provenance" => fingerprint_supporting_provenance,
      "retry_override_ref" => retry_override_ref,
      "lead_decision" => decision || {
        "state" => "blocked", "action" => is_genesis ? "establish" : "continue",
        "reason" => is_genesis ? "control anchored" : "observation accepted"
      },
      "reconcile_trigger" => reconcile_trigger || {
        "event" => is_genesis ? "genesis" : (decision && decision["action"] == "dispatch" ? "dispatch_before" : "attempt_terminal"),
        "reason" => "Decision trigger recorded for this checkpoint."
      },
      "next_trigger" => next_trigger || {
        "event" => is_genesis ? "dispatch_before" : (decision && decision["action"] == "dispatch" ? "attempt_created" : "successor_before"),
        "reason" => "Awaiting the next control event."
      },
      "writer_authority_provenance" => writer_provenance(policy, writer_action, writer_assertion)
    )
  end

  # Canonical two-layer budget bindings through the shared derivation seam:
  # policy_default per scope unless a typed in-ceiling adjustment (or its
  # inherited continuation) applies. Measurements default to the unverified
  # pending forward state; override consumption is built explicitly by
  # callers through reseal_checkpoint/override fixtures.
  def default_budget_bindings(
    policy:,
    measurements: nil,
    measurements_by_scope: nil,
    budget_adjustment: nil,
    predecessor_checkpoint: nil,
    active_task_ref: nil,
    selected_work_unit_ref: nil
  )
    adjustment_digest =
      budget_adjustment && Orbit::V2::ControlAuthority.budget_adjustment_digest(budget_adjustment)
    Orbit::V2::ControlAuthority::BUDGET_SCOPES.map do |scope|
      payload =
        budget_adjustment.is_a?(Hash) && budget_adjustment["budget_scope_type"] == scope ?
          budget_adjustment : nil
      predecessor_binding =
        predecessor_checkpoint &&
        predecessor_checkpoint["effective_budget_bindings"] &&
        predecessor_checkpoint["effective_budget_bindings"].find do |binding|
          binding["budget_scope_type"] == scope
        end
      Orbit::V2::ControlAuthority.derive_binding(
        scope: scope,
        project_id: PROJECT_ID,
        control_id: CONTROL_ID,
        policy: policy,
        policy_ref: policy_ref(policy),
        predecessor_binding: predecessor_binding,
        predecessor_checkpoint_ref:
          predecessor_checkpoint && cp_ref(predecessor_checkpoint),
        predecessor_work_unit_ref:
          predecessor_checkpoint &&
            (scope == "work_unit_lineage" ? predecessor_checkpoint["selected_work_unit_ref"] : nil),
        adjustment_payload: payload,
        adjustment_digest: adjustment_digest,
        override_record: nil,
        override_mode: nil,
        origin_consuming_checkpoint_ref: nil,
        active_task_ref: active_task_ref,
        work_unit_ref: selected_work_unit_ref,
        measurements:
          (measurements_by_scope && measurements_by_scope[scope]) ||
          measurements ||
          unverified_pending_measurements
      )
    end
  end

  def checkpoint_proposal_refs(checkpoint, kind)
    assessment_refs = %w[task_queue active_mainline work_graph_branches current_attempt].flat_map do |layer|
      Array(checkpoint.dig("assessments", layer, "supporting_refs"))
    end
    (assessment_refs +
      Array(checkpoint.dig("delivery_progress", "supporting_refs")) +
      Array(checkpoint.dig("assurance_progress", "supporting_refs")))
      .select { |ref| ref.is_a?(Hash) && ref["kind"] == kind }
  end

  def unverified_pending_measurements(
    lead_reason_code: "Lead judgment: default dispatch proceeds pending independent review.",
    lead_supporting_refs: []
  )
    assessment = {
      "lead_disposition" => "proceed_pending_independent_review",
      "lead_reason_code" => lead_reason_code,
      "lead_supporting_refs" => lead_supporting_refs,
      "review_status" => "pending",
      "review_gate_evaluation_ref" => nil
    }
    {
      "test_count" => {
        "status" => "unverified", "usage" => nil, "source_ref" => nil,
        "unverified_assessment" => assessment
      },
      "test_code_lines" => {
        "status" => "unverified", "usage" => nil, "source_ref" => nil,
        "unverified_assessment" => assessment
      }
    }
  end

  # Verified test-budget measurements through per-metric provider-verified
  # test.measurement.attest assertions: each metric and scope gets its own
  # canonical-scope assertion binding project/policy/TaskRevision/WorkUnit
  # (exact for work_unit_lineage, canonical null for task_lineage)/
  # metric/usage/snapshot. A bare snapshot reference is never "verified".
  def attested_measurements(bundle, usage_count:, usage_lines:, task:, unit:, policy:, scope:)
    snapshot = bundle["repository_snapshot"]
    build = lambda do |metric, usage|
      unit_ref = scope == "work_unit_lineage" ? work_unit_ref(unit) : nil
      envelope = {
        "scope_digest" => nil,
        "project_id" => PROJECT_ID,
        "project_policy_revision_ref" => policy_ref(policy),
        "task_revision_ref" => task_ref(task),
        "work_unit_ref" => unit_ref,
        "metric_identity" => metric,
        "usage" => usage,
        "repository_snapshot_ref" => { "id" => "repository-snapshot", "digest" => snapshot["tree_digest"] }
      }
      envelope["scope_digest"] = Orbit::V2::ControlAuthority.measurement_scope_digest(
        project_id: envelope["project_id"],
        policy_ref: envelope["project_policy_revision_ref"],
        task_ref: envelope["task_revision_ref"],
        work_unit_ref: envelope["work_unit_ref"],
        metric_identity: metric,
        usage: usage,
        snapshot_ref: envelope["repository_snapshot_ref"]
      )
      id = "oassert_measurement_#{scope}_#{metric}"
      document = {
        "schema_version" => "orbit-authority-assertion-v1",
        "protocol_epoch" => "orbit-v2",
        "project_id" => PROJECT_ID,
        "assertion_id" => id,
        "issuer_kind" => "user",
        "issuer_subject" => "project-owner",
        "provider_id" => AUTHORITY_PROVIDER_ID,
        "authority_scope_ref" => envelope["scope_digest"],
        "grants" => [Orbit::V2::ControlAuthority::MEASUREMENT_ATTEST_ACTION],
        "asserted_at" => "2026-07-30T00:00:00Z",
        "measurement_attestation_envelope" => envelope
      }
      document["assertion_digest"] = Orbit::V2::AuthorityVerifier.assertion_digest(document)
      document["verification_receipt"] = FAKE_AUTHORITY_PROVIDER.issue(
        document,
        receipt_id: "oareceipt_#{id.delete_prefix("oassert_")}",
        issued_at: document["asserted_at"]
      )
      bundle["authority_assertions"] << document
      { "kind" => "measurement_attestation", "id" => id, "digest" => document["assertion_digest"] }
    end
    {
      "test_count" => {
        "status" => "verified", "usage" => usage_count,
        "source_ref" => build.call("test_count", usage_count),
        "unverified_assessment" => nil
      },
      "test_code_lines" => {
        "status" => "verified", "usage" => usage_lines,
        "source_ref" => build.call("test_code_lines", usage_lines),
        "unverified_assessment" => nil
      }
    }
  end

  def pinned_rule_ref(attempt, resolution)
    return nil unless resolution.is_a?(Hash)

    {
      "resolution_id" => resolution["resolution_id"],
      "identity_sha256" => resolution["identity_sha256"]
    }
  end

  # Recompute the increment-4 authority fields of an already-built checkpoint
  # document in place (policy rotation rebinds, overridden bindings): the
  # bindings, plan digest and closure basis must always match the exact
  # authoritative inputs of the final document.
  def reseal_checkpoint(
    checkpoint,
    policy:,
    predecessor_checkpoint: nil,
    measurements: nil,
    measurements_by_scope: nil,
    budget_adjustment: nil,
    bindings: nil,
    active_task_ref: nil,
    selected_work_unit_ref: nil,
    attempt: nil,
    resolution: nil,
    proposed_thesis_ref: nil,
    proposed_rule_ref: nil
  )
    checkpoint["effective_budget_bindings"] = bindings || default_budget_bindings(
      policy: policy,
      measurements: measurements,
      measurements_by_scope: measurements_by_scope,
      budget_adjustment: budget_adjustment,
      predecessor_checkpoint: predecessor_checkpoint,
      active_task_ref: active_task_ref || checkpoint["active_task_ref"],
      selected_work_unit_ref: selected_work_unit_ref || checkpoint["selected_work_unit_ref"]
    )
    adjustment_digest =
      budget_adjustment && Orbit::V2::ControlAuthority.budget_adjustment_digest(budget_adjustment)
    checkpoint["budget_adjustment_digest"] = adjustment_digest
    checkpoint["test_budget_adjust"] = budget_adjustment
    task_ref = checkpoint["active_task_ref"] || Array(checkpoint["task_queue"]).first
    unit_ref = checkpoint["selected_work_unit_ref"]
    observation_basis = checkpoint.dig("reconcile_trigger", "event") == "attempt_created"
    # The dispatch proposal is part of the checkpoint's own supporting
    # provenance; resealing must re-derive the plan/closure basis from it.
    thesis_proposals = checkpoint_proposal_refs(checkpoint, "change_thesis")
    rule_proposals = checkpoint_proposal_refs(checkpoint, "rule_resolution")
    proposed_thesis_ref ||= if thesis_proposals.length == 1
      {
        "change_thesis_id" => thesis_proposals.first["id"],
        "content_digest" => thesis_proposals.first["digest"]
      }
    end
    proposed_rule_ref ||= if rule_proposals.length == 1
      {
        "resolution_id" => rule_proposals.first["id"],
        "identity_sha256" => rule_proposals.first["digest"]
      }
    end
    rule_ref = proposed_rule_ref
    rule_ref = pinned_rule_ref(attempt, resolution) if observation_basis && rule_ref.nil?
    thesis_ref = proposed_thesis_ref
    if observation_basis && thesis_ref.nil? && attempt
      thesis_ref = attempt.dig("events", 0, "assignment", "change_thesis_ref")
    end
    checkpoint["effective_verification_plan_digest"] =
      Orbit::V2::ControlAuthority.effective_verification_plan_digest(
        policy_ref: checkpoint["project_policy_revision_ref"],
        task_revision_ref: task_ref,
        assigned_rule_resolution_ref: rule_ref,
        effective_budget_bindings: checkpoint["effective_budget_bindings"]
      )
    checkpoint["closure_basis_digest"] =
      Orbit::V2::ControlAuthority.closure_basis_digest(
        task_revision_ref: task_ref,
        work_unit_ref: unit_ref,
        change_thesis_ref: thesis_ref,
        assigned_rule_resolution_ref: rule_ref,
        effective_verification_plan_digest: checkpoint["effective_verification_plan_digest"]
      )
    digested(checkpoint)
  end

  def checkpoint_progress(change, measured: nil, substantive: [])
    {
      "change" => change,
      "rationale" => "Lead judgment recorded for the control checkpoint.",
      "measured_terminal_attempt_ref" => measured,
      "substantive_change_kinds" => substantive,
      "supporting_refs" => measured ? [
        { "kind" => "attempt_event", "id" => measured["attempt_id"], "event_id" => measured["event_id"], "digest" => measured["event_digest"] }
      ] : []
    }
  end

  def checkpoint_assessments(active_task_ref, selected_work_unit_ref, attempt_ref)
    layer = lambda do |basis, status|
      {
        "status" => status,
        "rationale" => "Layer assessed against its exact basis projection.",
        "basis_projection" => basis,
        "supporting_refs" => []
      }
    end
    {
      "task_queue" => layer.call("task_queue", "ok"),
      "active_mainline" => layer.call("active_task_ref", active_task_ref ? "ok" : "none"),
      "work_graph_branches" => layer.call("selected_work_unit_ref", selected_work_unit_ref ? "ok" : "none"),
      "current_attempt" => layer.call("current_or_terminal_attempt_ref", attempt_ref ? "ok" : "none")
    }
  end

  def append_dispatch_checkpoint(bundle, attempt:, unit:, task: nil, pin_attempt_id: nil)
    tip = bundle["lead_checkpoints"].last
    session = bundle["lead_sessions"].last
    lead_agent = bundle["agent_instances"].find { |candidate| candidate["agent_instance_id"] == session["agent_instance_id"] }
    writer_assertion = bundle["authority_assertions"].find { |candidate| candidate["assertion_id"] == "oassert_controlwriter" }
    task ||= bundle["task_revisions"].first
    policy ||= bundle["project_policy_revisions"].last
    attempt_ref = pin_attempt_id ? attempt_event_ref(bundle["work_unit_attempts"], pin_attempt_id) : nil
    assigned_rule_id = attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id")
    resolution = bundle["rule_resolution_artifacts"].find do |candidate|
      candidate["resolution_id"] == assigned_rule_id
    end
    if resolution.nil? && assigned_rule_id.is_a?(String) && assigned_rule_id.start_with?("rr-sha256-")
      # The artifact is appended after the checkpoint in some fixtures; its
      # identity is content-addressed, so the exact ref is derivable.
      resolution = {
        "resolution_id" => assigned_rule_id,
        "identity_sha256" => "sha256:#{assigned_rule_id.delete_prefix("rr-sha256-")}"
      }
    end
    checkpoint = lead_checkpoint(
      "olcheckpoint_dispatch_#{attempt["attempt_id"].delete_prefix("oattempt_")}",
      is_genesis: false,
      predecessor_ref: cp_ref(tip),
      predecessor_checkpoint: tip,
      policy: policy,
      session: session,
      agent: lead_agent,
      logical_lead: bundle["logical_leads"].first,
      task: task,
      writer_action: "control.checkpoint",
      writer_assertion: writer_assertion,
      active_task_ref: task_ref(task),
      selected_work_unit_ref: work_unit_ref(unit),
      attempt_ref: attempt_ref,
      unit: unit,
      proposed_thesis_ref: begin
        thesis = bundle["change_theses"].find do |candidate|
          candidate["work_unit_id"] == unit["work_unit_id"]
        end
        {
          "change_thesis_id" => thesis["change_thesis_id"],
          "content_digest" => thesis["content_digest"]
        }
      end,
      proposed_rule_ref: pinned_rule_ref(attempt, resolution),
      decision: DISPATCH_DECISION
    )
    bundle["lead_checkpoints"] << checkpoint
    attempt["dispatch_lead_checkpoint_ref"] = cp_ref(checkpoint)
    bundle["lead_checkpoints"] << observation_checkpoint(checkpoint, attempt,
      policy: policy, resolution: resolution)
    checkpoint
  end

  # The dispatch proof is constructive: the successor observes the exact
  # AttemptCreated event. The observation is a NEW checkpoint with its own
  # deterministic authority fields: bindings derive from the dispatch
  # checkpoint's binding lineage (inherited adjustment/override or back to
  # policy default), the adjustment payload is never copied (no second
  # consume, no forged adjust), and the plan/closure basis pins the created
  # Attempt's actual thesis/rule assignment.
  def observation_checkpoint(dispatch, attempt, session: nil, cp_id: nil, policy: nil, resolution: nil)
    observation = deep_copy(dispatch)
    observation["lead_checkpoint_id"] = cp_id || "olcheckpoint_created_#{attempt["attempt_id"].delete_prefix("oattempt_")}"
    observation["predecessor_lead_checkpoint_ref"] = cp_ref(dispatch)
    observation["active_lead_session_ref"] = session_ref(session) if session
    observation["current_or_terminal_attempt_ref"] = attempt_event_ref([attempt], attempt["attempt_id"], 0)
    observation["assessments"] = checkpoint_assessments(
      observation["active_task_ref"],
      observation["selected_work_unit_ref"],
      observation["current_or_terminal_attempt_ref"]
    )
    %w[delivery_progress assurance_progress].each do |field|
      observation[field] = checkpoint_progress("not_assessed").merge("predecessor_lead_checkpoint_ref" => observation["predecessor_lead_checkpoint_ref"])
    end
    observation["effective_budget_bindings"] = default_budget_bindings(
      policy: policy,
      predecessor_checkpoint: dispatch,
      active_task_ref: observation["active_task_ref"],
      selected_work_unit_ref: observation["selected_work_unit_ref"]
    )
    observation["budget_adjustment_digest"] = nil
    observation["test_budget_adjust"] = nil
    # Fingerprint/retry-override authority belongs to the terminal/dispatch
    # checkpoint that authored or consumed it, never to a copied observation.
    observation["fingerprint_identity_basis"] = nil
    observation["fingerprint"] = nil
    observation["fingerprint_supporting_provenance"] = nil
    observation["retry_override_ref"] = nil
    rule_ref = pinned_rule_ref(attempt, resolution)
    observation["effective_verification_plan_digest"] =
      Orbit::V2::ControlAuthority.effective_verification_plan_digest(
        policy_ref: observation["project_policy_revision_ref"],
        task_revision_ref: observation["active_task_ref"],
        assigned_rule_resolution_ref: rule_ref,
        effective_budget_bindings: observation["effective_budget_bindings"]
      )
    observation["closure_basis_digest"] =
      Orbit::V2::ControlAuthority.closure_basis_digest(
        task_revision_ref: observation["active_task_ref"],
        work_unit_ref: observation["selected_work_unit_ref"],
        change_thesis_ref: attempt.dig("events", 0, "assignment", "change_thesis_ref"),
        assigned_rule_resolution_ref: rule_ref,
        effective_verification_plan_digest: observation["effective_verification_plan_digest"]
      )
    observation["lead_decision"] = {
      "state" => "blocked", "action" => "continue", "reason" => "attempt creation observed"
    }
    observation["reconcile_trigger"] = {
      "event" => "attempt_created", "reason" => "Observing AttemptCreated."
    }
    observation["next_trigger"] = {
      "event" => "attempt_terminal", "reason" => "Awaiting the Attempt terminal event."
    }
    digested(observation)
  end

  def cp_ref(checkpoint)
    checkpoint.slice("lead_checkpoint_id", "content_digest")
  end

  def session_ref(session)
    session.slice("lead_session_id", "session_generation")
  end

  def attempt_event_ref(attempts, attempt_id, index = -1)
    attempt = attempts.find { |candidate| candidate["attempt_id"] == attempt_id }
    event = attempt.fetch("events")[index]
    { "attempt_id" => attempt_id, "event_id" => event["event_id"], "event_digest" => event["event_digest"] }
  end

  def work_unit_ref(unit)
    ref("work_unit_id", unit["work_unit_id"], unit["content_digest"])
  end

  def control_registry(policy:, genesis_checkpoint:, task:, writer_assertion:)
    digested(
      "schema_version" => "orbit-lead-control-registry-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "object_type" => "lead_control_registry",
      "lead_control_id" => CONTROL_ID,
      "genesis_checkpoint_ref" => ref(
        "lead_checkpoint_id",
        genesis_checkpoint["lead_checkpoint_id"],
        genesis_checkpoint["content_digest"]
      ),
      "writer_authority_provenance" => writer_provenance(policy, "control.genesis", writer_assertion),
      "owned_task_refs" => [task_ref(task)]
    )
  end

  def writer_provenance(policy, action, assertion)
    {
      "policy_revision_ref" => policy_ref(policy),
      "action" => action,
      "assertion_ref" => assertion_ref(assertion)
    }
  end

  def assertion_ref(assertion)
    {
      "assertion_id" => assertion["assertion_id"],
      "assertion_digest" => assertion["assertion_digest"]
    }
  end

  def policy_ref(policy)
    ref("policy_revision_id", policy["policy_revision_id"], policy["content_digest"])
  end

  def task_ref(task)
    ref("task_id", task["task_id"], task["content_digest"]).merge(
      "task_revision_id" => task["task_revision_id"]
    )
  end

  def attempt(
    id,
    unit_id,
    agent_id,
    role,
    purpose,
    thesis,
    rule_id,
    index,
    policy_digest,
    task_id: TASK_ID,
    task_revision_id: TASK_REVISION_ID,
    authorization_record_refs: [],
    lead_control_id: "olcontrol_slice0main",
    predecessor_work_unit_attempt_ref: nil,
    dispatch_lead_checkpoint_ref: nil,
    started_at: nil
  )
    assignment = {
      "agent_instance_id" => agent_id,
      "context_generation" => 1,
      "resolved_role" => role,
      "purpose" => purpose,
      "authority_snapshot" => {
        "project_policy_revision_ref" => ref(
          "policy_revision_id",
          POLICY_ID,
          policy_digest
        ),
        "authorization_record_refs" => deep_copy(authorization_record_refs)
      },
      "change_thesis_ref" => ref(
        "change_thesis_id",
        thesis["change_thesis_id"],
        thesis["content_digest"]
      ).merge("revision" => thesis["revision"]),
      "assigned_rule_resolution_id" => rule_id
    }
    creation = event(
      "oevent_#{id.delete_prefix("oattempt_")}_created",
      "AttemptCreated",
      nil,
      "assignment" => assignment,
      "started_at" => started_at || "2026-07-30T00:01:0#{index}Z",
      "status" => "active"
    )
    {
      "schema_version" => "orbit-agent-runtime-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "object_type" => "work_unit_attempt",
      "attempt_id" => id,
      "lead_control_id" => lead_control_id,
      "predecessor_work_unit_attempt_ref" => predecessor_work_unit_attempt_ref,
      "dispatch_lead_checkpoint_ref" => dispatch_lead_checkpoint_ref,
      "task_id" => task_id,
      "task_revision_id" => task_revision_id,
      "work_unit_id" => unit_id,
      "events" => [creation]
    }
  end

  def implementation_evidence(
    id,
    attempt,
    resolution,
    thesis_ref,
    paths,
    acceptance_recorded_at: "2026-07-30T00:02:00Z",
    evidence_results: DEFAULT_EVIDENCE_RESULTS
  )
    change_claim = {
      "artifact_ref" => "artifact://#{id}/change",
      "artifact_kind" => "change",
      "content_digest" => digest_for("#{id}:change:#{paths.sort.join(":")}"),
      "paths" => paths.sort
    }
    verification_claim = {
      "artifact_ref" => "artifact://#{id}/verification",
      "artifact_kind" => "verification",
      "content_digest" => digest_for("#{id}:verification:contract-test"),
      "paths" => []
    }
    change_ref = {
      "artifact_ref" => change_claim["artifact_ref"],
      "content_digest" => change_claim["content_digest"]
    }
    verification_ref = {
      "artifact_ref" => verification_claim["artifact_ref"],
      "content_digest" => verification_claim["content_digest"]
    }
    report_claims = evidence_results.map do |result|
      use = result["verification_use"]
      next unless %w[audit_record_evidence acceptance_proof_evidence].include?(use)

      {
        "artifact_ref" => "artifact://#{id}/report/#{result["evidence_requirement_id"]}",
        "artifact_kind" => "report",
        "content_digest" => digest_for("#{id}:report:#{result["evidence_requirement_id"]}"),
        "paths" => []
      }
    end.compact
    requirement_results = evidence_results.map do |result|
      use = result["verification_use"]
      ref = if use == "permanent_test_evidence"
        verification_ref
      else
        claim = report_claims.find do |candidate|
          candidate["artifact_ref"] == "artifact://#{id}/report/#{result["evidence_requirement_id"]}"
        end
        { "artifact_ref" => claim["artifact_ref"], "content_digest" => claim["content_digest"] }
      end
      {
        "evidence_requirement_id" => result["evidence_requirement_id"],
        "verification_use" => use,
        "status" => "pass",
        "evidence_refs" => [ref]
      }
    end
    digested(
      "schema_version" => "orbit-evidence-v2",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "evidence_record_id" => id,
      "record_kind" => "implementation",
      "task_id" => attempt["task_id"],
      "task_revision_id" => attempt["task_revision_id"],
      "work_unit_id" => attempt["work_unit_id"],
      "attempt_id" => attempt["attempt_id"],
      "submitted_rule_resolution_id" => resolution["resolution_id"],
      "accepted" => true,
      "acceptance_recorded_at" => acceptance_recorded_at,
      "implementation_check" => {
        "change_thesis_ref" => thesis_ref,
        "scope_match" => {
          "status" => "pass",
          "evidence_refs" => [change_ref]
        },
        "acceptance_results" => [
          {
            "acceptance_id" => "acc_contract_valid",
            "status" => "pass",
            "evidence_refs" => [verification_ref]
          }
        ],
        "evidence_requirement_results" => requirement_results,
        "change_thesis_status" => {
          "status" => "supported",
          "evidence_refs" => [change_ref]
        },
        "changed_paths" => paths,
        "verification_refs" => [verification_ref],
        "assumptions_changed" => [],
        "known_gaps" => []
      },
      "submission_artifact_refs" =>
        ([change_claim, verification_claim] + report_claims).sort_by { |claim| claim["artifact_ref"] },
      "supersedes_evidence_record_id" => nil
    )
  end

  def evaluator_submission(
    id,
    attempt,
    resolution,
    acceptance_recorded_at: "2026-07-30T00:02:00Z"
  )
    report_claim = {
      "artifact_ref" => "artifact://#{id}/report",
      "artifact_kind" => "report",
      "content_digest" => digest_for("#{id}:review-report"),
      "paths" => []
    }
    digested(
      "schema_version" => "orbit-evidence-v2",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "evidence_record_id" => id,
      "record_kind" => "evaluator_submission",
      "task_id" => attempt["task_id"],
      "task_revision_id" => attempt["task_revision_id"],
      "work_unit_id" => attempt["work_unit_id"],
      "attempt_id" => attempt["attempt_id"],
      "submitted_rule_resolution_id" => resolution["resolution_id"],
      "accepted" => true,
      "acceptance_recorded_at" => acceptance_recorded_at,
      "submission_artifact_refs" => [report_claim],
      "supersedes_evidence_record_id" => nil
    )
  end

  def event(id, type, previous_digest, fields)
    document = {
      "event_id" => id,
      "event_type" => type,
      "previous_event_digest" => previous_digest
    }.merge(fields)
    document["recorded_at"] ||= document["started_at"] ||
      document["ended_at"] ||
      "2026-07-30T00:30:00Z"
    document["event_digest"] = Orbit::V2::CanonicalJSON.digest_excluding(
      document,
      "event_digest",
      "writer_receipt",
      "created_at",
      "accepted_at",
      "envelope"
    )
    document["writer_receipt"] = FAKE_LIFECYCLE_PROVIDER.issue(
      document,
      project_id: PROJECT_ID
    )
    document
  end

  def resign_event(event)
    event["event_digest"] = Orbit::V2::CanonicalJSON.digest_excluding(
      event,
      "event_digest",
      "writer_receipt",
      "created_at",
      "accepted_at",
      "envelope"
    )
    event["writer_receipt"] = FAKE_LIFECYCLE_PROVIDER.issue(
      event,
      project_id: PROJECT_ID
    )
    event
  end

  def resign_event_chain(attempt)
    previous_digest = nil
    attempt.fetch("events").each do |event|
      event["previous_event_digest"] = previous_digest if previous_digest
      resign_event(event)
      previous_digest = event["event_digest"]
    end
    attempt
  end

  def resign_runtime_identity(agent)
    identity = agent.fetch("runtime_identity")
    identity["verification_receipt_ref"] = FAKE_RUNTIME_IDENTITY_PROVIDER.issue(
      provider_id: identity.fetch("provider_id"),
      project_id: agent.fetch("project_id"),
      agent_instance_id: agent.fetch("agent_instance_id"),
      runtime_subject_id: identity.fetch("runtime_subject_id")
    )
    agent
  end

  def ref(id_key, id, digest)
    { id_key => id, "content_digest" => digest }
  end

  def digest_for(value)
    "sha256:#{Digest::SHA256.hexdigest(value)}"
  end

  def rule_path(role)
    if role == "reviewer"
      "skills/orbit/references/runtime/quality-outcome-and-review.md"
    else
      "skills/orbit/references/runtime/coding-guideline.md"
    end
  end

  def rule_digest(role)
    "sha256:#{Digest::SHA256.file(File.join(ROOT, rule_path(role))).hexdigest}"
  end

  # ---------------------------------------------------------------- increment 4

  def thesis_for(bundle, unit)
    bundle["change_theses"].find { |candidate| candidate["work_unit_id"] == unit["work_unit_id"] }
  end

  # A fresh content-addressed rule resolution for a new attempt, cloned from
  # the base identity of the same work unit.
  def rule_resolution_for(bundle, attempt_id, unit:, role:, index:)
    base = bundle["rule_resolution_artifacts"].find do |candidate|
      candidate.dig("identity", "work_unit_id") == unit["work_unit_id"]
    end
    identity = deep_copy(base.fetch("identity"))
    identity["attempt_id"] = attempt_id
    identity["resolved_role"] = role
    identity["agent_instance_id"] = "oagent_implementertwo" if role == "coder"
    identity["context_generation"] = 1
    rule = Orbit::V2::RuleResolution.build(
      identity,
      created_at: "2026-07-30T00:2#{index % 10}:00Z",
      project_root: ROOT
    )
    bundle["rule_resolution_artifacts"] << rule
    rule
  end

  def test_fingerprint_identity(task:, unit:)
    {
      "canonicalization_version" => Orbit::V2::ControlAuthority::FINGERPRINT_CANONICALIZATION_VERSION,
      "scope" => {
        "task_revision_ref" => task_ref(task),
        "work_unit_ref" => work_unit_ref(unit)
      },
      "category" => "test",
      "failure_code" => "contract-validation-failure",
      "finding_ref" => nil,
      "stable_signal_identity" => {
        "test_or_check_id" => "test-orbit-contract-suite",
        "signal_subject_id" => "signal:#{unit["work_unit_id"]}",
        "normalized_failure_code" => "contract-validation-failure"
      }
    }
  end

  # Two same-fingerprint failed Attempts recorded in the accepted lineage
  # with separate supporting provenance and the ordered prior chain. The
  # second-failure checkpoint is the authorizing checkpoint of the retry:
  # its decision is needs_user/escalate (no user authority yet). With
  # override: true the successor checkpoint reconciles on authority_change,
  # consumes a provider-verified task.retry.override record, and authorizes
  # the third Attempt; with override: false no such checkpoint exists and
  # the third dispatch stays needs_user. The record is authorized against
  # the second-failure checkpoint (a fixed non-circular ancestor) and is
  # consumed by the later dispatch checkpoint, so no checkpoint content
  # digest ever depends on the record and the record never depends on the
  # consuming checkpoint.
  def retry_fuse_bundle(override: true, forged_fingerprint: nil, gap_chain: false, omit_fingerprint: false, fingerprint_without_failure: false, intermediate_repin: false)
    bundle = valid_bundle
    review = bundle["work_unit_attempts"].find { |c| c["attempt_id"] == "oattempt_independentreview" }
    review["events"] << event(
      "oevent_reviewfuseterminal",
      "AttemptCompleted",
      review.dig("events", 0, "event_digest"),
      "ended_at" => "2026-07-30T03:00:00Z",
      "status" => "completed"
    )
    unit = bundle["work_units"].find { |c| c["work_unit_id"] == "owu_implementationtwo" }
    task = bundle["task_revisions"].first
    policy = bundle["project_policy_revisions"].first
    session = bundle["lead_sessions"].last
    agent = bundle["agent_instances"].find { |c| c["agent_instance_id"] == session["agent_instance_id"] }
    lead = bundle["logical_leads"].first
    writer = bundle["authority_assertions"].find { |c| c["assertion_id"] == "oassert_controlwriter" }
    thesis = thesis_for(bundle, unit)
    basis = test_fingerprint_identity(task: task, unit: unit)
    fingerprint = Orbit::V2::ControlAuthority.fingerprint_digest(basis)
    tip = bundle["lead_checkpoints"].last

    rules = {
      "oattempt_fuseattemptone" => rule_resolution_for(bundle, "oattempt_fuseattemptone", unit: unit, role: "coder", index: 4),
      "oattempt_fuseattempttwo" => rule_resolution_for(bundle, "oattempt_fuseattempttwo", unit: unit, role: "coder", index: 5)
    }
    thesis_ref_for_unit = {
      "change_thesis_id" => thesis["change_thesis_id"],
      "content_digest" => thesis["content_digest"]
    }
    fuse_attempt = lambda do |attempt_id, predecessor_id, index, prior_chain, cp_id, dispatch_cp_id, decision, next_event, retry_override_ref, started_at, failed_at, successor_proposals: nil|
      rule = rules.fetch(attempt_id)
      created = attempt(
        attempt_id,
        unit["work_unit_id"],
        "oagent_implementertwo",
        "coder",
        "implementation",
        thesis,
        rule["resolution_id"],
        index,
        policy["content_digest"],
        authorization_record_refs:
          unit.dig("authority_scope", "authorization_record_refs"),
        predecessor_work_unit_attempt_ref: predecessor_id,
        started_at: started_at
      )
      bundle["work_unit_attempts"] << created
      dispatch =
        if dispatch_cp_id.nil?
          checkpoint = lead_checkpoint(
            "olcheckpoint_#{attempt_id.delete_prefix("oattempt_")}_dispatch",
            is_genesis: false,
            predecessor_ref: cp_ref(tip),
            predecessor_checkpoint: tip,
            policy: policy,
            session: session,
            agent: agent,
            logical_lead: lead,
            task: task,
            writer_action: "control.checkpoint",
            writer_assertion: writer,
            active_task_ref: task_ref(task),
            selected_work_unit_ref: work_unit_ref(unit),
            unit: unit,
            proposed_thesis_ref: thesis_ref_for_unit,
            proposed_rule_ref: pinned_rule_ref(created, rule),
            decision: DISPATCH_DECISION,
            reconcile_trigger: { "event" => "dispatch_before", "reason" => "First fuse attempt dispatch." },
            next_trigger: { "event" => "attempt_created", "reason" => "Awaiting creation." }
          )
          bundle["lead_checkpoints"] << checkpoint
          checkpoint
        else
          terminal_cp = bundle["lead_checkpoints"].find do |candidate|
            candidate["lead_checkpoint_id"] == dispatch_cp_id
          end
          raise "missing fuse terminal checkpoint #{dispatch_cp_id}" unless terminal_cp

          terminal_cp
        end
      created["dispatch_lead_checkpoint_ref"] = cp_ref(dispatch)
      observation = observation_checkpoint(dispatch, created, policy: policy, resolution: rule)
      bundle["lead_checkpoints"] << observation

      failed = event(
        "oevent_#{attempt_id.delete_prefix("oattempt_")}_failed",
        "AttemptFailed",
        created.dig("events", 0, "event_digest"),
        "ended_at" => failed_at,
        "status" => "failed",
        "failure_signal" => basis["stable_signal_identity"]
      )
      created["events"] << failed
      attempt_ref = attempt_event_ref([created], attempt_id)
      provenance = {
        "terminal_attempt_ref" => attempt_ref,
        "outcome_refs" => [
          {
            "kind" => "attempt_event",
            "id" => attempt_id,
            "event_id" => failed["event_id"],
            "digest" => failed["event_digest"]
          }
        ],
        "authoring_checkpoint_ref" => cp_ref(dispatch),
        "prior_attempt_chain" => prior_chain
      }
      terminal = lead_checkpoint(
        cp_id,
        is_genesis: false,
        predecessor_ref: cp_ref(observation),
        predecessor_checkpoint: observation,
        policy: policy,
        session: session,
        agent: agent,
        logical_lead: lead,
        task: task,
        writer_action: "control.checkpoint",
        writer_assertion: writer,
        active_task_ref: task_ref(task),
        selected_work_unit_ref: work_unit_ref(unit),
        attempt_ref: attempt_ref,
        unit: unit,
        proposed_thesis_ref: successor_proposals && successor_proposals[0],
        proposed_rule_ref: successor_proposals && successor_proposals[1],
        delivery: checkpoint_progress("changed", measured: attempt_ref),
        assurance: checkpoint_progress("changed", measured: attempt_ref),
        decision: decision,
        reconcile_trigger: { "event" => "attempt_terminal", "reason" => "Failed round observed." },
        next_trigger: { "event" => next_event, "reason" => "Awaiting the next control event." },
        fingerprint_identity_basis: omit_fingerprint ? nil : basis,
        fingerprint: forged_fingerprint || (omit_fingerprint ? nil : fingerprint),
        fingerprint_supporting_provenance: omit_fingerprint ? nil : provenance,
        retry_override_ref: retry_override_ref
      )
      bundle["lead_checkpoints"] << terminal
      [created, terminal, attempt_ref]
    end

    first, cp1, ref1 = fuse_attempt.call(
      "oattempt_fuseattemptone", "oattempt_implementationtwo", 4, [],
      "olcheckpoint_fuseterminal_one", nil,
      DISPATCH_DECISION, "attempt_created", nil,
      "2026-07-30T05:00:00Z", "2026-07-30T05:15:00Z",
      successor_proposals: [thesis_ref_for_unit, pinned_rule_ref(nil, rules.fetch("oattempt_fuseattempttwo"))]
    )
    second, cp2, ref2 = fuse_attempt.call(
      "oattempt_fuseattempttwo", first["attempt_id"], 5, [ref1],
      "olcheckpoint_fuseterminal_two", "olcheckpoint_fuseterminal_one",
      { "state" => "needs_user", "action" => "escalate", "reason" => "third same-fingerprint Attempt requires a provider-verified task.retry.override" },
      "authority_change", nil,
      "2026-07-30T05:30:00Z", "2026-07-30T05:45:00Z"
    )

    if intermediate_repin
      # An intermediate checkpoint re-pins the FIRST failure event with the
      # same fingerprint: the occurrence chain must count that event exactly
      # once (dedupe by exact terminal event identity), never twice.
      o2 = bundle["lead_checkpoints"].find do |candidate|
        candidate["lead_checkpoint_id"] == "olcheckpoint_created_fuseattempttwo"
      end
      repinned = deep_copy(cp1)
      repinned["lead_checkpoint_id"] = "olcheckpoint_fuserepin_intermediate"
      repinned["predecessor_lead_checkpoint_ref"] = cp_ref(o2)
      %w[delivery_progress assurance_progress].each do |field|
        repinned[field]["predecessor_lead_checkpoint_ref"] = cp_ref(o2)
      end
      repinned = digested(repinned)
      bundle["lead_checkpoints"].insert(
        bundle["lead_checkpoints"].index(cp2),
        repinned
      )
      cp2["predecessor_lead_checkpoint_ref"] = cp_ref(repinned)
      %w[delivery_progress assurance_progress].each do |field|
        cp2[field]["predecessor_lead_checkpoint_ref"] = cp_ref(repinned)
      end
      bundle["lead_checkpoints"][bundle["lead_checkpoints"].index(cp2)] = digested(cp2)
    end

    if override
      record, assertion = retry_override_record(
        bundle,
        task: task,
        unit: unit,
        fingerprint: fingerprint,
        prior_chain: [ref1, ref2],
        authorizing_checkpoint_ref: cp_ref(cp2)
      )
      bundle["authority_assertions"] << assertion
      bundle["authorization_records"] << record
      rule = rule_resolution_for(bundle, "oattempt_fuseattemptthree", unit: unit, role: "coder", index: 6)
      third = attempt(
        "oattempt_fuseattemptthree",
        unit["work_unit_id"],
        "oagent_implementertwo",
        "coder",
        "implementation",
        thesis,
        rule["resolution_id"],
        6,
        policy["content_digest"],
        authorization_record_refs:
          unit.dig("authority_scope", "authorization_record_refs"),
        predecessor_work_unit_attempt_ref: second["attempt_id"],
        started_at: "2026-07-30T06:00:00Z"
      )
      bundle["work_unit_attempts"] << third
      third_dispatch = lead_checkpoint(
        "olcheckpoint_fusethird_dispatch",
        is_genesis: false,
        predecessor_ref: cp_ref(cp2),
        predecessor_checkpoint: cp2,
        policy: policy,
        session: session,
        agent: agent,
        logical_lead: lead,
        task: task,
        writer_action: "control.checkpoint",
        writer_assertion: writer,
        active_task_ref: task_ref(task),
        selected_work_unit_ref: work_unit_ref(unit),
        attempt_ref: ref2,
        unit: unit,
        proposed_thesis_ref: thesis_ref_for_unit,
        proposed_rule_ref: pinned_rule_ref(nil, rule),
        decision: DISPATCH_DECISION,
        reconcile_trigger: { "event" => "authority_change", "reason" => "User retry authority arrived." },
        next_trigger: { "event" => "attempt_created", "reason" => "Awaiting creation." },
        fingerprint_identity_basis: basis,
        fingerprint: fingerprint,
        fingerprint_supporting_provenance: {
          "terminal_attempt_ref" => ref2,
          "outcome_refs" => [
            {
              "kind" => "attempt_event",
              "id" => second["attempt_id"],
              "event_id" => ref2["event_id"],
              "digest" => ref2["event_digest"]
            }
          ],
          "authoring_checkpoint_ref" => cp_ref(cp1),
          "prior_attempt_chain" => [ref1]
        },
        retry_override_ref: {
          "authorization_record_id" => record["authorization_record_id"],
          "content_digest" => record["content_digest"]
        }
      )
      bundle["lead_checkpoints"] << third_dispatch
      third["dispatch_lead_checkpoint_ref"] = cp_ref(third_dispatch)
      bundle["lead_checkpoints"] << observation_checkpoint(
        third_dispatch, third, policy: policy, resolution: rule
      )
    end

    if gap_chain
      cp2["fingerprint_supporting_provenance"]["prior_attempt_chain"] = []
      bundle["lead_checkpoints"][bundle["lead_checkpoints"].index(cp2)] = digested(cp2)
    end

    if fingerprint_without_failure
      # A checkpoint whose pinned attempt is NOT a failure carries fingerprint
      # fields: fails closed.
      observation = bundle["lead_checkpoints"].find do |candidate|
        candidate["lead_checkpoint_id"] == "olcheckpoint_created_implementationone"
      end
      observation["fingerprint"] = fingerprint
      observation["fingerprint_identity_basis"] = basis
      observation["fingerprint_supporting_provenance"] = {
        "terminal_attempt_ref" => attempt_event_ref([bundle["work_unit_attempts"].first], "oattempt_implementationone"),
        "outcome_refs" => [],
        "authoring_checkpoint_ref" => cp_ref(bundle["lead_checkpoints"].first),
        "prior_attempt_chain" => []
      }
      bundle["lead_checkpoints"][bundle["lead_checkpoints"].index(observation)] = digested(observation)
    end

    bundle
  end

  # Provider-verified control.checkpoint_due.observe assertion: canonical
  # scope exact binds project, active policy, control, the scheduled
  # checkpoint ref+digest, the derived deadline and observed_at; asserted_at
  # and the receipt issued_at equal observed_at.
  def checkpoint_due_observation_assertion(bundle, schedule:, deadline:, observed_at:, policy:)
    envelope = {
      "scope_digest" => nil,
      "project_id" => PROJECT_ID,
      "project_policy_revision_ref" => policy_ref(policy),
      "lead_control_id" => CONTROL_ID,
      "scheduled_checkpoint_ref" => cp_ref(schedule),
      "deadline" => deadline,
      "observed_at" => observed_at
    }
    envelope["scope_digest"] = Orbit::V2::ControlAuthority.checkpoint_due_scope_digest(
      project_id: envelope["project_id"],
      policy_ref: envelope["project_policy_revision_ref"],
      lead_control_id: envelope["lead_control_id"],
      scheduled_checkpoint_ref: envelope["scheduled_checkpoint_ref"],
      deadline: envelope["deadline"],
      observed_at: envelope["observed_at"]
    )
    id = "oassert_checkpointdueobserve"
    document = {
      "schema_version" => "orbit-authority-assertion-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "assertion_id" => id,
      "issuer_kind" => "user",
      "issuer_subject" => "project-owner",
      "provider_id" => AUTHORITY_PROVIDER_ID,
      "authority_scope_ref" => envelope["scope_digest"],
      "grants" => [Orbit::V2::ControlAuthority::CHECKPOINT_DUE_OBSERVE_ACTION],
      "asserted_at" => observed_at,
      "checkpoint_due_observation_envelope" => envelope
    }
    document["assertion_digest"] = Orbit::V2::AuthorityVerifier.assertion_digest(document)
    document["verification_receipt"] = FAKE_AUTHORITY_PROVIDER.issue(
      document,
      receipt_id: "oareceipt_checkpointdueobserve",
      issued_at: observed_at
    )
    document
  end

  def retry_override_record(bundle, task:, unit:, fingerprint:, prior_chain:, authorizing_checkpoint_ref:)
    scope_digest = Orbit::V2::ControlAuthority.retry_override_scope_digest(
      project_id: PROJECT_ID,
      task_ref: task_ref(task),
      work_unit_ref: work_unit_ref(unit),
      fingerprint: fingerprint,
      prior_attempt_chain: prior_chain,
      authorizing_checkpoint_ref: authorizing_checkpoint_ref,
      lead_control_id: CONTROL_ID
    )
    assertion = assertion(
      "oassert_retryoverride",
      [Orbit::V2::ControlAuthority::RETRY_OVERRIDE_ACTION],
      "project-owner",
      authority_scope_ref: scope_digest
    )
    envelope = {
      "scope_digest" => scope_digest,
      "project_id" => PROJECT_ID,
      "task_ref" => task_ref(task),
      "work_unit_ref" => work_unit_ref(unit),
      "fingerprint" => fingerprint,
      "prior_attempt_chain" => prior_chain,
      "authorizing_checkpoint_ref" => authorizing_checkpoint_ref,
      "lead_control_id" => CONTROL_ID
    }
    record = digested(
      "schema_version" => "orbit-authorization-record-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "authorization_record_id" => "oauthz_retryoverride",
      "project_policy_revision_id" => POLICY_ID,
      "action" => Orbit::V2::ControlAuthority::RETRY_OVERRIDE_ACTION,
      "subject_ref" => scope_digest,
      "authorization_source_ref" => assertion["assertion_id"],
      "authorization_assertion_digest" => assertion["assertion_digest"],
      "retry_override_envelope" => envelope
    )
    [record, assertion]
  end

  # Verified budget measurements on the first dispatch checkpoint:
  # - mode :overrun  -> policy-default bindings with usage over the ceiling
  # - mode :override -> a consumed test.budget.override record raising the
  #   work_unit_lineage ceiling (inherit: the following observation inherits)
  # - mode :second_consume -> a second checkpoint consumes the same record
  # - mode :inherit_gap -> the inherited observation skips the origin ref
  def budget_override_bundle(mode:, usage_count: 12, usage_lines: 400, override_ceilings: [20, 600], scope: "work_unit_lineage")
    bundle = valid_bundle
    dispatch = bundle["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone"
    end
    index = bundle["lead_checkpoints"].index(dispatch)
    policy = bundle["project_policy_revisions"].first
    task = bundle["task_revisions"].first
    unit = bundle["work_units"].find { |c| c["work_unit_id"] == "owu_implementationone" }
    override_index = scope == "work_unit_lineage" ? 0 : 1
    override_work_unit_ref = scope == "work_unit_lineage" ? work_unit_ref(unit) : nil
    measurements_wu = attested_measurements(
      bundle, usage_count: usage_count, usage_lines: usage_lines,
      task: task, unit: unit, policy: policy, scope: "work_unit_lineage"
    )
    measurements_task = attested_measurements(
      bundle, usage_count: usage_count, usage_lines: usage_lines,
      task: task, unit: unit, policy: policy, scope: "task_lineage"
    )
    predecessor = bundle["lead_checkpoints"][index - 1]
    if mode == :overrun
      wu_binding = Orbit::V2::ControlAuthority.derive_binding(
        scope: "work_unit_lineage",
        project_id: PROJECT_ID,
        control_id: CONTROL_ID,
        policy: policy,
        policy_ref: policy_ref(policy),
        predecessor_binding: predecessor["effective_budget_bindings"].first,
        predecessor_checkpoint_ref: cp_ref(predecessor),
        predecessor_work_unit_ref: predecessor["selected_work_unit_ref"],
        adjustment_payload: nil,
        adjustment_digest: nil,
        override_record: nil,
        override_mode: nil,
        origin_consuming_checkpoint_ref: nil,
        active_task_ref: task_ref(task),
        work_unit_ref: work_unit_ref(unit),
        measurements: measurements_wu
      )
      task_binding = Orbit::V2::ControlAuthority.derive_binding(
        scope: "task_lineage",
        project_id: PROJECT_ID,
        control_id: CONTROL_ID,
        policy: policy,
        policy_ref: policy_ref(policy),
        predecessor_binding: predecessor["effective_budget_bindings"].last,
        predecessor_checkpoint_ref: cp_ref(predecessor),
        predecessor_work_unit_ref: nil,
        adjustment_payload: nil,
        adjustment_digest: nil,
        override_record: nil,
        override_mode: nil,
        origin_consuming_checkpoint_ref: nil,
        active_task_ref: task_ref(task),
        work_unit_ref: nil,
        measurements: measurements_task
      )
      resealed = reseal_checkpoint(
        dispatch,
        policy: policy,
        predecessor_checkpoint: predecessor,
        bindings: [wu_binding, task_binding]
      )
      bundle["lead_checkpoints"][index] = resealed
      return bundle
    end

    record, assertion = budget_override_record(
      bundle,
      task: task,
      unit: unit,
      scope: scope,
      predecessor_checkpoint: bundle["lead_checkpoints"][index - 1],
      predecessor_binding: bundle["lead_checkpoints"][index - 1]["effective_budget_bindings"][override_index],
      ceilings: override_ceilings
    )
    bundle["authority_assertions"] << assertion
    bundle["authorization_records"] << record
    wu_binding = Orbit::V2::ControlAuthority.derive_binding(
      scope: "work_unit_lineage",
      project_id: PROJECT_ID,
      control_id: CONTROL_ID,
      policy: policy,
      policy_ref: policy_ref(policy),
      predecessor_binding: bundle["lead_checkpoints"][index - 1]["effective_budget_bindings"].first,
      predecessor_checkpoint_ref: cp_ref(bundle["lead_checkpoints"][index - 1]),
      predecessor_work_unit_ref: bundle["lead_checkpoints"][index - 1]["selected_work_unit_ref"],
      adjustment_payload: nil,
      adjustment_digest: nil,
      override_record: scope == "work_unit_lineage" ? record : nil,
      override_mode: scope == "work_unit_lineage" ? "consume" : nil,
      origin_consuming_checkpoint_ref: nil,
      active_task_ref: task_ref(task),
      work_unit_ref: override_work_unit_ref,
      measurements: measurements_wu
    )
    task_binding = Orbit::V2::ControlAuthority.derive_binding(
      scope: "task_lineage",
      project_id: PROJECT_ID,
      control_id: CONTROL_ID,
      policy: policy,
      policy_ref: policy_ref(policy),
      predecessor_binding: bundle["lead_checkpoints"][index - 1]["effective_budget_bindings"].last,
      predecessor_checkpoint_ref: cp_ref(bundle["lead_checkpoints"][index - 1]),
      predecessor_work_unit_ref: nil,
      adjustment_payload: nil,
      adjustment_digest: nil,
      override_record: scope == "task_lineage" ? record : nil,
      override_mode: scope == "task_lineage" ? "consume" : nil,
      origin_consuming_checkpoint_ref: nil,
      active_task_ref: task_ref(task),
      work_unit_ref: nil,
      measurements: measurements_task
    )
    resealed = reseal_checkpoint(
      dispatch,
      policy: policy,
      predecessor_checkpoint: bundle["lead_checkpoints"][index - 1],
      bindings: [wu_binding, task_binding]
    )
    bundle["lead_checkpoints"][index] = resealed
    dispatch = resealed

    # The consumed override changes the dispatch checkpoint content, so the
    # immediate observation must be rebuilt against the resealed dispatch ref
    # (its bindings revert to policy default unless explicitly inherited).
    created_attempt = bundle["work_unit_attempts"][0]
    assigned_rule_id = created_attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id")
    resolution = bundle["rule_resolution_artifacts"].find do |candidate|
      candidate["resolution_id"] == assigned_rule_id
    end
    following = observation_checkpoint(dispatch, created_attempt, policy: policy, resolution: resolution)

    if mode == :second_consume
      following_bindings = deep_copy(dispatch["effective_budget_bindings"])
      if scope == "task_lineage"
        # Cross-scope replay: the work_unit binding replays the task_lineage
        # override record; the layers must never mix.
        task_source = following_bindings[1]["user_override_source"]
        task_ceilings = [
          following_bindings[1]["effective_test_count"],
          following_bindings[1]["effective_test_code_lines"]
        ]
        following_bindings[0] = deep_copy(following_bindings[1])
        following_bindings[0]["budget_scope_type"] = "work_unit_lineage"
        following_bindings[0]["user_override_source"] = task_source
        following_bindings[0]["effective_test_count"] = task_ceilings[0]
        following_bindings[0]["effective_test_code_lines"] = task_ceilings[1]
        following_bindings[1] = Orbit::V2::ControlAuthority.derive_binding(
          scope: "task_lineage",
          project_id: PROJECT_ID,
          control_id: CONTROL_ID,
          policy: policy,
          policy_ref: policy_ref(policy),
          predecessor_binding: nil,
          predecessor_checkpoint_ref: nil,
          predecessor_work_unit_ref: nil,
          adjustment_payload: nil,
          adjustment_digest: nil,
          override_record: nil,
          override_mode: nil,
          origin_consuming_checkpoint_ref: nil,
          active_task_ref: task_ref(task),
          work_unit_ref: nil,
          measurements: measurements_task
        )
      end
      following = reseal_checkpoint(
        following,
        policy: policy,
        predecessor_checkpoint: dispatch,
        bindings: following_bindings,
        attempt: created_attempt,
        resolution: resolution
      )
    elsif mode == :inherit || mode == :inherit_gap
      inherited = deep_copy(dispatch["effective_budget_bindings"])
      inherited_source = inherited[override_index]["user_override_source"]
      inherited[override_index]["user_override_source"] = {
        "mode" => "inherit",
        "authorization_record_ref" => inherited_source["authorization_record_ref"],
        "origin_consuming_checkpoint_ref" =>
          (mode == :inherit_gap ? nil : cp_ref(dispatch))
      }
      following = reseal_checkpoint(
        following,
        policy: policy,
        predecessor_checkpoint: dispatch,
        bindings: inherited,
        attempt: created_attempt,
        resolution: resolution
      )
    end
    bundle["lead_checkpoints"][index + 1] = following
    created_attempt["dispatch_lead_checkpoint_ref"] = cp_ref(dispatch)
    repin_lineage_tail(bundle, index + 2)
    bundle
  end

  # After an in-place checkpoint reseal changes its content digest, every
  # later lineage checkpoint must re-pin the exact new predecessor ref, re-derive
  # its budget bindings against the resealed predecessor (an adjustment
  # inherits down the continuous lineage), and every Attempt dispatch ref must
  # re-pin its checkpoint's new digest.
  def repin_lineage_tail(bundle, start_index, measurements_by_scope: nil, measurements_for: nil)
    policy = bundle["project_policy_revisions"].first
    attempts = bundle["work_unit_attempts"].to_h { |attempt| [attempt["attempt_id"], attempt] }
    resolutions = bundle["rule_resolution_artifacts"].to_h do |resolution|
      [resolution["resolution_id"], resolution]
    end
    (start_index...bundle["lead_checkpoints"].length).each do |tail_index|
      tail = bundle["lead_checkpoints"][tail_index]
      tail["predecessor_lead_checkpoint_ref"] = cp_ref(bundle["lead_checkpoints"][tail_index - 1])
      %w[delivery_progress assurance_progress].each do |field|
        tail[field]["predecessor_lead_checkpoint_ref"] = tail["predecessor_lead_checkpoint_ref"]
      end
      pinned = (ref = tail["current_or_terminal_attempt_ref"]) && attempts[ref["attempt_id"]]
      resolution = pinned && resolutions[
        pinned.dig("events", 0, "assignment", "assigned_rule_resolution_id")
      ]
      bundle["lead_checkpoints"][tail_index] = reseal_checkpoint(
        tail,
        policy: policy,
        predecessor_checkpoint: bundle["lead_checkpoints"][tail_index - 1],
        measurements_by_scope: measurements_for ? measurements_for.call(tail) : measurements_by_scope,
        attempt: pinned,
        resolution: resolution
      )
    end
    checkpoints = bundle["lead_checkpoints"].to_h do |candidate|
      [candidate["lead_checkpoint_id"], candidate]
    end
    bundle["work_unit_attempts"].each do |attempt|
      ref = attempt["dispatch_lead_checkpoint_ref"]
      next unless ref.is_a?(Hash)

      dispatch = checkpoints[ref["lead_checkpoint_id"]]
      attempt["dispatch_lead_checkpoint_ref"] = cp_ref(dispatch) if dispatch
    end
  end

  def budget_override_record(bundle, task:, unit:, scope:, predecessor_checkpoint:, predecessor_binding:, ceilings:)
    scope_digest = Orbit::V2::ControlAuthority.budget_override_scope_digest(
      budget_scope_type: scope,
      project_id: PROJECT_ID,
      policy_ref: policy_ref(bundle["project_policy_revisions"].first),
      task_ref: task_ref(task),
      work_unit_ref: scope == "work_unit_lineage" ? work_unit_ref(unit) : nil,
      authorizing_checkpoint_ref: cp_ref(predecessor_checkpoint),
      predecessor_binding_digest: Orbit::V2::ControlAuthority.binding_digest(predecessor_binding),
      effective_test_count: ceilings[0],
      effective_test_code_lines: ceilings[1],
      lead_control_id: CONTROL_ID
    )
    assertion = assertion(
      "oassert_budgetoverride",
      [Orbit::V2::ControlAuthority::BUDGET_OVERRIDE_ACTION],
      "project-owner",
      authority_scope_ref: scope_digest
    )
    envelope = {
      "scope_digest" => scope_digest,
      "budget_scope_type" => scope,
      "project_id" => PROJECT_ID,
      "project_policy_revision_ref" => policy_ref(bundle["project_policy_revisions"].first),
      "task_ref" => task_ref(task),
      "work_unit_ref" => scope == "work_unit_lineage" ? work_unit_ref(unit) : nil,
      "authorizing_checkpoint_ref" => cp_ref(predecessor_checkpoint),
      "predecessor_binding_digest" => Orbit::V2::ControlAuthority.binding_digest(predecessor_binding),
      "effective_test_count" => ceilings[0],
      "effective_test_code_lines" => ceilings[1],
      "lead_control_id" => CONTROL_ID
    }
    record = digested(
      "schema_version" => "orbit-authorization-record-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "authorization_record_id" => "oauthz_budgetoverride",
      "project_policy_revision_id" => POLICY_ID,
      "action" => Orbit::V2::ControlAuthority::BUDGET_OVERRIDE_ACTION,
      "subject_ref" => scope_digest,
      "authorization_source_ref" => assertion["assertion_id"],
      "authorization_assertion_digest" => assertion["assertion_digest"],
      "budget_override_envelope" => envelope
    )
    [record, assertion]
  end

  # A wall-clock fallback schedule checkpoint (awaits checkpoint_due with the
  # exact active-policy pin, pins no attempt) followed by the timer round:
  # checkpoint_due reconciles normally and the resulting dispatch decision is
  # observed by a real successor Attempt, proving the timer only ever wakes
  # reconcile. bad_fallback/missing_schedule/unpinned_policy mutate the
  # schedule for negative cases.
  def fallback_bundle(bad_fallback: false, missing_schedule: false, unpinned_policy: false, deadline_drift: false, early_due: false, unrelated_basis: false)
    bundle = valid_bundle
    review = bundle["work_unit_attempts"].find { |c| c["attempt_id"] == "oattempt_independentreview" }
    review["events"] << event(
      "oevent_reviewfallbackterminal",
      "AttemptCompleted",
      review.dig("events", 0, "event_digest"),
      "ended_at" => "2026-07-30T01:30:00Z",
      "status" => "completed"
    )
    unit = bundle["work_units"].find { |c| c["work_unit_id"] == "owu_independentreview" }
    policy = bundle["project_policy_revisions"].first
    session = bundle["lead_sessions"].last
    agent = bundle["agent_instances"].find { |c| c["agent_instance_id"] == session["agent_instance_id"] }
    lead = bundle["logical_leads"].first
    task = bundle["task_revisions"].first
    writer = bundle["authority_assertions"].find { |c| c["assertion_id"] == "oassert_controlwriter" }
    tip = bundle["lead_checkpoints"].last

    # The schedule basis is the exact Attempt event ALREADY pinned by the
    # schedule's predecessor observation checkpoint (review creation); the
    # deadline is deterministically derived from its provider-recorded
    # recorded_at plus the exact active-policy interval (never free text,
    # never a future or unobserved event).
    pinned_ref = tip["current_or_terminal_attempt_ref"]
    created_event = review["events"].find { |candidate| candidate["event_id"] == pinned_ref["event_id"] }
    schedule_basis_ref = {
      "kind" => "attempt_event",
      "id" => pinned_ref["attempt_id"],
      "event_id" => pinned_ref["event_id"],
      "digest" => pinned_ref["event_digest"]
    }
    if unrelated_basis
      # The review TERMINAL event exists in the bundle but is pinned only by
      # the DUE checkpoint (a descendant), never by the schedule checkpoint
      # or a strict ancestor: a future/unobserved basis must fail closed.
      terminal = review["events"].last
      schedule_basis_ref = {
        "kind" => "attempt_event",
        "id" => review["attempt_id"],
        "event_id" => terminal["event_id"],
        "digest" => terminal["event_digest"]
      }
    end
    interval = policy.dig("orchestration_policy", "wall_clock_fallback", "interval_seconds")
    deadline = Orbit::V2::ControlAuthority.fallback_deadline(
      recorded_at: created_event["recorded_at"],
      interval_seconds: interval
    )
    if deadline_drift
      deadline = "2026-07-30T05:00:00Z"
    end
    fallback_pin = {
      "source_kind" => "policy",
      "deadline" => deadline,
      "source_ref" => {
        "id" => policy["policy_revision_id"],
        "content_digest" => policy["content_digest"]
      },
      "schedule_basis_ref" => schedule_basis_ref
    }
    if bad_fallback
      fallback_pin = {
        "source_kind" => "authorization_record",
        "deadline" => deadline,
        "source_ref" => { "id" => "oauthz_absentfallback", "content_digest" => "sha256:#{'a' * 64}" },
        "schedule_basis_ref" => schedule_basis_ref
      }
    elsif unpinned_policy
      fallback_pin = {
        "source_kind" => "policy",
        "deadline" => deadline,
        "source_ref" => {
          "id" => policy["policy_revision_id"],
          "content_digest" => "sha256:#{'a' * 64}"
        },
        "schedule_basis_ref" => schedule_basis_ref
      }
    end
    schedule = lead_checkpoint(
      "olcheckpoint_fallbackschedule",
      is_genesis: false,
      predecessor_ref: cp_ref(tip),
      predecessor_checkpoint: tip,
      policy: policy,
      session: session,
      agent: agent,
      logical_lead: lead,
      task: task,
      writer_action: "control.checkpoint",
      writer_assertion: writer,
      active_task_ref: task_ref(task),
      selected_work_unit_ref: work_unit_ref(unit),
      unit: unit,
      wall_clock_fallback: missing_schedule ? nil : fallback_pin,
      decision: { "state" => "blocked", "action" => "continue", "reason" => "attempt creation observed" },
      reconcile_trigger: { "event" => "attempt_created", "reason" => "Observation round." },
      next_trigger: missing_schedule ? { "event" => "attempt_terminal", "reason" => "No timer scheduled." } :
        { "event" => "checkpoint_due", "reason" => "Scheduled wall-clock fallback." }
    )
    bundle["lead_checkpoints"] << schedule

    # The successor's rule resolution is part of the due dispatch proposal
    # (the closure basis is frozen at dispatch, never chosen by the Attempt).
    rule = rule_resolution_for(bundle, "oattempt_reviewsuccessor", unit: unit, role: "reviewer", index: 7)

    # The timer occurrence is proven only by a provider-verified
    # control.checkpoint_due.observe assertion bound to the exact schedule
    # checkpoint ref+digest, the derived deadline and observed_at; the review
    # terminal at 01:30 is after the deadline 01:03.
    terminal_event = review["events"].last
    due_observed_at = early_due ? created_event["recorded_at"] : terminal_event["recorded_at"]
    due_assertion = checkpoint_due_observation_assertion(
      bundle,
      schedule: schedule,
      deadline: deadline,
      observed_at: due_observed_at,
      policy: policy
    )
    bundle["authority_assertions"] << due_assertion
    due = lead_checkpoint(
      "olcheckpoint_fallbackdue",
      is_genesis: false,
      predecessor_ref: cp_ref(schedule),
      predecessor_checkpoint: schedule,
      policy: policy,
      session: session,
      agent: agent,
      logical_lead: lead,
      task: task,
      writer_action: "control.checkpoint",
      writer_assertion: writer,
      active_task_ref: task_ref(task),
      selected_work_unit_ref: work_unit_ref(unit),
      attempt_ref: attempt_event_ref([review], review["attempt_id"]),
      checkpoint_due_observation_ref: {
        "assertion_id" => due_assertion["assertion_id"],
        "assertion_digest" => due_assertion["assertion_digest"]
      },
      unit: unit,
      proposed_thesis_ref: {
        "change_thesis_id" => thesis_for(bundle, unit)["change_thesis_id"],
        "content_digest" => thesis_for(bundle, unit)["content_digest"]
      },
      proposed_rule_ref: pinned_rule_ref(nil, rule),
      decision: DISPATCH_DECISION,
      reconcile_trigger: { "event" => "checkpoint_due", "reason" => "Wall-clock fallback fired." },
      next_trigger: { "event" => "attempt_created", "reason" => "Awaiting creation." }
    )
    bundle["lead_checkpoints"] << due

    successor = attempt(
      "oattempt_reviewsuccessor",
      unit["work_unit_id"],
      rule.dig("identity", "agent_instance_id"),
      "reviewer",
      "review",
      thesis_for(bundle, unit),
      rule["resolution_id"],
      7,
      policy["content_digest"],
      authorization_record_refs: unit.dig("authority_scope", "authorization_record_refs"),
      predecessor_work_unit_attempt_ref: review["attempt_id"],
      started_at: "2026-07-30T04:00:00Z"
    )
    successor["dispatch_lead_checkpoint_ref"] = cp_ref(due)
    bundle["work_unit_attempts"] << successor
    bundle["lead_checkpoints"] << observation_checkpoint(
      due, successor, policy: policy, resolution: rule
    )
    bundle
  end

  # An in-ceiling test.budget.adjust on the first dispatch checkpoint with
  # the canonical adjustment digest and derived binding. mode :valid keeps
  # the payload consistent; :over_ceiling requests ceilings above the policy
  # lead ceiling; :forged_digest pins a digest that does not match the
  # payload; :absent_digest pins a digest without any payload.
  def adjustment_bundle(mode: :valid)
    bundle = valid_bundle
    dispatch = bundle["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone"
    end
    index = bundle["lead_checkpoints"].index(dispatch)
    policy = bundle["project_policy_revisions"].first
    task = bundle["task_revisions"].first
    unit = bundle["work_units"].find { |c| c["work_unit_id"] == "owu_implementationone" }
    predecessor = bundle["lead_checkpoints"][index - 1]
    predecessor_binding = predecessor["effective_budget_bindings"].first
    new_ceilings =
      mode == :over_ceiling ? { "test_count" => 25, "test_code_lines" => 700 } :
        { "test_count" => 15, "test_code_lines" => 450 }
    payload = {
      "budget_scope_type" => "work_unit_lineage",
      "project_policy_revision_ref" => policy_ref(policy),
      "predecessor_lead_checkpoint_ref" => cp_ref(predecessor),
      "predecessor_binding_digest" => Orbit::V2::ControlAuthority.binding_digest(predecessor_binding),
      "old_effective_budget" => {
        "test_count" => predecessor_binding["effective_test_count"],
        "test_code_lines" => predecessor_binding["effective_test_code_lines"]
      },
      "new_effective_budget" => new_ceilings,
      "supporting_refs" => []
    }
    adjustment_digest = Orbit::V2::ControlAuthority.budget_adjustment_digest(payload)
    if mode == :forged_digest
      adjustment_digest = "sha256:#{'a' * 64}"
    elsif mode == :absent_digest
      payload = nil
      adjustment_digest = "sha256:#{'a' * 64}"
    end
    if mode == :valid || mode == :unverified_adjust
      # Slice 2 phase boundary: a lead_adjustment in effect may never rest on
      # unverified pending numbers — the adjusted scope's current measurements
      # must be provider-attested verified. :unverified_adjust keeps the same
      # valid payload with pending measurements for the negative case.
      attested_wu = attested_measurements(
        bundle, usage_count: 12, usage_lines: 400,
        task: task, unit: unit, policy: policy, scope: "work_unit_lineage"
      )
      wu_measurements = mode == :unverified_adjust ? unverified_pending_measurements : attested_wu
      wu_binding = Orbit::V2::ControlAuthority.derive_binding(
        scope: "work_unit_lineage",
        project_id: PROJECT_ID,
        control_id: CONTROL_ID,
        policy: policy,
        policy_ref: policy_ref(policy),
        predecessor_binding: predecessor["effective_budget_bindings"].first,
        predecessor_checkpoint_ref: cp_ref(predecessor),
        predecessor_work_unit_ref: predecessor["selected_work_unit_ref"],
        adjustment_payload: payload,
        adjustment_digest: adjustment_digest,
        override_record: nil,
        override_mode: nil,
        origin_consuming_checkpoint_ref: nil,
        active_task_ref: task_ref(bundle["task_revisions"].first),
        work_unit_ref: dispatch["selected_work_unit_ref"],
        measurements: wu_measurements
      )
      task_binding = Orbit::V2::ControlAuthority.derive_binding(
        scope: "task_lineage",
        project_id: PROJECT_ID,
        control_id: CONTROL_ID,
        policy: policy,
        policy_ref: policy_ref(policy),
        predecessor_binding: predecessor["effective_budget_bindings"].last,
        predecessor_checkpoint_ref: cp_ref(predecessor),
        predecessor_work_unit_ref: nil,
        adjustment_payload: nil,
        adjustment_digest: nil,
        override_record: nil,
        override_mode: nil,
        origin_consuming_checkpoint_ref: nil,
        active_task_ref: task_ref(bundle["task_revisions"].first),
        work_unit_ref: nil,
        measurements: unverified_pending_measurements
      )
      resealed = reseal_checkpoint(
        dispatch,
        policy: policy,
        predecessor_checkpoint: predecessor,
        budget_adjustment: payload,
        bindings: [wu_binding, task_binding]
      )
      resealed["budget_adjustment_digest"] = adjustment_digest
      resealed = OrbitV2FixtureFactory.digested(resealed)
      bundle["lead_checkpoints"][index] = resealed
      # The observation after the adjusted dispatch inherits the adjustment
      # along the exact lineage; its adjusted scope also keeps verified
      # measurements. Rebuild it against the resealed dispatch ref.
      created_attempt = bundle["work_unit_attempts"][0]
      assigned_rule_id = created_attempt.dig("events", 0, "assignment", "assigned_rule_resolution_id")
      resolution = bundle["rule_resolution_artifacts"].find do |candidate|
        candidate["resolution_id"] == assigned_rule_id
      end
      obs_wu = Orbit::V2::ControlAuthority.derive_binding(
        scope: "work_unit_lineage",
        project_id: PROJECT_ID,
        control_id: CONTROL_ID,
        policy: policy,
        policy_ref: policy_ref(policy),
        predecessor_binding: wu_binding,
        predecessor_checkpoint_ref: cp_ref(resealed),
        predecessor_work_unit_ref: resealed["selected_work_unit_ref"],
        adjustment_payload: nil,
        adjustment_digest: nil,
        override_record: nil,
        override_mode: nil,
        origin_consuming_checkpoint_ref: nil,
        active_task_ref: task_ref(bundle["task_revisions"].first),
        work_unit_ref: dispatch["selected_work_unit_ref"],
        measurements: wu_measurements
      )
      bundle["lead_checkpoints"][index + 1] = reseal_checkpoint(
        observation_checkpoint(resealed, created_attempt, policy: policy, resolution: resolution),
        policy: policy,
        predecessor_checkpoint: resealed,
        bindings: [obs_wu, task_binding],
        attempt: created_attempt,
        resolution: resolution
      )
      created_attempt["dispatch_lead_checkpoint_ref"] = cp_ref(resealed)
      repin_lineage_tail(
        bundle, index + 2,
        measurements_for: lambda do |tail|
          selected = tail["selected_work_unit_ref"]
          if selected && selected["work_unit_id"] == unit["work_unit_id"]
            { "work_unit_lineage" => wu_measurements }
          end
        end
      )
    else
      # Negative modes: the invalid payload/digest is recorded on the
      # checkpoint as written; the Validator must reject it (the derivation
      # raises or the digest does not recompute).
      dispatch["test_budget_adjust"] = payload
      dispatch["budget_adjustment_digest"] = adjustment_digest
      bundle["lead_checkpoints"][index] = OrbitV2FixtureFactory.digested(dispatch)
    end
    bundle
  end

  # Mutate one of the increment-4 checkpoint authority fields for negative
  # digest-chain cases: :plan_digest, :basis_digest, :binding_order.
  def digest_chain_mutation_bundle(mutation)
    bundle = valid_bundle
    checkpoint = bundle["lead_checkpoints"].find do |candidate|
      candidate["lead_checkpoint_id"] == "olcheckpoint_dispatch_implone"
    end
    index = bundle["lead_checkpoints"].index(checkpoint)
    case mutation
    when :plan_digest
      checkpoint["effective_verification_plan_digest"] = "sha256:#{'b' * 64}"
    when :basis_digest
      checkpoint["closure_basis_digest"] = "sha256:#{'c' * 64}"
    when :binding_order
      checkpoint["effective_budget_bindings"] = checkpoint["effective_budget_bindings"].reverse
    end
    bundle["lead_checkpoints"][index] = OrbitV2FixtureFactory.digested(checkpoint)
    bundle
  end
end
