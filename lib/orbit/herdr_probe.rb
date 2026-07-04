# frozen_string_literal: true

def herdr_command_path
  command_path("herdr")
end

def herdr_available?
  path = herdr_command_path
  return false unless path

  _stdout, _stderr, status = Open3.capture3(path, "--version")
  status.success?
end

def herdr_parse_json(stdout)
  parsed = JSON.parse(stdout)
  parsed.is_a?(Hash) ? parsed : {}
rescue JSON::ParserError
  {}
end

def herdr_probe_agent_list
  path = herdr_command_path
  return { "success" => false, "reason" => "herdr_not_found", "agents" => [] } unless path

  stdout, stderr, status = Open3.capture3(path, "agent", "list")
  parsed = herdr_parse_json(stdout)
  agents = parsed.dig("result", "agents") || parsed["agents"] || []
  {
    "success" => status.success?,
    "exit_status" => status.exitstatus,
    "stdout" => stdout,
    "stderr" => stderr,
    "agents" => agents.is_a?(Array) ? agents : []
  }
end

def herdr_probe_agents_for_panes(panes)
  pane_ids = Array(panes).map(&:to_s).reject(&:empty?)
  list = herdr_probe_agent_list
  candidates = list["agents"].select do |entry|
    entry.is_a?(Hash) && pane_ids.include?(entry["pane_id"].to_s)
  end
  list.merge(
    "candidate_count" => candidates.length,
    "candidates" => candidates.map { |entry| compact_herdr_agent_entry(entry) }
  )
end

def herdr_current_context
  {
    "session" => non_empty_env("HERDR_SESSION_ID", "HERDR_SESSION"),
    "workspace" => non_empty_env("HERDR_WORKSPACE_ID", "HERDR_WORKSPACE", "HERDR_SPACE_ID", "HERDR_SPACE"),
    "tab" => non_empty_env("HERDR_TAB_ID", "HERDR_TAB"),
    "pane" => ENV["HERDR_PANE_ID"].to_s
  }
end

def herdr_agent_matches_session?(agent, session)
  return false unless agent.is_a?(Hash) && session.is_a?(Hash)

  expected_client = session["client"].to_s
  expected_cwd = expanded_path_for_compare(session["project_root"])
  actual_client = agent["agent"].to_s
  return false if expected_client.empty? || actual_client.empty?

  cwd_matches = %w[cwd foreground_cwd project_root].any? do |field|
    expanded_path_for_compare(agent[field]) == expected_cwd
  end
  client_matches = actual_client == expected_client
  cwd_matches && client_matches
end
