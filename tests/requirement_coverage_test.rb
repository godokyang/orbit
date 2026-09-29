# frozen_string_literal: true

# Key behaviors only: complete coverage releases the exact current binding;
# any version drift, stale record or process check revokes it; missing or
# corrupt data stays ready=false with a gap and is never repaired.

require "tmpdir"

require_relative "../lib/orbit/requirement_coverage"

module RequirementCoverageTest
  module_function

  def assert(value, message)
    raise "ASSERTION FAILED: #{message}" unless value
  end

  def with_coverage
    Dir.mktmpdir do |root|
      record = Orbit::TaskRecord.create(project_root: root, instruction: "Deliver the CLI",
                                        source: "test", connection: {}, review: {})
      yield Orbit::RequirementCoverage.new(record: record)
    end
  end

  def coverage(complete: true, verified: true)
    { "complete" => complete,
      "items" => [
        { "requirement" => "CLI aggregates the CSV", "status" => verified ? "verified" : "unverified",
          "evidence" => verified ? "npm test passed at the recorded artifact digest" : "" },
        { "requirement" => "README usage documented", "status" => "verified",
          "evidence" => "reviewer read README at the recorded artifact digest" }
      ] }
  end

  def binding(digest: "in-1", artifact: "art-1", root: "/fixture/project")
    { input_digest: digest, artifact_digest: artifact, artifact_root: root }
  end

  # A complete, fully verified artifact-scope reviewer record releases exactly
  # the binding it was recorded at; an incomplete enumeration or an
  # unverified item blocks readiness with a named gap, and a newer partial
  # review overrides an earlier pass.
  def complete_verified_coverage_releases_the_current_binding
    with_coverage do |coverage|
      assert(coverage.status(**binding)["ready"] == false, "no record is never ready")

      coverage.record(check_id: "check-1", kind: "artifact", role: "reviewer",
                      coverage: coverage(), stale: false, **binding)
      status = coverage.status(**binding)
      assert(status["ready"] == true && status["current"] == true && status["complete"] == true,
             "a complete verified artifact review releases the current binding")
      assert(status["verified"] == 2 && status["unverified"] == 0 && status["items"].length == 2,
             "per-item evidence is preserved for audit")
      assert(File.stat(coverage.path).mode & 0o777 == 0o600, "the coverage file is 0600")

      coverage.record(check_id: "check-2", kind: "artifact", role: "reviewer",
                      coverage: coverage(verified: false), **binding)
      status = coverage.status(**binding)
      assert(status["ready"] == false && status["gap"].include?("unverified"),
             "a newer artifact review with an unverified item overrides the earlier pass")

      coverage.record(check_id: "check-3", kind: "artifact", role: "reviewer",
                      coverage: coverage(complete: false), **binding)
      status = coverage.status(**binding)
      assert(status["ready"] == false && status["gap"].include?("complete"),
             "a checker that did not enumerate everything is not delivery coverage")
    end
  end

  # Any input/artifact/root revision or a stale record revokes currency.
  # Process checks and adjudicator records stay history: they never grant,
  # replace or erase artifact-review coverage in either direction.
  def revisions_stale_records_and_process_checks_never_release
    with_coverage do |coverage|
      coverage.record(check_id: "check-1", kind: "artifact", role: "reviewer",
                      coverage: coverage(), **binding)
      assert(coverage.status(**binding(digest: "in-2"))["current"] == false,
             "a revised input invalidates the old coverage")
      assert(coverage.status(**binding(artifact: "art-2"))["current"] == false,
             "a changed artifact invalidates the old coverage")
      assert(coverage.status(**binding(root: "/fixture/other"))["current"] == false,
             "a different artifact root invalidates the old coverage")

      coverage.record(check_id: "check-2", kind: "artifact", role: "reviewer",
                      coverage: coverage(verified: false), **binding)
      assert(coverage.status(**binding)["ready"] == false,
             "the newer partial artifact review overrides the pass")
      coverage.record(check_id: "check-3", kind: "process", role: "reviewer",
                      coverage: coverage(), **binding)
      assert(coverage.status(**binding)["ready"] == false,
             "a process check never replaces the artifact review")
      coverage.record(check_id: "check-4", kind: "artifact", role: "adjudicator",
                      coverage: coverage(), **binding)
      assert(coverage.status(**binding)["ready"] == false,
             "an adjudicator record is not reviewer coverage")
      coverage.record(check_id: "check-5", kind: "artifact", role: "reviewer",
                      coverage: coverage(), stale: true, **binding)
      assert(coverage.status(**binding)["ready"] == false,
             "a stale artifact review cannot release; history keeps it")
    end
  end

  # Missing or corrupt data stays ready=false with an explicit gap; invalid
  # submissions raise and never repair or overwrite real history.
  def missing_corrupt_and_invalid_never_count
    with_coverage do |coverage|
      status = coverage.status(**binding)
      assert(status["ready"] == false && status["gap"].is_a?(String), "no file means a named gap")

      File.write(coverage.path, "{not json")
      status = coverage.status(**binding)
      assert(status["ready"] == false && status["gap"].include?("unreadable"),
             "a corrupt file degrades to a gap, never to ready")
      begin
        coverage.record(check_id: "c", kind: "artifact", role: "reviewer", coverage: coverage(), **binding)
        raise "record on corrupt history must raise"
      rescue Orbit::RequirementCoverage::Error
        nil
      end
      assert(File.read(coverage.path) == "{not json", "corrupt history is never silently replaced")
    end

    with_coverage do |coverage|
      duplicate = coverage()
      duplicate["items"] << duplicate["items"].first.dup
      begin
        coverage.record(check_id: "c", kind: "artifact", role: "reviewer", coverage: duplicate, **binding)
        raise "duplicate requirements must raise"
      rescue Orbit::RequirementCoverage::Error
        nil
      end

      no_evidence = { "complete" => true,
                      "items" => [{ "requirement" => "r", "status" => "verified", "evidence" => "" }] }
      begin
        coverage.record(check_id: "c", kind: "artifact", role: "reviewer", coverage: no_evidence, **binding)
        raise "a verified item without evidence must raise"
      rescue Orbit::RequirementCoverage::Error
        nil
      end

      bad_kind = begin
        coverage.record(check_id: "c", kind: "final", role: "reviewer", coverage: coverage(), **binding)
        raise "an unknown kind must raise"
      rescue Orbit::RequirementCoverage::Error
        nil
      end

      too_many = { "complete" => true,
                   "items" => (1..65).map { |i| { "requirement" => "r#{i}", "status" => "unverified", "evidence" => "" } } }
      begin
        coverage.record(check_id: "c", kind: "artifact", role: "reviewer", coverage: too_many, **binding)
        raise "more than 64 items must raise"
      rescue Orbit::RequirementCoverage::Error
        nil
      end
      assert(!File.exist?(coverage.path), "invalid submissions never create the file")
    end
  end

  def run
    complete_verified_coverage_releases_the_current_binding
    revisions_stale_records_and_process_checks_never_release
    missing_corrupt_and_invalid_never_count
    puts "REQUIREMENT_COVERAGE_TEST_PASS"
  end
end

RequirementCoverageTest.run
