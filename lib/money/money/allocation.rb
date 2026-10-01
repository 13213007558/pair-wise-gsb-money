# frozen_string_literal: true

class Money
  class Allocation
    WEIGHT_KEYS = %i[weight].freeze
    MINIMUM_KEYS = %i[minimum min].freeze
    MAXIMUM_KEYS = %i[maximum max].freeze

    # Allocates a specified amount into parts based on their proportions or distributes
    # it evenly when the number of parts is specified numerically.
    #
    # The total of the allocated amounts will always equal the original amount.
    #
    # The parts can be specified as:
    #   Numeric — performs the split between a given number of parties evenly
    #   Array<Numeric> — allocates the amounts proportionally to the given array
    #   Array<Hash> — allocates whole smallest units with +:weight+, +:min+ and +:max+
    #   Hash — behaves like Array<Hash>, where each key is the stable allocation ID
    #
    # Bounded allocations always use whole smallest currency units. Weights may be
    # fractional, while +:min+ and +:max+ must be whole units. A negative amount is
    # allocated as a positive amount and every result is then negated, so bounds apply
    # to refund magnitudes.
    #
    # @param amount [Numeric] The total amount to be allocated.
    # @param parts [Numeric, Array<Numeric>, Array<Hash>, Hash] Number of parts or weighted parts.
    # @param decimal_cutoff [Boolean, Integer] Controls unrestricted per-split precision.
    # @return [Array<Numeric>, Hash<Object, Numeric>, Array<Hash>] Allocated amounts.
    # @raise [ArgumentError] If parts or bounds are invalid, or the bounds are infeasible.
    def self.generate(amount, parts, decimal_cutoff = true)
      normalized_parts, bounded = normalize_parts(parts)

      raise ArgumentError, "need at least one part" if normalized_parts.empty?

      if bounded
        validate_unique_ids(normalized_parts)
        result = generate_bounded(amount, normalized_parts)
        if parts.is_a?(::Hash)
          result.to_h { |entry| [entry[:output_id], entry[:amount]] }
        else
          result.map { |entry| {id: entry[:output_id], amount: entry[:amount]} }
        end
      else
        generate_unrestricted(amount, normalized_parts, decimal_cutoff)
      end
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
        number.to_d(Money.conversion_precision)
      else
        BigDecimal(number.to_s)
      end
    end

    def self.normalize_parts(parts)
      case parts
      when Numeric
        [Array.new(parts, 1), false]
      when ::Hash
        raise ArgumentError, "need at least one part" if parts.empty?

        entries = parts.map do |id, specification|
          build_entry(specification[:id] || id, specification, index: id, output_id: id)
        end
        [entries, true]
      when Array
        bounded = parts.any?(::Hash)
        entries =
          if bounded
            parts.each_with_index.map do |specification, index|
              if specification.is_a?(::Hash)
                id = specification[:id]
                internal_id = id || [:position, index]
                build_entry(internal_id, specification, index: index, output_id: id || index)
              else
                raise ArgumentError, "allocation parts must be numeric or hashes, not both"
              end
            end
          else
            parts.dup
          end

        [entries, bounded]
      else
        raise ArgumentError, "parts must be a number, array, or hash"
      end
    end

    private_class_method def self.build_entry(id, specification, index: nil, output_id: id)
      entry = {
        id: id,
        output_id: output_id,
        index: index.nil? ? id : index,
        weight: specification_value(specification, WEIGHT_KEYS, 1),
        minimum: specification_value(specification, MINIMUM_KEYS, 0),
        maximum: specification_value(specification, MAXIMUM_KEYS, nil),
      }

      validate_entry(entry)
      entry
    end

    private_class_method def self.specification_value(specification, keys, default)
      key = keys.find { |candidate| specification.key?(candidate) }
      key.nil? ? default : specification.fetch(key)
    end

    private_class_method def self.validate_entry(entry)
      unless numeric?(entry[:weight]) && entry[:weight].finite? && entry[:weight] >= 0
        raise ArgumentError, "weight must be a non-negative number"
      end

      validate_whole_number(entry[:minimum], "minimum")
      validate_whole_number(entry[:maximum], "maximum") unless entry[:maximum].nil?
      raise ArgumentError, "minimum cannot be negative" if entry[:minimum].negative?

      return if entry[:maximum].nil? || entry[:minimum] <= entry[:maximum]

      raise ArgumentError, "minimum cannot be greater than maximum"
    end

    private_class_method def self.validate_whole_number(value, name)
      return if value.is_a?(Integer)
      return if numeric?(value) && value.finite? && value == value.to_i

      raise ArgumentError, "#{name} must be a whole number of smallest currency units"
    end

    private_class_method def self.numeric?(value)
      value.is_a?(Numeric)
    end

    private_class_method def self.validate_unique_ids(entries)
      ids = entries.map { |entry| entry[:id] }
      return if ids.uniq.length == ids.length

      raise ArgumentError, "allocation ids must be unique"
    end

    private_class_method def self.generate_unrestricted(amount, parts, decimal_cutoff)
      parts = Array.new(parts.count, 1) if parts.all?(&:zero?)

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

    private_class_method def self.generate_bounded(raw_amount, entries)
      amount = whole_amount(raw_amount)
      magnitude = amount.abs

      entries.each { |entry| normalize_bounded_entry(entry) }
      validate_feasibility(magnitude, entries)

      amounts = bounded_amounts(magnitude, entries)
      amounts.map!.with_index do |value, index|
        entry = entries[index]
        entry.merge(amount: amount.negative? ? -value : value).slice(:id, :output_id, :amount)
      end
    end

    private_class_method def self.whole_amount(amount)
      validate_whole_number(amount, "amount")
      amount.to_i
    end

    private_class_method def self.normalize_bounded_entry(entry)
      entry[:weight] = convert_to_big_decimal(entry[:weight])
      entry[:minimum] = entry[:minimum].to_i
      entry[:maximum] = entry[:maximum]&.to_i
    end

    private_class_method def self.validate_feasibility(amount, entries)
      minimum_total = entries.sum { |entry| entry[:minimum] }
      raise ArgumentError, "amount is less than the total minimum (#{minimum_total})" if amount < minimum_total

      maximum_total = entries.sum { |entry| entry[:maximum] || amount }
      return unless amount > maximum_total

      raise ArgumentError, "amount exceeds the total maximum (#{maximum_total})"
    end

    private_class_method def self.bounded_amounts(amount, entries)
      allocations = entries.map { |entry| entry[:minimum] }
      active_indexes = entries.each_index.to_a
      remaining = amount - allocations.sum

      until remaining.zero?
        next_allocations = allocations.dup
        weight_map = active_weights(entries, active_indexes)
        weight_sum = weight_map.values.sum
        weight_map = active_indexes.to_h { |index| [index, BigDecimal(1)] } if weight_sum.zero?
        next_active_indexes = []
        next_remaining = remaining

        active_indexes.each do |index|
          entry = entries[index]
          available = entry[:maximum] - allocations[index] unless entry[:maximum].nil?
        share = ((remaining * weight_map.fetch(index)) / weight_map.values.sum).floor

          if entry[:maximum] && share >= available
            next_allocations[index] = entry[:maximum]
            next_remaining -= available
          else
            next_allocations[index] += share
            next_remaining -= share
            next_active_indexes << index
          end
        end

        if next_active_indexes == active_indexes
          distribute_whole_remainder(entries, next_allocations, next_active_indexes, next_remaining)
          return next_allocations
        end

        allocations = next_allocations
        active_indexes = next_active_indexes
        remaining = next_remaining
      end

      allocations
    end

    private_class_method def self.active_weights(entries, active_indexes)
      active_indexes.to_h { |index| [index, entries[index][:weight]] }
    end

    private_class_method def self.distribute_whole_remainder(entries, allocations, active_indexes, remaining)
      positive_weight_indexes = active_indexes.select { |index| entries[index][:weight] > 0 }
      candidate_indexes = positive_weight_indexes.empty? ? active_indexes : positive_weight_indexes
      ordered_indexes = candidate_indexes.sort_by { |index| stable_order(entries[index]) }

      until remaining.zero?
        eligible_indexes = ordered_indexes.select do |index|
          entries[index][:maximum].nil? || allocations[index] < entries[index][:maximum]
        end
        raise ArgumentError, "amount exceeds the total maximum" if eligible_indexes.empty?

        eligible_indexes.each do |index|
          break if remaining.zero?

          allocations[index] += 1
          remaining -= 1
        end
      end
    end

    private_class_method def self.stable_order(entry)
      id = entry[:id]

      case id
      when Numeric
        [0, convert_to_big_decimal(id), entry[:index]]
      else
        [1, String(id), entry[:index]]
      end
    end
  end
end
