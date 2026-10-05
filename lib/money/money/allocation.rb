# frozen_string_literal: true

class Money
  class Allocation
    # Raised when the requested amount cannot cover the combined minimums.
    class ShortfallError < ArgumentError
      attr_reader :amount, :required

      def initialize(amount, required)
        @amount = amount
        @required = required
        super("cannot allocate #{amount}: minimums total #{required}, shortfall of #{required - amount}")
      end

      # How much more is needed to satisfy every minimum.
      def shortfall
        required - amount
      end
    end

    # Raised when the combined maximums cannot absorb the requested amount.
    class UndistributableError < ArgumentError
      attr_reader :amount, :distributable

      def initialize(amount, distributable)
        @amount = amount
        @distributable = distributable
        super("cannot allocate #{amount}: maximums total #{distributable}, #{amount - distributable} cannot be distributed")
      end

      # The balance that no share is allowed to take.
      def undistributable
        amount - distributable
      end
    end

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

    # Allocates an amount expressed in the smallest currency unit (e.g. cents)
    # into shares that each carry their own weight, minimum and maximum.
    #
    # Every share first receives its minimum. The remaining balance is then
    # distributed proportionally to the weights. A share that reaches its
    # maximum leaves the distribution and the leftover is redistributed among
    # the remaining shares, repeating until the whole amount is allocated.
    #
    # Leftover pennies are handed out one at a time to the largest fractional
    # remainders; ties are broken by each share's explicit, stable +:key+
    # (defaults to the share's position), never by input order alone.
    #
    # Weights may be any non-negative Numeric, including Rational, and are
    # compared exactly. Results are always whole units of the smallest
    # currency denomination and sum exactly to the given amount.
    #
    # Negative amounts are refunds and must be requested explicitly with
    # +refund: true+; the limits are then applied to the refunded magnitudes
    # and the negated shares are returned.
    #
    # @param amount [Numeric] total to allocate, in smallest currency units.
    # @param shares [Array<Hash>] one hash per share:
    #   - +:weight+ [Numeric] proportion for the remaining balance (default 1).
    #   - +:min+ [Integer] guaranteed minimum (default 0).
    #   - +:max+ [Integer, nil] cap, nil means uncapped (default nil).
    #   - +:key+ stable tie-break key (default the share's index).
    # @param refund [Boolean] must be true to allocate a negative amount.
    #
    # @return [Array<Integer>] allocated amount per share, in input order.
    # @raise [ArgumentError] if shares are empty, limits are inconsistent,
    #   or a negative amount is given without +refund: true+.
    # @raise [ShortfallError] if the minimums exceed the amount.
    # @raise [UndistributableError] if the maximums cannot absorb the amount.
    #
    # @example
    #   Money::Allocation.generate_with_bounds(100, [
    #     { weight: 1, max: 10 },
    #     { weight: 1, max: 40 },
    #     { weight: 1 },
    #   ])
    #   #=> [10, 40, 50]
    def self.generate_with_bounds(amount, shares, refund: false)
      raise ArgumentError, "need at least one share" if shares.empty?

      if amount.negative?
        unless refund
          raise ArgumentError, "negative amounts are refunds; pass refund: true to allocate them"
        end

        return generate_with_bounds(-amount, shares).map { |split| -split }
      end

      amount = amount.truncate

      shares = shares.each_with_index.map do |share, index|
        weight = share.fetch(:weight, 1)
        min = share.fetch(:min, 0)
        max = share[:max]

        raise ArgumentError, "weight must be non-negative" if weight.negative?
        raise ArgumentError, "min must be non-negative" if min.negative?
        raise ArgumentError, "max must be greater than or equal to min" if max && max < min

        { weight: weight, min: min, max: max, key: share.fetch(:key, index) }
      end

      required = shares.sum { |share| share[:min] }
      raise ShortfallError.new(amount, required) if required > amount

      distributable = shares.sum { |share| share[:max] || 0 } if shares.all? { |share| share[:max] }
      raise UndistributableError.new(amount, distributable) if distributable && distributable < amount

      allocations = shares.map { |share| share[:min] }
      remaining = amount - required

      active = shares.each_index.select do |index|
        shares[index][:max].nil? || shares[index][:max] > shares[index][:min]
      end

      until remaining.zero? || active.empty?
        total_weight = active.sum { |index| shares[index][:weight] }
        weights =
          if total_weight.zero?
            active.map { Rational(1, active.size) }
          else
            active.map { |index| Rational(shares[index][:weight], total_weight) }
          end

        tentative = distribute_even_remainder(remaining, weights, active.map { |index| shares[index][:key] })

        clamped = active.each_with_index.select do |share_index, position|
          headroom = shares[share_index][:max] - allocations[share_index] if shares[share_index][:max]
          headroom && tentative[position] > headroom
        end

        if clamped.empty?
          active.each_with_index { |share_index, position| allocations[share_index] += tentative[position] }
          remaining = 0
        else
          clamped.each do |share_index, _|
            headroom = shares[share_index][:max] - allocations[share_index]
            allocations[share_index] += headroom
            remaining -= headroom
          end
          active -= clamped.map(&:first)
        end
      end

      allocations
    end

    # Splits +amount+ into whole units proportional to the given rational
    # weights. Leftover units go to the largest fractional remainders, with
    # ties broken by the stable keys.
    #
    # @param amount [Integer] total to distribute.
    # @param weights [Array<Rational>] proportions, summing to 1.
    # @param keys [Array] stable tie-break keys, one per weight.
    #
    # @return [Array<Integer>]
    def self.distribute_even_remainder(amount, weights, keys)
      exact = weights.map { |weight| amount * weight }
      splits = exact.map(&:floor)

      leftover = amount - splits.sum
      order = splits.each_index.sort_by { |index| [splits[index] - exact[index], keys[index]] }
      leftover.times { |i| splits[order[i]] += 1 }

      splits
    end
    private_class_method :distribute_even_remainder
  end
end
