# frozen_string_literal: true

require "bigdecimal"
require_relative "exchange_rate_consistency/snapshot"

class Money
  # Offline detector for directed exchange-rate cycles whose product is
  # strictly greater than one. Rates are converted to Rational for exact
  # arithmetic, while the values returned on witness edges remain the exact
  # objects supplied in the snapshot.
  class ExchangeRateConsistency
    Edge = Data.define(:from, :to, :rate, :rational_rate)
    Result = Data.define(:status, :path, :edges, :product, :budget_remaining) do
      def found?
        status == :found
      end

      def incomplete?
        status == :incomplete
      end

      def complete?
        status != :incomplete
      end

      def rates
        edges.map(&:rate)
      end

      def product_rational
        product
      end
    end

    class InvalidSnapshot < ArgumentError; end
    class InvalidRate < ArgumentError; end

    # @param snapshot [Hash, #each_rate] Fixed directed rate snapshot.
    # @option budget [Integer, nil] Maximum number of relevant directed edges
    #   to traverse. nil analyzes the complete finite snapshot.
    # @return [Result]
    def self.find_profitable_cycle(snapshot, budget: nil)
      new(snapshot).find_profitable_cycle(budget: budget)
    end

    def self.check(snapshot, budget: nil)
      find_profitable_cycle(snapshot, budget: budget)
    end

    def initialize(snapshot)
      normalized = Snapshot.build(snapshot)
      @adjacency = normalized.fetch(:adjacency)
      @vertices = normalized.fetch(:vertices)
      @remaining = nil
    end

    def find_profitable_cycle(budget: nil)
      @remaining = validate_budget(budget)

      @vertices.each do |root|
        witness = visit(root, root, [root], { root => true }, Rational(1))
        return witness if witness
      end

      not_found_result
    end

    private

    def visit(root, current, path, visited, product)
      @adjacency[current].sort.each do |to, edge|
        next if to < root

        return incomplete_result unless consume_budget

        next_product = product * edge.rational_rate

        if to == root
          return found_result(path + [root], next_product) if next_product > 1

          next
        end

        next if visited.key?(to)

        visited[to] = true
        witness = visit(root, to, path + [to], visited, next_product)
        visited.delete(to)
        return witness if witness
      end

      nil
    end

    def consume_budget
      return true if @remaining.nil?
      return false if @remaining.zero?

      @remaining -= 1
      true
    end

    def found_result(closed_path, product)
      edges = closed_path.each_cons(2).map { |from, to| @adjacency.fetch(from).fetch(to) }
      result(:found, closed_path, edges, product)
    end

    def not_found_result
      result(:not_found, nil, [], nil)
    end

    def incomplete_result
      result(:incomplete, nil, [], nil)
    end

    def result(status, path, edges, product)
      Result.new(
        status: status,
        path: path,
        edges: edges,
        product: product,
        budget_remaining: @remaining,
      )
    end

    def validate_budget(budget)
      return nil if budget.nil?

      unless budget.is_a?(Integer) && budget >= 0
        raise ArgumentError, "budget must be a non-negative Integer or nil"
      end

      budget
    end
  end
end
