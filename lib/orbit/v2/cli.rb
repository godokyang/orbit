# frozen_string_literal: true

require "fileutils"
require "optparse"
require "time"
require "yaml"

require_relative "cli/document_factory"
require_relative "control_store"
require_relative "evidence_store"
require_relative "gate_engine"
require_relative "gate_fact_store"
require_relative "local_provider"
require_relative "policy_store"
require_relative "protocol_root"
require_relative "task_store"

module Orbit
  module V2
    # Minimal real CLI path (Slice 6 phase D, workorder D.1/D.2/D.3.1).
    # Eight subcommands under `orbit v2`; each performs exactly one
    # controlled write boundary (or one read-only projection) against the
    # task-scoped stores, with all receipts issued by the local providers.
    #
    # NOT provided (see workorder D.2 answer 4): policy rotation, control
    # -flow commands (retry/fuse/budget override/checkpoint-due), cross-task
    # queries, key rotation, session replacement, waived findings.
    module Cli
      module_function

      class UsageError < StandardError; end

      ROLES = {
        "implementer" => { "role" => "coder", "purpose" => "implementation", "kind" => "implementation" },
        "reviewer" => { "role" => "reviewer", "purpose" => "review", "kind" => "evaluation" }
      }.freeze

      def run(argv)
        command = argv.shift
        case command
        when "init" then init(argv)
        when "task" then task(argv)
        when "dispatch" then dispatch(argv)
        when "evidence" then evidence(argv)
        when "gate" then gate(argv)
        when "finding" then finding(argv)
        when "complete" then complete(argv)
        when "status" then status(argv)
        when nil, "-h", "--help", "help"
          puts USAGE
          0
        else
          raise UsageError, "unknown v2 command: #{command}"
        end
      rescue UsageError => e
        warn("usage error: #{e.message}")
        2
      rescue ContractError => e
        warn("error #{e.code}: #{e.message}")
        1
      rescue Errno::ENOENT => e
        warn("error file_missing: #{e.message}")
        1
      end

      def context
        project_root = Dir.pwd
        marker = ProtocolRoot.read(project_root: project_root)
        verifiers = LocalProvider.verifiers(project_root)
        policy = PolicyStore.new(active_root: File.join(project_root, ".orbit"))
          .resolve(pinned_genesis_ref: marker["project_policy_genesis_ref"],
                   authority_verifier: verifiers[0])
          .fetch("active_policy")
        { project_root: project_root, marker: marker, verifiers: verifiers,
          policy: policy }
      end

      # Strictly-increasing logical clock persisted per task scope: every
      # issued timestamp is max(now, last+1s) so records written by later
      # commands can never precede earlier ones.
      def task_clock(project_root, task_id)
        lambda do
          now = Time.now.utc
          path = task_id && File.join(project_root, ".orbit", V2::TASK_SCOPES_SEGMENT,
                                      task_id, ".cli-clock")
          if path && File.file?(path)
            last = Time.iso8601(File.read(path).strip)
            now = last + 1 if now <= last
          end
          if path
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, now.utc.iso8601(6))
          end
          now.utc.iso8601(6)
        end
      end

      def with_task_factory(base, task_id)
        key = LocalProvider.load_key(base[:project_root])
        clock = task_clock(base[:project_root], task_id)
        factory = DocumentFactory.new(
          project_id: base[:marker]["project_id"], policy: base[:policy],
          authority: LocalProvider::Authority.new(key["secret"]),
          runtime: LocalProvider::Runtime.new(key["secret"]),
          lifecycle: LocalProvider::Lifecycle.new(key["secret"]),
          issuer_subject: LocalProvider.issuer_subject(base[:project_root]),
          clock: clock, project_root: base[:project_root]
        )
        factory
      end

      def orbit_root(base)
        File.join(base[:project_root], ".orbit")
      end


      def task_store(base, task_id)
        TaskStore.new(active_root: orbit_root(base), task_id: task_id)
      end

      def control_store(base, task_id)
        ControlStore.new(active_root: orbit_root(base), task_id: task_id)
      end

      def evidence_store(base, task_id)
        EvidenceStore.new(active_root: orbit_root(base), task_id: task_id)
      end

      def gate_store(base, task_id)
        GateFactStore.new(active_root: orbit_root(base), task_id: task_id)
      end

      def control_id_for(base, task_id)
        control_store(base, task_id).records.each do |payload|
          next unless payload.is_a?(Hash) && payload["registry"]

          return payload["registry"]["lead_control_id"]
        end
        raise ContractError.new("v2_cli_control_missing",
          "no control genesis exists in the task scope",
          path: "task-scopes/#{task_id}")
      end

      def resolved_task(base, task_id)
        task_store(base, task_id).resolve(task_id: task_id,
                                          authority_verifier: base[:verifiers][0])
      end

      def resolved_control(base, task_id)
        control_store(base, task_id).resolve(
          control_id: control_id_for(base, task_id),
          authority_verifier: base[:verifiers][0],
          runtime_identity_verifier: base[:verifiers][1],
          lifecycle_verifier: base[:verifiers][2]
        )
      end

      def tip_revision(task_result)
        Array(task_result["task_revisions"]).max_by { |t| t["revision_number"] }
      end

      def units_for_revision(task_result, revision)
        Array(task_result["all_work_units"])
          .select { |u| u["task_revision_id"] == revision["task_revision_id"] }
      end

      def gate_for_revision(task_result, revision)
        Array(task_result["all_gate_requirements"])
          .find { |g| g["task_revision_id"] == revision["task_revision_id"] }
      end

      def thesis_for(task_result, unit)
        Array(task_result["all_change_theses"])
          .find { |t| t["work_unit_id"] == unit["work_unit_id"] }
      end

      def active_attempt(control_result)
        Array(control_result["attempts"]).find do |attempt|
          attempt.dig("events", -1, "event_type") == "AttemptCreated"
        end
      end

      def terminal_attempt(control_result)
        Array(control_result["attempts"]).reverse.find do |attempt|
          %w[AttemptCompleted AttemptFailed AttemptBlocked AttemptCancelled]
            .include?(attempt.dig("events", -1, "event_type"))
        end
      end

      # -- commands ------------------------------------------------------------

      def init(argv)
        project_id = argv.shift
        raise UsageError, "usage: orbit v2 init <project_id>" unless project_id
        raise UsageError, "invalid project_id #{project_id.inspect}" unless Identifiers.valid?("project_id", project_id)

        project_root = Dir.pwd
        key_state = LocalProvider.ensure_key(project_root)
        key = LocalProvider.load_key(project_root)
        verifiers = LocalProvider.verifiers(project_root)
        factory = DocumentFactory.new(
          project_id: project_id, policy: nil,
          authority: LocalProvider::Authority.new(key["secret"]),
          runtime: LocalProvider::Runtime.new(key["secret"]),
          lifecycle: LocalProvider::Lifecycle.new(key["secret"]),
          issuer_subject: key["issuer_subject"],
          clock: -> { Time.now.utc.iso8601(6) }, project_root: project_root
        )
        policy_revision_id = "opolicy_#{DocumentFactory.hex}"
        assertion_id = "oassert_#{DocumentFactory.hex}"
        policy, assertion = factory.policy_genesis_pair(policy_revision_id, assertion_id)
        FileUtils.mkdir_p(File.join(project_root, ".orbit"))
        PolicyStore.new(active_root: File.join(project_root, ".orbit"))
          .genesis(policy: policy, assertion: assertion, authority_verifier: verifiers[0])
        created = ProtocolRoot.create(project_root: project_root, project_id: project_id,
          policy_genesis_ref: {
            "policy_revision_id" => policy["policy_revision_id"],
            "content_digest" => policy["content_digest"]
          })
        ProtocolRoot.preflight(project_root: project_root, expected_project_id: project_id,
          authority_verifier: verifiers[0])
        puts("project_id: #{project_id}")
        puts("policy_revision_id: #{policy['policy_revision_id']}")
        puts("protocol_root: #{File.join(project_root, '.orbit', 'protocol.yaml')} (#{created})")
        puts("local_provider_key: #{LocalProvider.key_path(project_root)} (#{key_state})")
        warn("note: the local provider is a consistency mechanism, not a security boundary; keep the key file backed up — losing it makes the project unverifiable.")
        0
      end

      def task(argv)
        sub = argv.shift
        raise UsageError, "usage: orbit v2 task start <task_id> --def FILE" unless sub == "start"
        task_id = argv.shift
        raise UsageError, "task_id required" unless task_id
        raise UsageError, "invalid task_id #{task_id.inspect}" unless Identifiers.valid?("task_id", task_id)
        options = parse_options(argv) do |opts, hash|
          opts.on("--def FILE") { |v| hash["def"] = v }
        end
        raise UsageError, "--def FILE required" unless options["def"]

        base = context
        defn = YAML.safe_load(File.binread(options["def"]), permitted_classes: [], aliases: false)
        raise ContractError.new("v2_cli_def_invalid", "task definition must be a mapping",
          path: "task_def") unless defn.is_a?(Hash)

        factory = with_task_factory(base, task_id)
        records = factory.task_records(task_id: task_id, task_def: defn)
        task, gates, units, theses, assertions, authorizations, lead = records
        task_store(base, task_id).genesis(task: task, gate_requirements: gates,
          work_units: units, change_theses: theses, authority_assertions: assertions,
          authorization_records: authorizations, logical_lead: lead,
          authority_verifier: base[:verifiers][0])
        control_id = "olcontrol_#{DocumentFactory.hex}"
        control_records = factory.control_genesis_records(task: task, lead: lead,
                                                           control_id: control_id)
        control_store(base, task_id).genesis(registry: control_records[0],
          session: control_records[1], checkpoint: control_records[2],
          agent: control_records[3], assertion: control_records[4],
          authority_verifier: base[:verifiers][0],
          runtime_identity_verifier: base[:verifiers][1],
          lifecycle_verifier: base[:verifiers][2])
        puts("task_id: #{task_id}")
        puts("task_revision_id: #{task['task_revision_id']}")
        puts("control_id: #{control_id}")
        puts("genesis_checkpoint_id: #{control_records[2]['lead_checkpoint_id']}")
        puts("units: #{units.map { |u| u['work_unit_id'] }.join(', ')}")
        0
      end

      def dispatch(argv)
        options = parse_options(argv) do |opts, hash|
          opts.on("--task ID") { |v| hash["task"] = v }
          opts.on("--role ROLE") { |v| hash["role"] = v }
          opts.on("--rule PATH") { |v| (hash["rules"] ||= []) << v }
        end
        task_id = options.fetch("task")
        role_key = options.fetch("role")
        spec = ROLES.fetch(role_key) { raise UsageError, "role must be implementer or reviewer" }
        base = context
        factory = with_task_factory(base, task_id)
        rule_paths = Array(options["rules"])
        if rule_paths.empty?
          raise UsageError, "--rule PATH required (at least one rule file for the dispatch)"
        end

        task_result = resolved_task(base, task_id)
        revision = tip_revision(task_result)
        units = units_for_revision(task_result, revision)
        control_result = resolved_control(base, task_id)
        control_records = [
          { "lead_control_id" => control_result["registry"]["lead_control_id"] },
          control_result["session"],
          control_result["checkpoint"],
          control_result["agent"]
        ]
        attempted_unit_ids = Array(control_result["attempts"]).map { |a| a["work_unit_id"] }.uniq
        unit = units.find do |candidate|
          candidate["work_unit_kind"] == spec["kind"] &&
            (spec["kind"] == "evaluation" || !attempted_unit_ids.include?(candidate["work_unit_id"]))
        end
        raise ContractError.new("v2_cli_unit_missing",
          "no unattempted #{spec['kind']} work unit remains for role #{role_key}",
          path: "task-scopes/#{task_id}") unless unit

        thesis = thesis_for(task_result, unit)
        active = active_attempt(control_result)
        if active
          records = factory.terminal_records(task: revision, unit: unit, thesis: thesis,
            lead: task_result["logical_lead"], control_records: control_records,
            execution: execution_from(control_result, active),
            rule_paths: rule_paths, role: spec["role"], purpose: spec["purpose"])
          control_store(base, task_id).terminal(attempt: records[0], checkpoint: records[1],
            assertion: records[2], successor_attempt: records[3], worker_agent: records[4],
            rule_resolution: records[5], observation_checkpoint: records[6],
            observation_assertion: records[7],
            authority_verifier: base[:verifiers][0],
            runtime_identity_verifier: base[:verifiers][1],
            lifecycle_verifier: base[:verifiers][2])
          puts("terminated_attempt_id: #{records[0]['attempt_id']}")
          puts("attempt_id: #{records[3]['attempt_id']}")
        else
          records = factory.execution_records(task: revision, unit: unit, thesis: thesis,
            lead: task_result["logical_lead"], control_records: control_records,
            rule_paths: rule_paths, role: spec["role"], purpose: spec["purpose"])
          control_store(base, task_id).dispatch(rule_resolution: records[0],
            dispatch_checkpoint: records[1], dispatch_assertion: records[2],
            attempt: records[3], worker_agent: records[4],
            observation_checkpoint: records[5], observation_assertion: records[6],
            authority_verifier: base[:verifiers][0],
            runtime_identity_verifier: base[:verifiers][1],
            lifecycle_verifier: base[:verifiers][2])
          puts("attempt_id: #{records[3]['attempt_id']}")
        end
        puts("work_unit_id: #{unit['work_unit_id']}")
        puts("role: #{spec['role']} (#{spec['purpose']})")
        0
      end

      # The terminal composite needs the execution records array layout
      # [rule, dispatch_cp, dispatch_assertion, attempt, worker,
      # observation_cp, observation_assertion]; the factory only reads the
      # attempt (index 3), its rule resolution (index 0), and the attempt's
      # CURRENT observation tip (index 5, the control lineage tip itself).
      def execution_from(control_result, active)
        resolution = Array(control_result["rule_resolutions"]).find do |rule|
          rule["resolution_id"] == active.dig("events", 0, "assignment", "assigned_rule_resolution_id")
        end
        [resolution, nil, nil, active, nil, control_result["checkpoint"], nil]
      end

      def evidence(argv)
        sub = argv.shift
        unless sub == "submit"
          raise UsageError, "usage: orbit v2 evidence submit --task ID --proposal FILE"
        end
        options = parse_options(argv) do |opts, hash|
          opts.on("--task ID") { |v| hash["task"] = v }
          opts.on("--attempt ID") { |v| hash["attempt"] = v }
          opts.on("--proposal FILE") { |v| hash["proposal"] = v }
        end
        raise UsageError, "--proposal FILE required" unless options["proposal"]

        base = context
        task_id = options.fetch("task")
        factory = with_task_factory(base, task_id)
        proposal = YAML.safe_load(File.binread(options["proposal"]), permitted_classes: [], aliases: false)
        raise ContractError.new("v2_cli_def_invalid", "evidence proposal must be a mapping",
          path: "evidence_proposal") unless proposal.is_a?(Hash)

        control_result = resolved_control(base, task_id)
        attempt = options["attempt"] &&
          Array(control_result["attempts"]).find { |a| a["attempt_id"] == options["attempt"] }
        attempt ||= active_attempt(control_result) || terminal_attempt(control_result)
        raise ContractError.new("v2_cli_attempt_missing", "no attempt to bind evidence to",
          path: "task-scopes/#{task_id}") unless attempt

        resolved = control_store(base, task_id).resolve_attempt(attempt_id: attempt["attempt_id"],
          authority_verifier: base[:verifiers][0],
          runtime_identity_verifier: base[:verifiers][1],
          lifecycle_verifier: base[:verifiers][2])
        worker = resolved["worker_agent"]
        resolution = resolved["rule_resolution"]
        evidence_id = "oevr_#{DocumentFactory.hex}"
        kind = proposal.fetch("kind", "implementation")
        paths = Array(proposal["paths"]).map(&:to_s).sort.uniq
        raise ContractError.new("v2_cli_def_invalid", "evidence paths must be a non-empty list",
          path: "evidence_proposal.paths") if paths.empty?

        record = if kind == "evaluator_submission"
          factory.evaluator_submission(id: evidence_id, attempt: attempt, resolution: resolution)
        else
          factory.implementation_evidence(id: evidence_id, attempt: attempt,
            resolution: resolution, paths: paths)
        end
        proposal_record = record.reject { |key, _v| EvidenceStore::STORE_OWNED_KEYS.include?(key) }
        snapshot = DocumentFactory.repository_snapshot(base[:project_root])
        evidence_store(base, task_id).accept(proposal: proposal_record,
          repository_snapshot: snapshot, code_surface_paths: paths,
          authority_verifier: base[:verifiers][0],
          runtime_identity_verifier: base[:verifiers][1],
          lifecycle_verifier: base[:verifiers][2])
        puts("evidence_record_id: #{evidence_id}")
        puts("attempt_id: #{attempt['attempt_id']}")
        puts("kind: #{kind}")
        0
      end

      def gate(argv)
        sub = argv.shift
        raise UsageError, "usage: orbit v2 gate submit --task ID --def FILE" unless sub == "submit"
        options = parse_options(argv) do |opts, hash|
          opts.on("--task ID") { |v| hash["task"] = v }
          opts.on("--def FILE") { |v| hash["def"] = v }
        end
        raise UsageError, "--def FILE required" unless options["def"]

        base = context
        task_id = options.fetch("task")
        factory = with_task_factory(base, task_id)
        defn = YAML.safe_load(File.binread(options["def"]), permitted_classes: [], aliases: false)
        raise ContractError.new("v2_cli_def_invalid", "evaluation definition must be a mapping",
          path: "gate_def") unless defn.is_a?(Hash)

        task_result = resolved_task(base, task_id)
        revision = tip_revision(task_result)
        gate_requirement = gate_for_revision(task_result, revision)
        units = units_for_revision(task_result, revision)
        control_result = resolved_control(base, task_id)
        evaluator = active_attempt(control_result)
        raise ContractError.new("v2_cli_attempt_missing",
          "no active evaluation attempt; dispatch a reviewer first",
          path: "task-scopes/#{task_id}") unless evaluator

        store = evidence_store(base, task_id)
        payloads = store.records
        submission = payloads.reverse.find do |payload|
          payload.dig("evidence_record", "record_kind") == "evaluator_submission" &&
            payload.dig("evidence_record", "attempt_id") == evaluator["attempt_id"]
        end
        raise ContractError.new("v2_cli_evidence_missing",
          "no accepted evaluator submission for the active review attempt",
          path: "task-scopes/#{task_id}") unless submission

        latest = payloads.last
        accepted = payloads.map do |payload|
          store.resolve(evidence_record_id: payload.dig("evidence_record", "evidence_record_id"),
            authority_verifier: base[:verifiers][0],
            runtime_identity_verifier: base[:verifiers][1],
            lifecycle_verifier: base[:verifiers][2]).fetch("evidence_record")
        end
        impl_unit_ids = units.select { |u| u["work_unit_kind"] == "implementation" }
          .map { |u| u["work_unit_id"] }
        subject_attempts = Array(control_result["attempts"])
          .select { |a| impl_unit_ids.include?(a["work_unit_id"]) }
        gate_payloads = gate_store(base, task_id).records
        previous = gate_payloads.reverse.find do |payload|
          payload["gate_evaluation"] &&
            payload.dig("gate_evaluation", "gate_requirement_id") == gate_requirement["gate_requirement_id"]
        end
        defn["supersedes"] ||= previous && previous.dig("gate_evaluation", "gate_evaluation_id")
        evaluation, findings = factory.evaluation_records(
          gate: gate_requirement, task: revision, units: units,
          attempts: subject_attempts, evidence_records: accepted,
          snapshot: latest["repository_snapshot"], code_surface: latest["code_surface"],
          evaluator_attempt: evaluator,
          submission_id: submission.dig("evidence_record", "evidence_record_id"),
          defn: defn)
        gate_store(base, task_id).accept(evaluation: evaluation, findings: findings,
          authority_verifier: base[:verifiers][0],
          runtime_identity_verifier: base[:verifiers][1],
          lifecycle_verifier: base[:verifiers][2])
        puts("gate_evaluation_id: #{evaluation['gate_evaluation_id']}")
        puts("verdict: #{evaluation['verdict']}")
        puts("supersedes: #{evaluation['supersedes_gate_evaluation_id']}")
        findings.each { |f| puts("finding_id: #{f['finding_id']} (#{f['severity']} #{f['basis']})") }
        0
      end

      def finding(argv)
        sub = argv.shift
        raise UsageError, "usage: orbit v2 finding resolve --task ID --def FILE" unless sub == "resolve"
        options = parse_options(argv) do |opts, hash|
          opts.on("--task ID") { |v| hash["task"] = v }
          opts.on("--def FILE") { |v| hash["def"] = v }
        end
        raise UsageError, "--def FILE required" unless options["def"]

        base = context
        task_id = options.fetch("task")
        defn = YAML.safe_load(File.binread(options["def"]), permitted_classes: [], aliases: false)
        finding_id = defn.is_a?(Hash) ? defn["finding_id"] : nil
        raise ContractError.new("v2_cli_def_invalid", "resolution definition needs finding_id",
          path: "finding_def") unless finding_id

        factory = with_task_factory(base, task_id)
        store = gate_store(base, task_id)
        payloads = store.records
        source = payloads.find do |payload|
          payload["gate_evaluation"] &&
            Array(payload.dig("gate_evaluation", "finding_refs")).include?(finding_id)
        end
        raise ContractError.new("v2_cli_finding_missing",
          "no accepted evaluation carries finding #{finding_id}",
          path: "task-scopes/#{task_id}") unless source

        evaluations = payloads.select { |p| p["gate_evaluation"] }
          .map { |p| p["gate_evaluation"] }
        resolving = evaluations.reverse.find do |evaluation|
          evaluation["gate_evaluation_id"] != source.dig("gate_evaluation", "gate_evaluation_id")
        end
        raise ContractError.new("v2_cli_resolution_prerequisite_missing",
          "resolving requires a follow-up evaluation; submit one first",
          path: "task-scopes/#{task_id}") unless resolving

        control_result = resolved_control(base, task_id)
        reviewer = active_attempt(control_result) ||
          Array(control_result["attempts"]).reverse.find do |a|
            a.dig("events", 0, "assignment", "purpose") == "review"
          end
        evidence_payloads = evidence_store(base, task_id).records
        submission = evidence_payloads.reverse.find do |payload|
          payload.dig("evidence_record", "record_kind") == "evaluator_submission"
        end
        proposal = evidence_payloads.reverse.find do |payload|
          payload.dig("evidence_record", "record_kind") == "implementation"
        end
        unless reviewer && submission && proposal
          raise ContractError.new("v2_cli_resolution_prerequisite_missing",
            "resolving needs a review attempt, its submission, and implementation evidence",
            path: "task-scopes/#{task_id}")
        end

        finding = store.resolve_finding(finding_id: finding_id,
          authority_verifier: base[:verifiers][0],
          runtime_identity_verifier: base[:verifiers][1],
          lifecycle_verifier: base[:verifiers][2])
        resolution = factory.resolution_record(finding: finding,
          source_evaluation: source["gate_evaluation"],
          resolving_evaluation: resolving,
          issuer_attempt: reviewer,
          submission_id: submission.dig("evidence_record", "evidence_record_id"),
          proposal_evidence_id: proposal.dig("evidence_record", "evidence_record_id"))
        store.accept_resolution(resolution: resolution,
          authority_verifier: base[:verifiers][0],
          runtime_identity_verifier: base[:verifiers][1],
          lifecycle_verifier: base[:verifiers][2])
        puts("finding_resolution_id: #{resolution['finding_resolution_id']}")
        puts("finding_id: #{finding_id}")
        puts("resolution: addressed")
        0
      end

      def complete(argv)
        options = parse_options(argv) do |opts, hash|
          opts.on("--task ID") { |v| hash["task"] = v }
        end
        base = context
        task_id = options.fetch("task")
        task_result = resolved_task(base, task_id)
        revision = tip_revision(task_result)
        outcome = GateEngine.new(active_root: orbit_root(base), task_id: task_id).derive(
          task_id: task_id, task_revision_id: revision["task_revision_id"],
          authority_verifier: base[:verifiers][0],
          runtime_identity_verifier: base[:verifiers][1],
          lifecycle_verifier: base[:verifiers][2])
        puts("task_id: #{task_id}")
        puts("task_revision_id: #{revision['task_revision_id']}")
        puts("closed: #{outcome['closed']}")
        Array(outcome["gate_results"]).each do |result|
          gate_id = result.dig("gate_requirement_ref", "gate_requirement_id")
          puts("gate #{gate_id}: #{result['status']}")
        end
        Array(outcome["unresolved_blocking_finding_refs"]).each do |ref|
          puts("unresolved_finding: #{ref['finding_id'] || ref}")
        end
        Array(outcome["unresolved_adjudication_required_finding_refs"]).each do |ref|
          puts("unresolved_adjudication: #{ref['finding_id'] || ref}")
        end
        outcome["closed"] == true ? 0 : 1
      end

      def status(argv)
        options = parse_options(argv) do |opts, hash|
          opts.on("--task ID") { |v| hash["task"] = v }
        end
        base = context
        unless options["task"]
          segment = File.join(orbit_root(base), V2::TASK_SCOPES_SEGMENT)
          puts("project_id: #{base[:marker]['project_id']}")
          puts("policy_revision_id: #{base[:policy]['policy_revision_id']}")
          if File.directory?(segment)
            Dir.children(segment).sort.each { |id| puts("task: #{id}") }
          end
          return 0
        end
        task_id = options["task"]
        task_result = resolved_task(base, task_id)
        revision = tip_revision(task_result)
        puts("task_id: #{task_id}")
        puts("task_revision_id: #{revision['task_revision_id']} (goal: #{revision['goal']})")
        control_result = resolved_control(base, task_id)
        puts("control_id: #{control_result.dig('registry', 'lead_control_id')}")
        puts("checkpoints: #{Array(control_result['checkpoints']).length}")
        Array(control_result["attempts"]).each do |attempt|
          puts("attempt #{attempt['attempt_id']}: #{attempt.dig('events', -1, 'event_type')} " \
               "(#{attempt.dig('events', 0, 'assignment', 'purpose')})")
        end
        puts("evidence_records: #{evidence_store(base, task_id).records.length}")
        puts("gate_facts: #{gate_store(base, task_id).records.length}")
        0
      end

      def parse_options(argv)
        hash = {}
        OptionParser.new do |opts|
          yield(opts, hash)
        end.parse!(argv)
        hash
      rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
        raise UsageError, e.message
      end

      USAGE = <<~TEXT
        usage: orbit v2 <command> [options]

        commands:
          init <project_id>                      create the v2 protocol root + genesis policy
          task start <task_id> --def FILE        create one task (definition + control genesis)
          dispatch --task ID --role R --rule P   dispatch an attempt (implementer|reviewer)
          evidence submit --task ID --proposal F  submit evidence for an attempt
          gate submit --task ID --def FILE       submit an independent gate evaluation
          finding resolve --task ID --def FILE   resolve a finding (addressed) after a follow-up evaluation
          complete --task ID                     derive the aggregate outcome
          status [--task ID]                     read-only projection

        The local provider is a consistency mechanism, not a security
        boundary (workorder D.3.1). Key file: .orbit/local-provider.json.
      TEXT
    end
  end
end

def run_v2_cli(argv)
  Orbit::V2::Cli.run(argv)
end
