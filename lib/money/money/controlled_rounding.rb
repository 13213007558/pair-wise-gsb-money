# frozen_string_literal: true

class Money
  # Rounds every cell of a matrix of exact amounts either down or up to a
  # whole number of smallest currency units (e.g. cents), so that the
  # rounded matrix matches prescribed row and column totals exactly while
  # the total absolute rounding error is minimized.
  #
  # This is commonly known as "controlled rounding" of two-dimensional
  # tables. The problem is solved exactly with a minimum-cost maximum-flow
  # computation using exact rational arithmetic, so the result is provably
  # optimal and not merely a heuristic that happens to add up.
  #
  # Cells may be given as Money, Integer, Rational or BigDecimal and are
  # interpreted as amounts in the smallest currency unit. Money cells are
  # read through +fractional+, so any currency works, including ones that
  # are not cent-based (e.g. KWD with 1000 fils); all Money amounts must
  # share a single currency. Negative amounts are supported. Individual
  # cells may be locked to a fixed whole-unit value. When no assignment of
  # floor/ceil values can satisfy all totals, the result carries a
  # Conflict naming the incompatible set of rows and columns.
  #
  # @example
  #   result = Money::ControlledRounding.round(
  #     [[Rational(6, 5), Rational(13, 10)], [Rational(7, 10), Rational(12, 5)]],
  #     row_totals: [3, 3],
  #     column_totals: [2, 4],
  #   )
  #   result.feasible? # => true
  #   result.matrix    # => [[1, 2], [1, 2]]
  #   result.error     # => Rational(8, 5)
  class ControlledRounding
    # Explains why a rounding problem has no feasible solution.
    #
    # +rows+ and +columns+ are the indexes of a conflicting set of rows and
    # columns: those rows demand more (or fewer) upward roundings than those
    # columns are able to absorb, so no choice of floor/ceil values can
    # satisfy all of the totals at once.
    class Conflict
      attr_reader :rows, :columns, :message

      def initialize(rows:, columns:, message:)
        @rows = rows.freeze
        @columns = columns.freeze
        @message = message.freeze
      end

      def to_s
        @message
      end
    end

    # The outcome of a controlled rounding run.
    class Result
      # @return [Array<Array<Integer>>, nil] the rounded matrix in smallest
      #   currency units, or nil when the problem is infeasible
      attr_reader :matrix

      # @return [Rational, nil] the total absolute rounding error, or nil
      #   when the problem is infeasible
      attr_reader :error

      # @return [Conflict, nil] an explanation of the conflict when the
      #   problem is infeasible
      attr_reader :conflict

      def initialize(matrix:, error:, conflict:)
        @matrix = matrix
        @error = error
        @conflict = conflict
      end

      def feasible?
        !@matrix.nil?
      end
    end

    class << self
      # Round a matrix of exact amounts to whole smallest currency units.
      #
      # @param matrix [Array<Array<Money, Integer, Rational, BigDecimal>>]
      #   the amounts, expressed in the smallest currency unit
      # @param row_totals [Array<Money, Integer, Rational, BigDecimal>] the
      #   required total of each row, in whole smallest currency units
      # @param column_totals [Array<Money, Integer, Rational, BigDecimal>]
      #   the required total of each column, in whole smallest currency units
      # @param locked [Hash{Array(Integer, Integer) => Integer}] cells fixed
      #   to a given whole-unit value, keyed by [row, column] indexes
      #
      # @return [Result]
      def round(matrix, row_totals:, column_totals:, locked: {})
        currencies = []
        grid = normalize_matrix(matrix, currencies)
        rows = grid.size
        columns = rows.zero? ? 0 : grid.first.size
        row_targets = normalize_totals(row_totals, rows, "row", currencies)
        column_targets = normalize_totals(column_totals, columns, "column", currencies)
        locks = normalize_locks(locked, grid, currencies)
        check_single_currency(currencies)

        new(grid, row_targets, column_targets, locks).send(:solve)
      end

      private

      def normalize_matrix(matrix, currencies)
        unless matrix.is_a?(Array) && matrix.all? { |row| row.is_a?(Array) }
          raise ArgumentError, "matrix must be an Array of Arrays"
        end
        width = matrix.first&.size || 0
        unless matrix.all? { |row| row.size == width }
          raise ArgumentError, "all matrix rows must have the same number of columns"
        end
        matrix.map do |row|
          row.map do |cell|
            currencies << cell.currency if cell.is_a?(Money)
            exact_value(cell, "cell")
          end
        end
      end

      def normalize_totals(totals, expected, label, currencies)
        raise ArgumentError, "#{label} totals must be an Array" unless totals.is_a?(Array)
        unless totals.size == expected
          raise ArgumentError, "expected #{expected} #{label} total(s), got #{totals.size}"
        end
        totals.map.with_index do |total, index|
          currencies << total.currency if total.is_a?(Money)
          exact = exact_value(total, "#{label} total #{index}")
          unless exact.denominator == 1
            raise ArgumentError, "#{label} total #{index} (#{total.inspect}) is not a whole number of smallest currency units"
          end
          exact.to_i
        end
      end

      def normalize_locks(locked, grid, currencies)
        unless locked.is_a?(Hash)
          raise ArgumentError, "locked must be a Hash of [row, column] => value pairs"
        end
        locked.each_with_object({}) do |(key, value), locks|
          row, column = normalize_lock_key(key, grid)
          currencies << value.currency if value.is_a?(Money)
          exact = exact_value(value, "locked value at #{key.inspect}")
          unless exact.denominator == 1
            raise ArgumentError, "locked value at #{key.inspect} must be a whole number of smallest currency units"
          end
          cell = grid[row][column]
          unless exact >= cell.floor && exact <= cell.ceil
            raise ArgumentError,
                  "locked value #{exact.to_i} at #{key.inspect} is not between the floor (#{cell.floor}) and ceil (#{cell.ceil}) of the cell"
          end
          locks[[row, column]] = exact.to_i
        end
      end

      def normalize_lock_key(key, grid)
        unless key.is_a?(Array) && key.size == 2 && key.all? { |part| part.is_a?(Integer) }
          raise ArgumentError, "locked keys must be [row, column] pairs, got #{key.inspect}"
        end
        row, column = key
        width = grid.first&.size || 0
        unless row >= 0 && row < grid.size && column >= 0 && column < width
          raise ArgumentError, "locked cell #{key.inspect} is out of bounds"
        end
        [row, column]
      end

      def exact_value(value, what)
        case value
        when Money
          value.fractional.to_r
        when Integer
          value.to_r
        when Rational
          value
        when BigDecimal
          value.to_r
        when Float
          raise ArgumentError, "#{what} must be exact; Float is not supported, use Money, Integer, Rational or BigDecimal"
        else
          raise ArgumentError, "#{what} must be a Money, Integer, Rational or BigDecimal, got #{value.inspect}"
        end
      end

      def check_single_currency(currencies)
        unique = currencies.uniq(&:id)
        return if unique.size <= 1

        raise ArgumentError, "all Money amounts must use the same currency, got: #{unique.map(&:iso_code).join(", ")}"
      end
    end

    def initialize(grid, row_targets, column_targets, locks)
      @grid = grid
      @rows = grid.size
      @columns = row_targets.empty? ? 0 : grid.first.size
      @row_targets = row_targets
      @column_targets = column_targets
      @locks = locks
    end

    private

    def solve
      base, can_up = cell_bounds
      need_rows = Array.new(@rows) { |i| @row_targets[i] - base[i].sum }
      need_columns = Array.new(@columns) { |j| @column_targets[j] - base.sum { |row| row[j] } }

      conflict = check_total_balance(need_rows, need_columns) ||
                 check_negative_needs(need_rows, need_columns)
      return infeasible(conflict) if conflict

      ups, conflict = round_up_cells(can_up, need_rows, need_columns)
      return infeasible(conflict) if conflict

      matrix = Array.new(@rows) { |i| Array.new(@columns) { |j| base[i][j] + (ups[i][j] ? 1 : 0) } }
      Result.new(matrix: matrix, error: total_error(matrix), conflict: nil)
    end

    def cell_bounds
      base = Array.new(@rows) do |i|
        Array.new(@columns) { |j| @locks[[i, j]] || @grid[i][j].floor }
      end
      can_up = Array.new(@rows) do |i|
        Array.new(@columns) do |j|
          !@locks.key?([i, j]) && @grid[i][j].ceil > @grid[i][j].floor
        end
      end
      [base, can_up]
    end

    def check_total_balance(need_rows, need_columns)
      difference = need_rows.sum - need_columns.sum
      return nil if difference.zero?

      Conflict.new(
        rows: (0...@rows).to_a,
        columns: (0...@columns).to_a,
        message: "sum of row totals differs from sum of column totals by #{difference} smallest unit(s)",
      )
    end

    def check_negative_needs(need_rows, need_columns)
      need_rows.each_with_index do |need, i|
        next if need >= 0

        return Conflict.new(
          rows: [i],
          columns: (0...@columns).to_a,
          message: "row #{i} total is #{-need} smallest unit(s) below the minimum reachable with every cell rounded down",
        )
      end
      need_columns.each_with_index do |need, j|
        next if need >= 0

        return Conflict.new(
          rows: (0...@rows).to_a,
          columns: [j],
          message: "column #{j} total is #{-need} smallest unit(s) below the minimum reachable with every cell rounded down",
        )
      end
      nil
    end

    # Chooses which cells to round up. Each upward rounding adds one
    # smallest unit to its row and its column, so this is a transportation
    # problem: row i needs exactly need_rows[i] upward roundings, column j
    # absorbs exactly need_columns[j], and the extra absolute error of
    # rounding a cell up instead of down is the edge cost.
    def round_up_cells(can_up, need_rows, need_columns)
      source = 0
      column_offset = 1 + @rows
      sink = column_offset + @columns
      network = FlowNetwork.new(sink + 1)

      need_rows.each_with_index do |need, i|
        network.add_edge(source, 1 + i, need, 0) if need > 0
      end
      need_columns.each_with_index do |need, j|
        network.add_edge(column_offset + j, sink, need, 0) if need > 0
      end

      cell_edges = Array.new(@rows) { Array.new(@columns) }
      @rows.times do |i|
        @columns.times do |j|
          next unless can_up[i][j]

          cell = @grid[i][j]
          cost = (cell.ceil - cell) - (cell - cell.floor)
          cell_edges[i][j] = network.add_edge(1 + i, column_offset + j, 1, cost)
        end
      end

      flow, = network.min_cost_max_flow(source, sink)
      return [chosen_ups(cell_edges), nil] if flow == need_rows.sum

      [nil, cut_conflict(network, source, column_offset, need_rows, need_columns, can_up)]
    end

    def chosen_ups(cell_edges)
      Array.new(@rows) do |i|
        Array.new(@columns) do |j|
          edge = cell_edges[i][j]
          !edge.nil? && edge.capacity.zero?
        end
      end
    end

    # Turns the minimum cut of an unsaturated flow network into a Hall-type
    # certificate: a set of rows whose required upward roundings exceed what
    # the reachable columns can absorb plus the cells available elsewhere.
    def cut_conflict(network, source, column_offset, need_rows, need_columns, can_up)
      reachable = network.reachable_from(source)
      rows = (0...@rows).select { |i| reachable[1 + i] }
      columns = (0...@columns).select { |j| reachable[column_offset + j] }
      required = rows.sum { |i| need_rows[i] }
      absorbable = columns.sum { |j| need_columns[j] }
      elsewhere = rows.sum { |i| (0...@columns).count { |j| !reachable[column_offset + j] && can_up[i][j] } }
      Conflict.new(
        rows: rows,
        columns: columns,
        message: "rows #{rows} require #{required} upward rounding(s), but columns #{columns} can absorb " +                 "#{absorbable} and only #{elsewhere} further cell(s) can be rounded up elsewhere; " +                 "short by #{required - absorbable - elsewhere}",
      )
    end

    def total_error(matrix)
      error = 0
      @rows.times do |i|
        @columns.times do |j|
          error += (matrix[i][j] - @grid[i][j]).abs
        end
      end
      error
    end

    def infeasible(conflict)
      Result.new(matrix: nil, error: nil, conflict: conflict)
    end

    # Minimum-cost maximum-flow over exact rational costs, used internally
    # to find an optimal assignment of upward roundings. Successive
    # shortest augmenting paths (SPFA) keep the arithmetic exact.
    #
    # @api private
    class FlowNetwork
      Edge = Struct.new(:to, :rev, :capacity, :cost)

      def initialize(size)
        @graph = Array.new(size) { [] }
      end

      def add_edge(from, to, capacity, cost)
        forward = Edge.new(to, @graph[to].length, capacity, cost)
        backward = Edge.new(from, @graph[from].length, 0, -cost)
        @graph[from] << forward
        @graph[to] << backward
        forward
      end

      def min_cost_max_flow(source, sink)
        flow = 0
        cost = 0
        while (path = shortest_path(source, sink))
          edges, path_cost = path
          amount = edges.inject(Float::INFINITY) { |minimum, (node, index)| [minimum, @graph[node][index].capacity].min }
          edges.each do |node, index|
            edge = @graph[node][index]
            edge.capacity -= amount
            @graph[edge.to][edge.rev].capacity += amount
          end
          flow += amount
          cost += amount * path_cost
        end
        [flow, cost]
      end

      def reachable_from(source)
        seen = Array.new(@graph.size, false)
        seen[source] = true
        stack = [source]
        until stack.empty?
          @graph[stack.pop].each do |edge|
            next if edge.capacity <= 0 || seen[edge.to]

            seen[edge.to] = true
            stack << edge.to
          end
        end
        seen
      end

      private

      def shortest_path(source, sink)
        dist = Array.new(@graph.size) { Float::INFINITY }
        previous = Array.new(@graph.size)
        in_queue = Array.new(@graph.size, false)
        dist[source] = 0
        queue = [source]
        in_queue[source] = true
        until queue.empty?
          node = queue.shift
          in_queue[node] = false
          relax_edges(node, dist, previous, queue, in_queue)
        end
        return nil if previous[sink].nil?

        [reconstruct_path(previous, source, sink), dist[sink]]
      end

      def relax_edges(node, dist, previous, queue, in_queue)
        @graph[node].each_with_index do |edge, index|
          next if edge.capacity <= 0

          candidate = dist[node] + edge.cost
          next unless candidate < dist[edge.to]

          dist[edge.to] = candidate
          previous[edge.to] = [node, index]
          unless in_queue[edge.to]
            queue << edge.to
            in_queue[edge.to] = true
          end
        end
      end

      def reconstruct_path(previous, source, sink)
        path = []
        node = sink
        until node == source
          from, index = previous[node]
          path.unshift([from, index])
          node = from
        end
        path
      end
    end
  end
end
