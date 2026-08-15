# frozen_string_literal: true

require_relative "active_root"
require_relative "authority_verifier"
require_relative "canonical_json"
require_relative "errors"
require_relative "identifiers"
require_relative "policy_issuance"
require_relative "protocol_root"
require_relative "schema_catalog"
require_relative "transaction_log"
require_relative "validator"

module Orbit
  module V2
    # Slice 6 increment 3: the durable controlled ProjectPolicyRevision
    # authority store — genesis + linear rotation + active-tip resolution —
    # built on the TransactionLog under the canonical active root.
    #
    # Every accepted transaction stores the policy AND its exact
    # AuthorityAssertion as one canonical transaction payload, so the
    # policy, its provider-verified issuance, and its issuance envelope
    # commit or fail together. The active policy is never a second mutable
    # pointer: there is no latest-by-time rule, no dual store/read, no
    # fallback, and no backfill. The unique active tip is DERIVED by
    # walking from the ProtocolRoot-pinned immutable genesis through exact
    # parent refs in accepted transaction order.
    #
    # Bootstrap order is explicit: the verified durable genesis is appended
    # first; the ProtocolRoot marker may then pin it. A marker-create
    # failure may leave an unreferenced durable genesis, but such a genesis
    # is not an active trust root and is never selected without a valid
    # marker pin (preflight requires both marker and pin). No cross-file
    # atomicity is claimed between store and marker.
    #
    # Public behavior:
    # - `genesis(policy:, assertion:, authority_verifier:)` validates the
    #   candidate ProjectPolicyRevision + exact AuthorityAssertion (final
    #   schema/digests/epoch, create-only parent-nil genesis, provider
    #   verification through the configured AuthorityVerifier, exact
    #   genesis issuance envelope) BEFORE appending; returns `:appended` or
    #   `:idempotent` (same revision id with byte-identical canonical
    #   content). Invalid, unconfigured, or self-reported authority leaves
    #   no accepted transaction.
    # - `rotate(policy:, assertion:, authority_verifier:)` extends an
    #   ACTIVE trust root only: inside the SAME locked snapshot the append
    #   commits on, it first proves that THIS store is the marker's
    #   canonical real active root (File.realpath(active_root) must equal
    #   <canonical project root>/.orbit, so a sibling/shadow/alias store
    #   can never borrow the marker pin), then runs the complete
    #   provider-verified lineage resolution from the in-root ProtocolRoot
    #   marker's pin (schema, digest, structural binding, and provider
    #   verification for every stored transaction, exact pin match —
    #   otherwise `policy_store_lineage_invalid`) and exact-binds the
    #   marker project to the store genesis project (otherwise
    #   `policy_store_unpinned`). A missing/corrupt marker or non-canonical
    #   root fails `policy_store_unpinned`, so an unreferenced durable
    #   genesis can never accumulate a rotation chain, and no stale resolve
    #   can authorize an append. It then
    #   appends one successor only if its parent ref is the resolved
    #   active policy, the parent policy grants the exact policy.rotate
    #   authority to the issuer under the existing contract, and the
    #   provider verifies the exact rotation issuance. Concurrent
    #   same-parent rotations yield exactly one accepted successor; the
    #   loser fails closed with `policy_store_rotation_invalid` and
    #   re-resolves. Returns `:appended` or `:idempotent` (committed
    #   replay). Stale, unauthorized, self-authorizing, cross-project, or
    #   unpinned successors fail closed and leave bytes unchanged.
    # - `records` returns detached verified transaction payloads in chain
    #   order; `resolve(pinned_genesis_ref:, authority_verifier:)`
    #   REQUIRES a configured authority verifier and returns
    #   {genesis_policy, genesis_assertion, active_policy} after verifying
    #   the whole lineage AND provider-verifying every stored assertion.
    #   Missing pinned genesis, same-ID-different-content, malformed/
    #   unknown policy transactions, unauthorized successors, forks/
    #   multiple tips, project/epoch mismatch, and broken lineage all fail
    #   closed.
    #
    # Error codes: policy_store_argument_invalid, policy_store_reuse,
    # policy_store_genesis_conflict, policy_store_genesis_invalid,
    # policy_store_rotation_invalid, policy_store_unpinned,
    # policy_store_lineage_invalid. TransactionLog storage-level failures
    # (transaction_log_corrupt, transaction_log_path_invalid) propagate
    # as-is.
    class PolicyStore
      POLICY_TRANSACTIONS_FILE = "policy-transactions.json".freeze
      PAYLOAD_KEYS = %w[assertion policy].freeze
      ROTATION_ACTION = "policy.rotate".freeze

      def initialize(active_root:)
        @active_root = File.expand_path(active_root)
        unless File.directory?(@active_root)
          raise ContractError.new(
            "policy_store_argument_invalid",
            "active root must be an existing directory",
            path: "policy_store.active_root"
          )
        end
        @log = TransactionLog.new(path: File.join(@active_root, POLICY_TRANSACTIONS_FILE))
      end

      def genesis(policy:, assertion:, authority_verifier:)
        validate_transaction!(policy, assertion, authority_verifier, parent: nil)
        candidate = payload(policy, assertion)
        result = @log.append(
          transaction_id: policy.fetch("policy_revision_id"),
          expected_tip_digest: nil,
          payload: candidate
        )
        case result
        when :appended, :idempotent
          result
        when :stale
          # A concurrent genesis committed first: resolve to idempotent or
          # fail closed on a conflicting genesis.
          first = payloads(@log.records).first
          if first && canonical_equal?(first, candidate)
            :idempotent
          else
            raise ContractError.new(
              "policy_store_genesis_conflict",
              "a different policy genesis was committed concurrently",
              path: "policy_store.genesis"
            )
          end
        end
      rescue ContractError => e
        raise e unless e.code == "transaction_log_reuse"

        raise ContractError.new(
          "policy_store_reuse",
          "policy revision #{policy.fetch("policy_revision_id")} already exists " \
            "with different canonical content",
          path: "policy_store.#{policy.fetch("policy_revision_id")}"
        )
      end

      def rotate(policy:, assertion:, authority_verifier:)
        unless policy.is_a?(Hash) && assertion.is_a?(Hash) &&
               authority_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "policy_store_argument_invalid",
            "policy, assertion, and a configured authority verifier are required",
            path: "policy_store"
          )
        end
        candidate = payload(policy, assertion)
        transaction_id = policy.fetch("policy_revision_id")
        # Validation and the compare-and-append share ONE locked snapshot
        # (TransactionLog#append_with): inside that snapshot the store
        # FIRST runs the complete provider-verified lineage resolution from
        # the marker pin (schema/binding/provider for every stored
        # transaction, exact pin match, marker project exact-binding) to
        # obtain the verified active policy, and only then validates the
        # candidate against it. A stale/out-of-snapshot resolve can never
        # authorize an append, and concurrent same-parent rotations yield
        # exactly one accepted successor — the loser fails closed with
        # rotation_invalid and re-resolves.
        @log.append_with(
          transaction_id: transaction_id,
          payload: candidate,
          validate: lambda do |records, _tip|
            validate_rotation_snapshot!(
              records, policy, assertion, authority_verifier, candidate, transaction_id
            )
          end
        )
      rescue ContractError => e
        raise e unless e.code == "transaction_log_reuse"

        raise ContractError.new(
          "policy_store_reuse",
          "policy revision #{policy.fetch("policy_revision_id")} already exists " \
            "with different canonical content",
          path: "policy_store.#{policy.fetch("policy_revision_id")}"
        )
      end

      # Runs inside TransactionLog's exclusive lock against the same
      # verified snapshot the append commits on. Returns nil to proceed,
      # :idempotent for a committed replay, or raises. The complete
      # provider-verified lineage resolution from the marker pin runs on
      # THIS snapshot (never a stale one), and the marker project is
      # exact-bound to the store genesis project before any candidate is
      # accepted.
      def validate_rotation_snapshot!(records, policy, assertion,
                                       authority_verifier, candidate, transaction_id)
        txs = payloads(records)
        if txs.empty?
          raise ContractError.new(
            "policy_store_rotation_invalid",
            "rotation requires a committed policy genesis",
            path: "policy_store.rotate"
          )
        end
        marker = marker_for_rotation!
        resolved = resolve_snapshot(
          txs,
          marker.fetch("project_policy_genesis_ref"),
          authority_verifier
        )
        unless resolved.fetch("genesis_policy").fetch("project_id") == marker["project_id"]
          raise ContractError.new(
            "policy_store_unpinned",
            "store genesis project does not match the marker project",
            path: "policy_store.rotate",
            details: {
              "marker_project_id" => marker["project_id"],
              "genesis_project_id" => resolved.fetch("genesis_policy").fetch("project_id")
            }
          )
        end
        existing = txs.find do |transaction|
          transaction.fetch("policy").fetch("policy_revision_id") == transaction_id
        end
        if existing
          return :idempotent if canonical_equal?(existing, candidate)

          raise ContractError.new(
            "policy_store_reuse",
            "policy revision #{transaction_id} already exists " \
              "with different canonical content",
            path: "policy_store.#{transaction_id}"
          )
        end
        active_policy = resolved.fetch("active_policy")
        unless policy["parent_policy_revision_id"] == active_policy["policy_revision_id"]
          raise ContractError.new(
            "policy_store_rotation_invalid",
            "rotation parent is not the currently resolved active tip",
            path: "policy_store.rotate.parent_policy_revision_id",
            details: {
              "expected_parent" => active_policy["policy_revision_id"],
              "actual_parent" => policy["parent_policy_revision_id"]
            }
          )
        end
        validate_transaction!(policy, assertion, authority_verifier, parent: active_policy)
        nil
      end

      def records
        payloads(@log.records)
      end

      def resolve(pinned_genesis_ref:, authority_verifier:)
        unless pinned_genesis_ref.is_a?(Hash) &&
               Identifiers.valid?(
                 "policy_revision_id",
                 pinned_genesis_ref["policy_revision_id"]
               ) &&
               Identifiers.digest?(pinned_genesis_ref["content_digest"])
          raise ContractError.new(
            "policy_store_argument_invalid",
            "pinned_genesis_ref must carry an exact policy revision id and content digest",
            path: "policy_store.pinned_genesis_ref"
          )
        end
        unless authority_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "policy_store_argument_invalid",
            "resolve requires a configured authority verifier",
            path: "policy_store.resolve"
          )
        end
        resolve_snapshot(payloads(@log.records), pinned_genesis_ref, authority_verifier)
      end

      # The complete provider-verified lineage resolution over an explicit
      # transaction snapshot: closed payload shape, per-record
      # schema/digest/epoch, one project across the store, exact parent
      # refs in accepted transaction order (forks, orphans, cycles, skips
      # fail closed), structural issuance binding for every transaction,
      # provider verification of every stored assertion, and the pinned
      # ref exact-matching the stored genesis. Returns
      # {genesis_policy, genesis_assertion, active_policy}. rotate runs
      # this against the SAME locked snapshot its append commits on, so no
      # stale resolve can authorize an append.
      def resolve_snapshot(txs, pinned_genesis_ref, authority_verifier)
        raise lineage_invalid("policy store has no genesis transaction") if txs.empty?

        validator = Orbit::V2::Validator.new(project_root: @active_root)
        genesis_project = txs.first.fetch("policy").fetch("project_id")
        txs.each_with_index do |tx, index|
          unless tx.is_a?(Hash) && tx.keys.sort == PAYLOAD_KEYS
            raise lineage_invalid("transaction carries fields outside the closed payload shape", index)
          end
          policy = tx.fetch("policy")
          assertion = tx.fetch("assertion")
          begin
            validator.validate_document!("project_policy_revision", policy)
            validator.validate_document!("authority_assertion", assertion)
          rescue ValidationFailure
            raise lineage_invalid("transaction contains malformed policy or assertion records", index)
          end
          unless CanonicalJSON.content_digest(policy) == policy["content_digest"]
            raise lineage_invalid("policy content_digest is not self-consistent", index)
          end
          unless policy["project_id"] == genesis_project
            raise lineage_invalid("policy project does not match the store genesis project", index)
          end
          parent = index.zero? ? nil : txs.fetch(index - 1).fetch("policy")
          expected_parent = parent ? parent["policy_revision_id"] : nil
          unless policy["parent_policy_revision_id"] == expected_parent
            raise lineage_invalid(
              "policy lineage does not follow exact parent refs in accepted transaction order",
              index
            )
          end
          binding = binding_errors(policy, assertion, parent)
          unless binding.empty?
            raise lineage_invalid("unauthorized policy transaction: #{binding.join('; ')}", index)
          end

          begin
            authority_verifier.verify!(assertion)
          rescue ContractError => error
            raise lineage_invalid(
              "stored assertion was not provider-verified: #{error.code}",
              index
            )
          end
        end

        genesis = txs.first.fetch("policy")
        unless genesis["policy_revision_id"] == pinned_genesis_ref["policy_revision_id"] &&
               genesis["content_digest"] == pinned_genesis_ref["content_digest"]
          raise lineage_invalid("pinned genesis ref does not exact-match the stored genesis")
        end
        {
          "genesis_policy" => genesis,
          "genesis_assertion" => txs.first.fetch("assertion"),
          "active_policy" => txs.last.fetch("policy")
        }
      end

      def marker_for_rotation!
        ActiveRoot.marker_for(
          @active_root,
          code: "policy_store_unpinned",
          label: "policy_store.rotate"
        )
      end

      private :validate_rotation_snapshot!, :resolve_snapshot, :marker_for_rotation!

      private

      def payload(policy, assertion)
        { "assertion" => assertion, "policy" => policy }
      end

      def payloads(records)
        records.map do |record|
          payload = record["payload"]
          raise lineage_invalid("transaction payload is not a canonical object") unless payload.is_a?(Hash)

          # Detached canonical copies: re-serialize through the canonical
          # dump so caller mutation can never corrupt stored truth.
          JSON.parse(CanonicalJSON.dump(payload))
        end
      end

      def canonical_equal?(left, right)
        CanonicalJSON.dump(left) == CanonicalJSON.dump(right)
      end

      def lineage_invalid(message, index = nil)
        details = index.nil? ? nil : { "transaction_index" => index }
        ContractError.new(
          "policy_store_lineage_invalid",
          "policy authority store lineage is invalid: #{message}",
          path: "policy_store",
          details: details
        )
      end

      # Full write-time validation: final schema/digests/epoch, exact
      # parent (nil for genesis, resolved active tip for rotation), the
      # provider-verified assertion, and the exact issuance envelope
      # semantics (the same boundary and rules the public Validator
      # composes).
      def validate_transaction!(policy, assertion, authority_verifier, parent:)
        unless policy.is_a?(Hash) && assertion.is_a?(Hash) &&
               authority_verifier.respond_to?(:verify!)
          raise ContractError.new(
            "policy_store_argument_invalid",
            "policy, assertion, and a configured authority verifier are required",
            path: "policy_store"
          )
        end
        validator = Orbit::V2::Validator.new(project_root: @active_root)
        begin
          validator.validate_document!("project_policy_revision", policy)
          validator.validate_document!("authority_assertion", assertion)
        rescue ValidationFailure
          raise ContractError.new(
            "policy_store_argument_invalid",
            "policy or assertion violates its contract",
            path: "policy_store"
          )
        end
        unless CanonicalJSON.content_digest(policy) == policy["content_digest"]
          raise write_invalid(parent, "policy content_digest is not self-consistent")
        end
        expected_parent = parent ? parent["policy_revision_id"] : nil
        unless policy["parent_policy_revision_id"] == expected_parent
          raise write_invalid(
            parent,
            parent ? "successor does not name the resolved active tip as parent" : "genesis must be parentless"
          )
        end
        if parent && policy["project_id"] != parent["project_id"]
          raise write_invalid(parent, "successor project does not match the parent policy project")
        end
        unless assertion["assertion_id"] == policy["authorization_source_ref"]
          raise write_invalid(parent, "policy does not pin its issuance assertion")
        end
        binding = binding_errors(policy, assertion, parent)
        unless binding.empty?
          raise write_invalid(parent, binding.join("; "))
        end
        begin
          authority_verifier.verify!(assertion)
        rescue ContractError => error
          raise write_invalid(
            parent,
            "issuance was not provider-verified: #{error.code} (#{error.message})"
          )
        end
      end

      def write_invalid(parent, message)
        ContractError.new(
          parent ? "policy_store_rotation_invalid" : "policy_store_genesis_invalid",
          "#{parent ? 'rotation' : 'genesis'} rejected: #{message}",
          path: "policy_store"
        )
      end

      # Structural issuance-binding semantics shared by writer and reader:
      # the exact envelope rules the public Validator's genesis/rotation
      # branch composes, without provider verification (the writer and
      # preflight add that through the configured AuthorityVerifier).
      def binding_errors(policy, assertion, parent)
        envelope = assertion["policy_issuance_envelope"]
        receipt = assertion["verification_receipt"]
        return ["missing issuance envelope or receipt"] unless envelope.is_a?(Hash) && receipt.is_a?(Hash)

        expected_grant = parent ? unique_rotate_grant(parent) : "policy.genesis"
        return ["parent policy does not grant policy.rotate"] if parent && expected_grant.nil?

        errors = []
        errors << "wrong envelope schema" unless envelope["schema_version"] == PolicyIssuance::SCHEMA_VERSION
        expected_kind = parent ? "rotation" : "genesis"
        errors << "wrong issuance kind" unless envelope["issuance_kind"] == expected_kind
        errors << "envelope project mismatch" unless envelope["project_id"] == policy["project_id"]
        errors << "wrong parent policy ref" unless envelope["parent_policy_revision_ref"] == PolicyIssuance.policy_ref(parent)
        errors << "wrong candidate policy ref" unless envelope["candidate_policy_revision_ref"] == PolicyIssuance.policy_ref(policy)
        errors << "wrong authority source ref" unless envelope["authority_source_revision_ref"] == {
          "provider_id" => assertion["provider_id"],
          "receipt_id" => receipt["receipt_id"],
          "assertion_id" => assertion["assertion_id"],
          "assertion_digest" => assertion["assertion_digest"]
        }
        errors << "issuance not approved" unless envelope["decision"] == "approved"
        errors << "issued_at does not match the receipt" unless envelope["issued_at"] == receipt["issued_at"]
        errors << "envelope digest not self-consistent" unless envelope["envelope_digest"] == PolicyIssuance.envelope_digest(envelope)
        errors << "assertion scope does not pin the envelope" unless assertion["authority_scope_ref"] == envelope["envelope_digest"]
        errors << "assertion project mismatch" unless assertion["project_id"] == policy["project_id"]
        errors << "self-reported issuer" unless %w[user control_plane].include?(assertion["issuer_kind"])
        errors << "wrong grants" unless Array(assertion["grants"]) == [expected_grant]
        errors << "assertion digest not pinned by the policy" unless policy["authorization_assertion_digest"] == assertion["assertion_digest"]
        if parent
          parent_issued_at = stored_parent_issued_at(parent)
          if parent_issued_at.nil?
            errors << "parent issuance time unavailable"
          else
            begin
              valid = Time.iso8601(envelope["issued_at"]) > Time.iso8601(parent_issued_at)
            rescue ArgumentError, TypeError
              valid = false
            end
            errors << "rotation not after the parent issuance" unless valid
          end
        end
        errors
      end

      def unique_rotate_grant(policy)
        matches = Array(policy["authority_grants"]).select do |grant|
          grant.is_a?(Hash) && grant["action"] == ROTATION_ACTION
        end
        matches.length == 1 ? matches.first["required_external_grant"] : nil
      end

      def stored_parent_issued_at(parent_policy)
        @log.records.each do |record|
          payload = record["payload"]
          next unless payload.is_a?(Hash) && payload["policy"].is_a?(Hash)
          next unless payload["policy"]["policy_revision_id"] == parent_policy["policy_revision_id"]

          assertion = payload["assertion"]
          return assertion.dig("policy_issuance_envelope", "issued_at") if assertion.is_a?(Hash)
        end
        nil
      end
    end
  end
end
