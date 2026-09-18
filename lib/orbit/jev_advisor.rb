# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

module Orbit
  # A bounded semantic observation. Jev supplies probabilities; TaskRuntime
  # owns every check, correction and stop decision.
  class JevAdvisor
    ENDPOINT = URI("https://api.typesafe.ai/v1/systemone")
    MODEL = "jev-latest"
    QUESTIONS = {
      "stuck" => {
        "type" => "noul",
        "instructions" => "Is the coding agent likely unable to make useful progress on the current task now? Do not infer this from elapsed time alone; ordinary exploration or a single failed command is not stuckness.",
        "criteria" => { "true" => "Repeated failure or inactivity without a useful new approach", "false" => "Useful work is continuing or the evidence is insufficient" }
      },
      "off_track" => {
        "type" => "noul",
        "instructions" => "Is recent work likely outside or contrary to the latest effective user request? Normal investigation, tests and necessary setup can be relevant work.",
        "criteria" => { "true" => "Concrete recent activity appears unrelated or contrary to the request", "false" => "Activity appears relevant or the evidence is insufficient" }
      },
      "artifact_ready" => {
        "type" => "noul",
        "instructions" => "Would a full independent review of the current artifact now likely provide useful, current feedback? Consider whether the agent is actively changing it and the review would quickly become stale.",
        "criteria" => { "true" => "A meaningful artifact checkpoint is available now", "false" => "The artifact is still too early or actively changing" }
      }
    }.freeze

    class Error < StandardError; end

    AMENDMENT_BUDGET = 8000
    AMENDMENT_TEXT_LIMIT = 1200

    def self.for_project(project_root, env: ENV)
      return nil if env["TYPESAFE_API_KEY"].to_s.empty?
      return nil if File.exist?(File.join(project_root, ".orbit", "jev-disabled"))

      new(api_key: env["TYPESAFE_API_KEY"])
    end

    def initialize(api_key:, endpoint: ENDPOINT)
      @api_key = api_key.to_s
      @endpoint = endpoint
    end

    def assess(state:)
      raise Error, "TYPESAFE_API_KEY is missing" if @api_key.empty?

      request = Net::HTTP::Post.new(@endpoint)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate("model" => MODEL, "state" => state, "questions" => QUESTIONS)
      response = Net::HTTP.start(@endpoint.host, @endpoint.port, use_ssl: @endpoint.scheme == "https",
                                 open_timeout: 3, read_timeout: 5, write_timeout: 3) do |http|
        http.request(request)
      end
      raise Error, "TypeSafe HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body)
      raise Error, "invalid TypeSafe response" unless payload.is_a?(Hash) && payload["answers"].is_a?(Hash) &&
                                                      payload["model"].is_a?(String)
      answers = payload.fetch("answers")
      scores = QUESTIONS.to_h do |name, _question|
        answer = answers.fetch(name)
        raise Error, "invalid #{name} answer" unless answer.is_a?(Hash)
        value = answer.fetch("noul")
        raise Error, "invalid #{name} answer" unless answer["type"] == "noul" && value.is_a?(Numeric) && value.finite? && value.between?(0, 1)

        [name, value]
      end
      { "model" => payload.fetch("model"), "scores" => scores, "usage" => payload["usage"] }
    rescue Error
      raise
    rescue StandardError => error
      raise Error, "TypeSafe assessment failed: #{error.class}"
    end

    def self.observation(inputs:, host:, members:, project_root:, artifact_digest:, elapsed_seconds:)
      amendments, omitted = bounded_amendments(inputs.fetch("amendments", []))
      {
        "instruction" => limit(inputs.fetch("instruction"), 4000),
        "amendments" => amendments,
        "amendments_omitted" => omitted,
        "host" => host.slice("status", "turn_id", "last_turn_id", "last_turn_status", "active_tools"),
        "recent_observations" => observation_tail(host["observations"]),
        "members" => members.last(5).map do |member|
          { "status" => member["status"], "error" => limit(member["error"], 300),
            "result_excerpt" => tail_text(JSON.generate(member["result"]), 1000) }
        end,
        "artifact_digest" => artifact_digest,
        "changes" => git_changes(project_root),
        "elapsed_seconds" => elapsed_seconds.to_i
      }
    end

    def self.limit(value, size)
      text = value.to_s
      text.length > size ? "#{text[0, size]}…[truncated]" : text
    end

    # Newest effective amendments are kept under a character budget. When
    # older ones do not fit, the omitted range is explicit: Jev must not treat
    # missing earlier context as evidence that work went off track.
    def self.bounded_amendments(amendments, budget: AMENDMENT_BUDGET)
      selected = []
      remaining = budget
      amendments.reverse_each do |entry|
        text = limit(entry.fetch("text"), AMENDMENT_TEXT_LIMIT)
        break if text.length > remaining

        selected.unshift(text)
        remaining -= text.length
      end
      omitted = amendments.length - selected.length
      omitted_info = if omitted.positive?
                       { "count" => omitted, "included_range" => "#{omitted + 1}-#{amendments.length}",
                         "note" => "Older effective user changes were omitted by the input budget; " \
                                   "missing earlier context is not evidence of going off track." }
                     end
      [selected, omitted_info]
    end

    def self.observation_tail(observations)
      return tail_text(JSON.generate(observations), 5000) unless observations.is_a?(Array)

      remaining = 5000
      latest = []
      observations.reverse_each do |item|
        break if remaining < 200

        text = tail_text(JSON.generate(item), [remaining, 1800].min)
        latest.unshift(text)
        remaining -= text.length
      end
      { "omitted_older_entries" => observations.length - latest.length, "latest_entries_json" => latest }
    end

    def self.tail_text(value, size)
      return value if value.length <= size

      prefix = "[older content truncated]…"
      "#{prefix}#{value[-(size - prefix.length), size - prefix.length]}"
    end

    def self.git_changes(root)
      status = git_read(root, ["status", "--short", "--untracked-files=normal"], 2000)
      diff = git_read(root, ["diff", "--no-ext-diff", "--no-textconv", "--unified=0", "HEAD", "--"], 4000)
      { "status" => status, "diff_excerpt" => diff }
    end

    def self.git_read(root, args, limit)
      IO.popen(["git", "-C", root, *args], err: File::NULL) { |io| io.read(limit) }.to_s
    rescue Errno::ENOENT, IOError, SystemCallError
      ""
    end
  end
end
