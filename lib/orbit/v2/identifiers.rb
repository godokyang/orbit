# frozen_string_literal: true

module Orbit
  module V2
    module Identifiers
      module_function

      HEX_DIGEST = /\Asha256:[0-9a-f]{64}\z/.freeze
      CONTENT_ADDRESS = /\Arr-sha256-[0-9a-f]{64}\z/.freeze
      PATTERNS = {
        "project_id" => /\Aoproj_[a-z0-9][a-z0-9_-]{7,63}\z/,
        "policy_revision_id" => /\Aopolicy_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "task_id" => /\Aotask_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "task_revision_id" => /\Atrev_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "work_unit_id" => /\Aowu_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "attempt_id" => /\Aoattempt_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "agent_instance_id" => /\Aoagent_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "logical_lead_id" => /\Aolead_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "lead_session_id" => /\Aoleadsession_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "change_thesis_id" => /\Aothesis_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "evidence_record_id" => /\Aoevr_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "gate_requirement_id" => /\Aogreq_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "gate_lineage_id" => /\Aogline_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "gate_evaluation_id" => /\Aogeval_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "finding_id" => /\Aofinding_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "finding_resolution_id" => /\Aofres_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "authorization_record_id" => /\Aoauthz_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "assertion_id" => /\Aoassert_[a-z0-9][a-z0-9_-]{7,95}\z/,
        "event_id" => /\Aoevent_[a-z0-9][a-z0-9_-]{7,95}\z/
      }.freeze

      def valid?(kind, value)
        pattern = PATTERNS.fetch(kind)
        value.is_a?(String) && pattern.match?(value)
      end

      def digest?(value)
        value.is_a?(String) && HEX_DIGEST.match?(value)
      end

      def content_address?(value)
        value.is_a?(String) && CONTENT_ADDRESS.match?(value)
      end
    end
  end
end
