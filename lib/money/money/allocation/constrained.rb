# frozen_string_literal: true

class Money
  class Allocation
    # Allocates one integer amount using each part's non-negative weight plus
    # inclusive +min+ and +max+ bounds. Results are returned in input order as
    # +{id:, amount:}+, while remainder order is descending fractional part and
    # then ascending +id+, which makes reordering the input irrelevant.
    #
    # Negative amounts represent refunds: the absolute value is allocated under
    # the same constraints, and every resulting amount is negated. No result is
    # returned when the total minimum or total maximum makes the request
    # infeasible.
    class Constrained
      def self.generate(amount, parts)
        integer_amount = integer_fractional_amount(amount)
        validated_parts = validate_parts(parts)
        allocations = allocate(integer_amount.abs, validated_parts)
        allocations.map!(&:-@) if integer_amount.negative?

        validated_parts.zip(allocations).map do |part, allocated_amount|
          { id: part[:id], amount: allocated_amount }
        end
      end

      def self.integer_fractional_amount(amount)
        return amount if amount.is_a?(Integer)

        if amount.is_a?(Rational) && amount.denominator == 1
          return amount.to_i
        end

        if amount.is_a?(BigDecimal) && (amount % 1).zero?
          return amount.to_i
        end

        raise ArgumentError, "constrained allocations require an integer amount in fractional units"
      end

      def self.validate_parts(parts)
        raise ArgumentError, "need at least one part" if parts.empty?
        raise ArgumentError, "constrained parts must be hashes" unless parts.all?(::Hash)

        validated_parts = parts.map { |part| validate_part(part) }
        validate_ids(validated_parts)
        validated_parts
      end

      def self.validate_part(part)
        unless part.key?(:id)
          raise ArgumentError, "constrained allocation parts require a stable :id"
        end

        minimum = part.fetch(:min, part.fetch(:minimum, 0))
        maximum = part.fetch(:max, part.fetch(:maximum, nil))
        weight = part.fetch(:weight, 1)

        validate_weight(weight)
        validate_bound(:minimum, minimum)
        validate_bound(:maximum, maximum, allow_nil: true)

        if !maximum.nil? && minimum > maximum
          raise ArgumentError, "allocation minimum #{minimum} cannot be greater than maximum #{maximum}"
        end

        {
          id: part.fetch(:id),
          weight: normalized_weight(weight),
          min: minimum,
          max: maximum || Float::INFINITY,
        }
      end

      def self.validate_weight(weight)
        unless weight.is_a?(Numeric) && weight.real? && !weight.negative?
          raise ArgumentError, "allocation weight must be a non-negative numeric value: #{weight.inspect}"
        end
      end

      def self.validate_bound(name, value, allow_nil: false)
        return if allow_nil && value.nil?
        return if value.is_a?(Integer) && !value.negative?

        suffix = allow_nil ? " or nil" : ""
        raise ArgumentError, "allocation #{name} must be a non-negative integer#{suffix}: #{value.inspect}"
      end

      def self.validate_ids(parts)
        ids = parts.map { |part| part[:id] }
        duplicates = ids.tally.filter_map { |id, count| id if count > 1 }
        raise ArgumentError, "allocation IDs must be unique: #{duplicates.inspect}" if duplicates.any?

        begin
          ids.sort
        rescue ArgumentError
          raise ArgumentError, "allocation IDs must be mutually comparable"
        end
      end

      def self.allocate(amount, parts)
        total_min = parts.sum { |part| part[:min] }
        total_max = parts.sum { |part| part[:max] }

        if total_min > amount
          raise Allocation::ConstraintError, "cannot allocate #{amount}: minimum allocation is #{total_min}"
        end

        if total_max < amount
          raise Allocation::ConstraintError, "cannot allocate #{amount}: maximum allocation is #{total_max}"
        end

        integerize(proportional_targets(amount, parts), parts, amount)
      end

      def self.proportional_targets(amount, parts)
        targets = parts.map { |part| Rational(part[:min]) }
        remaining = amount - parts.sum { |part| part[:min] }
        active = parts.each_index.select { |index| targets[index] < parts[index][:max] }

        while remaining.positive? && active.any?
          weights = active_weights(parts, active)
          weight_sum = weights.values.sum
          caps = cap_points(parts, active, targets, weights, weight_sum)

          if caps.empty? || caps.first.first >= remaining
            distribute!(targets, active, weights, weight_sum, remaining)
            remaining = 0
          else
            scaled_increment, _, index = caps.first
            distribute!(targets, active, weights, weight_sum, scaled_increment)
            targets[index] = Rational(parts[index][:max])
            remaining -= scaled_increment
            active.delete(index)
          end
        end

        targets
      end

      def self.active_weights(parts, active)
        weight_sum = active.sum { |index| parts[index][:weight] }

        active.to_h do |index|
          weight = weight_sum.zero? ? 1 : parts[index][:weight]
          [index, weight]
        end
      end

      def self.cap_points(parts, active, targets, weights, weight_sum)
        active.filter_map do |index|
          next if weights.fetch(index).zero?

          increment_to_cap = parts[index][:max] - targets[index]
          scaled_increment = increment_to_cap * weight_sum / weights.fetch(index)
          [scaled_increment, parts[index][:id], index]
        end.sort_by { |scaled_increment, id, _| [scaled_increment, id] }
      end

      def self.distribute!(targets, active, weights, weight_sum, amount)
        active.each do |index|
          targets[index] += amount * weights.fetch(index) / weight_sum
        end
      end

      def self.integerize(targets, parts, amount)
        allocations = targets.map(&:floor)
        remainder = amount - allocations.sum

        remainder.times do
          candidates = targets.each_index.filter_map do |index|
            next if allocations[index] >= parts[index][:max]

            fractional_part = targets[index] - allocations[index]
            [fractional_part, parts[index][:id], index]
          end

          if candidates.empty?
            total_max = parts.sum { |part| part[:max] }
            raise Allocation::ConstraintError, "cannot allocate #{amount}: maximum allocation is #{total_max}"
          end

          candidates.sort_by! { |fractional_part, id, _| [-fractional_part, id] }
          allocations[candidates.fetch(0).fetch(2)] += 1
        end

        allocations
      end

      def self.normalized_weight(weight)
        return Money::Allocation.convert_to_big_decimal(weight).to_r if weight.is_a?(Float)

        weight.to_r
      end
    end
  end
end
