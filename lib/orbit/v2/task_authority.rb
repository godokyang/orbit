# frozen_string_literal: true

require_relative "canonical_json"

module Orbit
  module V2
    module TaskAuthority
      module_function

      ACTIONS = %w[
        task.adjudication_authority.delegate
        task.risk_authority.delegate
        task.waiver_authority.delegate
      ].freeze

      def action?(action)
        ACTIONS.include?(action)
      end

      def scope_digest(task_revision)
        CanonicalJSON.content_digest(
          "schema_version" => "orbit-task-authority-scope-v1",
          "project_id" => task_revision.fetch("project_id"),
          "task_id" => task_revision.fetch("task_id"),
          "task_revision_ref" => {
            "task_revision_id" => task_revision.fetch("task_revision_id"),
            "content_digest" => task_revision.fetch("content_digest")
          }
        )
      end
    end
  end
end
