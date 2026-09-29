# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "time"
require "uri"

module Orbit
  # Optional user-level snapshot of the public OpenRouter model catalog,
  # consumed as a sourced-but-weak prior for checker quality ordering
  # (docs/reference/openrouter-model-mapping-audit.md). It is not an inference
  # route, not a substitute for the TypeSafe key and never proof that a
  # candidate matches the task: a coding index is a third-party Artificial
  # Analysis number carried by OpenRouter's catalog, with no measurement date,
  # no pricing and no end-to-end latency for the OMP execution route.
  #
  # Credential and gates. The only accepted credential is OPENROUTER_API_KEY
  # from the process environment (set up by `orbit openrouter setup`); project
  # `.env` files, TYPESAFE_API_KEY and every other secret are ignored. Without
  # the key, or while the project root carries `.orbit/jev-disabled`, both
  # #refresh and #lookup return early: zero HTTP requests and zero reads of a
  # previously cached snapshot, so removing the key never keeps old priors
  # alive. The key itself never reaches task records, logs, the snapshot or
  # error messages; only a salted-free SHA-256 digest of it is stored so a
  # rotated key cannot silently reuse the previous account's snapshot.
  #
  # Snapshot lifecycle. #refresh is called by the caller's pre-start phase,
  # never lazily from #lookup. A successful fetch of the official
  # GET /api/v1/models (Bearer auth, bounded open/read timeouts, pagination
  # links followed to completion) is fully validated before one atomic 0600
  # write; a fresh snapshot is reused for 72 hours, and a cross-process flock
  # on a sibling lock file coordinates concurrent tasks into a single fetch
  # (freshness is re-checked under the lock). Every failure — network, HTTP
  # error, invalid JSON, invalid structure, unterminated pagination or a
  # response that delivers fewer models than its own total_count without a
  # continuation — records a key-free error with the attempt time and applies
  # a short backoff window instead of retrying per task. Missing or absent
  # fields and null benchmark scores never manufacture capability.
  #
  # Mapping. OMP's provider/model/reasoning/billing_route execution identity
  # is not an OpenRouter identity. It is resolved through explicit, audited
  # mapping files: a read-only shipped default list (lib/orbit/data/
  # openrouter-model-map.json, maintained by Orbit reviewers) plus a
  # user-level override at ${XDG_CONFIG_HOME:-$HOME/.config}/orbit/
  # openrouter-model-map.json that wins per full identity. Entries without
  # complete identity, the audited OpenRouter row id and canonical_slug pair
  # and 1-5 supporting source URLs are invalid and ignored — never name
  # guessing or suffix stripping. Catalog rows are indexed by their real row
  # id with their own canonical_slug stored alongside (`~`-prefixed alias
  # rows are skipped and never mappable); at lookup time the audited row must
  # still exist and still carry the audited canonical_slug, otherwise the
  # mapping is suspended as "unavailable" pending re-audit instead of being
  # silently re-pointed. Only exact billing_route identity matches; a
  # concrete reasoning value conflicting with the mapping's verified variant
  # is "unmapped", while an unverified variant only yields a prior
  # explicitly labeled as such.
  #
  # #lookup is pure local read-only: no HTTP, no writes, no locking. It
  # returns {"status" => ..., "prior" => ...} where prior (fresh snapshots
  # with a verified mapping and a non-null coding_index only) is bounded to
  # canonical_slug, coding_index, agentic_index, fetched_at, sources and
  # reasoning_note.
  class OpenRouterModelOverview
    SCHEMA_VERSION = "orbit-openrouter-model-overview-v1"
    MAP_SCHEMA_VERSION = "orbit-openrouter-model-map-v1"
    CACHE_DIRECTORY = "orbit"
    FILE_NAME = "openrouter-model-overview-v1.json"

    MODELS_URL = "https://openrouter.ai/api/v1/models"
    BENCHMARK_SOURCE = "https://artificialanalysis.ai"

    TTL_SECONDS = 72 * 60 * 60
    RETRY_BACKOFF_SECONDS = 10 * 60
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 15
    MAX_PAGES = 50

    MAX_FILE_BYTES = 8 * 1024 * 1024
    MAX_RESPONSE_BYTES = 16 * 1024 * 1024
    MAX_MAP_FILE_BYTES = 256 * 1024
    MAX_MODELS = 5000
    MAX_MODALITIES = 8
    MAX_NAME_LENGTH = 120
    MAX_DESCRIPTION_LENGTH = 280
    MAX_URL_LENGTH = 2048
    MAX_SOURCES = 5
    MAX_ERROR_LENGTH = 200
    MAX_VERIFIED_BY_LENGTH = 64
    CLOCK_SKEW_SECONDS = 300

    PROVIDER_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:+@\/-]*\z/
    IDENTIFIER_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:+@\/-]*\z/
    SLUG_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._\/:+-]*\z/
    REASONING_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
    MODEL_PATTERN = %r{\A[^\s/]+/[^\s]+\z}
    TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
    CONTROL_CHARS = /[\x00-\x1F\x7F]/

    BILLING_ROUTES = %w[direct_api subscription_quota unknown].freeze
    MAP_ENTRY_KEYS = %w[provider model reasoning billing_route openrouter_id canonical_slug sources verified_at verified_by].freeze
    PRIOR_KEYS = %w[canonical_slug coding_index agentic_index fetched_at sources reasoning_note].freeze

    STATUS_FRESH = "fresh"
    STATUS_STALE = "stale"
    STATUS_UNMAPPED = "unmapped"
    STATUS_NO_BENCHMARK = "no_benchmark"
    STATUS_NOT_CONFIGURED = "not_configured"
    STATUS_DISABLED = "disabled"
    STATUS_UNAVAILABLE = "unavailable"
    STATUS_ERROR = "error"
    STATUS_BACKOFF = "backoff"

    class Error < StandardError; end

    # XDG_CACHE_HOME only counts when absolute; otherwise `home/.cache` is
    # used, as the XDG base directory specification requires.
    def self.default_cache_path(env: ENV, home: nil)
      cache_home = env["XDG_CACHE_HOME"].to_s
      base = cache_home.start_with?("/") ? cache_home : File.join(home_directory(env: env, home: home), ".cache")
      File.join(base, CACHE_DIRECTORY, FILE_NAME)
    end

    def self.default_map_path(env: ENV, home: nil)
      config_home = env["XDG_CONFIG_HOME"].to_s
      base = config_home.start_with?("/") ? config_home : File.join(home_directory(env: env, home: home), ".config")
      File.join(base, CACHE_DIRECTORY, "openrouter-model-map.json")
    end

    def self.shipped_map_path
      File.join(__dir__, "data", "openrouter-model-map.json")
    end

    def self.home_directory(env:, home: nil)
      candidate = home.to_s.empty? ? env["HOME"].to_s : home.to_s
      candidate.empty? ? Dir.home : candidate
    end

    attr_reader :cache_path, :map_path

    # `http_get` is injectable for deterministic tests: it receives
    # `url:`/`headers:` keyword arguments and must return
    # [Integer status, String body]. `map_path` overrides the user-level
    # mapping file only; the shipped default list is always read as well.
    def initialize(env: ENV, home: nil, clock: -> { Time.now.utc }, cache_path: nil, map_path: nil, http_get: nil)
      @env = env
      @api_key = env["OPENROUTER_API_KEY"].to_s.strip
      @clock = clock
      default = self.class.default_cache_path(env: env, home: home)
      @cache_path = File.expand_path(cache_path.nil? || cache_path.to_s.empty? ? default : cache_path.to_s)
      default_map = self.class.default_map_path(env: env, home: home)
      @map_path = File.expand_path(map_path.nil? || map_path.to_s.empty? ? default_map : map_path.to_s)
      @http_get = http_get || method(:net_http_get)
    end

    # Pre-start refresh. Returns a key-free status summary:
    # "fresh" (with fetched_at/model_count), "not_configured", "disabled",
    # "error" (with error) or "backoff" (with retry_in_seconds/last_error).
    # Local filesystem failures raise Error; every remote failure is reported
    # through the returned status and recorded with a short backoff.
    def refresh(project_root:)
      return { "status" => STATUS_DISABLED } if project_disabled?(project_root)
      return { "status" => STATUS_NOT_CONFIGURED } if @api_key.empty?

      with_lock do
        document = read_document
        return fresh_status(document) if snapshot_current?(document)

        # Backoff belongs to the key that failed it: a corrected
        # OPENROUTER_API_KEY retries immediately, and the old account's
        # snapshot is already unusable through the digest check above.
        remaining = if document.is_a?(Hash) && document["key_digest"] == key_digest
                      backoff_remaining(document["last_attempt"])
                    else
                      0
                    end
        if remaining.positive?
          return { "status" => STATUS_BACKOFF, "retry_in_seconds" => remaining,
                   "last_error" => error_text(document.is_a?(Hash) ? document["last_attempt"] : nil) }
        end

        begin
          document = fetch_snapshot
        rescue Error => error
          record_failure(document, error.message)
          return { "status" => STATUS_ERROR, "error" => bounded_text(error.message, MAX_ERROR_LENGTH) }
        end
        write_document(document)
        { "status" => STATUS_FRESH, "fetched_at" => document.fetch("fetched_at"),
          "model_count" => document.fetch("models").length }
      end
    end

    # Pure local read-only lookup of one OMP candidate identity
    # ("provider/model" plus reasoning/billing_route). Returns
    # {"status" => ..., "prior" => ...} with the statuses STATUS_FRESH,
    # STATUS_STALE, STATUS_UNMAPPED, STATUS_NO_BENCHMARK,
    # STATUS_NOT_CONFIGURED, STATUS_DISABLED and STATUS_UNAVAILABLE. `prior`
    # is non-nil only for "fresh" and is bounded to PRIOR_KEYS.
    def lookup(model:, reasoning: "unknown", billing_route: "unknown", project_root:)
      return { "status" => STATUS_DISABLED, "prior" => nil } if project_disabled?(project_root)
      return { "status" => STATUS_NOT_CONFIGURED, "prior" => nil } if @api_key.empty?

      document = read_document
      return { "status" => STATUS_STALE, "prior" => nil } unless snapshot_current?(document)
      return { "status" => STATUS_UNMAPPED, "prior" => nil } unless model.to_s.match?(MODEL_PATTERN)

      provider, model_id = model.to_s.split("/", 2)
      entry = mapping_for(provider: provider, model: model_id,
                          reasoning: normalize_reasoning(reasoning), billing_route: billing_route)
      return { "status" => STATUS_UNMAPPED, "prior" => nil } unless entry

      record = document.fetch("models")[entry.fetch("openrouter_id")]
      return { "status" => STATUS_UNAVAILABLE, "prior" => nil } unless record.is_a?(Hash)
      return { "status" => STATUS_UNAVAILABLE, "prior" => nil } unless record["canonical_slug"] == entry.fetch("canonical_slug")

      coding = record["coding_index"]
      return { "status" => STATUS_NO_BENCHMARK, "prior" => nil } unless coding.is_a?(Numeric)

      { "status" => STATUS_FRESH,
        "prior" => { "canonical_slug" => entry.fetch("canonical_slug"),
                     "coding_index" => coding,
                     "agentic_index" => record["agentic_index"].is_a?(Numeric) ? record["agentic_index"] : nil,
                     "fetched_at" => document.fetch("fetched_at"),
                     "sources" => prior_sources(entry),
                     "reasoning_note" => reasoning_note(requested: normalize_reasoning(reasoning), entry: entry) } }
    end

    # Read-only diagnostics for `orbit model-status`: never contacts the
    # network, never writes, and reads the cache only behind the same
    # disabled/not-configured gates as #lookup. Returns a key-free Hash:
    # "status" ("fresh"|"stale"|"not_configured"|"disabled"; "stale" covers a
    # missing, corrupt, expired or key-rotated snapshot), then, when known,
    # "fetched_at", "source", "model_count", "last_attempt_at",
    # "last_attempt" ("ok"|"error"), "last_error" and "key_rotated", plus the
    # resolved "cache_path" and "map_path".
    def status(project_root:)
      info = { "status" => nil, "cache_path" => @cache_path, "map_path" => @map_path }
      return info.merge("status" => STATUS_DISABLED) if project_disabled?(project_root)
      return info.merge("status" => STATUS_NOT_CONFIGURED) if @api_key.empty?

      document = read_document
      info["status"] = snapshot_current?(document) ? STATUS_FRESH : STATUS_STALE
      if document.is_a?(Hash)
        models = document["models"]
        info["fetched_at"] = document["fetched_at"] if document["fetched_at"].is_a?(String)
        info["source"] = document["source"] if document["source"].is_a?(String)
        info["model_count"] = models.is_a?(Hash) ? models.length : nil
        info["key_rotated"] = document["key_digest"] != key_digest
        attempt = document["last_attempt"]
        if attempt.is_a?(Hash)
          info["last_attempt_at"] = attempt["at"] if attempt["at"].is_a?(String)
          info["last_attempt"] = attempt["outcome"] if attempt["outcome"].is_a?(String)
          info["last_error"] = attempt["error"] if attempt["error"].is_a?(String)
        end
      end
      info
    end

    private

    def project_disabled?(project_root)
      File.exist?(File.join(project_root.to_s, ".orbit", "jev-disabled"))
    end

    def key_digest
      Digest::SHA256.hexdigest(@api_key)
    end

    def snapshot_current?(document)
      return false unless document.is_a?(Hash) && document["schema_version"] == SCHEMA_VERSION
      return false unless document["models"].is_a?(Hash) && document["key_digest"].is_a?(String)

      fetched_at = parse_time(document["fetched_at"])
      return false if fetched_at.nil? || now >= fetched_at + TTL_SECONDS

      document["key_digest"] == key_digest
    end

    def fresh_status(document)
      { "status" => STATUS_FRESH, "fetched_at" => document.fetch("fetched_at"),
        "model_count" => document.fetch("models").length }
    end

    def backoff_remaining(attempt)
      return 0 unless attempt.is_a?(Hash) && attempt["outcome"] == "error"

      attempted_at = parse_time(attempt["at"])
      return 0 if attempted_at.nil?

      remaining = RETRY_BACKOFF_SECONDS - (now - attempted_at)
      remaining.positive? ? remaining.ceil : 0
    end

    def error_text(attempt)
      attempt.is_a?(Hash) ? attempt["error"].to_s : ""
    end

    # A missing, corrupt, oversized or foreign-schema cache file reads as no
    # document: the snapshot is regenerable, so the next refresh rewrites it
    # instead of raising, and lookup simply reports "stale".
    def read_document
      return nil unless File.file?(@cache_path)
      return nil if File.size(@cache_path) > MAX_FILE_BYTES

      parsed = begin
        JSON.parse(File.read(@cache_path))
      rescue JSON::ParserError, Errno::ENOENT
        return nil
      end
      parsed.is_a?(Hash) && parsed["schema_version"] == SCHEMA_VERSION ? parsed : nil
    end

    def fetch_snapshot
      models = {}
      url = MODELS_URL
      seen = 0
      MAX_PAGES.times do
        status, body = perform_get(url)
        raise Error, "OpenRouter 请求失败：HTTP #{status}" unless status == 200

        parsed = begin
          JSON.parse(body)
        rescue JSON::ParserError
          raise Error, "OpenRouter 响应不是有效 JSON"
        end
        raise Error, "OpenRouter 响应缺少模型列表" unless parsed.is_a?(Hash) && parsed["data"].is_a?(Array)

        parsed.fetch("data").each { |item| store_model(models, item) }
        seen += parsed.fetch("data").length
        follow = next_link(parsed)
        if follow.nil?
          total = parsed["total_count"]
          if total.is_a?(Integer) && seen < total
            raise Error, "OpenRouter 响应不完整：#{seen}/#{total} 项且无下一页"
          end
          return { "schema_version" => SCHEMA_VERSION, "key_digest" => key_digest,
                   "fetched_at" => format_time(now), "source" => MODELS_URL, "models" => models,
                   "last_attempt" => { "at" => format_time(now), "outcome" => "ok", "error" => nil } }
        end
        url = resolve_next(follow)
      end
      raise Error, "OpenRouter 分页未在 #{MAX_PAGES} 页内结束"
    end

    def perform_get(url)
      result = @http_get.call(url: url, headers: request_headers)
      raise Error, "OpenRouter 请求未返回有效响应" unless result.is_a?(Array) && result.length == 2

      status, body = result
      raise Error, "OpenRouter 响应状态无效" unless status.is_a?(Integer) && body.is_a?(String)
      raise Error, "OpenRouter 响应过大" if body.bytesize > MAX_RESPONSE_BYTES

      [status, body]
    end

    def request_headers
      { "Authorization" => "Bearer #{@api_key}", "Accept" => "application/json" }
    end

    def next_link(parsed)
      links = parsed["links"]
      return nil if links.nil?
      raise Error, "OpenRouter 响应的 links 结构无效" unless links.is_a?(Hash)

      follow = links["next"]
      return nil if follow.nil?
      raise Error, "OpenRouter 响应的下一页链接无效" unless follow.is_a?(String)

      follow.empty? ? nil : follow
    end

    def resolve_next(link)
      uri = begin
        URI.join(MODELS_URL, link)
      rescue URI::InvalidURIError
        raise Error, "OpenRouter 下一页链接无法解析"
      end
      unless uri.scheme == "https" && uri.host == "openrouter.ai" && uri.path.start_with?("/api/v1/")
        raise Error, "OpenRouter 下一页链接指向意外地址"
      end

      uri.to_s
    end

    # Stores catalog rows indexed by their real row id, keeping the row's own
    # canonical_slug for the drift check at lookup time. `~`-prefixed alias
    # rows (e.g. ~deepseek/deepseek-v4-flash-latest) are skipped: an alias is
    # never a mappable canonical entity, and a mapping audited against an
    # alias id is rejected at entry validation.
    def store_model(models, item)
      raise Error, "OpenRouter 模型条目结构无效" unless item.is_a?(Hash)

      id = item["id"]
      return if id.is_a?(String) && id.start_with?("~")
      unless id.is_a?(String) && !id.empty? && id.length <= 200 && id.match?(IDENTIFIER_PATTERN)
        raise Error, "OpenRouter 模型条目缺少有效 id"
      end

      slug = item["canonical_slug"]
      unless slug.is_a?(String) && !slug.empty? && slug.length <= 200 && slug.match?(SLUG_PATTERN)
        raise Error, "OpenRouter 模型 #{id} 缺少有效 canonical_slug"
      end

      raise Error, "OpenRouter 模型目录超过 #{MAX_MODELS} 项" if models.length >= MAX_MODELS && !models.key?(id)

      models[id] = {
        "canonical_slug" => slug,
        "name" => bounded_string(item["name"], MAX_NAME_LENGTH),
        "description" => bounded_string(item["description"], MAX_DESCRIPTION_LENGTH),
        "context_length" => integer_or_nil(item["context_length"]),
        "architecture" => architecture(item["architecture"]),
        "coding_index" => index_or_nil(item, "coding_index"),
        "agentic_index" => index_or_nil(item, "agentic_index")
      }
    end

    def architecture(value)
      return nil if value.nil?
      raise Error, "OpenRouter 模型架构结构无效" unless value.is_a?(Hash)

      { "input_modalities" => modality_list(value["input_modalities"]),
        "output_modalities" => modality_list(value["output_modalities"]),
        "tokenizer" => bounded_string(value["tokenizer"], MAX_NAME_LENGTH) }
    end

    def modality_list(value)
      return nil unless value.is_a?(Array)
      raise Error, "OpenRouter 模型模态列表过长" if value.length > MAX_MODALITIES

      value.each do |entry|
        raise Error, "OpenRouter 模型模态项无效" unless entry.is_a?(String) && !entry.match?(CONTROL_CHARS)
      end
      value
    end

    def index_or_nil(item, key)
      benchmarks = item["benchmarks"]
      return nil if benchmarks.nil?
      raise Error, "OpenRouter 模型 #{item['id']} 的 benchmarks 结构无效" unless benchmarks.is_a?(Hash)

      scores = benchmarks["artificial_analysis"]
      return nil if scores.nil?
      raise Error, "OpenRouter 模型 #{item['id']} 的基准结构无效" unless scores.is_a?(Hash)

      value = scores[key]
      return nil if value.nil?
      unless value.is_a?(Numeric) && value.finite?
        raise Error, "OpenRouter 模型 #{item['id']} 的 #{key} 不是有效数值"
      end

      value.to_f
    end

    def bounded_string(value, limit)
      return nil unless value.is_a?(String)

      value.length <= limit ? value : value[0, limit]
    end

    def integer_or_nil(value)
      value.is_a?(Integer) ? value : nil
    end

    def bounded_text(value, limit)
      value.to_s.slice(0, limit)
    end

    # ---- mapping files ----------------------------------------------------

    def load_mappings
      entries = []
      [self.class.shipped_map_path, @map_path].each do |path|
        document = read_map_document(path)
        entries.concat(document.fetch("entries")) if document
      end
      dedupe_by_identity(entries)
    end

    def read_map_document(path)
      return nil unless File.file?(path)
      return nil if File.size(path) > MAX_MAP_FILE_BYTES

      parsed = begin
        JSON.parse(File.read(path))
      rescue JSON::ParserError, Errno::ENOENT
        return nil
      end
      return nil unless parsed.is_a?(Hash) && parsed["schema_version"] == MAP_SCHEMA_VERSION &&
                        parsed["entries"].is_a?(Array)

      { "entries" => parsed.fetch("entries").map { |payload| normalize_map_entry(payload) }.compact }
    end

    def normalize_map_entry(payload)
      return nil unless payload.is_a?(Hash) && payload.keys.map(&:to_s).sort == MAP_ENTRY_KEYS.sort

      entry = payload.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      return nil unless entry["provider"].is_a?(String) && entry["provider"].length <= 64 &&
                        entry["provider"].match?(PROVIDER_PATTERN)
      return nil unless entry["model"].is_a?(String) && entry["model"].length <= 200 &&
                        entry["model"].match?(IDENTIFIER_PATTERN)
      return nil unless entry["reasoning"].is_a?(String) && entry["reasoning"].length <= 64 &&
                        entry["reasoning"].match?(REASONING_PATTERN)
      return nil unless BILLING_ROUTES.include?(entry["billing_route"])
      return nil unless entry["openrouter_id"].is_a?(String) && !entry["openrouter_id"].empty? &&
                        !entry["openrouter_id"].start_with?("~") && entry["openrouter_id"].length <= 200 &&
                        entry["openrouter_id"].match?(SLUG_PATTERN)
      return nil unless entry["canonical_slug"].is_a?(String) && !entry["canonical_slug"].empty? &&
                        entry["canonical_slug"].length <= 200 && entry["canonical_slug"].match?(SLUG_PATTERN)
      return nil unless valid_sources?(entry["sources"])
      return nil unless entry["verified_by"].is_a?(String) && !entry["verified_by"].empty? &&
                        entry["verified_by"].length <= MAX_VERIFIED_BY_LENGTH && !entry["verified_by"].match?(CONTROL_CHARS)

      verified_at = parse_time(entry["verified_at"])
      return nil if verified_at.nil? || verified_at > now + CLOCK_SKEW_SECONDS
      entry["verified_at"] = format_time(verified_at)
      entry
    end

    def valid_sources?(value)
      return false unless value.is_a?(Array) && !value.empty? && value.length <= MAX_SOURCES

      value.all? do |source|
        next false unless source.is_a?(String) && source.length <= MAX_URL_LENGTH

        begin
          uri = URI.parse(source)
        rescue URI::InvalidURIError
          next false
        end
        (uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)) && uri.userinfo.nil? && !uri.host.to_s.empty?
      end
    end

    def dedupe_by_identity(entries)
      entries.each_with_object([]) do |entry, out|
        out.reject! { |existing| map_identity(existing) == map_identity(entry) }
        out << entry
      end
    end

    def map_identity(entry)
      entry.slice("provider", "model", "reasoning", "billing_route")
    end

    def mapping_for(provider:, model:, reasoning:, billing_route:)
      route = billing_route.to_s.strip
      route = "unknown" if route.empty?
      return nil unless BILLING_ROUTES.include?(route)

      matching = load_mappings.select do |entry|
        entry["provider"] == provider && entry["model"] == model && entry["billing_route"] == route
      end
      exact = matching.find { |entry| entry["reasoning"] == reasoning }
      return exact if exact

      # A sourced, concrete variant takes precedence over the generic unknown
      # entry: a different concrete variant must not silently borrow its score.
      return nil if reasoning != "unknown" && matching.any? { |entry| entry["reasoning"] != "unknown" }

      matching.find { |entry| entry["reasoning"] == "unknown" } || matching.first
    end

    def normalize_reasoning(value)
      text = value.to_s.strip
      text.empty? ? "unknown" : text
    end

    def prior_sources(entry)
      (entry.fetch("sources") + [MODELS_URL, BENCHMARK_SOURCE]).uniq.first(MAX_SOURCES)
    end

    def reasoning_note(requested:, entry:)
      verified = entry.fetch("reasoning")
      base = "基准为 OpenRouter 目录中的 Artificial Analysis 指数，无测量日期，不代表本路由价格或端到端耗时。"
      if verified != "unknown" && requested == verified
        "推理变体与映射核实记录一致（#{verified}）；#{base}"
      else
        label = requested == "unknown" ? "reasoning=unknown" : "请求 reasoning=#{requested}，映射未核实该变体"
        "推理变体未核实（#{label}）；仅作弱先验，不等于推理档位匹配；#{base}"
      end
    end

    # ---- persistence ------------------------------------------------------

    def record_failure(document, message)
      base = document.is_a?(Hash) && document["key_digest"] == key_digest ? document : {}
      base["schema_version"] = SCHEMA_VERSION
      base["key_digest"] = key_digest
      base["last_attempt"] = { "at" => format_time(now), "outcome" => "error",
                               "error" => bounded_text(message, MAX_ERROR_LENGTH) }
      write_document(base)
    rescue Error, SystemCallError
      # Persisting the attempt is best-effort; the returned error status is
      # the authoritative report and must not be masked.
      nil
    end

    def write_document(document)
      content = JSON.pretty_generate(document)
      if content.bytesize > MAX_FILE_BYTES
        raise Error, "OpenRouter 模型概述快照超过 #{MAX_FILE_BYTES} 字节；已有快照未改动"
      end

      directory = ensure_directory
      temporary = File.join(directory, ".#{File.basename(@cache_path)}.tmp-#{Process.pid}-#{format('%08x', rand(2**32))}")
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(content)
          file.flush
          file.fsync
        end
        tighten(temporary, 0o600)
        File.rename(temporary, @cache_path)
      rescue StandardError
        File.delete(temporary) if File.exist?(temporary)
        raise
      end
      sync_directory(directory)
    end

    # Serializes check-then-fetch-then-write across processes on a sibling
    # lock file; the lock is always released, including on raises and on
    # early returns from the yielded block.
    def with_lock
      directory = ensure_directory
      lock_path = File.join(directory, "#{File.basename(@cache_path)}.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        tighten(lock_path, 0o600)
        begin
          lock.flock(File::LOCK_EX)
        rescue SystemCallError => error
          raise Error, "OpenRouter 概述缓存锁失败：#{error.class}"
        end
        begin
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
    end

    def ensure_directory
      directory = File.dirname(@cache_path)
      FileUtils.mkdir_p(directory, mode: 0o700)
      tighten(directory, 0o700)
      directory
    end

    def tighten(path, mode)
      File.chmod(mode, path)
    rescue SystemCallError
      nil
    end

    def sync_directory(directory)
      File.open(directory, File::RDONLY) { |handle| handle.fsync }
    rescue SystemCallError, IOError, NotImplementedError
      nil
    end

    def net_http_get(url:, headers:)
      uri = URI.parse(url)
      raise Error, "OpenRouter 请求地址无效" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS
      response = http.get(uri.request_uri, headers)
      [response.code.to_i, response.body.to_s]
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
           SocketError, OpenSSL::SSL::SSLError, SystemCallError, IOError => e
      raise Error, "OpenRouter 网络请求失败：#{e.class}"
    end

    def now
      value = @clock.call
      raise Error, "OpenRouter 概述时钟必须返回 Time" unless value.is_a?(Time)

      value.utc
    end

    def parse_time(value)
      return nil unless value.is_a?(String) && value.match?(TIMESTAMP_PATTERN)

      Time.iso8601(value).utc
    rescue ArgumentError
      nil
    end

    def format_time(value)
      value.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
