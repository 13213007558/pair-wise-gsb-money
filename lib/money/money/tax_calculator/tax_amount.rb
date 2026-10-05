# frozen_string_literal: true

class Money
  class TaxCalculator
    # The calculated values for one tax.
    #
    # +unrounded_amount+ is expressed in major currency units and is kept as a
    # Rational so repeating decimal rates do not lose precision before audit.
    TaxAmount = Struct.new(
      :name,
      :rate,
      :base,
      :unrounded_amount,
      :amount,
      keyword_init: true,
    )
  end
end
