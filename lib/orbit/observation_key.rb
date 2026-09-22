# frozen_string_literal: true

require "digest"
require "json"

module Orbit
  # Deterministic observation key for check deduplication (slice C). A pure
  # function: no persistence, no network, no models. The runtime wires the
  # pieces later; this module only canonicalizes what it is given.
  #
  # Semantics: the same observation (same effective input version, canonical
  # artifact root, artifact digest, stable host state, open findings, dispute
  # and trigger) always yields the same key; any substantive change in one of
  # those dimensions must change the key. Transient noise — timestamps, poll
  # counters, hash insertion order, tool order — never does.
  module ObservationKey
    class Error < StandardError; end

    # Material schema version; bump when the canonical structure changes so
    # old keys never silently alias new semantics.
    VERSION = 1
    # Only the newest host observations are material; each is hashed so large
    # outputs never get copied into the key material.
    OBSERVATION_TAIL = 10
    # Per-string bound inside canonical material: a bounded prefix plus the
    # full original's SHA-256 and length, so a substantive change anywhere —
    # including deep in the tail — still changes the key while the material
    # itself stays small. The key output is always 64 hex chars.
    STRING_CAP = 2000
    OPEN = "open"
    # Root/input/artifact identity is already represented as top-level key
    # material. Finding provenance records when Orbit observed it; including
    # those duplicate fields would manufacture one extra observation after a
    # finding is carried forward unchanged.
    TRANSIENT_FINDING_FIELDS = %w[status check observed_root observed_version observed_input].freeze

    module_function

    def build(input_digest:, artifact_root:, artifact_digest:, host:, findings:, dispute: nil, trigger: nil)
      Digest::SHA256.hexdigest(JSON.generate(
        material(input_digest: input_digest, artifact_root: artifact_root, artifact_digest: artifact_digest,
                 host: host, findings: findings, dispute: dispute, trigger: trigger)
      ))
    end

    # The canonical, JSON-serializable structure the key hashes. Exposed so
    # wiring can log or debug what changed without recomputing heuristics.
    def material(input_digest:, artifact_root:, artifact_digest:, host:, findings:, dispute: nil, trigger: nil)
      {
        "version" => VERSION,
        "input_digest" => bound_string(input_digest),
        "artifact_root" => canonical_artifact_root(artifact_root),
        "artifact_digest" => bound_string(artifact_digest),
        "host" => host_material(host),
        "open_findings" => open_findings_material(findings),
        "dispute" => normalize(dispute),
        "trigger" => normalize(trigger)
      }
    end

    # Deep-canonical form: hash keys are sorted and every string is bounded,
    # so neither insertion order nor oversized content affects the result.
    def normalize(value)
      case value
      when Hash
        value.sort_by { |key, _| key.to_s }.to_h { |key, entry| [key.to_s, normalize(entry)] }
      when Array
        value.map { |entry| normalize(entry) }
      when String
        bound_string(value)
      when Symbol
        value.to_s
      else
        value
      end
    end

    def bound_string(value)
      text = value.to_s
      return text if text.length <= STRING_CAP

      "#{text[0, STRING_CAP]}…[#{text.length}:#{Digest::SHA256.hexdigest(text)}]"
    end

    # realpath keeps the key independent of symlink spelling; a missing or
    # non-directory root is a wiring bug and fails loudly, never a best-effort
    # string.
    def canonical_artifact_root(path)
      raise Error, "artifact_root is required" if path.to_s.strip.empty?

      real = File.realpath(path.to_s)
      raise Error, "artifact_root is not a directory: #{path}" unless File.directory?(real)

      real
    rescue SystemCallError => error
      raise Error, "artifact_root is not resolvable: #{path} (#{error.class})"
    end

    # Compatible with TaskRuntime#host_digest's stable fields, plus the host
    # status that decides delivery checks; transient fields (timestamps, poll
    # counts, turn counters, tool order, interruption flags) stay out.
    def host_material(host)
      raise Error, "host must be a Hash" unless host.is_a?(Hash)

      observations = host["observations"]
      raise Error, "host observations must be an Array" unless observations.nil? || observations.is_a?(Array)

      {
        "status" => host["status"],
        "last_turn_id" => host["last_turn_id"],
        "last_turn_status" => host["last_turn_status"],
        "observations" => (observations || []).last(OBSERVATION_TAIL).map do |entry|
          Digest::SHA256.hexdigest(JSON.generate(normalize(entry)))
        end
      }
    end

    # Accepts the runtime shape (Hash keyed by finding id) or a plain Array of
    # finding hashes. Only open findings enter, keyed by their stable id and
    # sorted; per-finding provenance counters (status, check number) are
    # dropped so an identical refiling does not masquerade as a new
    # observation. Hash insertion order and input order never affect the key.
    def open_findings_material(findings)
      entries =
        case findings
        when Hash
          findings.map { |id, finding| finding_material(id, finding) }
        when Array
          findings.map { |finding| finding_material(nil, finding) }
        when nil
          []
        else
          raise Error, "findings must be a Hash or an Array"
        end
      entries.compact.sort_by { |entry| entry.fetch("id") }
    end

    def finding_material(key_id, finding)
      raise Error, "finding must be a Hash" unless finding.is_a?(Hash)
      return nil unless finding["status"].nil? || finding["status"] == OPEN

      id = finding["id"] || key_id
      raise Error, "finding id is required" if id.nil?

      normalize(finding.reject { |field, _| TRANSIENT_FINDING_FIELDS.include?(field) }).merge("id" => id.to_s)
    end
  end
end
