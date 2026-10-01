# frozen_string_literal: true

class Money
  class Settlement
    # Returns a deterministic feasible settlement. At each step it pairs the
    # remaining creditor and debtor with the largest absolute balances, using
    # the canonical participant order to break ties.
    class LargestBalanceGreedy
      def initialize(entries, currency)
        @entries = entries
        @currency = currency
      end

      def transfers
        balances = @entries.map(&:amount)
        transfers = []

        until balances.all?(&:zero?)
          creditor = largest_index(balances, &:positive?)
          debtor = largest_index(balances, &:negative?)
          amount = [balances[creditor], -balances[debtor]].min

          balances[creditor] -= amount
          balances[debtor] += amount
          transfers << Transfer.new(
            @entries[debtor].participant,
            @entries[creditor].participant,
            Money.new(amount, @currency),
          )
        end

        transfers
      end

      private

      def largest_index(balances)
        balances.each_index.select { |index| yield balances[index] }.max_by do |index|
          [balances[index].abs, -index]
        end
      end
    end
  end
end
