# frozen_string_literal: true

class Money
  # Exact, inventory-aware cash change (coin change) computation.
  #
  # Given an amount of Money and the number of available pieces of each
  # denomination, it finds an exact combination using the minimum number of
  # pieces. Because arbitrary/non-decimal denomination systems are supported,
  # no greedy assumption is made: the solution is computed with an exact
  # branch-and-bound search over integer subunits.
  #
  # @see Money#cash_change
  # @see Money::CashChange.generate
  module CashChange
    # Default upper bound on the number of explored search states. Keeps the
    # bounded search from allocating structures proportional to the numeric
    # magnitude of the amount. Pass +nil+ via +budget:+ to disable.
    DEFAULT_BUDGET = 100_000

    # Raised when the exact search exceeds its state budget before proving an
    # optimum.
    class BudgetExceeded < StandardError; end

    # The result of a change computation.
    #
    # For reachable amounts, {#counts} maps every requested denomination to
    # the number of pieces used (including zeroes) and {#total_pieces} is the
    # minimized number of pieces. For unreachable amounts {#found?} is false
    # and {#counts}/{#total_pieces} are +nil+.
    class Result
      # @return [Hash, nil] pieces used per requested denomination, or +nil+
      #   when the amount is unreachable.
      attr_reader :counts

      # @return [Integer, nil] total number of pieces used, or +nil+ when the
      #   amount is unreachable.
      attr_reader :total_pieces

      def initialize(counts, total_pieces)
        @counts = counts
        @counts.freeze unless @counts.nil?
        @total_pieces = total_pieces
        freeze
      end

      # @return [Boolean] whether an exact combination exists.
      def found?
        !counts.nil?
      end

      alias solution? found?

      # Shared result for amounts that cannot be composed exactly.
      NONE = new(nil, nil).freeze
    end

    # Computes the minimum-piece exact change for +money+.
    #
    # @param money [Money] the exact amount to make, expressed in subunits.
    # @param stock [Hash{Integer, Money => Integer}] available pieces per
    #   denomination. Keys are denominations in fractional (subunit) units,
    #   either as positive Integers or as Money objects of the same currency
    #   as +money+; values are non-negative Integer quantities. The stock is
    #   never modified and its key objects are preserved in the result.
    # @param tie_break [Symbol, Array, #call] selects a single solution when
    #   several combinations use the same minimum number of pieces:
    #   - +:largest_first+ (default): prefer more pieces of larger
    #     denominations, deterministically from the largest denomination down.
    #   - +:smallest_first+: avoid small denominations unless inventory forces
    #     them; from the smallest denomination up, the solution using fewer
    #     pieces at the first differing denomination wins.
    #   - an Array of denomination keys ordered from highest to lowest
    #     tie-break priority; it must contain every stock denomination once.
    #   - a callable receiving +candidate_counts, best_counts+ (hashes keyed
    #     like +stock+) and returning true when the candidate is preferred.
    # @param budget [Integer, nil] maximum number of search states explored
    #   before raising {BudgetExceeded}. Defaults to {DEFAULT_BUDGET}; +nil+
    #   removes the bound.
    #
    # @return [Result]
    #
    # @raise [ArgumentError] when the amount, a denomination, a quantity, or
    #   the tie-break specification is invalid, or when currencies are mixed.
    # @raise [BudgetExceeded] when +budget+ is exhausted before an optimum is
    #   proven.
    #
    # @example
    #   money = Money.new(6, "USD")
    #   stock = { Money.new(4, "USD") => 1, Money.new(3, "USD") => 2 }
    #   result = Money::CashChange.generate(money, stock)
    #   result.found?       #=> true
    #   result.counts       #=> { #<Money 4 USD>=>0, #<Money 3 USD>=>2 }
    #   result.total_pieces #=> 2
    def self.generate(money, stock, tie_break: :largest_first, budget: DEFAULT_BUDGET)
      Solver.new(money, stock, tie_break, budget).call
    end

    # Exact branch-and-bound solver. Kept private: callers use {generate}.
    class Solver
      def initialize(money, stock, tie_break, budget)
        raise ArgumentError, "money must be a Money" unless money.is_a?(Money)

        @currency = money.currency
        amount = integer_subunits(money.fractional, "change amount")
        raise ArgumentError, "change amount cannot be negative" if amount.negative?
        raise ArgumentError, "stock must be a Hash" unless stock.is_a?(Hash)
        unless budget.nil? || (budget.is_a?(Integer) && budget.positive?)
          raise ArgumentError, "budget must be a positive Integer or nil"
        end

        @amount = amount
        @budget = budget
        @entries = build_entries(stock)
        @tie_break_mode = resolve_tie_break_mode(tie_break)
        @tie_break_callable =
          if @tie_break_mode == :callable
            tie_break
          else
            order_indexes(tie_break) if @tie_break_mode == :priority
          end
      end

      def call
        return Result.new(empty_counts, 0) if @amount.zero?
        return Result::NONE if @entries.empty?
        return Result::NONE if total_available < @amount

        order_entries!
        prepare_bounds!

        gcd = @entries.map { |entry| entry[:value] }.reduce(0) { |acc, value| acc.gcd(value) }
        return Result::NONE unless (@amount % gcd).zero?

        @best_pieces, @best_usage = greedy_incumbent
        @dfs_solution_found = false
        @memo = {}
        @usage = Array.new(@entries.length, 0)
        @visited = 0
        search(0, @amount, 0)

        @best_usage.nil? ? Result::NONE : Result.new(counts_from_usage(@best_usage), @best_pieces)
      end

      private

      def integer_subunits(value, label)
        return value if value.is_a?(Integer)

        if value.is_a?(BigDecimal) && value.finite? && (value % 1).zero?
          return value.to_i
        end

        raise ArgumentError, "#{label} must be a whole number of subunits"
      end

      def build_entries(stock)
        entries_by_value = {}
        stock.map do |key, quantity|
          value = denomination_value(key)
          unless quantity.is_a?(Integer) && !quantity.negative?
            raise ArgumentError, "quantity for denomination #{key.inspect} must be a non-negative Integer"
          end
          if entries_by_value.key?(value)
            raise ArgumentError, "duplicate denomination #{value} subunits"
          end

          entry = { value: value, stock: quantity, key: key, stock_index: entries_by_value.size }
          entries_by_value[value] = entry
        end
      end

      def denomination_value(key)
        value =
          if key.is_a?(Money)
            unless key.currency == @currency
              raise ArgumentError, "denomination currency #{key.currency} does not match #{@currency}"
            end

            integer_subunits(key.fractional, "denomination #{key.inspect}")
          elsif key.is_a?(Integer)
            key
          else
            raise ArgumentError, "denomination #{key.inspect} must be a positive Integer or a Money"
          end
        unless value.positive?
          raise ArgumentError, "denomination #{key.inspect} must be positive"
        end

        value
      end

      def resolve_tie_break_mode(tie_break)
        case tie_break
        when :largest_first
          :largest
        when :smallest_first
          :smallest
        when Symbol
          raise ArgumentError, "unknown tie_break #{tie_break.inspect}"
        else
          tie_break.respond_to?(:call) ? :callable : :priority
        end
      end

      # Returns the ordered list of stock indexes for an explicit priority
      # array and stashes the ordering on the solver.
      def order_indexes(priority)
        unless priority.is_a?(Array)
          raise ArgumentError, "tie_break must be a Symbol, an Array, or a callable"
        end

        value_to_index = @entries.to_h { |entry| [entry[:value], entry[:stock_index]] }
        indexes = priority.map do |key|
          value = denomination_value(key)
          value_to_index.fetch(value) do
            raise ArgumentError, "tie_break denomination #{key.inspect} is not in stock"
          end
        end

        unless indexes.sort == @entries.each_index.to_a
          raise ArgumentError, "tie_break must list every stock denomination exactly once"
        end

        @priority_indexes = indexes
      end

      def total_available
        @entries.sum { |entry| entry[:value] * entry[:stock] }
      end

      def order_entries!
        sorted = @entries.sort_by do |entry|
          case @tie_break_mode
          when :largest, :callable
            # Larger-first ordering reaches a tight incumbent quickly. For the
            # lexical modes it also defines the tie-break traversal order.
            -entry[:value]
          when :smallest
            entry[:value]
          when :priority
            @priority_indexes.index(entry[:stock_index])
          end
        end
        sorted.each_with_index { |entry, index| entry[:position] = index }
        @entries = sorted
      end

      def prepare_bounds!
        @suffix_max_value = Array.new(@entries.length + 1, 0)
        @tail_max_value = Array.new(@entries.length + 1, 0)
        @entries.each_index.reverse_each do |index|
          entry = @entries[index]
          @suffix_max_value[index] =
            @suffix_max_value[index + 1] + entry[:value] * entry[:stock]
          @tail_max_value[index] =
            [entry[:value], @tail_max_value[index + 1]].max
        end
      end

      # Produces a feasible (not necessarily optimal) starting incumbent, or
      # +[nil, nil]+ when neither greedy direction can make the amount.
      # Tries both largest-first and smallest-first greedy passes; the tightest
      # piece count seeds the branch-and-bound regardless of traversal order.
      def greedy_incumbent
        candidates = [greedy_pass(:largest), greedy_pass(:smallest)].compact
        return [nil, nil] if candidates.empty?

        candidates.min_by { |pieces, _usage| pieces }
      end

      def greedy_pass(direction)
        ordered = @entries.sort_by { |entry| direction == :largest ? -entry[:value] : entry[:value] }
        remaining = @amount
        pieces = 0
        usage = Array.new(@entries.length, 0)
        ordered.each do |entry|
          count = [entry[:stock], remaining / entry[:value]].min
          usage[entry[:position]] = count
          pieces += count
          remaining -= count * entry[:value]
        end
        remaining.zero? ? [pieces, usage] : nil
      end

      def search(index, remaining, used_pieces)
        tick_budget!

        if remaining.zero?
          accept(used_pieces)
          return
        end
        return if index >= @entries.length
        return if remaining > @suffix_max_value[index]
        return if @best_pieces && used_pieces >= @best_pieces

        if @best_pieces
          # Every remaining piece is worth at most the largest denomination
          # left, so this many more pieces are unavoidable.
          lower_bound = ceil_div(remaining, @tail_max_value[index])
          return if used_pieces + lower_bound > @best_pieces
          if big_first_lexical? && @dfs_solution_found &&
             used_pieces + lower_bound >= @best_pieces
            return
          end
        end

        memo_key = [index, remaining]
        previous = @memo[memo_key]
        if previous
          return if used_pieces > previous
          # Equal-prefix-length states may differ in prefix composition. Only
          # the big-first lexical traversals have the monotonicity making the
          # earlier arrival preferred; smallest-first and callable keep both.
          big_first = @tie_break_mode == :largest || @tie_break_mode == :priority
          return if used_pieces == previous && big_first
        end
        @memo[memo_key] = used_pieces

        entry = @entries[index]
        value = entry[:value]
        min_pieces, max_pieces = pieces_range(index, value, remaining, used_pieces)

        # Every lexical priority order enumerates piece counts from many to
        # few; the denomination order alone (large-first vs small-first) selects
        # the preferred vector among solutions of equal piece count.
        max_pieces.downto(min_pieces) do |count|
          explore_branch(index, count, used_pieces, remaining - count * value)
        end
        @usage[index] = 0
      end

      def explore_branch(index, count, used_pieces, new_remaining)
        return if new_remaining > @suffix_max_value[index + 1]

        @usage[index] = count
        search(index + 1, new_remaining, used_pieces + count)
      end

      # Inclusive range of current-denomination piece counts that can still
      # lead to a solution worth keeping. The suffix constraint is shared;
      # the piece-bound endpoints differ because counts are enumerated in
      # priority order (down for largest-first/priority, up for smallest).
      def pieces_range(index, value, remaining, used_pieces)
        max_pieces = [remaining / value, entry_stock(index)].min
        suffix_min = if remaining > @suffix_max_value[index + 1]
                       ceil_div(remaining - @suffix_max_value[index + 1], value)
                     else
                       0
                     end
        return [suffix_min, max_pieces] unless @best_pieces

        allowed = allowed_piece_budget(used_pieces)
        max_pieces = [max_pieces, allowed].min

        next_max = @tail_max_value[index + 1]
        min_pieces = [suffix_min, order_min(remaining, value, next_max, allowed)].max
        [[min_pieces, 0].max, [max_pieces, 0].max]
      end

      def entry_stock(index)
        @entries[index][:stock]
      end

      def allowed_piece_budget(used_pieces)
        bound = @best_pieces
        return nil if bound.nil?
        if big_first_lexical? && @dfs_solution_found
          # An equally sized DFS solution already wins the lexical tie-break.
          bound -= 1
        end
        bound - used_pieces
      end

      # Whether the denomination traversal is big-first, which has the
      # monotonicity needed to prune equal-size branches after the first win.
      def big_first_lexical?
        @tie_break_mode == :largest || @tie_break_mode == :priority
      end

      # Lower bound on current-denomination piece counts worth enumerating.
      # When the current denomination is larger than every tail denomination
      # (large-first traversal), using too few of it forces many smaller tail
      # pieces; the count + ceil((remaining - count*value)/next_max) allowance
      # gives a valid cutoff. In small-first traversal the tail is larger, so
      # no piece-based lower bound exists and the suffix bound is used instead.
      def order_min(remaining, value, next_max, allowed)
        if next_max.zero?
          remaining / value
        elsif value > next_max
          numerator = remaining - allowed * next_max
          denominator = value - next_max
          numerator.positive? ? ceil_div(numerator, denominator) : 0
        else
          0
        end
      end

      def ceil_div(numerator, denominator)
        (numerator / denominator.to_r).ceil
      end

      def accept(pieces)
        return if @best_pieces && pieces > @best_pieces

        candidate = @usage.dup

        if @best_pieces.nil? || pieces < @best_pieces
          @best_pieces = pieces
          @best_usage = candidate
          @dfs_solution_found = true
          return
        end

        # pieces == @best_pieces: select one solution deterministically.
        preferred =
          if @tie_break_mode == :callable
            @tie_break_callable.call(counts_from_usage(candidate), counts_from_usage(@best_usage))
          else
            # Explicitly compare complete count vectors under the configured
            # priority. The DFS traversal order alone is not sufficient: when
            # denominations are traversed small-first, deep larger-denomination
            # branches can complete before the lexically preferred ones.
            lexical_preferred?(candidate, @best_usage)
          end

        return unless preferred

        @best_usage = candidate
        @dfs_solution_found = true
      end

      # True when +candidate+ precedes +best+ under the configured lexical
      # priority (largest-first, smallest-first, or explicit priority array).
      def lexical_preferred?(candidate, best)
        # Smallest-first means: avoid small denominations unless inventory
        # forces them. Traversing denominations small-to-large, the preferred
        # vector uses *fewer* pieces at the first differing denomination.
        preferred_sign = @tie_break_mode == :smallest ? -1 : 1
        @entries.each do |entry|
          position = entry[:position]
          comparison = candidate[position] <=> best[position]
          next if comparison.zero?

          return comparison == preferred_sign
        end
        false
      end

      def tick_budget!
        return if @budget.nil?

        @visited += 1
        return unless @visited > @budget

        raise BudgetExceeded,
              "cash change search exceeded budget of #{@budget} states"
      end

      def empty_counts
        @entries.to_h { |entry| [entry[:key], 0] }
      end

      def counts_from_usage(usage)
        counts = empty_counts
        usage.each_with_index do |count, index|
          counts[@entries[index][:key]] = count
        end
        counts
      end
    end

    private_constant :Solver
  end
end
