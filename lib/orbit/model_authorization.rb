# frozen_string_literal: true

module Orbit
  # Exact identities, separate from the ordinary model preference pool.
  module ModelAuthorization
    module_function

    def parse(models)
      return nil if models.nil?
      unless models.is_a?(Array) && models.length.between?(1, 64) &&
             models.all? { |model| model.is_a?(String) && model.match?(%r{\A[^\s/]+/[^\s]+\z}) } &&
             models.uniq == models
        raise ArgumentError, "allowed models must be 1-64 unique exact provider/model identities"
      end
      models
    end

    def restrict(models, ceiling)
      models, ceiling = parse(models), parse(ceiling)
      return ceiling unless models
      raise ArgumentError, "task allowed models exceed the session authorization" if ceiling && (models - ceiling).any?
      models
    end

    def check!(model, models)
      raise ArgumentError, "model #{model} is outside the task authorization" if models && !parse(models).include?(model)
    end
  end
end
