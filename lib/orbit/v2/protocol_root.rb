# frozen_string_literal: true

require "yaml"

require_relative "authority_verifier"
require_relative "canonical_json"
require_relative "durable_file"
require_relative "errors"
require_relative "identifiers"
require_relative "policy_issuance"
require_relative "schema_catalog"
require_relative "validator"

module Orbit
  module V2
    # Slice 6 increment 2: the isolated ProtocolRoot marker + root/epoch
    # preflight seam.
    #
    # The create-only `.orbit/protocol.yaml` marker lives at the top of the
    # project root and its parent directory canonically defines the sole
    # active artifact root. The marker carries the exact final ProtocolRoot
    # shape only: schema_version, protocol_epoch (orbit-v2), project_id,
    # the immutable exact ProjectPolicyRevision genesis id+digest ref, and
    # the canonical content_digest. No copied policy/task/control body, no
    # compatibility fields, no mutable active pointer, no fallback root, no
    # cwd/config override, no backfill, and no dual read: every method takes
    # the explicit project_root and never searches for a root elsewhere.
    #
    # Public behavior:
    # - `create(project_root:, project_id:, policy_genesis_ref:)` returns
    #   `:created` or `:idempotent` (same canonical marker content already
    #   committed). Different content raises
    #   ContractError("protocol_root_reuse"); a symlink/hard-linked/non-
    #   regular marker path fails closed; a root already carrying known v1
    #   authority artifacts fails closed so the marker can never become
    #   accepted truth in a mixed-epoch root. The write is atomic and
    #   create-only: absent -> one durable marker, a failure before the
    #   rename leaves the previous state (absent or prior marker) readable,
    #   and competing creators serialize on the exclusive lock.
    # - `read(project_root:)` returns the verified marker record (detached)
    #   or raises ContractError("protocol_root_missing").
    #
    # Every method resolves the explicit project root through symlinks
    # (File.realpath) and enforces marker-parent containment BEFORE any
    # file access: the marker parent must be the canonical real
    # <project>/.orbit inside the canonical project root. A real path and a
    # symlink alias of the whole project resolve to the same canonical
    # root; a pre-existing .orbit that is a symlink, a non-directory, or
    # resolves outside the canonical root fails closed with
    # ContractError("protocol_root_path_invalid") before any marker, lock,
    # or staging byte is read or written outside. Create alone may see a
    # genuinely absent .orbit, which it then creates inside the canonical
    # root.
    # - `preflight(project_root:, expected_project_id:, genesis_policy:,
    #   genesis_assertion:, authority_verifier:)` returns the canonical
    #   active artifact root — the canonical real parent directory of the
    #   marker (<real project>/.orbit) — only after the explicit project
    #   root is resolved through symlinks (a real path and a symlink alias
    #   to the same physical marker resolve to the SAME active root, never
    #   two), the marker is verified, the pinned ProjectPolicyRevision
    #   genesis is bound through the existing public seams
    #   (SchemaCatalog/Validator#validate_document! for the records,
    #   AuthorityVerifier#verify! for the provider-verified issuance,
    #   PolicyIssuance for the exact issuance envelope) INCLUDING the exact
    #   project binding (marker, genesis policy, and issuance all carry the
    #   same project_id), and no known v1 authority artifact exists inside
    #   the active root. The marker's real parent must remain contained in
    #   the canonical project root. Nothing is self-authorized from marker
    #   text or candidate writer names: the marker only pins the genesis
    #   ref; the ref must exact-match a create-only genesis record whose
    #   issuance is provider-verified.
    #
    # The marker file must be exactly the canonical rendering of its own
    # record: unknown fields, noncanonical content, duplicate keys, trailing
    # junk, tag/alias tricks, a wrong epoch, a tampered content_digest, or
    # a symlink/hard-linked/non-regular path all fail closed.
    #
    # This increment is the seam only; no project-scoped command wiring
    # exists. The controlled genesis writer (which authors the
    # ProjectPolicyRevision + issuance that preflight consumes), policy
    # rotation, control/session genesis, v1 retirement, and E2E cutover
    # remain later Slice 6 increments.
    module ProtocolRoot
      module_function

      MARKER_RELATIVE_PATH = ".orbit/protocol.yaml".freeze
      SCHEMA_VERSION = "orbit-protocol-root-v1".freeze
      EPOCH = "orbit-v2".freeze

      # Known v1 authority artifacts relative to `.orbit`: runtime
      # session/instance state, loop state, role/instance config, and the
      # v1 authoring records. Presence of any of these inside the active
      # root alongside the v2 marker is a mixed-epoch authority state and
      # fails closed. v1 archives outside the active root are irrelevant.
      KNOWN_V1_AUTHORITY_PATHS = %w[
        runtime
        loop-state.yaml
        roles.yaml
        instances.yaml
        tasks
        evidence
        rules
        handoffs
      ].freeze

      def create(project_root:, project_id:, policy_genesis_ref:)
        validate_identity_inputs!(project_id, policy_genesis_ref)
        root = canonical_root(project_root)
        marker_path = verified_marker_path(root, allow_missing_orbit: true)
        reject_mixed_epoch!(root)

        record = {
          "schema_version" => SCHEMA_VERSION,
          "protocol_epoch" => EPOCH,
          "project_id" => project_id,
          "project_policy_genesis_ref" => {
            "policy_revision_id" => policy_genesis_ref.fetch("policy_revision_id"),
            "content_digest" => policy_genesis_ref.fetch("content_digest")
          }
        }
        record["content_digest"] = CanonicalJSON.content_digest(record)

        DurableFile.with_exclusive_lock(marker_path) do
          existing = begin
            load_verified_record(marker_path)
          rescue ContractError => e
            raise e unless e.code == "protocol_root_missing"

            nil
          end
          if existing
            return :idempotent if existing["content_digest"] == record["content_digest"]

            raise ContractError.new(
              "protocol_root_reuse",
              "a different ProtocolRoot marker already exists; the marker is create-only",
              path: "protocol_root"
            )
          end
          DurableFile.atomic_write(marker_path, YAML.dump(record))
          :created
        end
      end

      def read(project_root:)
        root = canonical_root(project_root)
        load_verified_record(verified_marker_path(root))
      end

      def preflight(project_root:, expected_project_id:, genesis_policy:,
                    genesis_assertion:, authority_verifier:)
        unless expected_project_id.is_a?(String) &&
               Identifiers.valid?("project_id", expected_project_id)
          raise ContractError.new(
            "protocol_root_argument_invalid",
            "expected_project_id must be a stable project identifier",
            path: "protocol_root.expected_project_id"
          )
        end
        root = canonical_root(project_root)
        marker = load_verified_record(verified_marker_path(root))
        unless marker["project_id"] == expected_project_id
          raise ContractError.new(
            "protocol_root_project_mismatch",
            "marker project_id does not match the expected project identity",
            path: "protocol_root.project_id",
            details: {
              "expected" => expected_project_id,
              "actual" => marker["project_id"]
            }
          )
        end
        validate_genesis_binding!(
          marker,
          genesis_policy,
          genesis_assertion,
          authority_verifier,
          root
        )
        reject_mixed_epoch!(root)
        # Containment was already enforced before any file access by
        # verified_marker_path, so the active artifact root is exactly the
        # canonical real parent directory of the marker: the canonical
        # project root's .orbit.
        File.join(root, ".orbit")
      end

      # Centralized marker-parent containment. Returns the marker path whose
      # parent has been verified to be the canonical real <project>/.orbit
      # INSIDE the canonical project root, and is called before ANY file
      # access in create/read/preflight — so no marker, lock, or staging
      # byte can ever be written to or read from outside the canonical
      # root. A genuinely absent .orbit is allowed only for create
      # (allow_missing_orbit: true): the real in-root directory is then
      # created by the commit primitive. An existing .orbit that is a
      # symlink, a non-directory, or resolves outside the canonical root
      # fails closed with protocol_root_path_invalid.
      def verified_marker_path(canonical_project_root, allow_missing_orbit: false)
        dot_orbit = File.join(canonical_project_root, ".orbit")
        if File.exist?(dot_orbit) || File.symlink?(dot_orbit)
          real_parent = File.realpath(dot_orbit)
          unless real_parent == dot_orbit && File.directory?(real_parent)
            raise ContractError.new(
              "protocol_root_path_invalid",
              "marker parent is not the canonical in-root .orbit directory",
              path: "protocol_root"
            )
          end
        elsif !allow_missing_orbit
          raise ContractError.new(
            "protocol_root_missing",
            "no #{MARKER_RELATIVE_PATH} marker exists in the project root",
            path: "protocol_root"
          )
        end
        File.join(dot_orbit, "protocol.yaml")
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise ContractError.new(
          "protocol_root_path_invalid",
          "marker parent is not the canonical in-root .orbit directory",
          path: "protocol_root"
        )
      end

      # The explicit project root is resolved to its canonical real path
      # (symlinks resolved); a missing root means no marker can exist there
      # and fails closed. The seam never searches for a root.
      def canonical_root(project_root)
        File.realpath(project_root)
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise ContractError.new(
          "protocol_root_missing",
          "no #{MARKER_RELATIVE_PATH} marker exists in the project root",
          path: "protocol_root"
        )
      end

      def marker_path(project_root)
        File.join(project_root, MARKER_RELATIVE_PATH)
      end

      def load_verified_record(marker_path)
        DurableFile.verify_single_link!(
          marker_path,
          code: "protocol_root_path_invalid",
          label: "protocol root marker"
        )
        bytes = File.binread(marker_path)
        parsed = parse_marker(bytes)
        verify_record!(parsed)
        parsed
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise ContractError.new(
          "protocol_root_missing",
          "no #{MARKER_RELATIVE_PATH} marker exists in the project root",
          path: "protocol_root"
        )
      end

      def parse_marker(bytes)
        parsed = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
        unless parsed.is_a?(Hash) && bytes == YAML.dump(parsed)
          raise ContractError.new(
            "protocol_root_corrupt",
            "marker bytes are not the canonical rendering of the marker record",
            path: "protocol_root"
          )
        end
        parsed
      rescue Psych::Exception, TypeError
        raise ContractError.new(
          "protocol_root_corrupt",
          "marker is not valid, safe YAML",
          path: "protocol_root"
        )
      end

      def verify_record!(record)
        SchemaCatalog.check!("protocol_root", record)
        validator = Orbit::V2::Validator.new(project_root: Dir.pwd)
        validator.validate_document!("protocol_root", record)
        expected = CanonicalJSON.content_digest(record)
        return if record["content_digest"] == expected

        raise ContractError.new(
          "protocol_root_corrupt",
          "marker content_digest does not match its canonical semantic content",
          path: "protocol_root.content_digest",
          details: { "expected" => expected, "actual" => record["content_digest"] }
        )
      rescue ValidationFailure => failure
        codes = failure.errors.map(&:code)
        if codes.include?("protocol_epoch_mismatch")
          raise ContractError.new(
            "protocol_root_epoch_mismatch",
            "marker protocol_epoch is not #{EPOCH}",
            path: "protocol_root.protocol_epoch"
          )
        end
        raise ContractError.new(
          "protocol_root_corrupt",
          "marker violates the ProtocolRoot contract",
          path: "protocol_root",
          details: failure.errors.map { |error| { "code" => error.code, "message" => error.message } }
        )
      end

      def validate_identity_inputs!(project_id, policy_genesis_ref)
        unless project_id.is_a?(String) && Identifiers.valid?("project_id", project_id)
          raise ContractError.new(
            "protocol_root_argument_invalid",
            "project_id must be a stable project identifier",
            path: "protocol_root.project_id"
          )
        end
        valid_ref = policy_genesis_ref.is_a?(Hash) &&
                    Identifiers.valid?(
                      "policy_revision_id",
                      policy_genesis_ref["policy_revision_id"]
                    ) &&
                    Identifiers.digest?(policy_genesis_ref["content_digest"])
        return if valid_ref

        raise ContractError.new(
          "protocol_root_argument_invalid",
          "policy_genesis_ref must carry an exact policy revision id and content digest",
          path: "protocol_root.project_policy_genesis_ref"
        )
      end

      def reject_mixed_epoch!(project_root)
        dot_orbit = File.join(project_root, ".orbit")
        KNOWN_V1_AUTHORITY_PATHS.each do |relative|
          next unless File.exist?(File.join(dot_orbit, relative))

          raise ContractError.new(
            "protocol_root_mixed_epoch",
            "active root contains the known v1 authority artifact .orbit/#{relative}",
            path: "protocol_root",
            details: { "v1_artifact" => relative }
          )
        end
      end

      # Binds the marker's pinned genesis ref to the exact create-only
      # ProjectPolicyRevision genesis through the existing public seams —
      # the same records, digest rules, provider boundary, and issuance
      # semantics the public Validator composes (AuthorityPolicy
      # policy_issuance_valid? genesis branch) — never from marker text or
      # candidate writer names.
      def validate_genesis_binding!(marker, genesis_policy, genesis_assertion,
                                    authority_verifier, project_root)
        unless genesis_policy.is_a?(Hash) && genesis_assertion.is_a?(Hash) &&
               authority_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "protocol_root_argument_invalid",
            "preflight requires the genesis ProjectPolicyRevision, its AuthorityAssertion, " \
              "and a configured authority verifier",
            path: "protocol_root.preflight"
          )
        end
        validator = Orbit::V2::Validator.new(project_root: project_root)
        begin
          validator.validate_document!("project_policy_revision", genesis_policy)
          validator.validate_document!("authority_assertion", genesis_assertion)
        rescue ValidationFailure
          raise genesis_invalid("genesis records violate their contracts")
        end
        unless genesis_policy["parent_policy_revision_id"].nil? &&
               CanonicalJSON.content_digest(genesis_policy) == genesis_policy["content_digest"]
          raise genesis_invalid("genesis policy is not a self-consistent create-only genesis")
        end
        pinned = marker["project_policy_genesis_ref"]
        unless pinned == {
          "policy_revision_id" => genesis_policy["policy_revision_id"],
          "content_digest" => genesis_policy["content_digest"]
        }
          raise genesis_invalid("marker genesis ref does not exact-match the genesis policy")
        end
        unless genesis_policy["project_id"] == marker["project_id"]
          raise genesis_invalid(
            "genesis policy project does not match the marker project"
          )
        end
        unless genesis_policy["authorization_source_ref"] == genesis_assertion["assertion_id"]
          raise genesis_invalid("genesis policy does not pin its issuance assertion")
        end
        begin
          authority_verifier.verify!(genesis_assertion)
        rescue ContractError => error
          raise genesis_invalid("genesis issuance was not provider-verified",
                                { "cause" => error.code, "message" => error.message })
        end

        envelope = genesis_assertion["policy_issuance_envelope"]
        receipt = genesis_assertion["verification_receipt"]
        valid = envelope.is_a?(Hash) && receipt.is_a?(Hash) &&
                envelope["schema_version"] == PolicyIssuance::SCHEMA_VERSION &&
                envelope["issuance_kind"] == "genesis" &&
                envelope["project_id"] == genesis_policy["project_id"] &&
                envelope["parent_policy_revision_ref"].nil? &&
                envelope["candidate_policy_revision_ref"] == PolicyIssuance.policy_ref(genesis_policy) &&
                envelope["authority_source_revision_ref"] == {
                  "provider_id" => genesis_assertion["provider_id"],
                  "receipt_id" => receipt["receipt_id"],
                  "assertion_id" => genesis_assertion["assertion_id"],
                  "assertion_digest" => genesis_assertion["assertion_digest"]
                } &&
                envelope["decision"] == "approved" &&
                envelope["issued_at"] == receipt["issued_at"] &&
                envelope["envelope_digest"] == PolicyIssuance.envelope_digest(envelope) &&
                genesis_assertion["authority_scope_ref"] == envelope["envelope_digest"] &&
                genesis_assertion["project_id"] == genesis_policy["project_id"] &&
                %w[user control_plane].include?(genesis_assertion["issuer_kind"]) &&
                Array(genesis_assertion["grants"]) == ["policy.genesis"] &&
                genesis_policy["authorization_assertion_digest"] == genesis_assertion["assertion_digest"]
        return if valid

        raise genesis_invalid("genesis issuance envelope does not exact-bind the genesis policy")
      end

      def genesis_invalid(message, details = nil)
        ContractError.new(
          "protocol_root_genesis_invalid",
          "ProtocolRoot genesis verification failed: #{message}",
          path: "protocol_root.project_policy_genesis_ref",
          details: details
        )
      end

      private_class_method(
        :canonical_root,
        :verified_marker_path,
        :load_verified_record,
        :parse_marker,
        :verify_record!,
        :validate_identity_inputs!,
        :reject_mixed_epoch!,
        :validate_genesis_binding!,
        :genesis_invalid
      )
    end
  end
end
