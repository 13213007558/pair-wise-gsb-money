# frozen_string_literal: true

require "date"

class Money
  class CashFlow
    # Day-count conventions used to turn two dates into a year fraction.
    #
    # The convention is selected by the caller; {Money::CashFlow} never picks
    # one implicitly. A callable may also be supplied directly:
    #
    #   ->(start_date, end_date) { (end_date - start_date) / 360.0 }
    #
    # Supported conventions:
    #
    # +:act_act_isda+:: Actual days over the actual number of days in each
    #   year covered by the period (ISDA 2006).
    # +:act_365_fixed+:: Actual days divided by 365 (spreadsheet XIRR).
    # +:act_360+:: Actual days divided by 360.
    # +:thirty_360_us+:: 30/360 US, including the February end-of-month rule.
    # +:thirty_e_360+:: 30E/360 (Eurobond).
    module DayCount
      CONVENTIONS = %i[
        act_act_isda
        act_365_fixed
        act_360
        thirty_360_us
        thirty_e_360
      ].freeze

      class << self
        # @param convention [Symbol, #call]
        # @return [#call(Date, Date) -> Float]
        def fetch(convention)
          return convention if convention.respond_to?(:call)

          unless convention.is_a?(Symbol) && CONVENTIONS.include?(convention)
            raise ArgumentError,
                  "unknown day-count convention #{convention.inspect}; " \
                  "use one of #{CONVENTIONS.map(&:inspect).join(", ")} " \
                  "or a callable"
          end

          method(convention)
        end

        # Actual/Actual ISDA. Periods are split on calendar year boundaries and
        # each slice is divided by the length of its year (365 or 366).
        #
        # @param start_date [Date]
        # @param end_date [Date]
        # @return [Float]
        def act_act_isda(start_date, end_date)
          return 0.0 if start_date == end_date

          year_fraction = 0.0
          cursor = start_date
          while cursor.year < end_date.year
            year_start = Date.new(cursor.year + 1, 1, 1)
            year_fraction += (year_start - cursor) / days_in_year(cursor.year).to_f
            cursor = year_start
          end
          year_fraction += (end_date - cursor) / days_in_year(end_date.year).to_f
          year_fraction
        end

        # Actual/365 Fixed.
        #
        # @param start_date [Date]
        # @param end_date [Date]
        # @return [Float]
        def act_365_fixed(start_date, end_date)
          (end_date - start_date) / 365.0
        end

        # Actual/360.
        #
        # @param start_date [Date]
        # @param end_date [Date]
        # @return [Float]
        def act_360(start_date, end_date)
          (end_date - start_date) / 360.0
        end

        # 30/360 US (Bond Basis).
        #
        # @param start_date [Date]
        # @param end_date [Date]
        # @return [Float]
        def thirty_360_us(start_date, end_date)
          start_day, end_day = us_adjusted_days(start_date, end_date)
          years = (end_date.year - start_date.year) * 360 +
                  (end_date.month - start_date.month) * 30 +
                  (end_day - start_day)
          years / 360.0
        end

        # 30E/360 (Eurobond Basis).
        #
        # @param start_date [Date]
        # @param end_date [Date]
        # @return [Float]
        def thirty_e_360(start_date, end_date)
          start_day = start_date.day == 31 ? 30 : start_date.day
          end_day = end_date.day == 31 ? 30 : end_date.day
          years = (end_date.year - start_date.year) * 360 +
                  (end_date.month - start_date.month) * 30 +
                  (end_day - start_day)
          years / 360.0
        end

        private

        def days_in_year(year)
          Date.leap?(year) ? 366 : 365
        end

        def us_adjusted_days(start_date, end_date)
          start_day = start_date.day
          end_day = end_date.day

          if start_day == 31
            start_day = 30
            end_day = 30
          elsif start_day == 30 && end_day == 31
            end_day = 30
          elsif last_day_of_february?(start_date)
            start_day = 30
            end_day = 30 if last_day_of_february?(end_date)
          end

          [start_day, end_day]
        end

        def last_day_of_february?(date)
          date.month == 2 && date.day == Date.new(date.year, 2, -1).day
        end
      end
    end
  end
end
