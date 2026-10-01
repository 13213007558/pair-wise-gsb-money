# frozen_string_literal: true

class Money
  class ControlledRounding
    # Enumerates every combination of rounding decisions to find the exact
    # optimum by brute force; used to verify the flow-based solver on small
    # matrices. Exponential in the number of free cells.
    #
    # @api private
    class ExhaustiveSearch
      def initialize(free_cells, fracs, row_need, column_need)
        @free_cells = free_cells
        @fracs = fracs
        @row_need = row_need.dup
        @column_need = column_need.dup
        @remaining_row = Array.new(row_need.length, 0)
        @remaining_column = Array.new(column_need.length, 0)
        free_cells.each do |(i, j)|
          @remaining_row[i] += 1
          @remaining_column[j] += 1
        end
        @best_error = nil
        @best = nil
        @assignment = {}
      end

      # Returns the assignment ({[row, column] => 1}) of an optimal feasible
      # rounding, or nil when no combination satisfies the totals.
      def run
        search(0, 0)
        @best
      end

      private

      def search(index, error)
        if index == @free_cells.length
          record(error) if @row_need.all?(&:zero?) && @column_need.all?(&:zero?)
          return
        end
        i, j = @free_cells[index]
        @remaining_row[i] -= 1
        @remaining_column[j] -= 1
        frac = @fracs[i][j]
        search(index + 1, error + frac) if promising?(error + frac)
        try_round_up(i, j, index, error + 1 - frac)
        @remaining_row[i] += 1
        @remaining_column[j] += 1
      end

      def try_round_up(i, j, index, error)
        return unless @row_need[i] > 0 && @column_need[j] > 0
        @row_need[i] -= 1
        @column_need[j] -= 1
        @assignment[[i, j]] = 1
        search(index + 1, error) if promising?(error)
        @assignment.delete([i, j])
        @row_need[i] += 1
        @column_need[j] += 1
      end

      def promising?(error)
        (@best_error.nil? || error < @best_error) && fillable?
      end

      def record(error)
        if @best_error.nil? || error < @best_error
          @best_error = error
          @best = @assignment.dup
        end
      end

      def fillable?
        @row_need.each_with_index.all? { |need, i| need >= 0 && need <= @remaining_row[i] } &&
          @column_need.each_with_index.all? { |need, j| need >= 0 && need <= @remaining_column[j] }
      end
    end
  end
end
