# frozen_string_literal: true

class Money
  # Exact minimum-transfer settlement for net balances in a single currency.
  #
  # Given every participant's net balance (positive means "should receive",
  # negative means "should pay"), expressed as integers in the currency's
  # smallest unit and summing to zero, Money::Settlement.solve finds a set of
  # transfers that zeroes everyone out using as few transfers as possible.
  #
  # A purely greedy strategy (always matching the largest creditor with the
  # largest debtor) does not always minimize the number of transfers. For
  # example, with balances {a: 5, b: 4, c: -4, d: -3, e: -2} greedy needs
  # four transfers, while the optimum is three (b pays c 4, a pays d 3,
  # a pays e 2).
  #
  # The optimum equals n - k, where n is the number of participants with a
  # non-zero balance and k is the maximum number of zero-sum groups the
  # participants can be partitioned into: a zero-sum group of m members
  # always needs at least m - 1 transfers, and m - 1 transfers per group are
  # also sufficient. Finding k is NP-hard in general, so the search accepts a
  # node budget (max_nodes); when the budget is exhausted, the best feasible
  # solution found so far is returned together with proven lower and upper
  # bounds and status :budget_exhausted instead of a false optimality claim.
  class Settlement
    # Raised when a settlement result fails an independent re-check.
    class VerificationError < StandardError; end

    # Raised internally when the search budget is exhausted.
    class BudgetExhausted < StandardError; end

    # A single transfer of +amount+ minor units from participant +from+ to
    # participant +to+.
    class Transfer
      include Comparable

      attr_reader :from, :to, :amount

      def initialize(from:, to:, amount:)
        @from = from
        @to = to
        @amount = amount
        freeze
      end

      def ==(other)
        other.is_a?(Transfer) && from == other.from && to == other.to && amount == other.amount
      end
      alias eql? ==

      def hash
        [from, to, amount].hash
      end

      # Canonical ordering (by participant name, then amount) used to make
      # solver output deterministic.
      def <=>(other)
        [from.to_s, to.to_s, amount] <=> [other.from.to_s, other.to.to_s, other.amount]
      end

      def to_s
        "#{from} pays #{to} #{amount}"
      end

      def inspect
        "#<#{self.class.name} #{self}>"
      end
    end

    # The outcome of Money::Settlement.solve.
    class Result
      # @return [Array<Transfer>] transfers that zero out every participant
      attr_reader :transfers

      # @return [Array<Array>] zero-sum groups of participant names; the
      #   optimality certificate (see #proof)
      attr_reader :groups

      # @return [Integer] proven lower bound on the number of transfers
      attr_reader :lower_bound

      # @return [Integer] number of transfers in the returned (feasible)
      #   solution; an upper bound on the optimum
      attr_reader :upper_bound

      # @return [Integer] search nodes explored
      attr_reader :nodes_explored

      # @return [Symbol] :optimal or :budget_exhausted
      attr_reader :status

      def initialize(transfers:, groups:, lower_bound:, upper_bound:, nodes_explored:, status:)
        @transfers = transfers.freeze
        @groups = groups.map(&:freeze).freeze
        @lower_bound = lower_bound
        @upper_bound = upper_bound
        @nodes_explored = nodes_explored
        @status = status
        freeze
      end

      def optimal?
        status == :optimal
      end

      def transfer_count
        transfers.size
      end

      # A reviewable optimality basis for the result: the zero-sum groups
      # (which any auditor can sum to check) plus the counting argument that
      # turns "at most k zero-sum groups" into "at least n - k transfers".
      #
      # @return [Hash]
      def proof
        {
          status: status,
          transfer_count: transfer_count,
          lower_bound: lower_bound,
          upper_bound: upper_bound,
          zero_sum_groups: groups,
          argument: proof_argument,
        }
      end

      private

      def proof_argument
        if optimal?
          "Every transfer connects two participants whose combined balance must sum to zero, "           "so settling a zero-sum component of m members takes at least m - 1 transfers. "           "Exhaustive search shows the participants cannot be partitioned into more than "           "#{groups.size} zero-sum group(s); at least "           "#{groups.sum(&:size)} - #{groups.size} = #{lower_bound} transfers are therefore necessary, "           "and the returned solution achieves that bound."
        else
          "The search budget was exhausted before optimality could be proven. "           "The returned solution is feasible with #{upper_bound} transfers; the optimum is "           "known to lie between #{lower_bound} and #{upper_bound} transfers. "           "Re-run with a larger max_nodes budget to narrow the gap."
        end
      end
    end

    # Tracks the remaining search budget. Not part of the public API.
    class Budget
      attr_reader :nodes

      def initialize(max_nodes)
        unless max_nodes.nil? || (max_nodes.is_a?(Integer) && max_nodes >= 0)
          raise ArgumentError, "max_nodes must be a non-negative Integer or nil"
        end

        @max_nodes = max_nodes
        @nodes = 0
      end

      def consume!
        @nodes += 1
        raise BudgetExhausted if @max_nodes && @nodes > @max_nodes
      end
    end

    class << self
      # Solves a settlement instance.
      #
      # @param balances [Hash, Array] participant => Integer net balance, or
      #   an Array of [participant, balance] pairs. Amounts are integers in
      #   the currency's smallest unit and must sum to zero. Zero balances are
      #   dropped; participant names must be unique.
      # @param max_nodes [Integer, nil] optional search budget. When the
      #   budget is exhausted the result carries the best feasible solution,
      #   proven bounds, and status :budget_exhausted.
      #
      # @return [Result]
      def solve(balances, max_nodes: nil)
        entries = normalize(balances)
        budget = Budget.new(max_nodes)
        count = entries.size
        return empty_result(budget) if count < 2

        amounts = entries.map(&:last)
        best_groups = greedy_partition(amounts)
        exhausted_at = nil

        group_count = count / 2
        while group_count > best_groups.size
          partition =
            begin
              find_partition(amounts, group_count, budget)
            rescue BudgetExhausted
              exhausted_at = group_count
              break
            end
          if partition
            best_groups = partition
            break
          end
          group_count -= 1
        end

        transfers = best_groups.flat_map { |group| settle_group(group.map { |i| entries[i] }) }
        transfers.sort!
        groups = components(entries.map(&:first), transfers)

        Result.new(
          transfers: transfers,
          groups: groups,
          lower_bound: exhausted_at ? count - exhausted_at : transfers.size,
          upper_bound: transfers.size,
          nodes_explored: budget.nodes,
          status: exhausted_at ? :budget_exhausted : :optimal,
        )
      end

      # Independently re-checks a settlement result.
      #
      # Verifies that the transfers net every participant to zero, that the
      # groups form a zero-sum partition consistent with the transfer count,
      # and - for results claiming optimality - re-runs the exhaustive
      # refutation that no partition into more zero-sum groups exists.
      #
      # @param balances [Hash, Array] the original balances
      # @param result [Result] the result to check
      # @param max_nodes [Integer, nil] budget for the optimality re-check
      #
      # @return [true]
      # @raise [VerificationError] when any check fails
      def verify(balances, result, max_nodes: nil)
        entries = normalize(balances)
        names = entries.map(&:first)
        verify_transfers(entries, result.transfers)
        verify_groups(entries, result.groups, names)
        verify_transfer_count(result, names.size)
        verify_optimality(entries, result, max_nodes) if result.optimal? && names.size >= 2
        true
      end

      private

      def empty_result(budget)
        Result.new(transfers: [], groups: [], lower_bound: 0, upper_bound: 0, nodes_explored: budget.nodes, status: :optimal)
      end

      def normalize(balances)
        pairs =
          case balances
          when Hash then balances.to_a
          when Array then balances
          else
            raise ArgumentError, "balances must be a Hash of participant => balance or an Array of [participant, balance] pairs"
          end

        amounts_by_name = {}
        pairs.each do |pair|
          unless pair.is_a?(Array) && pair.size == 2
            raise ArgumentError, "each balance entry must be a [participant, balance] pair, got #{pair.inspect}"
          end

          name, amount = pair
          unless amount.is_a?(Integer)
            raise ArgumentError, "balances must be Integers in the currency's smallest unit, got #{amount.inspect} for #{name.inspect}"
          end
          if amounts_by_name.key?(name)
            raise ArgumentError, "duplicate participant #{name.inspect}"
          end

          amounts_by_name[name] = amount
        end

        unless amounts_by_name.each_value.sum == 0
          raise ArgumentError, "balances must sum to zero"
        end

        amounts_by_name.reject { |_, amount| amount == 0 }
                       .sort_by { |name, amount| [amount, name.to_s] }
      end

      # A feasible partition into zero-sum groups, used as the incumbent
      # solution and as the search's initial upper bound.
      def greedy_partition(amounts)
        members = amounts.each_index.map { |i| [i, amounts[i]] }
        transfers = settle_group(members)
        parent = (0...amounts.size).to_a
        transfers.each { |t| union(parent, t.from, t.to) }
        amounts.each_index.group_by { |i| root(parent, i) }.values
      end

      # Exact search: can the participants be partitioned into group_count
      # zero-sum groups? Returns the partition (arrays of indices) or nil.
      def find_partition(amounts, group_count, budget)
        search_partition(amounts, (0...amounts.size).to_a, group_count, budget)
      end

      def search_partition(amounts, remaining, group_count, budget)
        budget.consume!
        if group_count == 1
          return remaining.sum { |i| amounts[i] } == 0 ? [remaining] : nil
        end
        return nil if remaining.size < 2 * group_count

        anchor = remaining.first
        rest = remaining.drop(1)
        max_subset_size = remaining.size - 2 * (group_count - 1) - 1
        each_subset(amounts, rest, -amounts[anchor], max_subset_size, budget) do |subset|
          partition = search_partition(amounts, rest - subset, group_count - 1, budget)
          return [[anchor, *subset], *partition] if partition
        end
        nil
      end

      # Yields every subset of candidates (in canonical index order) whose
      # amounts sum to target, with size at most max_size.
      def each_subset(amounts, candidates, target, max_size, budget, prefix = [], sum = 0, &block)
        budget.consume!
        yield prefix if !prefix.empty? && sum == target
        return if prefix.size == max_size

        candidates.each_with_index do |candidate, index|
          each_subset(amounts, candidates.drop(index + 1), target, max_size, budget, [*prefix, candidate], sum + amounts[candidate], &block)
        end
      end

      # Deterministic two-pointer settlement of one zero-sum group; yields at
      # most members.size - 1 transfers.
      def settle_group(members)
        debtors = members.select { |_, amount| amount < 0 }.sort_by { |name, amount| [amount, name.to_s] }
        creditors = members.select { |_, amount| amount > 0 }.sort_by { |name, amount| [-amount, name.to_s] }
        transfers = []
        until debtors.empty?
          debtor_name, debtor_amount = debtors.first
          creditor_name, creditor_amount = creditors.first
          amount = [creditor_amount, -debtor_amount].min
          transfers << Transfer.new(from: debtor_name, to: creditor_name, amount: amount)
          shift_member(debtors, amount)
          shift_member(creditors, -amount)
        end
        transfers
      end

      def shift_member(list, delta)
        name, amount = list.first
        if amount + delta == 0
          list.shift
        else
          list[0] = [name, amount + delta]
        end
      end

      def components(names, transfers)
        index_of = names.each_with_index.to_h
        parent = (0...names.size).to_a
        transfers.each { |t| union(parent, index_of.fetch(t.from), index_of.fetch(t.to)) }
        names.group_by { |name| root(parent, index_of.fetch(name)) }
             .values
             .map { |group| group.sort_by(&:to_s) }
             .sort_by { |group| group.map(&:to_s) }
      end

      def root(parent, node)
        node = parent[node] while parent[node] != node
        node
      end

      def union(parent, left, right)
        parent[root(parent, left)] = root(parent, right)
      end

      def verify_transfers(entries, transfers)
        known = entries.to_h
        net = Hash.new(0)
        transfers.each do |transfer|
          unless transfer.amount.is_a?(Integer) && transfer.amount.positive?
            raise VerificationError, "transfer amounts must be positive Integers"
          end
          if transfer.from == transfer.to || !known.key?(transfer.from) || !known.key?(transfer.to)
            raise VerificationError, "transfer #{transfer.inspect} references unknown or identical participants"
          end

          net[transfer.from] -= transfer.amount
          net[transfer.to] += transfer.amount
        end
        entries.each do |name, amount|
          unless net[name] == amount
            raise VerificationError, "net change for #{name.inspect} is #{net[name]}, expected #{amount}"
          end
        end
      end

      def verify_groups(entries, groups, names)
        amounts = entries.to_h
        flat = groups.flatten
        unless flat.size == names.size && flat.sort_by(&:to_s) == names.sort_by(&:to_s)
          raise VerificationError, "groups do not partition the participants"
        end

        groups.each do |group|
          unless group.sum { |name| amounts.fetch(name) } == 0
            raise VerificationError, "group #{group.inspect} does not sum to zero"
          end
        end
      end

      def verify_transfer_count(result, count)
        unless result.transfers.size == count - result.groups.size
          raise VerificationError, "transfer count does not match participants - groups"
        end
        unless result.lower_bound <= result.upper_bound && result.upper_bound == result.transfers.size
          raise VerificationError, "reported bounds are inconsistent with the transfers"
        end
      end

      def verify_optimality(entries, result, max_nodes)
        amounts = entries.map(&:last)
        budget = Budget.new(max_nodes)
        refutation =
          begin
            find_partition(amounts, result.groups.size + 1, budget)
          rescue BudgetExhausted
            raise VerificationError, "could not re-verify optimality within max_nodes=#{max_nodes}"
          end
        if refutation
          raise VerificationError, "optimality claim is false: a partition into #{result.groups.size + 1} zero-sum groups exists"
        end
      end
    end
  end

  # Solves net balances into a minimum set of settlement transfers.
  #
  # @param balances [Hash, Array] participant => Integer net balance (minor
  #   units, summing to zero), or an Array of [participant, balance] pairs
  # @param max_nodes [Integer, nil] optional search budget
  #
  # @return [Money::Settlement::Result]
  #
  # @see Money::Settlement
  def self.settle(balances, max_nodes: nil)
    Settlement.solve(balances, max_nodes: max_nodes)
  end
end
