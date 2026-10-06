# frozen_string_literal: true

require "money/cash_change/solver"

class Money
  # Finds an exact, inventory-limited combination of cash denominations.
  class CashChange
    # Represents either an exact change combination or an impossible request.
    class Result
      attr_reader :quantities, :total_count

      def initialize(quantities, total_count)
        @quantities = quantities
        @total_count = total_count
      end

      def solution?
        !quantities.nil?
      end

      alias solvable? solution?
    end

    NO_SOLUTION = Result.new(nil, nil).freeze

    def self.generate(amount, inventory, priority = nil)
      Solver.new(amount, inventory, priority).call
    end
  end

  # Finds the minimum-piece exact cash change for this Money amount.
  #
  # @param inventory [Hash{Money => Integer}] Available pieces per denomination.
  # @param priority [Array<Money>, nil] Denominations preferred first when totals tie.
  # @return [Money::CashChange::Result]
  def cash_change(inventory, priority: nil)
    Money.cash_change(self, inventory, priority: priority)
  end

  # Finds the minimum-piece exact cash change for an amount in fractional units.
  #
  # @param amount [Money] Exact amount to make.
  # @param inventory [Hash{Money => Integer}] Available pieces per denomination.
  # @param priority [Array<Money>, nil] Denominations preferred first when totals tie.
  # @return [Money::CashChange::Result]
  def self.cash_change(amount, inventory, priority: nil)
    CashChange.generate(amount, inventory, priority)
  end
end
