# frozen_string_literal: true

require_relative "errors"
require_relative "protocol_root"

module Orbit
  module V2
    # Shared canonical-active-root proof for the durable store seams
    # (PolicyStore rotation, ControlStore genesis/resolve). An artifact
    # store may extend/read an active trust root ONLY when its active_root
    # IS the ProtocolRoot marker's canonical real active root:
    # File.realpath(active_root) must equal <canonical project root>/.orbit
    # (containment through symlinks), so a sibling/shadow/alias store can
    # never borrow the marker's pin. The marker is then read at that
    # canonical project root (Inc2 containment/canonicalization re-verified
    # by ProtocolRoot.read). Missing/corrupt markers or non-canonical roots
    # fail closed with the caller-provided code.
    module ActiveRoot
      module_function

      def marker_for(active_root, code:, label:)
        canonical_project_root = File.realpath(File.dirname(active_root))
        canonical_active_root = File.join(canonical_project_root, ".orbit")
        unless File.realpath(active_root) == canonical_active_root
          raise ContractError.new(
            code,
            "#{label} is not the canonical real active root of its ProtocolRoot marker",
            path: label,
            details: {
              "active_root" => File.expand_path(active_root),
              "canonical_active_root" => canonical_active_root
            }
          )
        end
        ProtocolRoot.read(project_root: canonical_project_root)
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise ContractError.new(
          code,
          "#{label} is not the canonical real active root of its ProtocolRoot marker",
          path: label
        )
      rescue ContractError => e
        raise e if e.code == code

        raise ContractError.new(
          code,
          "#{label} requires a valid in-root ProtocolRoot marker",
          path: label,
          details: { "cause" => e.code, "message" => e.message }
        )
      end
    end
  end
end
