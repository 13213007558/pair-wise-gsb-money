# frozen_string_literal: true

class Money
  # Pure-computation amortization schedule for a fixed-rate loan.
  #
  # Each period is processed in a strict "accrue interest, then pay" order:
  #
  #   1. Interest is computed on the opening balance (+balance * rate+),
  #      plus any carried sub-subunit residue (see +carry_remainder+), and
  #      rounded to whole subunits with +rounding_mode+.
  #   2. The regular payment and any extra payment scheduled for the period
  #      are applied: interest first, the remainder to principal.
  #
  # The final period is capped at the exact payoff amount (balance + interest),
  # so the schedule never overshoots into a negative balance.
  #
  # Sub-subunit interest residue (the fraction of a cent dropped by rounding)
  # is either carried into the next period's interest computation
  # (+carry_remainder: true+, the default) or discarded. Each period row
  # exposes the residue in +interest_residue+ so the rounding trail is
  # fully auditable.
  #
  # Extra payments either shorten the term (+extra_payment_mode: :shorten_term+,
  # the default) or trigger a recast of the remaining fixed payment so the
  # loan still matures at the original term (+extra_payment_mode: :recast+).
  #
  # When a payment does not cover the period's interest, the schedule never
  # loops forever: +on_negative_amortization: :stop+ (default) halts with
  # status +:negative_amortization+, while +:capitalize+ adds the unpaid
  # interest to the balance and continues (bounded by +max_periods+).
  #
  # No calendars, rate feeds, or persistence are involved; everything is
  # computed from the constructor arguments.
  #
  # @example
  #   amortization = Money::Amortization.new(
  #     principal: Money.new(100_000_00, "USD"),
  #     rate: BigDecimal("0.005"),
  #     payment: Money.new(1_000_00, "USD"),
  #     extra_payments: { 12 => Money.new(5_000_00, "USD") },
  #   )
  #   schedule = amortization.schedule
  #   schedule.status         #=> :paid_off
  #   schedule.payoff_amount  #=> Money of the final period's total payment
  #   schedule.total_interest #=> Money
  class Amortization
    # A single period of an amortization schedule.
    #
    # @!attribute [r] number
    #   @return [Integer] 1-based period number.
    # @!attribute [r] interest
    #   @return [Money] interest accrued this period (rounded to subunits).
    # @!attribute [r] principal
    #   @return [Money] principal repaid this period (negative when unpaid
    #     interest is capitalized under negative amortization).
    # @!attribute [r] extra_payment
    #   @return [Money] extra payment actually applied this period.
    # @!attribute [r] payment
    #   @return [Money] total outflow this period (regular + extra, capped
    #     at the payoff amount).
    # @!attribute [r] balance
    #   @return [Money] outstanding balance after this period's payment.
    # @!attribute [r] interest_residue
    #   @return [BigDecimal] sub-subunit remainder left after rounding the
    #     period's interest, in fractional units (cents). Carried into the
    #     next period when +carry_remainder+ is enabled, discarded otherwise.
    # @!attribute [r] status
    #   @return [Symbol] +:regular+, +:payoff+, or +:negative_amortization+.
    Period = Struct.new(
      :number, :interest, :principal, :extra_payment, :payment,
      :balance, :interest_residue, :status,
      keyword_init: true
    )

    # The result of running an amortization schedule.
    class Schedule
      include Enumerable

      # @return [Array<Period>] one row per elapsed period.
      attr_reader :rows

      # @return [Symbol] +:paid_off+, +:negative_amortization+, or
      #   +:max_periods_exceeded+.
      attr_reader :status

      def initialize(rows:, status:, principal:, factory:)
        @rows = rows
        @status = status
        @principal = principal
        @factory = factory
      end

      def each(&block)
        rows.each(&block)
      end

      # @return [Integer] number of elapsed periods.
      def term
        rows.length
      end

      # @return [Boolean] whether the balance reached zero.
      def paid_off?
        status == :paid_off
      end

      # @return [Boolean] whether any period's payment failed to cover its
      #   interest.
      def negative_amortization?
        status == :negative_amortization || rows.any? { |row| row.status == :negative_amortization }
      end

      # @return [Money] total interest paid over the elapsed periods.
      def total_interest
        @factory.call(rows.sum { |row| row.interest.fractional })
      end

      # @return [Money] total principal repaid over the elapsed periods.
      def total_principal
        @factory.call(rows.sum { |row| row.principal.fractional })
      end

      # @return [Money] total amount paid over the elapsed periods.
      def total_payment
        @factory.call(rows.sum { |row| row.payment.fractional })
      end

      # The exact amount needed to settle the loan: the final period's total
      # payment when the schedule paid off.
      #
      # @return [Money, nil] nil when the loan did not pay off.
      def payoff_amount
        paid_off? ? rows.last.payment : nil
      end

      # Conservation check: every cent of outflow is accounted for as either
      # principal or interest, and a paid-off schedule repays exactly the
      # original principal.
      #
      # @return [Boolean]
      def balanced?
        flows_balance = total_payment == total_interest + total_principal
        flows_balance && (!paid_off? || total_principal == @principal)
      end
    end

    EXTRA_PAYMENT_MODES = %i[shorten_term recast].freeze
    NEGATIVE_AMORTIZATION_MODES = %i[stop capitalize].freeze
    DEFAULT_MAX_PERIODS = 1200

    attr_reader :principal, :rate, :payment, :extra_payments, :extra_payment_mode,
                :on_negative_amortization, :max_periods, :rounding_mode

    # @param principal [Money] the amount borrowed.
    # @param rate [Numeric] per-period interest rate (e.g. 0.005 for 0.5%).
    # @param payment [Money] the regular payment made each period.
    # @param extra_payments [Hash{Integer => Money}] one-off extra payments
    #   keyed by 1-based period number.
    # @param extra_payment_mode [Symbol] +:shorten_term+ keeps the payment
    #   fixed and pays off earlier; +:recast+ recomputes the remaining fixed
    #   payment (rounded up to the next subunit, so rounding never pushes the
    #   loan past its original term) and the final period adjusts downward.
    # @param carry_remainder [Boolean] whether the sub-subunit residue left
    #   after rounding each period's interest is carried into the next
    #   period's interest computation (true) or discarded (false).
    # @param on_negative_amortization [Symbol] +:stop+ halts the schedule
    #   with status +:negative_amortization+; +:capitalize+ adds the unpaid
    #   interest to the balance and keeps going.
    # @param max_periods [Integer] hard bound on the number of periods, so a
    #   non-amortizing loan can never loop forever.
    # @param rounding_mode [BigDecimal::ROUND_MODE] mode used to round
    #   interest (and recast payments) to whole subunits.
    def initialize(principal:, rate:, payment:, extra_payments: {},
                   extra_payment_mode: :shorten_term, carry_remainder: true,
                   on_negative_amortization: :stop,
                   max_periods: DEFAULT_MAX_PERIODS,
                   rounding_mode: Money.rounding_mode)
      @principal = principal
      @rate = rate.is_a?(BigDecimal) ? rate : BigDecimal(rate.to_s)
      @payment = payment
      @extra_payments = extra_payments
      @extra_payment_mode = extra_payment_mode
      @carry_remainder = carry_remainder
      @on_negative_amortization = on_negative_amortization
      @max_periods = max_periods
      @rounding_mode = rounding_mode

      validate!
    end

    # @return [Boolean] whether sub-subunit interest residue is carried forward.
    def carry_remainder?
      @carry_remainder
    end

    # Runs the computation.
    #
    # @return [Schedule]
    def schedule
      balance = principal.fractional.to_i
      regular_payment = payment.fractional.to_i
      original_term = extra_payment_mode == :recast ? compute_term(balance, regular_payment) : nil
      residue = BigDecimal("0")
      rows = []
      status = :paid_off

      loop do
        period_number = rows.length + 1
        break status = :max_periods_exceeded if period_number > max_periods

        interest_exact = BigDecimal(balance.to_s) * rate + residue
        interest = round_subunit(interest_exact)
        interest = 0 if interest.negative?
        residue = carry_remainder? ? interest_exact - interest : BigDecimal("0")

        extra = extra_fractional(period_number)
        payoff = balance + interest

        if regular_payment + extra < interest
          row, balance, halted = handle_negative_amortization(
            period_number, interest, regular_payment, extra, balance, residue
          )
          rows << row
          break status = :negative_amortization if halted
          next
        end

        applied_regular = [regular_payment, payoff].min
        applied_extra = [extra, payoff - applied_regular].min
        total = applied_regular + applied_extra
        principal_paid = total - interest
        balance -= principal_paid

        rows << build_period(
          number: period_number, interest: interest, principal: principal_paid,
          extra: applied_extra, payment: total, balance: balance,
          residue: residue, status: balance.zero? ? :payoff : :regular
        )

        break if balance.zero?

        if original_term && applied_extra.positive?
          regular_payment = recast_payment(balance, original_term - period_number)
        end
      end

      Schedule.new(rows: rows, status: status, principal: principal, factory: method(:build_money))
    end

    private

    def validate!
      raise ArgumentError, "principal must be positive" unless principal.positive?
      raise ArgumentError, "payment must be positive" unless payment.positive?
      raise ArgumentError, "rate must not be negative" if rate.negative?
      raise ArgumentError, "payment currency must match principal currency" unless payment.currency == principal.currency

      unless EXTRA_PAYMENT_MODES.include?(extra_payment_mode)
        raise ArgumentError, "unknown extra payment mode: #{extra_payment_mode.inspect}"
      end
      unless NEGATIVE_AMORTIZATION_MODES.include?(on_negative_amortization)
        raise ArgumentError, "unknown negative amortization mode: #{on_negative_amortization.inspect}"
      end
      raise ArgumentError, "max_periods must be positive" unless max_periods.is_a?(Integer) && max_periods.positive?

      extra_payments.each do |period, amount|
        unless period.is_a?(Integer) && period.positive?
          raise ArgumentError, "extra payment periods must be positive integers"
        end
        unless amount.is_a?(Money) && amount.positive?
          raise ArgumentError, "extra payments must be positive Money"
        end
        unless amount.currency == principal.currency
          raise ArgumentError, "extra payment currency must match principal currency"
        end
      end
    end

    def handle_negative_amortization(period_number, interest, regular_payment, extra, balance, residue)
      shortfall = interest - regular_payment - extra

      if on_negative_amortization == :capitalize
        row = build_period(
          number: period_number, interest: interest, principal: -shortfall,
          extra: extra, payment: regular_payment + extra, balance: balance + shortfall,
          residue: residue, status: :negative_amortization
        )
        [row, balance + shortfall, false]
      else
        row = build_period(
          number: period_number, interest: interest, principal: 0,
          extra: extra, payment: regular_payment + extra, balance: balance,
          residue: residue, status: :negative_amortization
        )
        [row, balance, true]
      end
    end

    # Number of periods needed to pay +balance+ off with a fixed payment.
    def compute_term(balance, payment_amount)
      if rate.zero?
        (balance.to_d / payment_amount).ceil
      else
        growth = 1 + rate.to_f
        numerator = balance * rate.to_f
        if payment_amount <= numerator
          raise ArgumentError, "payment does not cover the first period's interest; the loan never amortizes"
        end
        (-Math.log(1 - numerator / payment_amount) / Math.log(growth)).ceil
      end
    end

    # Fixed payment that amortizes +balance+ over +remaining_periods+ periods.
    # Rounded up so the loan still matures within the original term; the final
    # period then adjusts downward to the exact payoff amount.
    def recast_payment(balance, remaining_periods)
      if rate.zero?
        return balance.to_d.div(remaining_periods, Money.conversion_precision).ceil.to_i
      end

      growth = 1 + rate
      compounded = growth**remaining_periods
      exact = BigDecimal(balance.to_s) * rate * compounded / (compounded - 1)
      exact.ceil.to_i
    end

    def round_subunit(amount)
      amount.round(0, rounding_mode).to_i
    end

    def extra_fractional(period_number)
      extra = extra_payments[period_number]
      extra ? extra.fractional.to_i : 0
    end

    def build_period(number:, interest:, principal:, extra:, payment:, balance:, residue:, status:)
      Period.new(
        number: number,
        interest: build_money(interest),
        principal: build_money(principal),
        extra_payment: build_money(extra),
        payment: build_money(payment),
        balance: build_money(balance),
        interest_residue: residue,
        status: status
      )
    end

    def build_money(fractional)
      principal.dup_with(fractional: fractional)
    end
  end
end
