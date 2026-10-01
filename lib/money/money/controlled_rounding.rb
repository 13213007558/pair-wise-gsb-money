# frozen_string_literal: true

class Money
  # Solves the controlled rounding problem for a matrix of exact amounts.
  #
  # Given a matrix of exact rational amounts and a target total for every
  # row and every column, each cell is rounded to a whole number of the
  # currency's smallest unit (its subunit) such that:
  #
  # * every cell is rounded either down or up to one of the two integers
  #   surrounding its exact value,
  # * every row and column of the rounded matrix sums exactly to its target,
  # * the total absolute rounding error is as small as possible.
  #
  # Individual cells may be locked to a chosen whole-subunit value. When no
  # solution exists, the result names a conflicting set of rows and columns
  # that explains why the targets cannot be met.
  #
  # All computations use exact rational arithmetic. Amounts are expressed in
  # currency units while the returned matrix holds integers in the currency's
  # smallest unit (cents for USD, fils for KWD, khoums - 1/5 units - for
  # MRU, ...). Negative amounts and non-decimal currencies are supported.
  #
  # @example
  #   result = Money::ControlledRounding.round(
  #     [[Rational(67, 200), Rational(67, 200)], [Rational(67, 200), Rational(67, 200)]],
  #     row_totals: [Rational(67, 100), Rational(67, 100)],
  #     column_totals: [Rational(67, 100), Rational(67, 100)],
  #     currency: "USD",
  #   )
  #   result.feasible? # => true
  #   result.matrix    # => [[34, 33], [33, 34]] (whole cents, one optimal solution)
  #   result.error     # => (2/1) (total absolute error in cents)
  class ControlledRounding
    # The outcome of a controlled rounding computation.
    #
    # When feasible, +matrix+ holds the rounded integer matrix (in subunits)
    # and +error+ the total absolute rounding error as an exact Rational.
    # When infeasible, +conflict_rows+ and +conflict_columns+ hold the
    # indices of a conflicting set of rows and columns and +message+
    # describes the conflict.
    class Result
      attr_reader :matrix, :error, :conflict_rows, :conflict_columns, :message

      def initialize(matrix:, error:, conflict_rows:, conflict_columns:, message:)
        @matrix = matrix
        @error = error
        @conflict_rows = conflict_rows
        @conflict_columns = conflict_columns
        @message = message
      end

      def feasible?
        !@matrix.nil?
      end

      def infeasible?
        @matrix.nil?
      end
    end

    class << self
      # Rounds +matrix+ to whole subunits under the given row and column
      # totals, minimizing the total absolute rounding error.
      #
      # @param matrix [Array<Array<Numeric>>] exact amounts in currency
      #   units (Integer, Rational or BigDecimal; Float is rejected as inexact)
      # @param row_totals [Array<Numeric>] exact target total of each row
      # @param column_totals [Array<Numeric>] exact target total of each column
      # @param locked [Hash{Array(Integer, Integer) => Numeric}, nil] cells
      #   fixed to a chosen whole-subunit value, keyed by [row, column]
      # @param currency [Money::Currency, String, Symbol, nil] currency whose
      #   smallest unit is rounded to; defaults to Money.default_currency
      # @return [Result]
      def round(matrix, row_totals:, column_totals:, locked: nil, currency: nil)
        new(matrix, row_totals, column_totals, locked, currency).solve
      end

      # Finds the optimum by enumerating every combination of rounding
      # decisions. Exponential in the number of non-integral unlocked cells,
      # so only suitable for verifying small matrices (e.g. in tests).
      #
      # @param (see .round)
      # @param max_free_cells [Integer] refuse to enumerate above this many
      #   non-integral unlocked cells
      # @return [Result]
      # @raise [ArgumentError] if there are more free cells than allowed
      def brute_force(matrix, row_totals:, column_totals:, locked: nil, currency: nil, max_free_cells: 20)
        new(matrix, row_totals, column_totals, locked, currency).solve_by_enumeration(max_free_cells)
      end
    end

    def initialize(matrix, row_totals, column_totals, locked, currency)
      @currency = Currency.wrap(currency) || Money.default_currency
      @subunit = Integer(@currency.subunit_to_unit)
      @scaled = normalize_matrix(matrix).map { |row| row.map { |value| value * @subunit } }
      @rows = @scaled.length
      @cols = @rows.zero? ? 0 : @scaled.first.length
      @row_targets = normalize_totals(row_totals, @rows, "row")
      @column_targets = normalize_totals(column_totals, @cols, "column")
      @locked = normalize_locked(locked)
      @floors = @scaled.map { |row| row.map(&:floor) }
      @fracs = @scaled.each_with_index.map do |row, i|
        row.each_with_index.map { |value, j| value - @floors[i][j] }
      end
      @free_cells = []
      @free_by_row = Array.new(@rows) { [] }
      @rows.times do |i|
        @cols.times do |j|
          next if @locked[i][j] || @fracs[i][j] == 0
          @free_cells << [i, j]
          @free_by_row[i] << j
        end
      end
      @row_need = Array.new(@rows) do |i|
        @row_targets[i] - (0...@cols).sum { |j| @locked[i][j] || @floors[i][j] }
      end
      @column_need = Array.new(@cols) do |j|
        @column_targets[j] - (0...@rows).sum { |i| @locked[i][j] || @floors[i][j] }
      end
    end

    # Solves the rounding problem as a min-cost flow: every row must push
    # +row_need+ units of "round up" through its cells (capacity 1 each,
    # cost = error difference between rounding up and down) into columns
    # that can absorb +column_need+ units each.
    def solve
      conflict = trivial_conflict
      return conflict if conflict

      network = FlowNetwork.new(@rows + @cols + 2)
      source = @rows + @cols
      sink = source + 1
      @rows.times { |i| network.add_edge(source, i, @row_need[i], 0) }
      @cols.times { |j| network.add_edge(@rows + j, sink, @column_need[j], 0) }
      cell_edges = {}
      @free_cells.each do |(i, j)|
        cell_edges[[i, j]] = network.add_edge(i, @rows + j, 1, 1 - (2 * @fracs[i][j]))
      end
      target = @row_need.sum
      if network.min_cost_flow(source, sink, target) < target
        rows, columns, message = conflict_from(network.reachable_from(source))
        return infeasible_result(rows, columns, message)
      end
      assignment = {}
      cell_edges.each { |cell, edge| assignment[cell] = 1 - edge.cap }
      feasible_result(assignment)
    end

    def solve_by_enumeration(max_free_cells)
      if @free_cells.length > max_free_cells
        raise ArgumentError, "refusing to enumerate #{@free_cells.length} free cells (limit is #{max_free_cells})"
      end
      conflict = trivial_conflict
      return conflict if conflict

      best = ExhaustiveSearch.new(@free_cells, @fracs, @row_need, @column_need).run
      best ? feasible_result(best) : solve
    end

    private

    def normalize_matrix(matrix)
      unless matrix.is_a?(Array) && matrix.all? { |row| row.is_a?(Array) }
        raise ArgumentError, "matrix must be an Array of Arrays of exact amounts"
      end
      width = matrix.first ? matrix.first.length : 0
      unless matrix.all? { |row| row.length == width }
        raise ArgumentError, "matrix rows must all have the same length"
      end
      matrix.map { |row| row.map { |cell| exact(cell) } }
    end

    def normalize_totals(totals, count, label)
      unless totals.is_a?(Array) && totals.length == count
        raise ArgumentError, "expected #{count} #{label} total(s), got #{totals.inspect}"
      end
      totals.map do |total|
        scaled = exact(total) * @subunit
        unless scaled.denominator == 1
          raise ArgumentError, "#{label} total #{total.inspect} is not a whole number of subunits"
        end
        scaled.to_i
      end
    end

    def normalize_locked(locked)
      result = Array.new(@rows) { Array.new(@cols) }
      return result if locked.nil?
      unless locked.is_a?(Hash)
        raise ArgumentError, "locked must be a Hash mapping [row, column] to an exact amount"
      end
      locked.each do |key, value|
        row, col = validate_lock_key(key)
        scaled = exact(value) * @subunit
        floor = @scaled[row][col].floor
        ceil = @scaled[row][col].ceil
        unless scaled.denominator == 1 && (scaled.to_i == floor || scaled.to_i == ceil)
          raise ArgumentError, "locked value #{value.inspect} at #{key.inspect} is not the floor or ceil of the cell in whole subunits"
        end
        result[row][col] = scaled.to_i
      end
      result
    end

    def validate_lock_key(key)
      unless key.is_a?(Array) && key.length == 2
        raise ArgumentError, "locked keys must be [row, column] pairs, got #{key.inspect}"
      end
      row, col = key
      unless row.is_a?(Integer) && col.is_a?(Integer) && row.between?(0, @rows - 1) && col.between?(0, @cols - 1)
        raise ArgumentError, "locked cell #{key.inspect} is out of range for a #{@rows}x#{@cols} matrix"
      end
      [row, col]
    end

    def exact(value)
      case value
      when Integer then value.to_r
      when Rational then value
      when BigDecimal then value.to_r
      else
        raise ArgumentError, "#{value.inspect} is not an exact amount; use Integer, Rational or BigDecimal (Float is inexact)"
      end
    end

    # Infeasibilities that can be reported without running the flow.
    def trivial_conflict
      if @row_targets.sum != @column_targets.sum
        return infeasible_result((0...@rows).to_a, (0...@cols).to_a,
                                 "sum of row totals (#{@row_targets.sum}) does not equal sum of column totals (#{@column_targets.sum})")
      end
      @rows.times do |i|
        if @row_need[i].negative?
          return infeasible_result([i], [],
                                   "row #{i} total #{@row_targets[i]} is smaller than the #{@row_targets[i] - @row_need[i]} required by its floored and locked cells")
        end
      end
      @cols.times do |j|
        if @column_need[j].negative?
          return infeasible_result([], [j],
                                   "column #{j} total #{@column_targets[j]} is smaller than the #{@column_targets[j] - @column_need[j]} required by its floored and locked cells")
        end
      end
      nil
    end

    # Derives a Hall-type certificate of infeasibility from the min-cut of
    # the exhausted flow network: the rows still holding unassigned round-ups
    # and the saturated columns they can still reach.
    def conflict_from(reachable)
      rows = (0...@rows).select { |i| reachable[i] }
      columns = (0...@cols).select { |j| reachable[@rows + j] }
      in_columns = Array.new(@cols, false)
      columns.each { |j| in_columns[j] = true }
      demand = rows.sum { |i| @row_need[i] }
      slots = columns.sum { |j| @column_need[j] }
      rows.each do |i|
        @free_by_row[i].each { |j| slots += 1 unless in_columns[j] }
      end
      message = "rows #{rows.inspect} need #{demand} cell(s) rounded up, but at most #{slots} can be " +                "rounded up given the totals of columns #{columns.inspect}"
      [rows, columns, message]
    end

    def feasible_result(assignment)
      matrix = Array.new(@rows) do |i|
        Array.new(@cols) do |j|
          @locked[i][j] || @floors[i][j] + (assignment[[i, j]] || 0)
        end
      end
      error = 0.to_r
      @rows.times do |i|
        @cols.times { |j| error += (matrix[i][j] - @scaled[i][j]).abs }
      end
      Result.new(matrix: matrix, error: error, conflict_rows: [], conflict_columns: [], message: nil)
    end

    def infeasible_result(rows, columns, message)
      Result.new(matrix: nil, error: nil, conflict_rows: rows, conflict_columns: columns, message: message)
    end
  end
end
