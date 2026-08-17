# frozen_string_literal: true

require_relative "errors"
require_relative "identifiers"
require_relative "protocol_root"
require_relative "task_scopes"

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

      # Task-scoped trust-boundary proof for the four task-local store
      # seams. Extends marker_for (whose assertion and error codes are
      # untouched) with a canonical task-scope identity assertion: the
      # fully-resolved path of <canonical active root>/tasks/<task_id>
      # must equal that exact canonical join — equality of two resolved
      # paths, never prefix matching — so a symlinked tasks/ or task
      # segment can never redirect a store. The task_id is pattern-checked
      # here (no separators or traversal) before any path is joined.
      # Returns [marker, canonical_active_root, canonical_task_dir]; the
      # callers MUST use the returned canonical directories for every
      # subsequent file operation (the verified path is the opened path).
      def task_scope(active_root, task_id, code:, label:)
        unless task_id.is_a?(String) && Identifiers.valid?("task_id", task_id)
          raise ContractError.new(
            code,
            "#{label} requires a canonical task_id scope",
            path: label,
            details: { "task_id" => task_id.is_a?(String) ? task_id : task_id.inspect }
          )
        end
        marker = marker_for(active_root, code: code, label: label)
        canonical_active_root = File.realpath(active_root)
        canonical_task_dir = File.join(canonical_active_root, TASK_SCOPES_SEGMENT, task_id)
        begin
          real_task_dir = File.realpath(canonical_task_dir)
        rescue Errno::ENOENT, Errno::ENOTDIR
          raise ContractError.new(
            code,
            "#{label} task scope directory does not exist under the canonical active root",
            path: label,
            details: { "canonical_task_dir" => canonical_task_dir }
          )
        end
        unless real_task_dir == canonical_task_dir
          raise ContractError.new(
            code,
            "#{label} task scope is not the canonical task directory of its ProtocolRoot marker",
            path: label,
            details: {
              "canonical_task_dir" => canonical_task_dir,
              "resolved_task_dir" => real_task_dir
            }
          )
        end
        [marker, canonical_active_root, canonical_task_dir]
      end
    end
  end
end
