# frozen_string_literal: true

module Heya
  module Campaigns
    # {Campaigns::ScheduleCalculator} handles time-based scheduling calculations
    # for campaign steps that use `send_at`.
    module ScheduleCalculator
      extend self

      # Parses send_at value into [hour, minute] tuple.
      # Accepts:
      #   - Integer: 8 -> [8, 0]
      #   - String hour: "8" -> [8, 0]
      #   - String time: "10:30" -> [10, 30]
      #
      # @param send_at [Integer, String, nil] The send_at value
      # @return [Array<Integer>, nil] [hour, minute] or nil if send_at is nil
      # @raise [ArgumentError] if send_at format is invalid or values out of range
      def parse_send_at(send_at)
        return nil if send_at.nil?

        hour, minute = case send_at
        when Integer
          [send_at, 0]
        when String
          if send_at.include?(":")
            parts = send_at.split(":")
            [parts[0].to_i, parts[1].to_i]
          else
            [send_at.to_i, 0]
          end
        else
          raise ArgumentError, "Invalid send_at format: #{send_at.inspect}. Expected Integer or String."
        end

        unless hour.between?(0, 23)
          raise ArgumentError, "Invalid send_at hour: #{hour} (from #{send_at.inspect}). Hour must be 0-23."
        end
        unless minute.between?(0, 59)
          raise ArgumentError, "Invalid send_at minute: #{minute} (from #{send_at.inspect}). Minute must be 0-59."
        end

        [hour, minute]
      end

      # Calculates the scheduled_for datetime for a step.
      #
      # @param step [Step] The step being scheduled
      # @param reference_time [Time] The reference time (usually now or last_sent_at)
      # @param time_zone [String] The time zone name (e.g., "America/New_York")
      # @return [Time, nil] The calculated scheduled_for time in UTC, or nil if no send_at
      def calculate_scheduled_for(step:, reference_time:, time_zone:)
        send_at = parse_send_at(step.send_at)
        return nil if send_at.nil?

        tz = ActiveSupport::TimeZone[time_zone]
        raise ArgumentError, "Invalid time zone: #{time_zone}" if tz.nil?

        hour, minute = send_at
        wait_seconds = step.wait.to_i

        # Convert reference time to the campaign's time zone
        reference_in_tz = reference_time.in_time_zone(tz)

        # Apply wait duration to get target date
        target_date = (reference_in_tz + wait_seconds).to_date

        # Create datetime at send_at time on target date
        scheduled = tz.local(target_date.year, target_date.month, target_date.day, hour, minute)

        # If wait is 0 and the scheduled time is in the past, move to next day
        if wait_seconds == 0 && scheduled <= reference_in_tz
          scheduled += 1.day
        end

        scheduled.utc
      end

      # Ensures the scheduled_for time is not on a past date.
      # If the scheduled time is on a past date (not just past time today),
      # rolls forward to the next occurrence of the send_at time.
      #
      # This prevents the scenario where multiple steps with wait: 0 would
      # all send immediately after a skip because their calculated times
      # are on a past date.
      #
      # @param scheduled_for [Time, nil] The calculated scheduled_for time in UTC
      # @param send_at [Integer, String, nil] The send_at value for the step
      # @param time_zone [String] The time zone name
      # @param now [Time] The current time (defaults to Time.now.utc)
      # @return [Time, nil] The adjusted scheduled_for time in UTC
      def ensure_future_date(scheduled_for:, send_at:, time_zone:, now: Time.now.utc)
        return scheduled_for if scheduled_for.nil?
        return scheduled_for if scheduled_for >= now

        tz = ActiveSupport::TimeZone[time_zone]
        return scheduled_for if tz.nil?

        scheduled_date = scheduled_for.in_time_zone(tz).to_date
        today = now.in_time_zone(tz).to_date

        # If same date as today, allow (will send immediately - campaign already running)
        return scheduled_for if scheduled_date >= today

        # Past date - roll forward to next occurrence of send_at time
        parsed = parse_send_at(send_at)
        return scheduled_for if parsed.nil? # No send_at, keep as is

        hour, minute = parsed
        send_at_today = tz.local(today.year, today.month, today.day, hour, minute)
        now_in_tz = now.in_time_zone(tz)

        if send_at_today > now_in_tz
          send_at_today.utc
        else
          (send_at_today + 1.day).utc
        end
      end
    end
  end
end
