# frozen_string_literal: true

require "json"

require_relative "../../../lib/orbit/v2/schema_catalog"

module OrbitV2SchemaParity
  module_function

  ROOT_SCHEMA = "contract-bundle.schema.json"

  def cases(examples)
    generated = []
    examples.each do |example|
      walk(
        registry.schema_document(ROOT_SCHEMA),
        example,
        [],
        ROOT_SCHEMA,
        generated,
        example
      )
    end
    generated.each_with_object({}) do |item, unique|
      key = [item.fetch("category"), format_path(item.fetch("path"))]
      unique[key] ||= item
    end.values
  end

  def structural_examples(bundle)
    addressed = deep_copy(bundle)
    addressed_resolution = addressed.fetch("finding_resolutions").first
    addressed_resolution.delete("authorization_record_ref")
    addressed_resolution["resolution"] = "addressed"
    addressed_resolution["issuer_attempt_id"] = "oattempt_independentreview"
    addressed_resolution["issuer_submission_record_id"] = "oevr_independentreview"
    addressed_resolution["source_finding_ref"] = finding_ref(addressed)
    addressed_resolution["source_gate_evaluation_ref"] =
      gate_evaluation_ref(addressed)
    addressed_resolution["resolving_gate_evaluation_ref"] =
      {
        "gate_evaluation_id" => "ogeval_followupreview",
        "content_digest" => "sha256:#{'a' * 64}"
      }
    addressed_resolution["proposal_evidence_record_id"] = "oevr_implementationone"
    addressed_resolution["supporting_record_refs"] = ["oevr_implementationone"]

    disproved = deep_copy(bundle)
    disproved_resolution = disproved.fetch("finding_resolutions").first
    disproved_resolution.delete("authorization_record_ref")
    disproved_resolution["resolution"] = "disproved"
    disproved_resolution["issuer_attempt_id"] = "oattempt_independentreview"
    disproved_resolution["issuer_submission_record_id"] = "oevr_independentreview"
    disproved_resolution["source_finding_ref"] = finding_ref(disproved)
    disproved_resolution["source_gate_evaluation_ref"] =
      gate_evaluation_ref(disproved)
    disproved_resolution["resolving_gate_evaluation_ref"] =
      {
        "gate_evaluation_id" => "ogeval_followupreview",
        "content_digest" => "sha256:#{'a' * 64}"
      }
    disproved_resolution["supporting_record_refs"] = ["oevr_implementationone"]

    protected_change = deep_copy(bundle)
    protected_change.fetch("authorization_records") <<
      structural_protected_change_authorization

    [bundle, addressed, disproved, protected_change]
  end

  def structural_protected_change_authorization
    digest = "sha256:#{'a' * 64}"
    {
      "schema_version" => "orbit-authorization-record-v1",
      "protocol_epoch" => "orbit-v2",
      "project_id" => "oproj_slice0fixture",
      "authorization_record_id" => "oauthz_structuralprotectedchange",
      "project_policy_revision_id" => "opolicy_genesis0001",
      "action" => "task.protected_contract.change",
      "subject_ref" => "trev_slice0contract_r2",
      "authorization_source_ref" => "oassert_structuralprotectedchange",
      "authorization_assertion_digest" => digest,
      "protected_change_envelope" => {
        "schema_version" => "orbit-protected-change-authorization-v1",
        "project_id" => "oproj_slice0fixture",
        "task_id" => "otask_slice0contract",
        "parent_task_revision_ref" => {
          "task_revision_id" => "trev_slice0contract_r1",
          "content_digest" => digest
        },
        "candidate_task_revision_ref" => {
          "task_revision_id" => "trev_slice0contract_r2",
          "content_digest" => digest
        },
        "protected_change_digest" => digest,
        "authority_source_revision_ref" => {
          "provider_id" => "fixture.user-authority",
          "receipt_id" => "oareceipt_structuralprotectedchange",
          "assertion_id" => "oassert_structuralprotectedchange",
          "assertion_digest" => digest
        },
        "issuer_authority_ref" => {
          "assertion_id" => "oassert_structuralprotectedchange",
          "assertion_digest" => digest
        },
        "project_policy_revision_ref" => {
          "policy_revision_id" => "opolicy_genesis0001",
          "content_digest" => digest
        },
        "decision" => "approved",
        "issued_at" => "2026-07-30T00:00:00Z",
        "envelope_digest" => digest
      },
      "content_digest" => digest
    }
  end

  def gate_evaluation_ref(bundle)
    evaluation = bundle.fetch("gate_evaluations").first
    {
      "gate_evaluation_id" => evaluation.fetch("gate_evaluation_id"),
      "content_digest" => evaluation.fetch("content_digest")
    }
  end

  def finding_ref(bundle)
    finding = bundle.fetch("findings").first
    {
      "finding_id" => finding.fetch("finding_id"),
      "content_digest" => finding.fetch("content_digest")
    }
  end

  def mutate(item)
    document = deep_copy(item.fetch("example"))
    path = item.fetch("path")
    case item.fetch("category")
    when "required"
      parent(document, path).delete(path.last)
    when "type"
      write(document, path, wrong_type(read(document, path)))
    when "enum"
      write(document, path, "__invalid_enum__")
    when "const"
      write(document, path, "__invalid_const__")
    when "unknown_nested_field"
      target = path.empty? ? document : read(document, path)
      target["__unknown_nested_field__"] = true
    else
      raise "unknown schema parity category #{item.fetch("category")}"
    end
    document
  end

  def walk(schema, value, path, current_file, generated, example)
    if schema["$ref"]
      target, target_file = resolve(schema["$ref"], current_file)
      walk(target, value, path, target_file, generated, example)
      return
    end

    Array(schema["allOf"]).each do |child|
      walk(child, value, path, current_file, generated, example)
    end
    if schema["oneOf"]
      branch = schema["oneOf"].find do |child|
        registry.validate_fragment(child, value, current_file: current_file).empty?
      end
      walk(branch, value, path, current_file, generated, example) if branch
    end
    if schema["if"] &&
       registry.validate_fragment(schema["if"], value, current_file: current_file).empty?
      walk(schema["then"], value, path, current_file, generated, example) if schema["then"]
    elsif schema["if"] && schema["else"]
      walk(schema["else"], value, path, current_file, generated, example)
    end

    add_case(generated, "type", path, example) if schema["type"] && !path.empty?
    add_case(generated, "enum", path, example) if schema["enum"] && !path.empty?
    add_case(generated, "const", path, example) if schema.key?("const") && !path.empty?

    if value.is_a?(Hash)
      Array(schema["required"]).each do |field|
        add_case(generated, "required", path + [field], example)
      end
      if schema["additionalProperties"] == false
        add_case(generated, "unknown_nested_field", path, example)
      end
      (schema["properties"] || {}).each do |field, child|
        next unless value.key?(field)

        walk(child, value[field], path + [field], current_file, generated, example)
      end
    elsif value.is_a?(Array) && schema["items"]
      value.each_with_index do |item, index|
        walk(schema["items"], item, path + [index], current_file, generated, example)
      end
    end
  end

  def add_case(generated, category, path, example)
    generated << {
      "category" => category,
      "path" => path,
      "example" => example
    }
  end

  def resolve(reference, current_file)
    file_part, fragment = reference.split("#", 2)
    file_name = file_part.nil? || file_part.empty? ? current_file : file_part
    document = registry.schema_document(file_name)
    return [document, file_name] if fragment.nil? || fragment.empty?

    target = fragment.split("/").drop(1).reduce(document) do |current, token|
      current.fetch(token.gsub("~1", "/").gsub("~0", "~"))
    end
    [target, file_name]
  end

  def registry
    Orbit::V2::SchemaCatalog.schema_registry
  end

  def parent(document, path)
    path[0...-1].reduce(document) { |current, token| current.fetch(token) }
  end

  def read(document, path)
    path.reduce(document) { |current, token| current.fetch(token) }
  end

  def write(document, path, value)
    parent(document, path)[path.last] = value
  end

  def wrong_type(value)
    case value
    when Hash then []
    when Array then {}
    when String then 7
    when Integer then "not-an-integer"
    when TrueClass, FalseClass then "not-a-boolean"
    when NilClass then {}
    else
      "__wrong_type__"
    end
  end

  def format_path(path)
    path.reduce("$") do |formatted, token|
      token.is_a?(Integer) ? "#{formatted}[#{token}]" : "#{formatted}.#{token}"
    end
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end
end
