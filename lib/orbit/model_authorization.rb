# frozen_string_literal: true

module Orbit
  # Model exceptions come from native user messages, never from a Root tool
  # argument, environment variable, generated prompt or task-local text file.
  # Standalone directives are deliberately unambiguous; examples in fenced
  # code or quoted lines do not grant permission.
  module ModelAuthorization
    module_function
    def choice(text)
      fenced = false
      selected = nil
      text.to_s.each_line do |line|
        line = line.chomp
        if line.match?(/\A\s*(```|~~~)/)
          fenced = !fenced
          next
        end
        next if fenced
        match = /\AOrbit authorization: review_model(_session)?=([^\s\/]+\/[^\s]+)\z/.match(line)
        next unless match
        grant = { "scope" => match[1] ? "session" : "task", "model" => match[2] }
        raise ArgumentError, "conflicting review model choices in native user message" if selected && selected != grant
        selected = grant
      end
      selected
    end

    def directive(text, model)
      selected = choice(text)
      selected["scope"] if selected && selected["model"] == model
    end

    def verify(connection:, instruction_id:, message_id:, model:)
      raise ArgumentError, "an exact native user message id is required for review model authorization" if message_id.to_s.empty?

      message = connection.user_message(id: message_id)
      scope = directive(message["text"], model) if message.is_a?(Hash) && message["internal"] == false
      raise ArgumentError, "the native user did not authorize review model #{model} in message #{message_id}" unless scope

      if scope == "task" && (instruction_id.nil? ||
         (message_id != instruction_id && !connection.user_messages(after_id: instruction_id)
                                                    .any? { |item| item["id"] == message_id && item["internal"] == false }))
        raise ArgumentError, "one-task review model authorization cannot be reused for a different task"
      end
      { "kind" => "native_user_message", "message_id" => message_id, "model" => model, "scope" => scope }
    end
  end
end
