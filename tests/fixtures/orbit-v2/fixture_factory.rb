# frozen_string_literal: true

require "openssl"

require_relative "../../../lib/orbit/v2/authority_verifier"
require_relative "../../../lib/orbit/v2/canonical_json"
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

  def valid_bundle
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
        }
      ]
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
      "evidence_requirements" => [
        { "evidence_requirement_id" => "evreq_contract_test", "text" => "Contract tests pass." }
      ],
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

    units, theses = make_units_and_theses
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
        session: last ? successor_session : nil, cp_id: last ? SUCCESSOR_CHECKPOINT_ID : nil)
      predecessor_checkpoint = dispatch_checkpoints.last
    end
    control_registries = [control_registry(policy: policy, genesis_checkpoint: genesis_checkpoint, task: task,
      writer_assertion: writer_assertion)]
    all_checkpoints = [genesis_checkpoint, *dispatch_checkpoints]

    evidence = [
      implementation_evidence(
        "oevr_implementationone",
        attempts[0],
        resolutions[0],
        units[0]["initial_change_thesis_ref"],
        ["lib/orbit/v2/validator.rb"]
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
      "blocking" => true,
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

  def make_units_and_theses
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
        "evidence_requirement_refs" => ["evreq_contract_test"],
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
    active_task_ref: nil, selected_work_unit_ref: nil, attempt_ref: nil,
    delivery: nil, assurance: nil, decision: nil, reconcile_trigger: nil, next_trigger: nil
  )
    digested(
      "schema_version" => "orbit-lead-checkpoint-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => PROJECT_ID,
      "object_type" => "lead_checkpoint",
      "lead_checkpoint_id" => id,
      "lead_control_id" => CONTROL_ID,
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
      "task_queue" => [task_ref(task)],
      "active_task_ref" => active_task_ref,
      "selected_work_unit_ref" => selected_work_unit_ref,
      "current_or_terminal_attempt_ref" => attempt_ref,
      "assessments" => checkpoint_assessments(active_task_ref, selected_work_unit_ref, attempt_ref),
      "delivery_progress" => (delivery || checkpoint_progress("not_assessed")).merge(
        "predecessor_lead_checkpoint_ref" => predecessor_ref
      ),
      "assurance_progress" => (assurance || checkpoint_progress("not_assessed")).merge(
        "predecessor_lead_checkpoint_ref" => predecessor_ref
      ),
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
    checkpoint = lead_checkpoint(
      "olcheckpoint_dispatch_#{attempt["attempt_id"].delete_prefix("oattempt_")}",
      is_genesis: false,
      predecessor_ref: cp_ref(tip),
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
      decision: DISPATCH_DECISION
    )
    bundle["lead_checkpoints"] << checkpoint
    attempt["dispatch_lead_checkpoint_ref"] = cp_ref(checkpoint)
    bundle["lead_checkpoints"] << observation_checkpoint(checkpoint, attempt)
    checkpoint
  end

  # The dispatch proof is constructive: the successor observes the exact AttemptCreated event.
  def observation_checkpoint(dispatch, attempt, session: nil, cp_id: nil)
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
    acceptance_recorded_at: "2026-07-30T00:02:00Z"
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
        "evidence_requirement_results" => [
          {
            "evidence_requirement_id" => "evreq_contract_test",
            "status" => "pass",
            "evidence_refs" => [verification_ref]
          }
        ],
        "change_thesis_status" => {
          "status" => "supported",
          "evidence_refs" => [change_ref]
        },
        "changed_paths" => paths,
        "verification_refs" => [verification_ref],
        "assumptions_changed" => [],
        "known_gaps" => []
      },
      "submission_artifact_refs" => [change_claim, verification_claim],
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
end
