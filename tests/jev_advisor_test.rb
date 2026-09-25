# frozen_string_literal: true

# Deterministic tests for Orbit::JevAdvisor. The real transport is a local
# TCP fixture; no TypeSafe call is made and no real key is read. Run:
#   ruby --disable-gems tests/jev_advisor_test.rb

require "json"
require "socket"
require "tmpdir"

require_relative "../lib/orbit/jev_advisor"

module JevAdvisorTest
  module_function

  MEMBER_FIT_TEXT = "Given the callable member options and the supplied model evidence, is at least one member likely to meet the best bounded subtask's acceptance bar using only information that can be passed in a bounded handoff? Do not assume a handoff already exists, and do not assume the member can see Root's context. Do not treat a matching provider, model or reasoning identity as direct evidence of capability parity. Treat missing or stale evidence as unknown and do not infer capability from a model name alone. Handoff, rework and integration time overhead belong only to parallel_gain."
  PARALLEL_GAIN_TEXT = "Given the remaining task dependencies and the supplied execution evidence, would delegating the best bounded subtask now likely shorten the overall critical path after handoff, expected rework, integration, shared-resource contention, and verification are included? Output speed alone is not task completion speed."
  COST_APPROPRIATE_TEXT = "Given the submitter-provided coarse cost tier (low, medium, high, or unknown) with its source and confidence annotation for the callable member option, is that cost burden proportionate to the best bounded subtask? Judge the candidate's coarse price or subscription/quota burden tier against the size and value of the bounded subtask; the program checks only that a submitted tier carries a source and confidence annotation, not exact numbers against the vendor page. A clearly labeled low-confidence estimate from vendor or model positioning is acceptable evidence. Per-use API pricing and subscription quota must never be converted into a single fake per-token price or compared as if interchangeable. Do not convert currencies, compare it with the caller's own billing route, or rank providers by name or brand. Treat a missing, stale or unevaluated tier as unknown; unknown cost is not free and must not raise this score, and an unknown tier alone must not lower this score when the candidate already meets the quality and time bars. Any user-set hard budget is enforced separately by the calling program's runtime code, not by this question."
  DELEGATABLE_TEXT = "Is there likely a bounded, independent subtask in the effective task requirements or remaining work that an authorized execution member could deliver now while the main agent continues? Prioritize the instruction, basis and amendments over whether the main agent has already mentioned or started that subtask in recent activity. Explicit disjoint files, modules or acceptance surfaces are strong evidence. Count only separable work with a clear result; do not count trivial, overlapping, preference-only or dependency-blocked work. Member availability is enforced separately by the caller, so do not lower this task-structure probability merely because availability is unknown."

  def check(condition, message)
    raise "ASSERTION FAILED: #{message}" unless condition

    true
  end

  def noul(value)
    { "type" => "noul", "noul" => value }
  end

  def payload(answers, model: "jev-test")
    JSON.generate("model" => model, "answers" => answers, "usage" => { "input_tokens" => 12 })
  end

  STAGE_ONE_ANSWERS = {
    "stuck" => noul(0.1), "off_track" => noul(0.2),
    "artifact_ready" => noul(0.3), "delegatable" => noul(0.9)
  }.freeze
  STAGE_TWO_ANSWERS = { "member_fit" => noul(0.8), "parallel_gain" => noul(0.7), "cost_appropriate" => noul(0.6) }.freeze
  ALL_ANSWERS = STAGE_ONE_ANSWERS.merge(STAGE_TWO_ANSWERS).freeze

  # Serves one HTTP response per entry (String = 200 body, [status, body]
  # otherwise), recording each parsed request body in order.
  def with_fixture(entries)
    queue = entries.map { |entry| entry.is_a?(Array) ? entry : ["200 OK", entry] }
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    worker = Thread.new do
      queue.each do |status, body|
        socket = server.accept
        headers = +""
        headers << socket.gets until headers.end_with?("\r\n\r\n")
        length = headers[/Content-Length:\s*(\d+)/i, 1].to_i
        requests << JSON.parse(socket.read(length))
        socket.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        socket.close
      end
    end
    yield URI("http://127.0.0.1:#{server.addr[1]}/v1/systemone"), requests
  ensure
    server.close
    worker.join(3)
  end

  def expect_error(message)
    yield
    raise "ASSERTION FAILED: #{message}"
  rescue Orbit::JevAdvisor::Error
    true
  end

  GIT_IDENTITY = ["-c", "user.name=Orbit test", "-c", "user.email=orbit@example.invalid",
                  "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"].freeze

  def git(root, *args)
    ok = system("git", "-C", root, *args, out: File::NULL, err: File::NULL)
    raise "git #{args.join(' ')} failed in #{root}" unless ok
  end

  def commit(root)
    git(root, *GIT_IDENTITY, "commit", "-qm", "fixture")
  end

  def git_bytes(root, *args)
    IO.popen(["git", "-C", root, *args], err: File::NULL) { |io| io.read }.to_s.b
  end

  def run
    check_delegation_question_text
    check_stage_one_questions_unchanged
    check_candidate_assessment_round_trip
    check_stage_one_request_and_parsing
    check_stage_two_request_state_and_parsing
    check_stages_ignore_each_others_answers
    check_checker_quality_request_and_parsing
    check_stage_two_rejects_invalid_probabilities
    check_git_excerpt_utf8_boundary
    check_error_boundaries
    puts "JEV_ADVISOR_TEST_PASS (deterministic, local fixture only)"
  end

  # The second-stage questions exist and are single noul questions. The
  # member_fit and parallel_gain wording stays frozen with
  # docs/plan/jev-delegation-optimization.md; cost_appropriate follows the
  # ADR-009 coarse cost tiers.
  def check_delegation_question_text
    questions = Orbit::JevAdvisor::DELEGATION_QUESTIONS
    check(questions.keys.sort == %w[cost_appropriate member_fit parallel_gain],
          "stage two asks exactly member_fit, parallel_gain and cost_appropriate")
    %w[member_fit parallel_gain cost_appropriate].each do |name|
      check(questions[name]["type"] == "noul", "#{name} is a single noul question")
      check(questions[name]["criteria"].keys.sort == %w[false true], "#{name} keeps the shared question shape")
    end
    check(questions["member_fit"]["instructions"] == MEMBER_FIT_TEXT, "member_fit wording matches the frozen plan text")
    check(questions["parallel_gain"]["instructions"] == PARALLEL_GAIN_TEXT, "parallel_gain wording matches the frozen plan text")
    check(questions["cost_appropriate"]["instructions"] == COST_APPROPRIATE_TEXT,
          "cost_appropriate wording matches the ADR-009 coarse-tier text")
  end

  # The per-candidate pool stage asks one quality-line and one time question
  # per candidate, labels them by index, names agent+model in every
  # instruction, and reshapes the answers per candidate.
  def check_candidate_assessment_round_trip
    answers = {
      "candidate_0_quality" => noul(0.7), "candidate_0_time" => noul(0.6),
      "candidate_1_quality" => noul(0.4), "candidate_1_time" => noul(0.55)
    }
    with_fixture([payload(answers)]) do |endpoint, requests|
      candidates = [{ "provider" => "opencode-go", "model" => "deepseek-v4.1-flash", "agent" => "orbit-m-deepseek" },
                    { "provider" => "zhipu", "model" => "glm-5", "agent" => "orbit-m-glm" }]
      result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint)
                                .assess_candidates(state: { "instruction" => "x" }, candidates: candidates)
      sent = requests.first
      check(sent["questions"].keys.sort ==
            %w[candidate_0_quality candidate_0_time candidate_1_quality candidate_1_time],
            "one quality and one time question per candidate, labeled by index")
      blob = JSON.generate(sent["questions"])
      check(blob.include?("agent orbit-m-deepseek") && blob.include?("model opencode-go/deepseek-v4.1-flash") &&
            blob.include?("agent orbit-m-glm"),
            "every instruction names its candidate agent and model")
      quality = sent["questions"]["candidate_0_quality"]["instructions"]
      time = sent["questions"]["candidate_1_time"]["instructions"]
      check(quality.include?("brand name") && quality.include?("do not raise this score without sourced support") &&
            quality.include?("Treat missing, stale or unsourced evidence as unknown"),
            "the quality question forbids brand inference and unsourced raises")
      check(time.include?("handoff, expected rework, integration, shared-resource contention and verification") &&
            time.include?("Output speed alone is not task completion speed"),
            "the time question includes the full end-to-end cost model")
      check(result["scores"] == { "0" => { "quality" => 0.7, "time" => 0.6 },
                                  "1" => { "quality" => 0.4, "time" => 0.55 } },
            "scores are reshaped per candidate")
    end
  end

  # Stage one keeps exactly the four scheduling questions; the calibrated
  # delegatable wording stays synchronized with the plan.
  def check_stage_one_questions_unchanged
    questions = Orbit::JevAdvisor::QUESTIONS
    check(questions.keys.sort == %w[artifact_ready delegatable off_track stuck], "stage one keeps its four questions only")
    check(questions["delegatable"]["instructions"] == DELEGATABLE_TEXT, "stage one delegatable wording matches the calibrated plan")
  end

  def check_stage_one_request_and_parsing
    with_fixture([payload(STAGE_ONE_ANSWERS)]) do |endpoint, requests|
      result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess(state: { "instruction" => "stage one" })
      sent = requests.first
      check(sent["questions"].keys.sort == %w[artifact_ready delegatable off_track stuck],
            "stage one sends only its own four questions")
      check(!sent["questions"].key?("member_fit") && !sent["questions"].key?("parallel_gain"),
            "stage one does not ask the delegation questions")
      check(sent["state"] == { "instruction" => "stage one" } && sent["model"] == "jev-latest",
            "the caller's bounded state passes through unchanged")
      check(result["scores"] == { "stuck" => 0.1, "off_track" => 0.2, "artifact_ready" => 0.3, "delegatable" => 0.9 },
            "stage one parses exactly its own answers")
      check(result["model"] == "jev-test" && result["usage"] == { "input_tokens" => 12 }, "model and usage are returned")
    end
  end

  # Stage two accepts the caller-built bounded state (member options plus the
  # evidence comparison), asks only its two questions, and succeeds without
  # any stage-one answers.
  def check_stage_two_request_state_and_parsing
    state = {
      "instruction" => "Ship the login page",
      "member_options" => %w[codex opencode],
      "comparison" => { "root" => { "provider" => "openai", "model" => "gpt-6-astra", "reasoning" => "max" },
                        "candidate" => { "provider" => "opencode-go", "model" => "deepseek-v4.1-flash", "reasoning" => "default" },
                        "comparison" => { "speed_ratio" => 3.48, "quality_delta" => -14, "cost_ratio" => 0.08, "local_samples" => 0 },
                        "evidence" => { "retrieved_at" => "2026-09-22T10:00:00Z", "valid_until" => "2026-09-29T10:00:00Z",
                                        "sources" => ["https://artificialanalysis.ai/models"] } }
    }
    with_fixture([payload(STAGE_TWO_ANSWERS)]) do |endpoint, requests|
      result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: state)
      sent = requests.first
      check(sent["questions"].keys.sort == %w[cost_appropriate member_fit parallel_gain],
            "stage two sends only its own three questions")
      check(sent["state"] == state, "stage two consumes the caller's bounded state verbatim; it fabricates nothing")
      check(result["scores"] == { "member_fit" => 0.8, "parallel_gain" => 0.7, "cost_appropriate" => 0.6 },
            "stage two parses exactly its own answers")
    end
  end

  # Extra answers in the response must not leak into either stage's scores:
  # each stage parses only the questions it asked.
  def check_stages_ignore_each_others_answers
    with_fixture([payload(ALL_ANSWERS), payload(ALL_ANSWERS)]) do |endpoint, requests|
      advisor = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint)
      one = advisor.assess(state: { "instruction" => "stage one" })
      two = advisor.assess_delegation(state: { "instruction" => "stage two" })
      check(one["scores"].keys.sort == %w[artifact_ready delegatable off_track stuck],
            "stage one scores contain only stage one answers")
      check(two["scores"].keys.sort == %w[cost_appropriate member_fit parallel_gain],
            "stage two scores contain only stage two answers")
    end
  end

  def check_stage_two_rejects_invalid_probabilities
    cases = {
      "out of range" => { "member_fit" => noul(1.5), "parallel_gain" => noul(0.7), "cost_appropriate" => noul(0.6) },
      "non numeric" => { "member_fit" => { "type" => "noul", "noul" => "high" }, "parallel_gain" => noul(0.7),
                         "cost_appropriate" => noul(0.6) },
      "wrong answer type" => { "member_fit" => { "type" => "bool", "noul" => 0.8 }, "parallel_gain" => noul(0.7),
                               "cost_appropriate" => noul(0.6) }
    }
    entries = cases.values.map { |answers| payload(answers) }
    with_fixture(entries) do |endpoint, _requests|
      advisor = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint)
      cases.each_key do |label|
        expect_error("stage two rejects an invalid probability (#{label})") do
          advisor.assess_delegation(state: { "instruction" => "x" })
        end
      end
    end

    infinite = '{"model":"jev-test","answers":{"member_fit":{"type":"noul","noul":1e999},"parallel_gain":{"type":"noul","noul":0.7},"cost_appropriate":{"type":"noul","noul":0.6}}}'
    with_fixture([infinite]) do |endpoint, _requests|
      expect_error("stage two rejects a non-finite probability") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: { "instruction" => "x" })
      end
    end

    with_fixture([payload({ "member_fit" => noul(0.8), "cost_appropriate" => noul(0.6) })]) do |endpoint, _requests|
      expect_error("stage two rejects a missing answer") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: { "instruction" => "x" })
      end
    end
  end

  # The shared poster keeps the existing error boundaries for both stages.
  # The checker quality gate asks exactly one noul question per candidate and
  # maps the answers back to provider/id. The caller supplies the task
  # instruction and bounded cached evidence; the advisor adds nothing.
  def check_checker_quality_request_and_parsing
    state = {
      "instruction" => "Add a login page",
      "candidates" => [
        { "model" => "p/one", "evidence" => { "status" => "evidence", "sources" => ["https://s"] } },
        { "model" => "p/two", "evidence" => { "status" => "evidence", "sources" => ["https://s"] } }
      ]
    }
    with_fixture([payload({ "quality_0" => noul(0.8), "quality_1" => noul(0.2), "time_0" => noul(0.7), "time_1" => noul(0.4) })]) do |endpoint, requests|
      result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_checker_quality(
        state: state, candidates: state["candidates"]
      )
      sent = requests.first
      check(sent["questions"].keys.sort == %w[quality_0 quality_1 time_0 time_1],
            "one bounded quality and one end-to-end time question per candidate in a single request")
      check(sent["questions"].values.all? { |question| question["type"] == "noul" }, "each question is a single noul question")
      check(sent["questions"]["time_0"]["instructions"].include?("end-to-end"),
            "the time judgment asks for expected end-to-end check time including rework")
      check(sent["state"] == state, "the caller's bounded state passes through")
      check(result["scores"] == { "p/one" => { "quality" => 0.8, "time" => 0.7 },
                                  "p/two" => { "quality" => 0.2, "time" => 0.4 } },
            "quality and time answers map back to provider/id")
    end

    expect_error("no checker candidate is rejected before any request") do
      Orbit::JevAdvisor.new(api_key: "test-key").assess_checker_quality(state: {}, candidates: [])
    end
  end

  # Real git output is read as raw bytes under a byte budget, so the budget
  # can cut a multibyte character in half. That invalid UTF-8 used to make
  # JSON.generate raise and degrade every assessment to
  # "TypeSafe assessment failed: JSON::GeneratorError" (Zeen task
  # e337c16d). The excerpt must stay valid UTF-8 within the same byte budget
  # and remain byte-identical before the cut; genuinely invalid bytes beyond
  # the cut must still fail closed instead of being silently replaced.
  def check_git_excerpt_utf8_boundary
    Dir.mktmpdir("orbit-jev-cjk") do |root|
      git(root, "init", "-q")
      File.write(File.join(root, "notes.md"), "short\n")
      git(root, "add", "-A")
      commit(root)

      body = "中文页面走查记录，逐条说明修改原因与验收方式。\n"
      filler = ""
      raw = nil
      3.times do
        File.write(File.join(root, "notes.md"), filler + (body * 300))
        raw = git_bytes(root, "diff", "--no-ext-diff", "--no-textconv", "--unified=0", "HEAD", "--")
        head = raw.byteslice(0, 4000).dup.force_encoding(Encoding::UTF_8)
        break unless head.valid_encoding?

        filler = "x#{filler}" # shift the byte alignment of the cut and re-diff
      end
      check(raw.bytesize > 4000 && !raw.byteslice(0, 4000).dup.force_encoding(Encoding::UTF_8).valid_encoding?,
            "the fixture reproduces the real byte-budget cut through a multibyte character")

      state = Orbit::JevAdvisor.observation(
        inputs: { "instruction" => "orbit" }, host: { "status" => "running", "observations" => [] },
        members: [], project_root: root, artifact_digest: "sha256:fixture", elapsed_seconds: 6
      )
      excerpt = state["changes"]["diff_excerpt"]
      check(excerpt.encoding == Encoding::UTF_8 && excerpt.valid_encoding?,
            "the git excerpt is valid UTF-8 after the byte-budget cut")
      check(excerpt.bytesize.between?(3997, 4000) && excerpt.include?("中文"),
            "the excerpt keeps the byte budget and the cut content; only the split character is dropped")
      check(raw.start_with?(excerpt.b), "the excerpt is byte-identical to the git output before the cut")
      check(state["changes"]["status"] == " M notes.md\n", "an untruncated git read still passes through unchanged")

      with_fixture([payload(STAGE_ONE_ANSWERS)]) do |endpoint, requests|
        result = Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess(state: state)
        check(result["scores"]["delegatable"] == 0.9,
              "a diff cut at the byte budget no longer degrades the assessment to JSON::GeneratorError")
        check(requests.first["state"]["changes"]["diff_excerpt"].valid_encoding?,
              "the assessment request carries the excerpt as valid JSON text")
      end
    end

    Dir.mktmpdir("orbit-jev-bytes") do |root|
      git(root, "init", "-q")
      File.write(File.join(root, "legacy.txt"), "ascii\n")
      git(root, "add", "-A")
      commit(root)
      File.binwrite(File.join(root, "legacy.txt"), ("legacy \xFF\xFE row\n".b * 400))

      raw = git_bytes(root, "diff", "--no-ext-diff", "--no-textconv", "--unified=0", "HEAD", "--")
      state = Orbit::JevAdvisor.observation(
        inputs: { "instruction" => "orbit" }, host: { "status" => "running", "observations" => [] },
        members: [], project_root: root, artifact_digest: "sha256:fixture", elapsed_seconds: 6
      )
      excerpt = state["changes"]["diff_excerpt"]
      check(excerpt.b == raw.byteslice(0, 4000) && !excerpt.valid_encoding?,
            "invalid bytes inside the git output are preserved, not silently replaced or dropped")
      expect_error("content that is invalid beyond the cut still degrades Jev instead of being scrubbed") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: URI("http://127.0.0.1:1/v1/systemone"))
                          .assess(state: state)
      end
    end
  end

  def check_error_boundaries
    with_fixture([["500 Internal Server Error", payload(STAGE_TWO_ANSWERS)]]) do |endpoint, _requests|
      expect_error("an HTTP error stays a JevAdvisor::Error") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: { "instruction" => "x" })
      end
    end

    with_fixture(['{"model":"jev-test","answers":null}']) do |endpoint, _requests|
      expect_error("a malformed payload stays a JevAdvisor::Error") do
        Orbit::JevAdvisor.new(api_key: "test-key", endpoint: endpoint).assess_delegation(state: { "instruction" => "x" })
      end
    end

    expect_error("an empty key is rejected before any request") do
      Orbit::JevAdvisor.new(api_key: "").assess_delegation(state: { "instruction" => "x" })
    end
  end
end

JevAdvisorTest.run
