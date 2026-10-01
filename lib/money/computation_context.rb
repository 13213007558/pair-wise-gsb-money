# frozen_string_literal: true

class Money
  # An explicitly entered computation context that controls how monetary
  # operations round their results and which precision violations raise.
  #
  # Money operations silently round fractional amounts to the smallest
  # currency unit. Settlement code that must not lose track of dropped
  # decimals can wrap operations in a computation context:
  #
  #   Money.with_computation_context(precision: 0, traps: [:inexact]) do |context|
  #     Money.new(1, "USD") / 3 # raises Money::ComputationContext::InexactError
  #   end
  #
  # Two distinct signals are recorded on the context while it is active:
  #
  # - +:rounded+ — the representation of a result had to be reduced to the
  #   configured precision, even if only insignificant zero digits were
  #   dropped and the numeric value is unchanged.
  # - +:inexact+ — the quantized result differs from the exact result, i.e.
  #   the value actually changed.
  #
  # Contexts are local to the current thread and fiber, can be nested, and
  # restore the enclosing context when the block exits.
  #
  # @see Money.with_computation_context
  class ComputationContext
    # Base error for precision signals trapped by a computation context.
    class Error < StandardError; end

    # Raised when a trapped operation produces a result whose value differs
    # from the exact result.
    class InexactError < Error; end

    # Raised when a trapped operation had to discard digits to fit the
    # configured precision, even when the value itself did not change.
    class RoundedError < Error; end

    # Precision signals that can be recorded and trapped.
    SIGNALS = [:rounded, :inexact].freeze

    SIGNAL_ERRORS = {
      rounded: RoundedError,
      inexact: InexactError,
    }.freeze
    private_constant :SIGNAL_ERRORS

    # @return [Integer] number of fractional digits results are quantized to
    attr_reader :precision

    # @return [Array<Symbol>] signals that raise instead of only being recorded
    attr_reader :traps

    # @param [Integer] precision Number of fractional digits results are
    #   quantized to. Defaults to 0 (the smallest currency unit).
    # @param [BigDecimal::ROUND_MODE, nil] rounding_mode Rounding mode applied
    #   when quantizing results. Defaults to +Money.rounding_mode+.
    # @param [Array<Symbol>] traps Signals (+:rounded+, +:inexact+) that raise
    #   instead of only being recorded.
    def initialize(precision: 0, rounding_mode: nil, traps: [])
      unknown_traps = traps - SIGNALS
      unless unknown_traps.empty?
        raise ArgumentError, "unknown precision signal(s): #{unknown_traps.join(', ')}"
      end

      @precision = precision
      @rounding_mode = rounding_mode
      @traps = traps.freeze
      @signals = []
    end

    # The rounding mode applied when quantizing results. Falls back to
    # +Money.rounding_mode+ when the context does not configure one.
    #
    # @return [BigDecimal::ROUND_MODE]
    def rounding_mode
      @rounding_mode || Money.rounding_mode
    end

    # Signals recorded so far in this context, in order of first occurrence.
    #
    # @return [Array<Symbol>]
    def signals
      @signals.dup
    end

    # Whether any operation in this context had to discard digits to fit the
    # configured precision, even if the value itself did not change.
    #
    # @return [Boolean]
    def rounded?
      @signals.include?(:rounded)
    end

    # Whether any operation in this context produced a result whose value
    # differs from the exact result.
    #
    # @return [Boolean]
    def inexact?
      @signals.include?(:inexact)
    end

    # Quantizes +value+ to the context precision using the context rounding
    # mode, recording (and possibly trapping) precision signals.
    #
    # @param [Numeric] value The exact operation result.
    #
    # @return [BigDecimal] The quantized value.
    def quantize(value)
      value = self.class.to_bigdecimal(value)
      quantized = value.round(precision, rounding_mode)
      record(value, quantized, precision)
      quantized
    end

    # Records precision signals for +value+ having been rounded to
    # +quantized+ at +record_precision+ fractional digits. Used by explicit
    # quantization entry points that accept their own precision.
    #
    # @param [Numeric] value The exact value before rounding.
    # @param [Numeric] quantized The value after rounding.
    # @param [Integer] record_precision The precision the value was rounded to.
    #
    # @return [void]
    def record(value, quantized, record_precision = precision)
      value = self.class.to_bigdecimal(value)
      quantized = self.class.to_bigdecimal(quantized)

      if decimal_places(value) > record_precision
        signal(:rounded, "#{value} had to be rounded to #{record_precision} fractional digit(s)")
      end
      if quantized != value
        signal(:inexact, "#{value} is not exactly representable at #{record_precision} fractional digit(s) " \
                         "and changed to #{quantized}")
      end
    end

    # @private
    def self.to_bigdecimal(value)
      return value if value.is_a?(BigDecimal)

      if value.respond_to?(:to_d)
        value.is_a?(Rational) ? value.to_d(Money.conversion_precision) : value.to_d
      else
        BigDecimal(value.to_s.empty? ? 0 : value.to_s)
      end
    end

    private

    def signal(name, message)
      @signals << name unless @signals.include?(name)
      return unless traps.include?(name)

      raise SIGNAL_ERRORS.fetch(name), "#{name} signal trapped: #{message}"
    end

    def decimal_places(value)
      return 0 if value.zero?

      _sign, digits, _base, exponent = value.split
      [digits.length - exponent, 0].max
    end
  end
end

