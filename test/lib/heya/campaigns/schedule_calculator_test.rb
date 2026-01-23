# frozen_string_literal: true

require "test_helper"

module Heya
  module Campaigns
    class ScheduleCalculatorTest < ActiveSupport::TestCase
      test "parse_send_at returns nil for nil input" do
        assert_nil ScheduleCalculator.parse_send_at(nil)
      end

      test "parse_send_at parses integer hour" do
        assert_equal [8, 0], ScheduleCalculator.parse_send_at(8)
        assert_equal [14, 0], ScheduleCalculator.parse_send_at(14)
        assert_equal [0, 0], ScheduleCalculator.parse_send_at(0)
        assert_equal [23, 0], ScheduleCalculator.parse_send_at(23)
      end

      test "parse_send_at parses string hour" do
        assert_equal [8, 0], ScheduleCalculator.parse_send_at("8")
        assert_equal [14, 0], ScheduleCalculator.parse_send_at("14")
      end

      test "parse_send_at parses string hour:minute" do
        assert_equal [10, 30], ScheduleCalculator.parse_send_at("10:30")
        assert_equal [8, 0], ScheduleCalculator.parse_send_at("8:00")
        assert_equal [23, 59], ScheduleCalculator.parse_send_at("23:59")
        assert_equal [0, 0], ScheduleCalculator.parse_send_at("0:00")
      end

      test "parse_send_at raises for invalid hour" do
        assert_raises(ArgumentError) { ScheduleCalculator.parse_send_at(24) }
        assert_raises(ArgumentError) { ScheduleCalculator.parse_send_at(-1) }
        assert_raises(ArgumentError) { ScheduleCalculator.parse_send_at("25") }
        assert_raises(ArgumentError) { ScheduleCalculator.parse_send_at("24:00") }
      end

      test "parse_send_at raises for invalid minute" do
        assert_raises(ArgumentError) { ScheduleCalculator.parse_send_at("10:60") }
        assert_raises(ArgumentError) { ScheduleCalculator.parse_send_at("10:-1") }
      end

      test "parse_send_at raises for invalid format" do
        assert_raises(ArgumentError) { ScheduleCalculator.parse_send_at([10, 30]) }
        assert_raises(ArgumentError) { ScheduleCalculator.parse_send_at({hour: 10}) }
      end

      test "calculate_scheduled_for returns nil when step has no send_at" do
        step = create_test_step(wait: 1.day, send_at: nil)
        result = ScheduleCalculator.calculate_scheduled_for(
          step: step,
          reference_time: Time.utc(2025, 1, 20, 14, 0),
          time_zone: "UTC"
        )
        assert_nil result
      end

      test "calculate_scheduled_for calculates correct time with wait and send_at" do
        step = create_test_step(wait: 2.days, send_at: "10:00")
        reference = Time.utc(2025, 1, 20, 14, 0) # Monday 14:00

        result = ScheduleCalculator.calculate_scheduled_for(
          step: step,
          reference_time: reference,
          time_zone: "UTC"
        )

        # Monday + 2 days = Wednesday, at 10:00
        assert_equal Time.utc(2025, 1, 22, 10, 0), result
      end

      test "calculate_scheduled_for respects timezone" do
        step = create_test_step(wait: 1.day, send_at: "10:00")
        reference = Time.utc(2025, 1, 20, 14, 0) # Monday 14:00 UTC

        result = ScheduleCalculator.calculate_scheduled_for(
          step: step,
          reference_time: reference,
          time_zone: "America/New_York" # EST = UTC-5
        )

        # Reference in EST: Monday 9:00 EST
        # +1 day = Tuesday
        # 10:00 EST = 15:00 UTC
        assert_equal Time.utc(2025, 1, 21, 15, 0), result
      end

      test "calculate_scheduled_for rolls to next day when send_at is in past and wait is 0" do
        step = create_test_step(wait: 0, send_at: "10:00")
        reference = Time.utc(2025, 1, 20, 14, 0) # 14:00, after 10:00

        result = ScheduleCalculator.calculate_scheduled_for(
          step: step,
          reference_time: reference,
          time_zone: "UTC"
        )

        # 10:00 is before 14:00, so roll to next day
        assert_equal Time.utc(2025, 1, 21, 10, 0), result
      end

      test "calculate_scheduled_for does not roll when send_at is in future" do
        step = create_test_step(wait: 0, send_at: "16:00")
        reference = Time.utc(2025, 1, 20, 14, 0) # 14:00, before 16:00

        result = ScheduleCalculator.calculate_scheduled_for(
          step: step,
          reference_time: reference,
          time_zone: "UTC"
        )

        # 16:00 is after 14:00, same day
        assert_equal Time.utc(2025, 1, 20, 16, 0), result
      end

      test "ensure_future_date returns scheduled_for when it is in the future" do
        scheduled_for = Time.utc(2025, 1, 21, 10, 0)
        now = Time.utc(2025, 1, 20, 14, 0)

        result = ScheduleCalculator.ensure_future_date(
          scheduled_for: scheduled_for,
          send_at: "10:00",
          time_zone: "UTC",
          now: now
        )

        assert_equal scheduled_for, result
      end

      test "ensure_future_date returns scheduled_for when same day and time passed" do
        scheduled_for = Time.utc(2025, 1, 20, 9, 0)  # Same day, 9:00
        now = Time.utc(2025, 1, 20, 10, 5)           # Same day, 10:05

        result = ScheduleCalculator.ensure_future_date(
          scheduled_for: scheduled_for,
          send_at: "9:00",
          time_zone: "UTC",
          now: now
        )

        # Same day - allow immediate send
        assert_equal scheduled_for, result
      end

      test "ensure_future_date rolls forward when scheduled_for is on a past date" do
        scheduled_for = Time.utc(2025, 1, 20, 16, 0)  # Monday 16:00
        now = Time.utc(2025, 1, 21, 10, 5)            # Tuesday 10:05

        result = ScheduleCalculator.ensure_future_date(
          scheduled_for: scheduled_for,
          send_at: "16:00",
          time_zone: "UTC",
          now: now
        )

        # Monday is past, roll to Tuesday 16:00
        assert_equal Time.utc(2025, 1, 21, 16, 0), result
      end

      test "ensure_future_date rolls to next day when send_at time already passed today" do
        scheduled_for = Time.utc(2025, 1, 20, 9, 0)   # Monday 9:00
        now = Time.utc(2025, 1, 21, 10, 5)            # Tuesday 10:05

        result = ScheduleCalculator.ensure_future_date(
          scheduled_for: scheduled_for,
          send_at: "9:00",
          time_zone: "UTC",
          now: now
        )

        # Monday is past, 9:00 < 10:05 today, roll to Wednesday 9:00
        assert_equal Time.utc(2025, 1, 22, 9, 0), result
      end

      test "ensure_future_date returns nil when scheduled_for is nil" do
        result = ScheduleCalculator.ensure_future_date(
          scheduled_for: nil,
          send_at: "10:00",
          time_zone: "UTC",
          now: Time.utc(2025, 1, 20, 14, 0)
        )

        assert_nil result
      end

      test "ensure_future_date returns original when no send_at" do
        scheduled_for = Time.utc(2025, 1, 20, 16, 0)
        now = Time.utc(2025, 1, 21, 10, 5)

        result = ScheduleCalculator.ensure_future_date(
          scheduled_for: scheduled_for,
          send_at: nil,
          time_zone: "UTC",
          now: now
        )

        # No send_at, keep original (legacy behavior)
        assert_equal scheduled_for, result
      end
    end
  end
end
