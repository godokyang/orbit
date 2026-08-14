# frozen_string_literal: true

require_relative "canonical_json"
require_relative "errors"
require_relative "identifiers"
require_relative "path_scope"
require_relative "projection_primitives"

module Orbit
  module V2
    # Slice 5 increment 5: the pure derived CodeSurface construction seam.
    #
    # CodeSurface.derive(repository_snapshot:, paths:) builds the exact
    # existing `derived_code_surface` contract object from the
    # provider/store-supplied git snapshot identity and the canonical
    # repository-tree path set supplied by the snapshot/tree enumerator
    # boundary. The projector performs NO filesystem reads and NO
    # latest/current lookup; it owns no fact source and writes nothing.
    # Its only public singleton method is `derive`; the canonical hash rule
    # lives in ProjectionPrimitives.code_surface_digest, shared with the
    # EvaluationSubject consumer.
    #
    # Input contract (documented, enforced): repository_snapshot must be the
    # exact closed contract snapshot shape (exactly kind git, 40-hex
    # commit_sha, sha256 tree_digest — no extra fields) and paths must be a
    # non-empty sorted unique canonical repository-tree path set (the
    # snapshot/tree enumerator boundary's canonical-set invariant).
    # Non-canonical input fails closed rather than being silently
    # canonicalized, so the digest domain is exactly the contract's. The
    # returned object copies its inputs, so later source mutation cannot
    # corrupt the derived result. Rebuilding from the same snapshot+paths is
    # byte-identical; a tree digest or canonical path-set change changes the
    # surface digest.
    module CodeSurface
      module_function

      KIND = "derived_code_surface".freeze
      DERIVATION_VERSION = "orbit-code-surface-v1".freeze
      SNAPSHOT_KEYS = %w[commit_sha kind tree_digest].freeze

      def derive(repository_snapshot:, paths:)
        validate_snapshot!(repository_snapshot)
        unless PathScope.canonical_set?(paths, allow_empty: false)
          raise ContractError.new(
            "derived_input_invalid",
            "CodeSurface paths must be a non-empty sorted unique canonical repository-tree path set",
            path: "code_surface.paths"
          )
        end
        # Deep-enough copy for the closed shape: the array AND every
        # mutable path string are copied, so later in-place mutation of a
        # caller input cannot corrupt the returned surface or its digest.
        canonical_paths = paths.map(&:dup)
        {
          "kind" => KIND,
          "derivation_version" => DERIVATION_VERSION,
          "repository_tree_digest" => repository_snapshot["tree_digest"].dup,
          "paths" => canonical_paths,
          "code_surface_digest" => ProjectionPrimitives.code_surface_digest(
            derivation_version: DERIVATION_VERSION,
            repository_tree_digest: repository_snapshot["tree_digest"],
            paths: canonical_paths
          )
        }
      end

      def validate_snapshot!(repository_snapshot)
        unless repository_snapshot.is_a?(Hash) &&
               repository_snapshot.keys.sort == SNAPSHOT_KEYS &&
               repository_snapshot["kind"] == "git" &&
               /\A[0-9a-f]{40}\z/.match?(repository_snapshot["commit_sha"].to_s) &&
               Identifiers.digest?(repository_snapshot["tree_digest"])
          raise ContractError.new(
            "derived_input_invalid",
            "repository snapshot must be the exact git snapshot shape (kind, commit_sha, tree_digest)",
            path: "repository_snapshot"
          )
        end
      end
      private_class_method :validate_snapshot!
    end
  end
end
