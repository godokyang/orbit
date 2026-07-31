# frozen_string_literal: true

require_relative "canonical_json"

module Orbit
  module V2
    module WorkAuthority
      module_function

      PURPOSE_ACTIONS = {
        "implementation" => "work.implement",
        "review" => "gate.review.evaluate",
        "test" => "gate.test.evaluate",
        "adjudication" => "gate.adjudication.evaluate",
        "research" => "work.research",
        "release" => "gate.release.evaluate"
      }.freeze
      WORK_UNIT_PURPOSES = {
        "implementation" => %w[implementation],
        "evaluation" => %w[review test adjudication release],
        "research" => %w[research],
        "release" => %w[release]
      }.freeze
      ACTIONS = PURPOSE_ACTIONS.values.freeze

      def action?(action)
        ACTIONS.include?(action)
      end

      def action_for_purpose(purpose)
        PURPOSE_ACTIONS[purpose]
      end

      def purpose_allowed_for_kind?(purpose, work_unit_kind)
        Array(WORK_UNIT_PURPOSES[work_unit_kind]).include?(purpose)
      end

      def scope_digest(work_unit, task_revision, action)
        CanonicalJSON.content_digest(
          "schema_version" => "orbit-work-authority-scope-v1",
          "project_id" => work_unit.fetch("project_id"),
          "task_id" => work_unit.fetch("task_id"),
          "task_revision_ref" => {
            "task_revision_id" => task_revision.fetch("task_revision_id"),
            "content_digest" => task_revision.fetch("content_digest")
          },
          "work_unit" => {
            "work_unit_id" => work_unit.fetch("work_unit_id"),
            "work_unit_kind" => work_unit.fetch("work_unit_kind"),
            "objective" => work_unit.fetch("objective"),
            "scope" => work_unit.fetch("scope"),
            "input_refs" => work_unit.fetch("input_refs"),
            "output_refs" => work_unit.fetch("output_refs"),
            "stop_conditions" => work_unit.fetch("stop_conditions"),
            "acceptance_refs" => work_unit.fetch("acceptance_refs"),
            "evidence_requirement_refs" => work_unit.fetch("evidence_requirement_refs"),
            "source_requirement_refs" => work_unit.fetch("source_requirement_refs"),
            "initial_change_thesis_ref" => work_unit.fetch("initial_change_thesis_ref"),
            "allowed_actions" => work_unit.dig("authority_scope", "allowed_actions"),
            "forbidden_actions" => work_unit.dig("authority_scope", "forbidden_actions"),
            "writable_paths" => work_unit.dig("authority_scope", "writable_paths")
          },
          "action" => action
        )
      end
    end
  end
end
