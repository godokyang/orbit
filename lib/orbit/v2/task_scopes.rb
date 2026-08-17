# frozen_string_literal: true

module Orbit
  module V2
    # Task-local storage segment (2026-08-17 task-centric revision). The
    # name is DELIBERATELY distinct from every KNOWN_V1_AUTHORITY_PATHS
    # entry: ProtocolRoot.create runs its v1 mixed-epoch scan
    # UNCONDITIONALLY BEFORE the create-only marker check
    # (protocol_root.rb reject_mixed_epoch!), so a colliding segment would
    # make legitimate v2 data permanently indistinguishable from a v1
    # mixed epoch — a legal v2 root could never re-run ProtocolRoot.create
    # (e.g. idempotent replay). The runtime guard next to
    # KNOWN_V1_AUTHORITY_PATHS (protocol_root.rb) fails immediately if
    # anyone reintroduces a collision (tasks, evidence, rules, ...).
    #
    # This file is a ZERO-REQUIRE leaf so every other v2 file may load it
    # from any point of the (cyclic) require graph without introducing a
    # load-order dependency.
    TASK_SCOPES_SEGMENT = "task-scopes".freeze
  end
end
