# frozen_string_literal: true

class Money
  # Offline consistency checker for a fixed snapshot of exchange rates.
  #
  # Exchanging currency A for B, then B for C, then C back for A should
  # never increase the amount. If a directed cycle of rates exists whose
  # product is strictly greater than 1, the snapshot is inconsistent and
  # money can be created out of thin air by hopping around the cycle.
  #
  # The checker works on a frozen snapshot of directed rates. All
  # arithmetic is exact (Rational), so a cycle whose product exceeds 1 by
  # an arbitrarily small amount is still detected, and the returned
  # witness can be recomputed exactly by the caller. Missing reverse
  # edges are simply absent from the graph; rates are never inverted.
  #
  # @example
  #   checker = Money::RateConsistencyChecker.new
  #   result = checker.check(
  #     ["USD", "EUR"] => 2,
  #     ["EUR", "USD"] => Rational(3, 5),
  #   )
  #   result.status            #=> :arbitrage
  #   result.cycle.currencies  #=> ["EUR", "USD", "EUR"]
  #   result.cycle.product     #=> (6/5)
  class RateConsistencyChecker
    # The lowest error class for the consistency checker.
    class Error < StandardError; end

    # Raised when a rate is not a positive, finite number.
    class InvalidRate < Error; end

    # Raised when the snapshot cannot be understood.
    class InvalidSnapshot < Error; end

    # Key separator used by +Money::Bank::VariableExchange#export_rates+.
    SERIALIZER_SEPARATOR = "_TO_"

    # A single directed conversion edge of the snapshot, keeping the
    # original rate object next to its exact rational value.
    class Edge
      attr_reader :from, :to, :rate, :rational

      def initialize(from:, to:, rate:, rational:)
        @from = from
        @to = to
        @rate = rate
        @rational = rational
      end

      def to_s
        "#{from} -(#{rate})-> #{to}"
      end
    end

    # A witness cycle: a directed simple cycle whose rate product is
    # strictly greater than 1. The path starts and ends at the same
    # currency and every edge carries the original rate, so the product
    # can be recomputed exactly from the witness alone.
    class Cycle
      attr_reader :edges

      def initialize(edges)
        @edges = edges.freeze
      end

      # The currency path, e.g. ["USD", "EUR", "JPY", "USD"].
      #
      # @return [Array<String>]
      def currencies
        edges.map(&:from) << edges.last.to
      end

      # The exact product of the rates along the cycle.
      #
      # @return [Rational] strictly greater than 1
      def product
        edges.reduce(Rational(1)) { |acc, edge| acc * edge.rational }
      end

      def to_s
        edges.map { |edge| "#{edge.from} -(#{edge.rate})->" }.join(" ") + " #{edges.last.to}"
      end
    end

    # The outcome of a consistency check.
    #
    # +status+ is one of:
    #
    # [:consistent]   The whole snapshot was analyzed and no directed
    #                 simple cycle with product strictly greater than 1
    #                 exists.
    # [:arbitrage]    Such a cycle exists; +cycle+ holds the witness.
    # [:inconclusive] The +max_steps+ budget ran out before the analysis
    #                 could prove either of the above.
    class Result
      STATUSES = [:consistent, :arbitrage, :inconclusive].freeze

      attr_reader :status, :cycle, :steps

      def initialize(status:, cycle: nil, steps: 0)
        @status = status
        @cycle = cycle
        @steps = steps
      end

      def consistent?
        status == :consistent
      end

      def arbitrage?
        status == :arbitrage
      end

      def inconclusive?
        status == :inconclusive
      end
    end

    # Convenience wrapper for +#check+.
    def self.check(snapshot, max_steps: nil)
      new.check(snapshot, max_steps: max_steps)
    end

    # Checks a fixed snapshot of exchange rates for arbitrage cycles.
    #
    # The snapshot can be:
    #
    # - anything responding to +each_rate+ (e.g. +Money::RatesStore::Memory+),
    # - a +Money::Bank::VariableExchange+ (its store is snapshotted),
    # - a +Hash+ mapping +[from, to]+ pairs or +"FROM_TO"+ strings to rates,
    # - an +Enumerable+ of +[from, to, rate]+ triples.
    #
    # Rates may be +Rational+, +Integer+, +BigDecimal+, +Float+ or numeric
    # +String+; they are converted to exact rationals. Zero, negative,
    # non-finite or unparseable rates raise +InvalidRate+.
    #
    # @param [Object] snapshot The fixed rate snapshot to analyze.
    # @param [Integer, nil] max_steps Maximum number of edge relaxations
    #   to attempt before giving up with an +:inconclusive+ result.
    #   +nil+ (default) means no budget limit.
    #
    # @return [Result]
    #
    # @raise [InvalidRate] if a rate is not a positive, finite number.
    # @raise [InvalidSnapshot] if the snapshot format is not understood.
    # @raise [ArgumentError] if +max_steps+ is invalid.
    def check(snapshot, max_steps: nil)
      validate_budget!(max_steps)
      edges = build_edges(snapshot)
      vertices = edges.flat_map { |edge| [edge.from, edge.to] }.uniq
      dist = vertices.to_h { |vertex| [vertex, Rational(1)] }
      predecessors = {}
      steps = 0
      relaxed = nil

      vertices.size.times do |iteration|
        changed = false
        edges.each do |edge|
          return Result.new(status: :inconclusive, steps: steps) if max_steps && steps >= max_steps

          steps += 1
          candidate = dist[edge.from] * edge.rational
          if candidate > dist[edge.to]
            dist[edge.to] = candidate
            predecessors[edge.to] = edge
            changed = true
            relaxed = edge.to if iteration == vertices.size - 1
          end
        end
        break unless changed
      end

      if relaxed
        Result.new(status: :arbitrage, cycle: extract_cycle(relaxed, predecessors, vertices.size), steps: steps)
      else
        Result.new(status: :consistent, steps: steps)
      end
    end

    private

    def validate_budget!(max_steps)
      return if max_steps.nil?

      unless max_steps.is_a?(Integer) && max_steps >= 0
        raise ArgumentError, "max_steps must be a non-negative Integer or nil, got #{max_steps.inspect}"
      end
    end

    def build_edges(snapshot)
      normalize_snapshot(snapshot).map do |from, to, rate|
        Edge.new(
          from: normalize_currency(from),
          to: normalize_currency(to),
          rate: rate,
          rational: coerce_rate(rate),
        )
      end
    end

    def normalize_snapshot(snapshot)
      entries = []
      if snapshot.respond_to?(:each_rate)
        snapshot.each_rate { |from, to, rate| entries << [from, to, rate] }
      elsif snapshot.is_a?(Hash)
        snapshot.each { |key, rate| entries << normalize_hash_entry(key, rate) }
      elsif snapshot.is_a?(Enumerable)
        snapshot.each do |entry|
          from, to, rate = entry
          entries << [from, to, rate]
        end
      elsif snapshot.respond_to?(:store) && snapshot.store.respond_to?(:each_rate)
        snapshot.store.each_rate { |from, to, rate| entries << [from, to, rate] }
      else
        raise InvalidSnapshot, "cannot read rates from #{snapshot.inspect}"
      end
      entries
    end

    def normalize_hash_entry(key, rate)
      case key
      when Array
        from, to = key
      when String, Symbol
        from, to = key.to_s.split(SERIALIZER_SEPARATOR, 2)
      else
        raise InvalidSnapshot, "invalid rate key #{key.inspect}"
      end
      raise InvalidSnapshot, "invalid rate key #{key.inspect}" unless from && to

      [from, to, rate]
    end

    def normalize_currency(currency)
      raise InvalidSnapshot, "missing currency in rate entry" if currency.nil?

      Currency.wrap(currency).iso_code
    end

    # Converts a rate to its exact rational value. Strings are parsed as
    # exact decimal (or "num/den") rationals; Floats use their exact
    # binary value. Non-positive, non-finite and unparseable rates are
    # rejected.
    def coerce_rate(rate)
      rational =
        case rate
        when Rational
          rate
        when Integer
          rate.to_r
        when BigDecimal
          rate.to_r
        when Float
          rate.to_r
        when String
          begin
            Rational(rate.strip)
          rescue ArgumentError, TypeError
            raise InvalidRate, "invalid rate #{rate.inspect}: not a number"
          end
        else
          raise InvalidRate, "invalid rate #{rate.inspect}: unsupported #{rate.class}"
        end

      unless rational > 0
        raise InvalidRate, "invalid rate #{rate.inspect}: rate must be positive"
      end

      rational
    rescue FloatDomainError
      raise InvalidRate, "invalid rate #{rate.inspect}: rate must be finite"
    end

    # Walks predecessor pointers +length+ times to land inside the cycle,
    # then collects it in forward order. The cycle is rotated to start at
    # the lexicographically smallest currency for deterministic output.
    def extract_cycle(vertex, predecessors, length)
      start = vertex
      length.times { start = predecessors.fetch(start).from }

      cycle_edges = []
      current = start
      loop do
        edge = predecessors.fetch(current)
        cycle_edges << edge
        current = edge.from
        break if current == start
      end
      cycle_edges.reverse!

      offset = cycle_edges.each_index.min_by { |i| cycle_edges[i].from }
      Cycle.new(cycle_edges.rotate(offset))
    end
  end
end
