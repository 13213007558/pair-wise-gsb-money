# frozen_string_literal: true

class Money
  class Allocation
    # A serializable voucher recording how a single amount was allocated
    # across multiple parties, together with the agreed order in which the
    # smallest units are released back on refunds.
    #
    # Partial refunds are deducted from the voucher instead of re-allocating
    # every refund amount on its own. Each refund is derived from the
    # cumulative refunded total, so the per-party distribution for a given
    # cumulative refund amount is always identical, no matter how many
    # partial refunds (and in which order) were used to reach it. Refunding
    # the grand total always reproduces the original allocation exactly, so
    # the last pennies can never land on a different party than they did in
    # the original split.
    #
    # @example
    #   voucher = Money::Allocation::Voucher.new(Money::Allocation.generate(100, 3))
    #   voucher.splits           #=> [34, 33, 33]
    #   voucher.refund(50, id: "refund-1") #=> [17, 16, 17]
    #   voucher.refund(50, id: "refund-2") #=> [17, 17, 16]
    #   voucher.refunded_splits  #=> [34, 33, 33]
    class Voucher
      # Raised when a refund id is presented more than once. The voucher is
      # left unchanged, so a retried refund is never deducted twice.
      class DuplicateRefundError < StandardError; end

      # Raised when a refund would exceed the remaining refundable amount.
      # The voucher is left unchanged, so a rejected refund never leaves a
      # partial modification behind.
      class RefundExceedsTotalError < StandardError; end

      # @return [Array<Integer>] the original allocation in smallest units.
      attr_reader :splits

      # @return [Array<Integer>] the agreed order (party indexes) used to
      #   break ties when the smallest units are released back on refunds.
      attr_reader :release_order

      # @return [Integer] the cumulative refunded amount in smallest units.
      attr_reader :refunded

      # @param splits [Array<Integer>] the original allocation in smallest
      #   units, one entry per party. Must not be empty and every entry must
      #   be a non-negative Integer.
      # @param release_order [Array<Integer>, nil] the agreed tie-breaking
      #   order between the parties' smallest units. Must be a permutation
      #   of the party indexes and defaults to the natural party order.
      #   Parties later in the order release their units earlier.
      #
      # @raise [ArgumentError] If the splits or the release order are invalid.
      def initialize(splits, release_order: nil)
        unless splits.is_a?(Array) && !splits.empty? && splits.all? { |split| split.is_a?(Integer) && split >= 0 }
          raise ArgumentError, "splits must be a non-empty Array of non-negative Integers"
        end

        release_order ||= (0...splits.size).to_a
        unless release_order.is_a?(Array) && release_order.sort == (0...splits.size).to_a
          raise ArgumentError, "release_order must be a permutation of the party indexes"
        end

        @splits = splits.dup.freeze
        @release_order = release_order.dup.freeze
        @positions = Array.new(splits.size)
        release_order.each_with_index { |party, position| @positions[party] = position }
        @total = splits.sum
        @refunded = 0
        @refund_ids = Set.new
      end

      # @return [Integer] the total allocated amount in smallest units.
      def total
        @total
      end

      # @return [Integer] the amount that can still be refunded.
      def remaining
        @total - @refunded
      end

      # @return [Array] the refund identifiers seen so far.
      def refund_ids
        @refund_ids.to_a
      end

      # @return [Array<Integer>] the cumulative refunded amount per party.
      def refunded_splits
        cumulative_splits(@refunded)
      end

      # @return [Array<Integer>] the amount still refundable per party.
      def remaining_splits
        @splits.zip(refunded_splits).map { |split, refunded_split| split - refunded_split }
      end

      # Deducts a partial refund from the voucher.
      #
      # The per-party shares are computed from the cumulative refunded total,
      # never from the refund amount alone, so the same cumulative refund
      # always yields the same distribution regardless of how the refunds
      # were split into calls.
      #
      # @param amount [Integer] the refund amount in smallest units.
      # @param id [Object] a unique identifier for the refund. Presenting the
      #   same id twice raises {DuplicateRefundError} and never deducts twice.
      #
      # @return [Array<Integer>] the amount refunded to each party by this call.
      #
      # @raise [ArgumentError] If the amount is not a non-negative Integer.
      # @raise [DuplicateRefundError] If the refund id was already used.
      # @raise [RefundExceedsTotalError] If the refund exceeds the remaining
      #   refundable amount. The voucher is left unchanged.
      def refund(amount, id:)
        raise ArgumentError, "amount must be a non-negative Integer" unless amount.is_a?(Integer) && amount >= 0
        raise DuplicateRefundError, "refund #{id.inspect} was already deducted" if @refund_ids.include?(id)

        new_refunded = @refunded + amount
        if new_refunded > @total
          raise RefundExceedsTotalError,
                "refund of #{amount} exceeds the remaining refundable amount #{remaining}"
        end

        previous_splits = cumulative_splits(@refunded)
        new_splits = cumulative_splits(new_refunded)

        @refunded = new_refunded
        @refund_ids << id

        new_splits.zip(previous_splits).map { |new_split, previous_split| new_split - previous_split }
      end

      # @return [Hash] a plain-data representation suitable for serialization
      #   (e.g. JSON). The voucher is also marshalable as is.
      def to_h
        {
          splits: @splits.dup,
          release_order: @release_order.dup,
          refunded: @refunded,
          refund_ids: @refund_ids.to_a,
        }
      end

      # Rebuilds a voucher from the representation returned by {#to_h}.
      # String and Symbol keys are both accepted.
      #
      # @param hash [Hash] the serialized voucher.
      #
      # @return [Voucher]
      #
      # @raise [ArgumentError] If the serialized state is invalid.
      def self.from_h(hash)
        hash = hash.transform_keys(&:to_sym)
        voucher = new(hash.fetch(:splits), release_order: hash[:release_order])

        refunded = hash.fetch(:refunded, 0)
        unless refunded.is_a?(Integer) && refunded >= 0 && refunded <= voucher.total
          raise ArgumentError, "refunded must be an Integer between 0 and the voucher total"
        end

        voucher.instance_variable_set(:@refunded, refunded)
        Array(hash[:refund_ids]).each { |id| voucher.instance_variable_get(:@refund_ids) << id }
        voucher
      end

      def ==(other)
        other.is_a?(Voucher) &&
          splits == other.splits &&
          release_order == other.release_order &&
          refunded == other.refunded &&
          @refund_ids == other.instance_variable_get(:@refund_ids)
      end

      private

      # Cumulative refunded amount per party for a given cumulative refund
      # total.
      #
      # Every smallest unit of every party has a fixed release priority: the
      # k-th unit of a party with +split+ units has priority split/k, and
      # ties are broken by the release order (parties later in the order
      # release earlier). The cumulative refund of a party is the number of
      # its units among the +cumulative+ highest-priority units. Because the
      # unit order is fixed, per-party cumulative refunds are monotone in
      # the cumulative total, always sum to it, and reproduce the original
      # splits when the whole amount is refunded.
      def cumulative_splits(cumulative)
        result = Array.new(@splits.size, 0)
        return result if cumulative.zero? || @total.zero?

        threshold = release_threshold(cumulative)
        base_total = 0
        tie_parties = []

        @splits.each_with_index do |split, party|
          next if split.zero?

          units = split * threshold
          base = units.ceil - 1
          result[party] = base
          base_total += base
          tie_parties << party if units.denominator == 1 && units >= 1
        end

        need = cumulative - base_total
        tie_parties.sort_by! { |party| -@positions[party] }
        tie_parties.first(need).each { |party| result[party] += 1 }

        result
      end

      # The exact reciprocal of the release priority of the +cumulative+-th
      # released unit: the smallest s for which the number of units with
      # priority at least 1/s reaches +cumulative+. Binary-searched with
      # exact rational arithmetic, then snapped to the precise change point
      # (always of the form k/split for some party).
      def release_threshold(cumulative)
        low = Rational(0)
        high = Rational(1)
        precision = Rational(1, 2 * @total * @total)

        while high - low > precision
          mid = (low + high) / 2
          if priority_count(mid) >= cumulative
            high = mid
          else
            low = mid
          end
        end

        @splits.filter_map do |split|
          next if split.zero?

          Rational((split * low).floor + 1, split)
        end.min
      end

      # The number of units whose release priority is at least 1/s.
      def priority_count(reciprocal)
        @splits.sum { |split| [split, (split * reciprocal).floor].min }
      end
    end
  end
end
