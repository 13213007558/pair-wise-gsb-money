# frozen_string_literal: true

require "bigdecimal/util"

class Money
  # Purely computational amortization schedule. Interest is accrued before
  # each payment, payments are represented in the currency's smallest unit,
  # and the final payment is capped to settle the balance exactly.
  class AmortizationSchedule
    Payment = Struct.new(
      :period,
      :starting_balance,
      :interest,
      :scheduled_regular_payment,
      :regular_payment,
      :extra_payment,
      :payment,
      :principal,
      :ending_balance,
      :interest_remainder_before,
      :interest_remainder_after,
      :final_payment?,
      keyword_init: true,
    ) do
      def final_payment?
        self[:final_payment?]
      end
    end

    SHORTEN_TERM = :shorten_term
    RECAST_PAYMENT = :recast_payment
    VALID_STRATEGIES = [SHORTEN_TERM, RECAST_PAYMENT].freeze

    attr_reader :principal, :periodic_rate, :regular_payment, :extra_payments,
                :extra_payment_strategy, :payments, :status, :payoff_amount,
                :carry_interest_remainder

    # @param principal [Money] starting balance
    # @param periodic_rate [Numeric] non-negative interest rate per period
    # @param regular_payment [Money] payment scheduled before each extra payment
    # @param extra_payments [Hash{Integer => Money}] extra payments by period
    # @param carry_interest_remainder [Boolean] carry fractional interest cents
    # @param extra_payment_strategy [Symbol] +:shorten_term+ or +:recast_payment+
    def initialize(
      principal,
      periodic_rate,
      regular_payment,
      extra_payments = {},
      carry_interest_remainder: false,
      extra_payment_strategy: SHORTEN_TERM
    )
      @principal = normalize_money(principal, "principal")
      @periodic_rate = validate_rate(periodic_rate)
      @regular_payment = normalize_money(regular_payment, "regular_payment")
      @extra_payments = validate_extra_payments(extra_payments)
      @carry_interest_remainder = carry_interest_remainder
      @extra_payment_strategy = validate_strategy(extra_payment_strategy)

      validate_inputs

      @currency = @principal.currency
      @original_term = determine_original_term if @extra_payment_strategy == RECAST_PAYMENT
      @payments = []
      @status = build
      @payoff_amount = @payments.last&.payment if @status == :paid_off
    end

    def paid_off?
      @status == :paid_off
    end

    def negative_amortization?
      @status == :negative_amortization
    end

    def ending_balance
      @payments.last&.ending_balance || Money.empty(@principal.currency)
    end

    def interest_remainder
      @payments.last&.interest_remainder_after || BigDecimal("0")
    end

    def total_interest
      @payments.sum(Money.empty(@currency), &:interest)
    end

    def total_principal
      @payments.sum(Money.empty(@currency), &:principal)
    end

    def total_payments
      @payments.sum(Money.empty(@currency), &:payment)
    end

    def to_a
      @payments
    end

    private

    def validate_inputs
      unless @principal.positive?
        raise ArgumentError, "principal must be greater than zero"
      end

      unless @regular_payment.positive?
        raise ArgumentError, "regular_payment must be greater than zero"
      end

      unless same_currency?(@regular_payment)
        raise ArgumentError, "regular_payment must use the principal's currency"
      end

      return if @extra_payments.values.all? { |payment| same_currency?(payment) }

      raise ArgumentError, "extra payments must use the principal's currency"
    end

    def same_currency?(money)
      money.currency == @principal.currency
    end

    def validate_rate(rate)
      rate = BigDecimal(rate.to_s)
      raise ArgumentError, "periodic_rate must be greater than or equal to zero" if rate < 0

      rate
    end

    def validate_extra_payments(payments)
      unless payments.is_a?(Hash)
        raise ArgumentError, "extra_payments must be a Hash keyed by period"
      end

      payments.each_with_object({}) do |(period, payment), normalized|
        unless period.is_a?(Integer) && period.positive?
          raise ArgumentError, "extra payment periods must be positive integers"
        end

        normalized[period] = normalize_money(payment, "extra payment for period #{period}")
        unless normalized[period].positive?
          raise ArgumentError, "extra payment for period #{period} must be greater than zero"
        end
      end
    end

    def validate_strategy(strategy)
      unless VALID_STRATEGIES.include?(strategy)
        raise ArgumentError, "extra_payment_strategy must be #{SHORTEN_TERM} or #{RECAST_PAYMENT}"
      end

      strategy
    end

    def determine_original_term
      schedule = self.class.new(
        @principal,
        @periodic_rate,
        @regular_payment,
        {},
        carry_interest_remainder: @carry_interest_remainder,
        extra_payment_strategy: SHORTEN_TERM,
      )

      unless schedule.paid_off?
        raise ArgumentError, "regular_payment must amortize principal before it can be recast"
      end

      schedule.payments.size
    end

    def build
      balance = @principal
      carried_remainder = BigDecimal("0")
      period = 1

      loop do
        extra_payment = @extra_payments.fetch(period, Money.empty(@currency))
        starting_balance = balance
        exact_interest = interest_amount(balance, carried_remainder)
        interest, remainder_before, remainder_after =
          charge_interest(exact_interest, carried_remainder)
        payment, regular_payment, applied_extra =
          apply_payment(balance, interest, @regular_payment, extra_payment)
        principal_paid = payment - interest
        balance = balance - principal_paid
        final_payment = !balance.positive?
        balance = Money.empty(@currency) if final_payment

        @payments << build_payment(
          period,
          starting_balance,
          interest,
          @regular_payment,
          regular_payment,
          applied_extra,
          payment,
          principal_paid,
          balance,
          remainder_before,
          remainder_after,
          final_payment,
        )

        return :negative_amortization if principal_paid.negative?
        return :paid_off if final_payment

        if principal_paid.zero? && no_future_progress?(period, balance)
          return :interest_only
        end

        carried_remainder = carry? ? remainder_after : BigDecimal("0")

        if @extra_payment_strategy == RECAST_PAYMENT && applied_extra.positive?
          remaining_periods = @original_term - period
          @regular_payment = recast_payment(balance, remaining_periods) if remaining_periods.positive?
        end

        period += 1
      end
    end

    def interest_amount(balance, carried_remainder)
      balance.fractional.to_d * @periodic_rate + carried_remainder
    end

    def charge_interest(exact_interest, carried_remainder)
      if finite_money?
        charged = exact_interest.round(0, Money.rounding_mode)
        [money(charged), carried_remainder, exact_interest - charged]
      else
        [money(exact_interest), BigDecimal("0"), BigDecimal("0")]
      end
    end

    def apply_payment(balance, interest, regular_payment, extra_payment)
      due = balance + interest
      requested = regular_payment + extra_payment
      payment = [requested, due].min

      if regular_payment >= payment
        [payment, payment, Money.empty(@currency)]
      else
        [payment, regular_payment, payment - regular_payment]
      end
    end

    def recast_payment(balance, remaining_periods)
      payment =
        if @periodic_rate.zero?
          balance.fractional.to_d / remaining_periods
        else
          rate = @periodic_rate
          balance.fractional.to_d * rate / (1 - ((1 + rate) ** (-remaining_periods)))
        end

      payment = payment.round(0, BigDecimal::ROUND_CEILING) if finite_money?

      money(payment)
    end

    def no_future_progress?(period, balance)
      future_periods = @extra_payments.keys.select { |payment_period| payment_period > period }
      next_extra_period = future_periods.min
      return false if next_extra_period

      next_interest = balance.fractional.to_d * @periodic_rate
      next_interest = next_interest.round(0, Money.rounding_mode) if finite_money?
      @regular_payment.fractional <= next_interest
    end

    def build_payment(
      period,
      starting_balance,
      interest,
      scheduled_regular_payment,
      regular_payment,
      extra_payment,
      payment,
      principal,
      ending_balance,
      remainder_before,
      remainder_after,
      final_payment
    )
      Payment.new(
        period: period,
        starting_balance: starting_balance,
        interest: interest,
        scheduled_regular_payment: scheduled_regular_payment,
        regular_payment: regular_payment,
        extra_payment: extra_payment,
        payment: payment,
        principal: principal,
        ending_balance: ending_balance,
        interest_remainder_before: remainder_before,
        interest_remainder_after: remainder_after,
        final_payment?: final_payment,
      )
    end

    def money(amount)
      Money.new(amount, @currency)
    end

    def normalize_money(value, name)
      unless value.is_a?(Money)
        raise ArgumentError, "#{name} must be a Money"
      end

      Money.new(value.fractional, value.currency, bank: value.bank)
    end

    def carry?
      @carry_interest_remainder
    end

    def finite_money?
      !Money.default_infinite_precision
    end
  end
end
