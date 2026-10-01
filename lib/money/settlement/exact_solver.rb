# frozen_string_literal: true

class Money
  class Settlement
    # Canonical exact solver. A transfer plan with k transfers over a connected
    # group of n balances can change at most k+1 nonzero balances, so a zero-sum
    # group needs at least n-1 transfers. Maximizing the number of disjoint
    # zero-sum groups therefore minimizes the total number of transfers.
    class ExactSolver
      def initialize(entries, search_budget)
        @entries = entries
        @search_budget = search_budget
        @budget_used = 0
        @solutions = { 0 => [0, []] }
        @partial_solutions = {}
        @sums = { 0 => 0 }
        @group_indices = { 0 => [] }
      end

      def call
        full_mask = (1 << @entries.size) - 1
        solution = evaluate(full_mask)

        if solution
          [:optimal, solution, @budget_used, complete_proof(solution)]
        else
          [
            :budget_exhausted,
            @partial_solutions[full_mask],
            @budget_used,
            nil,
          ]
        end
      end

      private

      def evaluate(mask)
        return @solutions[mask] if @solutions.key?(mask)

        best_count = 0
        best_groups = nil
        maximum_groups = maximum_group_count(mask)
        proved = false

        each_candidate_group(mask) do |group|
          break if budget_exhausted?

          @budget_used += 1
          next unless sum(group).zero?

          child = evaluate(mask ^ group)
          next unless child

          candidate_groups = [indices(group), *child[1]]
          candidate_count = candidate_groups.size
          next unless better_partition?(
            candidate_count,
            candidate_groups,
            best_count,
            best_groups,
          )

          best_count = candidate_count
          best_groups = candidate_groups
          @partial_solutions[mask] = [best_count, best_groups]

          next unless best_count == maximum_groups

          proved = true
          break
        end

        return cache(mask, best_count, best_groups) if proved
        return timeout(mask, best_count, best_groups) if budget_exhausted?

        cache(mask, best_count, best_groups)
      end

      def budget_exhausted?
        @search_budget && @budget_used >= @search_budget
      end

      def timeout(mask, best_count, best_groups)
        @partial_solutions[mask] = [best_count, best_groups] if best_groups
        nil
      end

      def cache(mask, count, groups)
        @solutions[mask] = [count, groups]
      end

      def better_partition?(candidate_count, candidate_groups,
                            best_count, best_groups)
        candidate_count > best_count ||
          (candidate_count == best_count &&
            (best_groups.nil? || candidate_groups < best_groups))
      end

      def maximum_group_count(mask)
        positive = 0
        negative = 0
        each_entry(mask) do |entry|
          positive += 1 if entry.amount.positive?
          negative += 1 if entry.amount.negative?
        end
        [positive, negative].min
      end

      def each_candidate_group(mask)
        anchor = mask & -mask
        selectable = []
        each_index(mask ^ anchor) { |index| selectable << index }

        enumerate_groups(anchor, selectable) do |group|
          yield group
        end
      end

      def enumerate_groups(group, selectable, &block)
        block.call(group)

        selectable.each_with_index do |index, position|
          enumerate_groups(
            group | (1 << index),
            selectable.drop(position + 1),
          ) { |next_group| block.call(next_group) }
        end
      end

      def sum(mask)
        @sums[mask] ||= begin
          least_bit = mask & -mask
          sum(mask ^ least_bit) + @entries[least_bit.bit_length - 1].amount
        end
      end

      def indices(mask)
        @group_indices[mask] ||= begin
          indices = []
          each_index(mask) { |index| indices << index }
          indices
        end
      end

      def each_entry(mask, &block)
        each_index(mask) { |index| block.call(@entries[index]) }
      end

      def each_index(mask)
        index = 0
        while mask.positive?
          yield index if mask & 1 == 1
          mask >>= 1
          index += 1
        end
      end

      def complete_proof(solution)
        groups = solution[1].map do |group|
          group.map { |index| @entries[index].participant }
        end

        Proof.new(
          groups,
          groups.map { |group| group.size - 1 },
          "Every connected zero-sum group containing k non-zero participants " \
          "requires at least k-1 transfers, and each displayed group uses " \
          "exactly k-1. The canonical subset recurrence either evaluates all " \
          "partition choices or reaches the matching positive/negative group " \
          "upper bound, so it maximizes the number of disjoint zero-sum " \
          "groups. No settlement can therefore use fewer transfers.",
          {
            algorithm: "canonical_zero_sum_subset_dp",
            subset_choices_inspected: @budget_used,
            optimality_proved: true,
          },
        )
      end
    end
  end
end
