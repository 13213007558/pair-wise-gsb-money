# frozen_string_literal: true

class Money
  # A serializable voucher that records how an amount was allocated between
  # parties and in which order minimal units (cents) are released back when
  # the money is refunded in several instalments.
  #
  # Re-allocating every single refund with Money#allocate can hand the last
  # pennies to different parties than the original allocation did. The voucher
  # avoids that: it fixes the original allocation and a deterministic release
  # order once, and every partial refund simply advances along that order.
  # Therefore the cumulative refund of each party depends only on the
  # cumulative refunded amount, never on how the refunds were split or
  # ordered, and a full refund always returns exactly the original allocation.
  #
  # Every refund carries a caller-supplied id; a repeated id is reported as a
  # duplicate and is not deducted a second time. A refund that would exceed
  # the remaining total is rejected before any state is changed.
  #
  # The voucher can be persisted with #to_h (JSON-safe) and restored with
  # .from_h.
  #
  # @example
  #   voucher = Money.new(100, "USD").allocation_voucher([1, 1, 1])
  #   voucher.allocations #=> [Money.new(34), Money.new(33), Money.new(33)]
  #   voucher.refund(Money.new(1, "USD"), id: "r-1").current #=> [Money.new(1), Money.new(0), Money.new(0)]
  #   voucher.refund(Money.new(99, "USD"), id: "r-2").cumulative #=> [Money.new(34), Money.new(33), Money.new(33)]
  #
  class AllocationVoucher
    # Raised when a refund would exceed the remaining (not yet refunded) total.
    class RefundExceedsTotalError < StandardError; end

    # The outcome of a single AllocationVoucher#refund call.
    #
    # +current+ holds the amounts refunded to each party by this call,
    # +cumulative+ holds the amounts refunded to each party since the voucher
    # was created. A duplicate refund (an id that was already applied) changes
    # nothing and reports zero +current+ amounts.
    class Refund
      attr_reader :id, :current, :cumulative

      def initialize(id:, current:, cumulative:, duplicate:)
        @id = id
        @current = current.freeze
        @cumulative = cumulative.freeze
        @duplicate = duplicate
      end

      # Whether this call was ignored because its id had already been applied.
      def duplicate?
        @duplicate
      end
    end

    attr_reader :parts, :refund_ids

    # @param money [Money] the total amount being allocated; must be a
    #   non-negative whole number of minimal units (e.g. cents).
    # @param parts [Numeric, Array<Numeric>] number of parties to split into
    #   evenly, or proportions per party (same semantics as Money#allocate).
    def initialize(money, parts)
      fractional = money.fractional

      unless fractional == fractional.to_i
        raise ArgumentError, "amount must be a whole number of minimal units"
      end

      @total = fractional.to_i

      raise ArgumentError, "amount must not be negative" if @total.negative?

      @currency = money.currency
      @parts = parts.is_a?(Numeric) ? Array.new(parts, 1) : parts.dup
      @refunded = 0
      @refund_ids = []

      allocations_in_cents
    end

    # Restores a voucher previously exported with #to_h.
    #
    # @param hash [Hash] a hash as produced by #to_h (string or symbol keys).
    # @return [Money::AllocationVoucher]
    def self.from_h(hash)
      hash = hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      parts = hash.fetch("parts").map do |part|
        part.is_a?(String) ? (part.include?("/") ? Rational(part) : BigDecimal(part)) : part
      end
      voucher = new(Money.new(hash.fetch("total").to_i, hash.fetch("currency")), parts)
      refunded = hash.fetch("refunded", 0).to_i
      refund_ids = hash.fetch("refund_ids", []).map(&:to_s)
      voucher.send(:restore!, refunded, refund_ids)
      voucher
    end

    # Exports the voucher as a JSON-safe hash.
    #
    # @return [Hash]
    def to_h
      {
        "currency" => @currency.id.to_s,
        "total" => @total.to_s,
        "parts" => @parts.map do |part|
          case part
          when BigDecimal then part.to_s("F")
          when Rational then part.to_s
          else part
          end
        end,
        "refunded" => @refunded.to_s,
        "refund_ids" => @refund_ids.dup,
      }
    end

    # The total amount covered by this voucher.
    #
    # @return [Money]
    def total
      money_of(@total)
    end

    # The original allocation of the total amount between the parties.
    #
    # @return [Array<Money>]
    def allocations
      allocations_in_cents.map { |cents| money_of(cents) }
    end

    # The cumulative amount refunded to each party so far.
    #
    # @return [Array<Money>]
    def refunded
      refunded_in_cents.map { |cents| money_of(cents) }
    end

    # The cumulative refunded amount across all parties.
    #
    # @return [Money]
    def refunded_total
      money_of(@refunded)
    end

    # The amount each party has not yet refunded.
    #
    # @return [Array<Money>]
    def outstanding
      outstanding_in_cents.map { |cents| money_of(cents) }
    end

    # The amount not yet refunded across all parties.
    #
    # @return [Money]
    def outstanding_total
      money_of(@total - @refunded)
    end

    def fully_refunded?
      @refunded == @total
    end

    # The agreed order in which minimal units are released back by refunds:
    # an array of party indices, one per minimal unit of the total. The first
    # +refunded_total+ entries are exactly the units already refunded, so a
    # partial refund always claws back the units that the original allocation
    # handed out last.
    #
    # @return [Array<Integer>]
    def release_order
      @release_order ||=
        begin
          order = []
          previous = allocations_in_cents
          (@total - 1).downto(0) do |amount|
            current = Allocation.generate(amount, @parts, true).map(&:to_i)
            previous.each_with_index { |units, index| order.concat([index] * (units - current[index])) }
            previous = current
          end
          order
        end
    end

    # Applies a (partial) refund and reports how it is distributed.
    #
    # The distribution of a given cumulative refunded amount is fixed by the
    # voucher's release order, so the sequence and split of refund calls do
    # not change the cumulative result.
    #
    # @param amount [Money] the amount refunded in this call; must be a
    #   positive whole number of minimal units in the voucher's currency.
    # @param id [#to_s] idempotency key of this refund; a repeated id is not
    #   deducted a second time.
    #
    # @return [Money::AllocationVoucher::Refund]
    # @raise [ArgumentError] If the id is missing, the amount is not a
    #   positive whole number of minimal units, or the currency differs.
    # @raise [Money::AllocationVoucher::RefundExceedsTotalError] If the refund
    #   would exceed the remaining total; nothing is deducted in that case.
    def refund(amount, id:)
      raise ArgumentError, "refund id is required" if id.nil?

      id = id.to_s

      if @refund_ids.include?(id)
        return Refund.new(id: id, current: zero_monies, cumulative: refunded, duplicate: true)
      end

      cents = minimal_units_of(amount)

      if @refunded + cents > @total
        raise RefundExceedsTotalError,
              "refund of #{cents} exceeds the remaining #{@total - @refunded} minimal units"
      end

      before = refunded_in_cents
      after = cumulative_refund_in_cents(@refunded + cents)

      @refunded += cents
      @refund_ids << id

      current = after.zip(before).map { |now, previously| now - previously }
      Refund.new(
        id: id,
        current: current.map { |units| money_of(units) },
        cumulative: refunded,
        duplicate: false,
      )
    end

    private

    def restore!(refunded, refund_ids)
      if refunded.negative? || refunded > @total
        raise ArgumentError, "refunded amount is out of range"
      end

      if refund_ids.size != refund_ids.uniq.size
        raise ArgumentError, "refund ids must be unique"
      end

      @refunded = refunded
      @refund_ids = refund_ids
    end

    def allocations_in_cents
      @allocations_in_cents ||= Allocation.generate(@total, @parts, true).map(&:to_i)
    end

    def outstanding_in_cents
      Allocation.generate(@total - @refunded, @parts, true).map(&:to_i)
    end

    def refunded_in_cents
      cumulative_refund_in_cents(@refunded)
    end

    def cumulative_refund_in_cents(cumulative)
      remaining = Allocation.generate(@total - cumulative, @parts, true).map(&:to_i)
      allocations_in_cents.zip(remaining).map { |allocated, left| allocated - left }
    end

    def minimal_units_of(amount)
      unless amount.is_a?(Money)
        raise ArgumentError, "refund amount must be a Money"
      end

      unless amount.currency == @currency
        raise ArgumentError, "refund currency must match the voucher currency"
      end

      fractional = amount.fractional

      unless fractional == fractional.to_i
        raise ArgumentError, "refund amount must be a whole number of minimal units"
      end

      cents = fractional.to_i

      raise ArgumentError, "refund amount must be positive" unless cents.positive?

      cents
    end

    def money_of(cents)
      Money.new(cents, @currency)
    end

    def zero_monies
      Array.new(@parts.size) { money_of(0) }
    end
  end

  # Builds a voucher recording how this amount is allocated between the given
  # parts, so that partial refunds can be deducted consistently later.
  #
  # @param parts [Numeric, Array<Numeric>] see Money#allocate
  #
  # @return [Money::AllocationVoucher]
  #
  # @example
  #   voucher = Money.new(100, "USD").allocation_voucher([3, 7])
  #   voucher.refund(Money.new(10, "USD"), id: "r-1").current #=> [Money.new(3), Money.new(7)]
  def allocation_voucher(parts)
    AllocationVoucher.new(self, parts)
  end
end
