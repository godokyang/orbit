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

    # Isolated integration workspaces routinely exceed short label bounds.
    with_coverage do |coverage|
      root = "/Users/member/project/.loom/runtime/work/#{"a" * 64}/#{"b" * 36}/project"
      coverage.record(check_id: "long-path", kind: "artifact", role: "reviewer",
                      coverage: coverage(), **binding(root: root))
      assert(coverage.status(**binding(root: root))["ready"] == true,
             "long artifact paths survive persistence and exact binding readback")
      assert(coverage.status(**binding(root: "#{root}-other"))["current"] == false,
             "accepting a long path never grants coverage to a different root")
    end
  end

  def coverage_above_old_fixed_item_limit_is_preserved
    with_coverage do |coverage|
      items = 70.times.map do |index|
        { "requirement" => "requirement #{index + 1}", "status" => "verified",
          "evidence" => "inspected source for requirement #{index + 1}" }
      end
      coverage.record(check_id: "wide", kind: "artifact", role: "reviewer",
                      coverage: { "complete" => true, "items" => items }, **binding)
      status = coverage.status(**binding)
      assert(status["ready"] == true && status["verified"] == 70 && status["items"].length == 70,
             "all reported requirements above the former fixed capacity are preserved")
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

      assert(!File.exist?(coverage.path), "invalid submissions never create the file")
      over_old_limit = { "complete" => true,
                         "items" => (1..65).map { |i| { "requirement" => "r#{i}", "status" => "verified",
                                                        "evidence" => "checked r#{i}" } } }
      coverage.record(check_id: "c", kind: "artifact", role: "reviewer", coverage: over_old_limit, **binding)
      assert(coverage.status(**binding)["items"].length == 65,
             "coverage above the former 64-item limit remains complete and intact")
    end
  end

  # The item-text bound is a representation bound: a real 348-character
  # requirement sentence (from the rejected 0.7.20 check 5 result) must be
  # stored verbatim. Nothing is truncated and the other refusals still hold.
  def long_requirement_text_is_stored_verbatim_but_still_bounded
    with_coverage do |store|
      sentence = "The closing report must " + ("enumerate each enumerated requirement with its exact wording and evidence " * 5).strip + "."
      assert(sentence.length.between?(301, 1000), "fixture is between the old and new bound (#{sentence.length})")
      report = coverage()
      report["items"][0] = { "requirement" => sentence, "status" => "verified", "evidence" => "reviewer read the requirement list" }
      store.record(check_id: "long-1", kind: "artifact", role: "reviewer", coverage: report, **binding)
      state = store.status(**binding)
      assert(state["ready"] && state["items"].first["requirement"] == sentence,
             "a long requirement is stored verbatim, not truncated or rejected")

      too_long = coverage()
      too_long["items"][0] = { "requirement" => "x" * 1001, "status" => "verified", "evidence" => "e" }
      refused = begin
        store.record(check_id: "long-2", kind: "artifact", role: "reviewer", coverage: too_long, **binding)
        false
      rescue Orbit::RequirementCoverage::Error => error
        error.message.include?("1000")
      end
      assert(refused, "an oversized requirement is still refused at the new bound")

      duplicated = coverage()
      duplicated["items"][1]["requirement"] = duplicated["items"][0]["requirement"]
      duplicate_refused = begin
        store.record(check_id: "long-3", kind: "artifact", role: "reviewer", coverage: duplicated, **binding)
        false
      rescue Orbit::RequirementCoverage::Error
        true
      end
      assert(duplicate_refused, "duplicate requirements are still refused")
      assert(File.binread(store.path).include?(sentence), "the stored history keeps the verbatim sentence for audit")
    end
  end


  def unread_items_reuse_exact_evidence_but_counterevidence_revokes_it
    with_coverage do |store|
      report = coverage()
      store.record(check_id: "1", kind: "artifact", role: "reviewer", coverage: report, **binding)
      report["items"][0].merge!("status" => "unverified", "gap_kind" => "not_checked", "evidence" => "Unread this round")
      store.record(check_id: "2", kind: "artifact", role: "reviewer", coverage: report, **binding)
      assert(store.status(**binding)["ready"] && store.status(**binding)["items"][0]["verified_by_check"] == "1",
             "unread same-version item retains actual evidence and source")
      %w[evidence_missing defect].each_with_index do |gap, i|
        report["items"][0]["gap_kind"] = gap
        store.record(check_id: "gap-#{i}", kind: "artifact", role: "reviewer", coverage: report, **binding)
        report["items"][0]["gap_kind"] = "not_checked"
        store.record(check_id: "unread-#{i}", kind: "artifact", role: "reviewer", coverage: report, **binding)
        assert(!store.status(**binding)["ready"], "counterevidence is a barrier to older passes")
      end
      store.record(check_id: "fixed", kind: "artifact", role: "reviewer", coverage: coverage(), **binding)
      store.record(check_id: "finding", kind: "artifact", role: "reviewer", coverage: report,
                   invalidates_prior: true, **binding)
      assert(!store.status(**binding)["ready"], "real findings revoke prior evidence globally")
      store.record(check_id: "fixed-again", kind: "artifact", role: "reviewer", coverage: coverage(), **binding)
      assert(store.status(**binding)["ready"], "explicit new verification restores qualification")
    end
  end

  def unread_items_never_inherit_across_bindings_or_requirement_identity
    with_coverage do |store|
      store.record(check_id: "1", kind: "artifact", role: "reviewer", coverage: coverage(), **binding)
      report = coverage()
      report["items"][0].merge!("status" => "unverified", "gap_kind" => "not_checked", "ref" => "same-ref")
      [binding(artifact: "art-2"), binding(digest: "in-2"), binding(root: "/other")].each_with_index do |version, i|
        store.record(check_id: "changed-#{i}", kind: "artifact", role: "reviewer", coverage: report, **version)
        assert(!store.status(**version)["ready"], "changed versions require explicit new verification")
      end
      report["items"][0]["requirement"] = "Different behavior"
      store.record(check_id: "renamed", kind: "artifact", role: "reviewer", coverage: report, **binding)
      assert(!store.status(**binding)["ready"], "ref and similar text never substitute requirement identity")
      report["items"][0]["status"] = "verified"
      begin
        store.record(check_id: "invalid", kind: "artifact", role: "reviewer", coverage: report, **binding)
        raise "verified with gap_kind must be rejected"
      rescue Orbit::RequirementCoverage::Error
        # A gap classification cannot coexist with verified.
      end
    end
  end

  def run
    unread_items_reuse_exact_evidence_but_counterevidence_revokes_it
    unread_items_never_inherit_across_bindings_or_requirement_identity
    long_requirement_text_is_stored_verbatim_but_still_bounded
    coverage_above_old_fixed_item_limit_is_preserved
    complete_verified_coverage_releases_the_current_binding
    revisions_stale_records_and_process_checks_never_release
    missing_corrupt_and_invalid_never_count
    future_lifecycle_does_not_create_a_delivery_cycle
    puts "REQUIREMENT_COVERAGE_TEST_PASS"
  end

  # A real reviewer could not verify "stop after this final check" before
  # the stop. Keep that obligation visible; do not require a future event as
  # pre-delivery evidence, and do not turn past test execution into lifecycle.
  def future_lifecycle_does_not_create_a_delivery_cycle
    with_coverage do |store|
      report = coverage()
      report["items"] << { "requirement" => "Stop after the final check",
        "scope" => "lifecycle", "status" => "unverified", "evidence" => "Future runtime stop" }
      store.record(check_id: "c1", kind: "artifact", role: "reviewer", coverage: report, **binding)
      state = store.status(**binding)
      assert(state["ready"] && state["verified"] == 2 && state["lifecycle_items"] == 1,
        "future stop stays visible without claiming it already happened")
      report["items"][0]["status"] = "unverified"
      store.record(check_id: "c2", kind: "artifact", role: "reviewer", coverage: report, **binding)
      assert(!store.status(**binding)["ready"], "actual test execution remains a delivery requirement")
      report["items"] = [report["items"].last]
      store.record(check_id: "c3", kind: "artifact", role: "reviewer", coverage: report, **binding)
      assert(!store.status(**binding)["ready"], "lifecycle-only assertions cannot grant delivery coverage")
    end
  end
end

RequirementCoverageTest.run
