# frozen_string_literal: true

class Money
  # Finds a minimum number of same-currency transfers that reproduces a set of
  # net balances.
  class Settlement
    Transfer = Data.define(:from, :to, :amount)
    Proof = Data.define(:grouping, :group_transfer_counts, :basis, :search)
    Result = Data.define(
      :currency,
      :participants,
      :transfers,
      :lower_bound,
      :upper_bound,
      :status,
      :search_budget,
      :budget_used,
      :proof,
    ) do
      def optimal?
        status == "optimal"
      end

      def budget_exhausted?
        status == "budget_exhausted"
      end
    end

    Entry = Data.define(:participant, :amount)
    require "money/settlement/largest_balance_greedy"
    require "money/settlement/exact_solver"

    class << self
      # Finds a minimum-cardinality settlement for same-currency net balances.
      #
      # Balances can be supplied as a Hash or as an array of participant/value
      # pairs. Integer values are fractional units and require +currency+.
      # Money values must all use the same currency and integer fractional
      # amounts. Zero balances are removed.
      #
      # The exact search is exponential because minimum settlement is NP-hard.
      # +search_budget+ bounds the number of subset choices inspected. When it
      # is exhausted, the returned result remains feasible but separates its
      # upper bound, lower bound, and unproven status.
      def generate(balances, currency: nil, search_budget: nil)
        entries, resolved_currency = normalize(balances, currency)
        validate_search_budget(search_budget)

        return empty_result(resolved_currency, search_budget) if entries.empty?

        greedy_transfers = LargestBalanceGreedy.new(entries, resolved_currency).transfers
        status, solution, budget_used, proof =
          ExactSolver.new(entries, search_budget).call

        exact_transfers = solution && transfers_for(solution[1], entries, resolved_currency)
        transfers = choose_transfers(greedy_transfers, exact_transfers)

        lower_bound = lower_bound(entries)
        Result.new(
          resolved_currency,
          entries.map(&:participant),
          transfers,
          lower_bound,
          transfers.size,
          status.to_s,
          search_budget,
          budget_used,
          proof,
        )
      end

      private

      def normalize(balances, currency)
        pairs =
          case balances
          when Hash
            balances.to_a
          when Array
            balances
          else
            raise ArgumentError, "balances must be a Hash or an Array of pairs"
          end

        resolved_currency = Money::Currency.wrap(currency)
        entries = []
        seen_names = {}

        pairs.each do |pair|
          unless pair.is_a?(Array) && pair.size == 2
            raise ArgumentError, "each balance must be a participant and value"
          end

          participant, value = pair
          name = participant.to_s
          if seen_names.key?(name)
            raise ArgumentError, "duplicate participant: #{name.inspect}"
          end
          seen_names[name] = true

          amount, amount_currency = extract_amount(value, resolved_currency)
          resolved_currency ||= amount_currency
          if amount_currency && resolved_currency != amount_currency
            raise ArgumentError, "all balances must use the same currency"
          end

          entries << Entry.new(participant, amount)
        end

        unless entries.sum(&:amount).zero?
          raise ArgumentError, "balances must sum to zero"
        end

        entries = entries.reject { |entry| entry.amount.zero? }
        entries.sort_by! { |entry| [entry.participant.to_s, entry.participant.class.name] }
        [entries, resolved_currency]
      end

      def extract_amount(value, default_currency)
        case value
        when Money
          fractional = value.fractional
          unless fractional.is_a?(Integer)
            raise ArgumentError, "Money balances must use integer fractional amounts"
          end
          [fractional, value.currency]
        when Integer
          if default_currency.nil? && value.nonzero?
            raise ArgumentError, "currency is required for integer balances"
          end
          [value, default_currency]
        else
          raise TypeError, "balance values must be Money or Integer"
        end
      end

      def validate_search_budget(search_budget)
        return if search_budget.nil?
        return if search_budget.is_a?(Integer) && search_budget >= 0

        raise ArgumentError, "search_budget must be a non-negative Integer or nil"
      end

      def empty_result(currency, search_budget)
        Result.new(currency, [], [], 0, 0, "optimal", search_budget, 0,
                   Proof.new([], [], "There are no non-zero balances.",
                             {
                               algorithm: "canonical_zero_sum_subset_dp",
                               subset_choices_inspected: 0,
                               optimality_proved: true,
                             }))
      end

      def choose_transfers(greedy_transfers, exact_transfers)
        return greedy_transfers if exact_transfers.nil?
        return exact_transfers if exact_transfers.size <= greedy_transfers.size

        greedy_transfers
      end

      def lower_bound(entries)
        positive = entries.count { |entry| entry.amount.positive? }
        negative = entries.count { |entry| entry.amount.negative? }
        [positive, negative].max
      end

      def transfers_for(groups, entries, currency)
        groups.flat_map do |group|
          settle_group(group, entries, currency)
        end
      end

      def settle_group(group, entries, currency)
        balances = group.map { |index| entries[index].amount }
        transfers = []

        until balances.all?(&:zero?)
          debtor = balances.index(&:negative?)
          creditor = balances.index(&:positive?)
          amount = [-balances[debtor], balances[creditor]].min

          balances[debtor] += amount
          balances[creditor] -= amount
          transfers << Transfer.new(
            entries[group[debtor]].participant,
            entries[group[creditor]].participant,
            Money.new(amount, currency),
          )
        end

        transfers
      end
    end
  end

  # Settles same-currency net balances using the minimum number of transfers
  # that can be proven within the supplied search budget.
  def self.settle_balances(balances, currency: nil, search_budget: nil)
    Settlement.generate(balances, currency: currency,
                         search_budget: search_budget)
  end
end
