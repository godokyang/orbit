# frozen_string_literal: true

require "securerandom"
require "time"

module Orbit
  # Bounded, strictly read-only Git remote evidence for the independent
  # checker. The runtime captures these facts at start_check, before the fixed
  # snapshot is judged, and injects them into the checker context under
  # "git_remote" so a checker verifying a "commit and push" requirement does
  # not have to trust the Root's own push report.
  #
  # Target selection: an unambiguous explicit remote/branch named in the
  # instruction ("push to origin/main", "git push origin HEAD:main") wins over
  # the tracking branch — verifying the wrong branch is worse than asking —
  # and more than one distinct named target is "unknown", never a guess.
  # Without an explicit target the branch's upstream tracking reference is
  # used. The returned target_source records which one was compared.
  #
  # Semantics of status:
  #   "verified"  local HEAD equals the remote reference of the selected
  #               target (one and the same commit).
  #   "mismatch"  the remote reference resolves to a different commit than the
  #               local HEAD.
  #   "unknown"   the remote could not be verified: not a git repository, no
  #               commits, detached HEAD with no explicit target, no upstream
  #               tracking branch, an ambiguous explicit target, network
  #               unreachable/errored, the bounded timeout hit, or the
  #               instruction does not require remote delivery so the remote
  #               was deliberately not contacted.
  #
  # Guarantees:
  # - Read-only surface: only `git rev-parse`, `git remote get-url` and
  #   `git ls-remote` are ever run. No fetch, no push, no ref or config writes,
  #   no working-tree commands, and no credential prompts
  #   (GIT_TERMINAL_PROMPT=0, askpass helpers unset, ssh forced to BatchMode).
  # - Bounded: every command runs under a timeout and is killed (TERM then
  #   KILL) when it exceeds it; output reads are capped.
  # - Sanitized: remote URLs and error text have userinfo credentials redacted
  #   before they enter the returned evidence; no secrets are captured.
  # - Honest: a push is never asserted from a Root report; when the remote was
  #   not contacted, remote facts stay nil and remote_contacted is false.
  #
  # `capture` never raises for environment, git or network problems — those
  # are reported as status "unknown" with a bounded reason — so the runtime can
  # inject the hash unconditionally.
  class GitRemoteEvidence
    STATUSES = %w[verified mismatch unknown].freeze
    DEFAULT_NETWORK_TIMEOUT_SECONDS = 10
    LOCAL_TIMEOUT_SECONDS = 5
    OUTPUT_CAP = 8_192
    REASON_CAP = 400

    # Instruction markers that express actual remote-delivery intent. A plain
    # commit/merge requirement deliberately does NOT match: committing locally
    # asserts nothing about the remote, so the remote is not contacted and no
    # remote facts are asserted for it. Over-matching only costs one bounded
    # read-only ls-remote; under-matching would wrongly make a real push task
    # unverifiable, so the list stays broad on remote wording.
    REMOTE_DELIVERY_PATTERN = /
      \b(?:push|publish|github|gitlab|gitee)\b
      |推送|推到|推上|发布|远端|远程
      |pull[ _-]?request
      |\bPR\b
      |remote[ _-]?(?:branch|repo|repository)
    /ix.freeze

    def self.capture(workspace:, instruction:, timeout: DEFAULT_NETWORK_TIMEOUT_SECONDS)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      network_timeout = timeout.to_f.positive? ? timeout.to_f : DEFAULT_NETWORK_TIMEOUT_SECONDS
      evidence = {
        "status" => "unknown", "reason" => "",
        "head" => nil, "branch" => nil, "upstream" => nil,
        "remote" => nil, "remote_url" => nil, "remote_ref" => nil, "remote_head" => nil,
        "remote_contacted" => false, "target_source" => nil,
        "checked_at" => Time.now.utc.iso8601
      }
      root = workspace.to_s
      unless File.directory?(root)
        evidence["reason"] = "workspace is not a directory: remote delivery not verifiable"
        return finish(evidence, started)
      end

      head, error = git(root, ["rev-parse", "HEAD"], LOCAL_TIMEOUT_SECONDS)
      if head.nil?
        evidence["reason"] = bounded("not a git repository or no commits: #{error}")
        return finish(evidence, started)
      end
      evidence["head"] = head

      branch, = git(root, ["rev-parse", "--abbrev-ref", "HEAD"], LOCAL_TIMEOUT_SECONDS)
      evidence["branch"] = branch

      upstream, upstream_error = git(root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
                                     LOCAL_TIMEOUT_SECONDS)
      evidence["upstream"] = upstream unless upstream.nil? || upstream.empty? || upstream == "@{u}"

      remotes, = git(root, ["remote"], LOCAL_TIMEOUT_SECONDS)
      configured = remotes.to_s.lines.map(&:strip).reject(&:empty?)

      # An unambiguous explicit target in the instruction wins over the
      # tracking branch: "push to origin/main" while the current branch tracks
      # origin/feature must compare against origin/main, never verify the
      # feature branch instead. Multiple distinct targets are ambiguous and
      # stay unknown rather than guessing one.
      target = explicit_target(instruction, configured)
      if target == :ambiguous
        evidence["reason"] = "instruction names more than one distinct remote target; refusing to pick one"
        return finish(evidence, started)
      end

      if target
        remote_name, short_ref = target["remote"], target["branch"]
        evidence["target_source"] = "explicit"
      else
        if branch.nil? || branch == "HEAD"
          evidence["reason"] = "detached HEAD or unreadable branch: no target branch to compare"
          return finish(evidence, started)
        end
        if evidence["upstream"].nil?
          evidence["reason"] = bounded("no upstream tracking branch for #{branch}: #{upstream_error}")
          return finish(evidence, started)
        end
        remote_name, _, short_ref = evidence["upstream"].partition("/")
        evidence["target_source"] = "upstream"
      end
      evidence["remote"] = remote_name
      evidence["remote_ref"] = short_ref.to_s.empty? ? nil : "refs/heads/#{short_ref}"
      if evidence["remote_ref"].nil?
        evidence["reason"] = "target #{remote_name}/#{short_ref} does not name a branch reference"
        return finish(evidence, started)
      end

      url, = git(root, ["remote", "get-url", remote_name], LOCAL_TIMEOUT_SECONDS)
      evidence["remote_url"] = url && sanitize(url)

      unless remote_delivery_required?(instruction)
        evidence["reason"] = "remote not contacted: instruction does not require remote delivery"
        return finish(evidence, started)
      end

      remote_head, error = git(root, ["ls-remote", remote_name, evidence["remote_ref"]], network_timeout)
      evidence["remote_contacted"] = true
      evidence["remote_head"] = remote_head
      if remote_head.nil?
        evidence["reason"] = bounded("remote reference #{evidence['remote_ref']} on #{remote_name} not verifiable: #{error}")
        return finish(evidence, started)
      end

      if remote_head == head
        evidence["status"] = "verified"
        evidence["reason"] = "local HEAD #{head[0, 12]} equals #{evidence['remote_ref']} on #{remote_name}"
      else
        evidence["status"] = "mismatch"
        evidence["reason"] = "local HEAD #{head[0, 12]} differs from #{evidence['remote_ref']} " \
                             "#{remote_head[0, 12]} on #{remote_name}"
      end
      finish(evidence, started)
    end

    # Extracts an explicit remote/branch target from the instruction, grounded
    # in the repository's actually configured remote names (so file paths and
    # ordinary words never look like targets). Recognized shapes: a
    # "<configured-remote>/<branch>" mention ("push to origin/main") and a
    # push refspec ("git push origin main", "push origin HEAD:main",
    # "推送 origin main"). Returns {remote:, branch:}, :ambiguous when more
    # than one distinct target is named, or nil when no explicit target exists.
    def self.explicit_target(instruction, remotes)
      text = instruction.is_a?(String) ? instruction : ""
      return nil if text.empty? || remotes.empty?

      names = remotes.map { |name| Regexp.escape(name) }.join("|")
      candidates = []
      text.scan(%r{\b(#{names})/([A-Za-z0-9._\-/]+)}) do |remote, raw_branch|
        candidates << [remote, normalize_branch(raw_branch)]
      end
      refspec = /(?:\bgit\s+push\b|\bpush\b|推送|推到)\s+(?:--\S+\s+)*(?:to\s+)?(#{names})\s+(?:[A-Za-z0-9._\-\/]+:)?(?:refs\/heads\/)?([A-Za-z0-9._\-\/]+)/i
      text.scan(refspec) do |remote, raw_branch|
        candidates << [remote, normalize_branch(raw_branch)]
      end
      distinct = candidates.reject { |_remote, branch| branch.nil? || branch == "HEAD" }.uniq
      return nil if distinct.empty?
      return :ambiguous if distinct.length > 1

      { "remote" => distinct.first[0], "branch" => distinct.first[1] }
    end

    # Strips trailing punctuation and an optional refs/heads/ prefix; a bare
    # "HEAD" carries no branch and is not a target.
    def self.normalize_branch(raw)
      branch = raw.to_s.sub(%r{\Arefs/heads/}, "").gsub(%r{[.,;:!?)"'’]+$}, "").strip
      branch.empty? ? nil : branch
    end

    # Broad on remote wording (see REMOTE_DELIVERY_PATTERN) so a task that
    # genuinely requires a push is never silently marked uncontacted.
    def self.remote_delivery_required?(instruction)
      text = instruction.is_a?(String) ? instruction : ""
      text.match?(REMOTE_DELIVERY_PATTERN)
    end

    # Runs one read-only git command with bounded output and a hard timeout.
    # Returns [value, error]: value is the trimmed first line of stdout on
    # success (or the exact ls-remote ref sha), nil on any failure; error is a
    # bounded, sanitized diagnostic for failure reasons.
    def self.git(root, args, timeout)
      out_path = "/tmp/orbit-git-evidence-#{SecureRandom.hex(8)}.out"
      err_path = "/tmp/orbit-git-evidence-#{SecureRandom.hex(8)}.err"
      out_file = File.open(out_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600)
      err_file = File.open(err_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600)
      pid = Process.spawn(git_env, "git", "-c", "core.askPass=", *args, chdir: root,
                            out: out_file, err: err_file, in: File::NULL, pgroup: true)
      status = wait_with_deadline(pid, timeout)
      if status.nil?
        [nil, "timed out after #{timeout}s"]
      elsif status.success?
        out_file.close
        err_file.close
        output = File.file?(out_path) ? File.read(out_path, OUTPUT_CAP) : ""
        if output.nil? || output.strip.empty?
          [nil, "no output"]
        else
          [parse_value(args, output), nil]
        end
      else
        err_file.close
        detail = File.file?(err_path) ? File.read(err_path, OUTPUT_CAP).to_s.lines.first.to_s.strip : ""
        [nil, "git exited #{status.exitstatus}#{detail.empty? ? '' : ": #{detail}"}"]
      end
    rescue SystemCallError => e
      [nil, "#{e.class}: #{sanitize(e.message)}"]
    ensure
      out_file&.close
      err_file&.close
      [out_path, err_path].each { |path| File.delete(path) if File.exist?(path) }
    end

    # `git ls-remote <remote> <ref>` prints "<sha>\t<ref>" per matching ref.
    # Only the exact ref we asked for counts.
    def self.parse_value(args, output)
      if args.first == "ls-remote"
        line = output.lines.find { |entry| entry.split("\t")[1].to_s.strip == args[2] }
        sha = line.to_s.split("\t").first.to_s.strip
        sha.empty? ? nil : sha
      elsif args == ["remote"]
        output.strip
      else
        output.lines.first.to_s.strip
      end
    end

    # No terminal or askpass credential prompting; ssh never goes interactive.
    # Ambient credential helpers stay available so legitimate non-interactive
    # auth for private remotes still works without a prompt.
    def self.git_env
      env = ENV.to_h
      env["GIT_TERMINAL_PROMPT"] = "0"
      env.delete("GIT_ASKPASS")
      env.delete("SSH_ASKPASS")
      base = env["GIT_SSH_COMMAND"].to_s.strip
      env["GIT_SSH_COMMAND"] = base.empty? ? "ssh -o BatchMode=yes" : "#{base} -o BatchMode=yes"
      env
    end

    def self.wait_with_deadline(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
      loop do
        result = Process.waitpid2(pid, Process::WNOHANG)
        return result.last if result

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          signal_group(pid, "TERM")
          grace = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
          loop do
            result = Process.waitpid2(pid, Process::WNOHANG)
            return result.last if result
            break unless Process.clock_gettime(Process::CLOCK_MONOTONIC) < grace

            sleep 0.05
          end
          signal_group(pid, "KILL")
          Process.waitpid2(pid)
          return nil
        end
        sleep 0.05
      end
    rescue Errno::ESRCH
      nil
    end

    def self.signal_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    # Redacts userinfo credentials wherever a URL appears.
    def self.sanitize(text)
      text.to_s.gsub(%r{(://)[^/@\s]+@}, '\1[redacted]@')
    end

    def self.bounded(text)
      sanitized = sanitize(text)
      sanitized.length <= REASON_CAP ? sanitized : "#{sanitized[0, REASON_CAP]}…"
    end

    def self.finish(evidence, started)
      evidence["reason"] = "remote evidence unavailable" if evidence["reason"].to_s.empty?
      evidence["elapsed_seconds"] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
      evidence
    end

    private_class_method :git, :parse_value, :git_env, :wait_with_deadline, :signal_group, :sanitize, :bounded, :finish
  end
end
