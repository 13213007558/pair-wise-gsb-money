# frozen_string_literal: true

class Money
  class Allocation
    # Allocates a specified amount into parts based on their proportions or distributes
    # it evenly when the number of parts is specified numerically.
    #
    # The total of the allocated amounts will always equal the original amount.
    #
    # The parts can be specified as:
    #   Numeric — performs the split between a given number of parties evenly
    #   Array<Numeric> — allocates the amounts proportionally to the given array
    #
    # @param amount [Numeric] The total amount to be allocated.
    # @param parts [Numeric, Array<Numeric>] Number of parts to split into or an array (proportions for allocation)
    # @param decimal_cutoff [Boolean, Integer] Controls per-split precision:
    #   - When true, splits are truncated to whole amounts.
    #   - When an Integer N, splits are rounded to N decimal places.
    #   - When false or nil, no rounding/truncation is applied.
    #   Defaults to true (whole amounts).
    #
    # @return [Array<Numeric>] An array containing the allocated amounts.
    # @raise [ArgumentError] If parts is empty or not provided.
    def self.generate(amount, parts, decimal_cutoff = true)
      parts =
        if parts.is_a?(Numeric)
          Array.new(parts, 1)
        elsif parts.all?(&:zero?)
          Array.new(parts.count, 1)
        else
          parts.dup
        end

      raise ArgumentError, "need at least one part" if parts.empty?

      if [amount, *parts].any? { |i| i.is_a?(BigDecimal) || i.is_a?(Float) || i.is_a?(Rational) }
        amount = convert_to_big_decimal(amount)
        parts.map! { |p| convert_to_big_decimal(p) }
      end

      result = []
      remaining_amount = amount
      round_to_whole = decimal_cutoff.is_a?(TrueClass)
      round_to_precision = decimal_cutoff.is_a?(Integer)

      parts_sum = parts.sum

      until parts.empty?
        part = parts.pop

        current_split = 0
        if parts_sum > 0
          current_split = remaining_amount * part / parts_sum
          current_split =
            if round_to_whole
              current_split.truncate
            elsif round_to_precision
              current_split.round(decimal_cutoff)
            else
              current_split
            end
        end

        result.unshift current_split
        remaining_amount -= current_split
        parts_sum -= part
      end

      result
    end

    # Allocates a specified amount into shares that each carry their own weight,
    # minimum (floor) and maximum (cap), expressed in the smallest currency unit.
    #
    # Minimums are satisfied first; the remaining amount is then distributed
    # proportionally to the weights. Shares that reach their cap are removed
    # from the distribution and the leftover is redistributed among the
    # remaining shares, repeating until everything is allocated. Weights may be
    # any non-negative Numeric, including Rational, and are handled with exact
    # arithmetic. Leftover pennies and exact ties are resolved by each share's
    # explicit, unique +key+ (ascending), never by input order.
    #
    # Each share is a Hash:
    #   key:    (required) unique, mutually comparable stable tie-break key
    #   weight: (required) non-negative Numeric, e.g. 1, 0.5, Rational(2, 3)
    #   min:    (optional) non-negative Integer floor, defaults to 0
    #   max:    (optional) Integer cap (>= min), defaults to nil (uncapped)
    #
    # The amount must be feasible: the sum of minimums must not exceed it and
    # the sum of maximums (when every share is capped) must not be below it,
    # otherwise an ArgumentError reporting the shortfall or the undistributable
    # remainder is raised.
    #
    # Negative amounts are refunds and must be opted into with +refund: true+;
    # the constraints then apply to the refunded magnitudes and the resulting
    # shares are negated. Positive-amount comparisons are never reused for
    # negative totals.
    #
    # @param amount [Integer] The total amount in the smallest currency unit.
    # @param shares [Array<Hash>] Share specifications as described above.
    # @param refund [Boolean] Whether a negative amount is an explicit refund.
    #
    # @return [Array<Integer>] The allocated amounts, in input order.
    # @raise [ArgumentError] If the shares are invalid or the amount is infeasible.
    def self.generate_with_bounds(amount, shares, refund: false)
      raise ArgumentError, "amount must be an Integer (smallest currency unit)" unless amount.is_a?(Integer)
      raise ArgumentError, "need at least one share" if shares.empty?

      if amount.negative?
        unless refund
          raise ArgumentError, "negative amount requires explicit refund mode: pass refund: true"
        end

        return generate_with_bounds(-amount, shares).map { |share_amount| -share_amount }
      end

      specs = normalize_bounded_shares(shares)

      min_sum = specs.sum { |spec| spec[:min] }
      if min_sum > amount
        raise ArgumentError,
          "minimums total #{min_sum} but amount is #{amount}: shortfall of #{min_sum - amount}"
      end

      if specs.all? { |spec| spec[:max] }
        max_sum = specs.sum { |spec| spec[:max] }
        if max_sum < amount
          raise ArgumentError,
            "caps total #{max_sum} but amount is #{amount}: #{amount - max_sum} cannot be allocated"
        end
      end

      result = specs.map { |spec| spec[:min] }
      headrooms = specs.map { |spec| spec[:max] && spec[:max] - spec[:min] }
      active = specs.each_index.select do |index|
        specs[index][:weight].positive? && (headrooms[index].nil? || headrooms[index].positive?)
      end
      remaining = amount - min_sum

      until remaining.zero?
        if active.empty?
          raise ArgumentError,
            "#{remaining} of #{amount} cannot be allocated: no share has both a positive weight and remaining headroom"
        end

        total_weight = active.sum { |index| specs[index][:weight] }
        quotas = active.map { |index| remaining * specs[index][:weight] / total_weight }
        splits = quotas.map(&:floor)

        leftover = remaining - splits.sum
        active.each_index
          .sort_by { |position| [splits[position] - quotas[position], specs[active[position]][:key]] }
          .first(leftover)
          .each { |position| splits[position] += 1 }

        capped = active.each_index.select do |position|
          headroom = headrooms[active[position]]
          headroom && splits[position] > headroom
        end

        if capped.empty?
          active.each_with_index { |index, position| result[index] += splits[position] }
          remaining = 0
        else
          capped.each do |position|
            index = active[position]
            result[index] += headrooms[index]
            remaining -= headrooms[index]
            headrooms[index] = 0
          end
          active -= capped.map { |position| active[position] }
        end
      end

      result
    end

    # Converts a given number to BigDecimal.
    # This method supports inputs of BigDecimal, Rational, and other numeric types by ensuring they are all returned
    # as BigDecimal instances for consistent handling.
    #
    # @param number [Numeric, BigDecimal, Rational] The number to convert.
    # @return [BigDecimal] The converted number as a BigDecimal.
    def self.convert_to_big_decimal(number)
      if number.is_a? BigDecimal
        number
      elsif number.is_a? Rational
        BigDecimal(number.to_f.to_s)
      else
        BigDecimal(number.to_s)
      end
    end

    # Validates share specifications for generate_with_bounds and returns them
    # normalized to { key:, weight:, min:, max: } hashes with exact Rational weights.
    #
    # @param shares [Array<Hash>] The raw share specifications.
    # @return [Array<Hash>] The normalized share specifications.
    # @raise [ArgumentError] If any specification is invalid.
    def self.normalize_bounded_shares(shares)
      keys = shares.map { |share| share[:key] }
      if keys.any?(&:nil?)
        raise ArgumentError, "every share needs an explicit :key used as stable tie-break"
      end
      if keys.uniq.length != keys.length
        raise ArgumentError, "share keys must be unique: #{keys.tally.select { |_, n| n > 1 }.keys.join(', ')} duplicated"
      end

      shares.map do |share|
        weight = share[:weight]
        unless weight.is_a?(Numeric) && !weight.negative?
          raise ArgumentError, "share #{share[:key].inspect} needs a non-negative numeric :weight"
        end

        min = share.fetch(:min, 0)
        max = share[:max]
        unless min.is_a?(Integer) && !min.negative?
          raise ArgumentError, "share #{share[:key].inspect} needs a non-negative Integer :min"
        end
        unless max.nil? || (max.is_a?(Integer) && max >= min)
          raise ArgumentError, "share #{share[:key].inspect} needs an Integer :max that is >= :min"
        end

        { key: share[:key], weight: weight.to_r, min: min, max: max }
      end
    end
    private_class_method :normalize_bounded_shares
  end
end
