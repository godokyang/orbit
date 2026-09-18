# frozen_string_literal: true

require "json"

module Orbit
  # Member authorization and adapter resolution.
  #
  # `allowed_kinds` is an authorization input only: it never claims that a
  # kind is installed, logged in or natively controllable. Checks happen
  # before any host or member is created, and a changed list never affects
  # stopping or result collection for already-registered members.
  class MemberPolicy
    DEFAULT_KINDS = %w[codex omp opencode kimi cursor-agent grok].freeze
    NATIVE_HOSTS = %w[codex opencode omp].freeze
    CODEX_HOST_ROOTS = %w[opencode].freeze
    CONFIG_RELATIVE = File.join("orbit", "members.json")

    class Error < StandardError; end
    class NotAllowed < Error; end
    class NoAdapter < Error; end

    def self.config_path(env: ENV, home: Dir.home)
      base = env["XDG_CONFIG_HOME"].to_s.empty? ? File.join(home, ".config") : env["XDG_CONFIG_HOME"]
      File.join(base, CONFIG_RELATIVE)
    end

    def self.load(env: ENV, home: Dir.home)
      path = config_path(env: env, home: home)
      return new(allowed_kinds: DEFAULT_KINDS, source: "默认名单", path: path) unless File.file?(path)

      data = JSON.parse(File.read(path))
      raise Error, "#{path}: expected a JSON object" unless data.is_a?(Hash)

      unknown = data.keys - ["allowed_kinds"]
      raise Error, "#{path}: only allowed_kinds is supported (found #{unknown.join(', ')})" unless unknown.empty?

      kinds = data["allowed_kinds"]
      unless kinds.is_a?(Array) && kinds.all? { |kind| kind.is_a?(String) && !kind.strip.empty? }
        raise Error, "#{path}: allowed_kinds must be an array of non-empty strings"
      end
      normalized = kinds.map(&:strip)
      raise Error, "#{path}: allowed_kinds contains duplicates" if normalized.uniq.length != normalized.length

      new(allowed_kinds: normalized, source: path, path: path)
    rescue JSON::ParserError => error
      raise Error, "#{path}: invalid JSON (#{error.message})"
    end

    attr_reader :allowed_kinds, :source, :path

    def initialize(allowed_kinds:, source:, path:)
      @allowed_kinds = allowed_kinds.freeze
      @source = source
      @path = path
    end

    def allowed?(kind)
      @allowed_kinds.include?(kind.to_s)
    end

    def check!(kind)
      return true if allowed?(kind)

      listed = @allowed_kinds.empty? ? "创建新成员已被禁止" : @allowed_kinds.join("、")
      raise NotAllowed,
            "member kind #{kind.inspect} is not in allowed_kinds (#{@source}: #{listed}); " \
            "edit #{@path} to allow it"
    end

    # Requested kind (nil/empty/native) resolves to the Root's actual kind
    # before the allowlist check.
    def resolve_kind(requested, provider)
      value = requested.to_s.strip
      return value unless value.empty? || value == "native"

      provider = provider.to_s
      raise Error, "Root provider #{provider.inspect} has no known native member kind" unless NATIVE_HOSTS.include?(provider)

      provider
    end
  end

  # The member paths that are actually controlled today, by Root provider.
  # Allowed-but-unadapted kinds stay visible as not callable instead of being
  # reported as working.
  module MemberAdapters
    module_function

    # Returns {"adapter" => "same_host"|"codex_host", "detail" => "..."} or nil.
    def resolve(kind, provider)
      kind = kind.to_s
      provider = provider.to_s
      if kind == provider && MemberPolicy::NATIVE_HOSTS.include?(kind)
        { "adapter" => "same_host", "detail" => "同宿主 #{kind} 成员" }
      elsif kind == "codex" && MemberPolicy::CODEX_HOST_ROOTS.include?(provider)
        { "adapter" => "codex_host", "detail" => "任务持有独立 Codex app-server 的跨宿主成员" }
      end
    end

    def callable_kinds(provider)
      MemberPolicy::DEFAULT_KINDS.select { |kind| resolve(kind, provider) }
    end

    # Kinds with a controlled adapter from at least one currently verified Root.
    def portably_callable_kinds
      providers = MemberPolicy::NATIVE_HOSTS + MemberPolicy::CODEX_HOST_ROOTS
      MemberPolicy::DEFAULT_KINDS.select do |kind|
        providers.any? { |provider| resolve(kind, provider) }
      end
    end

    def require!(kind, provider)
      info = resolve(kind, provider)
      return info if info

      raise MemberPolicy::NoAdapter,
            "member kind #{kind.inspect} is allowed but has no controlled adapter from a #{provider} Root; " \
            "currently only same-host codex/opencode/omp members and OpenCode Root -> codex members are verified"
    end
  end
end
