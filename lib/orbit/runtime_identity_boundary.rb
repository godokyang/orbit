# frozen_string_literal: true

HERDR_RUNTIME_IDENTITY_BOUNDARY_SCHEMA = "orbit-herdr-runtime-identity-boundary-v1"

def runtime_identity_boundary
  {
    "schema_version" => HERDR_RUNTIME_IDENTITY_BOUNDARY_SCHEMA,
    "adapter" => "herdr",
    "status" => "unavailable",
    "reason" => "herdr_public_api_no_authenticated_caller_pane",
    "detail" => "Herdr exposes pane control and observation, but its public CLI, socket API, integrations, and plugins do not authenticate the calling process to a pane. Orbit therefore cannot issue Herdr-verified runtime identity.",
    "safe_capabilities" => %w[agent.start pane.capture],
    "disabled_capabilities" => %w[verified_identity direct.dispatch],
    "required_upstream_primitive" => "An authenticated server-owned assertion that binds the calling process to a live pane and can be independently reverified."
  }
end
