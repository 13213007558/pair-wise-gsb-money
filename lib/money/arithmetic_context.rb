# frozen_string_literal: true

class Money
  # An explicitly entered arithmetic context for money calculations that must
  # not silently drop decimals (e.g. settlement code).
  #
  # While a context is active, the four rounding-sensitive operations -
  # division (Money#/), multiplication (Money#*), currency exchange
  # (Money#exchange_to) and explicit quantization (Money#round) - are
  # carried out with the context's rounding mode and precision, and every
  # precision signal that occurs is recorded on the context.
  #
  # Two signals are tracked, mirroring IEEE 754 / BigDecimal semantics:
  #
  # - +:rounded+ - the delivered representation had to discard digits to fit
  #   the configured precision, even if those digits were zeros and the
  #   numeric value is unchanged.
  # - +:inexact+ - the delivered value differs from the exact mathematical
  #   result. Implies +:rounded+.
  #
  # Either signal can be trapped, in which case the offending operation
  # raises instead of silently rounding.
  #
  # The active context is fiber-local (and therefore also thread-local), so
  # concurrent threads and fibers never pollute each other. Contexts can be
  # nested; exiting an inner context restores the outer one.
  #
  # @example
  #   Money.with_arithmetic_context(precision: 0, traps: [:inexact]) do |ctx|
  #     Money.new(100) / 4  # exact, no signal
  #     Money.new(1) / 3    # raises Money::ArithmeticContext::Inexact
  #   end
  #
  # @see Money.with_arithmetic_context
  class ArithmeticContext
    # Signals recorded by the context.
    SIGNALS = [:rounded, :inexact].freeze

    # Symbolic aliases accepted for BigDecimal rounding modes.
    ROUNDING_MODES = {
      up: BigDecimal::ROUND_UP,
      down: BigDecimal::ROUND_DOWN,
      half_up: BigDecimal::ROUND_HALF_UP,
      half_down: BigDecimal::ROUND_HALF_DOWN,
      half_even: BigDecimal::ROUND_HALF_EVEN,
      ceiling: BigDecimal::ROUND_CEILING,
      floor: BigDecimal::ROUND_FLOOR,
    }.freeze

    # Base class for errors raised by trapped precision signals.
    class SignalError < StandardError
      # @return [Symbol] the signal that was trapped (:rounded or :inexact)
      attr_reader :signal

      # @return [Money::ArithmeticContext] the context that raised
      attr_reader :context

      def initialize(signal, context)
        @signal = signal
        @context = context
        super("#{signal} result trapped by arithmetic context " \
              "(precision: #{context.precision}, rounding_mode: #{context.rounding_mode})")
      end
    end

    # Raised when the +:rounded+ signal is trapped: the result representation
    # had to discard digits to fit the configured precision.
    class Rounded < SignalError
      def initialize(context)
        super(:rounded, context)
      end
    end

    # Raised when the +:inexact+ signal is trapped: the delivered value
    # differs from the exact mathematical result.
    class Inexact < SignalError
      def initialize(context)
        super(:inexact, context)
      end
    end

    # @return [BigDecimal::ROUND_MODE] rounding mode applied by this context
    attr_reader :rounding_mode

    # @return [Integer] number of fractional decimal digits results are
    #   quantized to
    attr_reader :precision

    # @return [Array<Symbol>] signals that raise instead of being recorded
    attr_reader :traps

    # @return [Array<Symbol>] precision signals recorded so far, in order of
    #   first occurrence (subset of [:rounded, :inexact])
    attr_reader :signals

    # @param [BigDecimal::ROUND_MODE, Symbol] rounding_mode rounding applied
    #   when a result does not fit the precision. Accepts BigDecimal rounding
    #   mode constants or symbols such as :half_up, :down, :half_even.
    # @param [Integer] precision number of fractional decimal digits kept for
    #   results computed inside the context (0 = whole fractional units).
    # @param [Array<Symbol>] traps any of :rounded, :inexact. Trapped signals
    #   raise Money::ArithmeticContext::Rounded / ::Inexact.
    def initialize(rounding_mode: Money.rounding_mode, precision: 0, traps: [])
      @rounding_mode = self.class.normalize_rounding_mode(rounding_mode)
      @precision = self.class.normalize_precision(precision)
      @traps = traps.map { |trap| self.class.normalize_signal(trap) }.uniq.freeze
      @signals = []
    end

    # Whether the +:rounded+ signal has been recorded in this context.
    #
    # @return [Boolean]
    def rounded?
      signal?(:rounded)
    end

    # Whether the +:inexact+ signal has been recorded in this context.
    #
    # @return [Boolean]
    def inexact?
      signal?(:inexact)
    end

    # Whether the given signal has been recorded in this context.
    #
    # @param [Symbol] name :rounded or :inexact
    #
    # @return [Boolean]
    def signal?(name)
      @signals.include?(name)
    end

    # Whether the given signal is trapped by this context.
    #
    # @param [Symbol] name :rounded or :inexact
    #
    # @return [Boolean]
    def trap?(name)
      @traps.include?(name)
    end

    # Quantizes +value+ to the context precision and rounding mode (or to
    # explicitly given overrides), records the +:rounded+ / +:inexact+
    # signals and raises when a recorded signal is trapped.
    #
    # @param [BigDecimal] value the exact result of an operation
    # @param [Integer] precision quantization target, defaults to the
    #   context precision
    # @param [BigDecimal::ROUND_MODE] rounding_mode defaults to the context
    #   rounding mode
    # @param [Integer, Float] scale number of fractional decimal digits in
    #   the exact mathematical result (Float::INFINITY for non-terminating
    #   results); derived from +value+ when omitted
    # @param [Boolean, nil] inexact whether the exact mathematical result
    #   cannot be represented at the target precision; derived by comparing
    #   the quantized value when omitted
    #
    # @return [BigDecimal] the quantized value
    def apply(value, precision: @precision, rounding_mode: @rounding_mode, scale: nil, inexact: nil)
      scale = self.class.decimal_scale(value) if scale.nil?
      quantized = value.round(precision, rounding_mode)
      inexact = quantized != value if inexact.nil?

      record(:rounded) if inexact || scale > precision
      record(:inexact) if inexact

      quantized
    end

    # Number of fractional decimal digits needed to represent +value+
    # exactly (trailing zeros are not counted).
    #
    # @param [BigDecimal] value
    #
    # @return [Integer]
    def self.decimal_scale(value)
      return 0 if value.zero?

      _sign, digits, _base, exponent = value.split
      [digits.length - exponent, 0].max
    end

    # Exact decimal scale of +dividend+ / +divisor+. Returns the scale and
    # whether the quotient is inexact at any finite precision (i.e. its
    # decimal expansion does not terminate, as with 1/3).
    #
    # @param [BigDecimal] dividend
    # @param [BigDecimal] divisor must be non-zero
    #
    # @return [Array] a [scale, non_terminating] pair
    def self.division_scale(dividend, divisor)
      denominator = (dividend.to_r / divisor.to_r).denominator

      twos = 0
      while (denominator % 2).zero?
        denominator /= 2
        twos += 1
      end

      fives = 0
      while (denominator % 5).zero?
        denominator /= 5
        fives += 1
      end

      if denominator == 1
        [[twos, fives].max, nil]
      else
        [Float::INFINITY, true]
      end
    end

    # @api private
    def self.normalize_rounding_mode(mode)
      return ROUNDING_MODES.fetch(mode) if mode.is_a?(Symbol)

      mode
    end

    # @api private
    def self.normalize_precision(precision)
      precision = Integer(precision)
      raise ArgumentError, "precision must be >= 0" if precision.negative?

      precision
    end

    # @api private
    def self.normalize_signal(signal)
      signal = signal.to_sym
      unless SIGNALS.include?(signal)
        raise ArgumentError, "unknown precision signal: #{signal.inspect} (expected one of #{SIGNALS.inspect})"
      end

      signal
    end

    private

    def record(signal)
      @signals << signal unless @signals.include?(signal)

      return unless trap?(signal)

      raise(signal == :inexact ? Inexact.new(self) : Rounded.new(self))
    end
  end
end
