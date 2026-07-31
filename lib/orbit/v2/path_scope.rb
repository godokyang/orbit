# frozen_string_literal: true

module Orbit
  module V2
    module PathScope
      module_function

      def canonical?(path)
        return false unless path.is_a?(String) && !path.empty?
        return false if path.start_with?("/") || path.include?("\\") || path.include?("\0")

        segments = path.split("/", -1)
        segments.all? do |segment|
          !segment.empty? && segment != "." && segment != ".."
        end
      end

      def canonical_set?(paths, allow_empty: true)
        paths.is_a?(Array) &&
          (allow_empty || !paths.empty?) &&
          paths == paths.sort.uniq &&
          paths.all? { |path| canonical?(path) }
      rescue ArgumentError
        false
      end

      def covered?(path, scope)
        canonical?(path) &&
          canonical?(scope) &&
          (path == scope || path.start_with?("#{scope}/"))
      end

      def covered_by_any?(path, scopes)
        Array(scopes).any? { |scope| covered?(path, scope) }
      end
    end
  end
end
