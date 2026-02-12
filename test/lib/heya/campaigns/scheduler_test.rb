# frozen_string_literal: true

require "test_helper"

module Heya
  module Campaigns
    class SchedulerTest < ActiveSupport::TestCase
      def run_once
        Scheduler.new.run
      end

      def run_twice
        2.times {
          run_once
        }
      end

      def setup
        Heya.campaigns = []
      end

      test "it processes campaign actions in order" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default action: action
          user_type "Contact"
          step :one, wait: 5.days
          step :two, wait: 3.days
          step :three, wait: 2.days
        }
        contact = contacts(:one)
        campaign.add(contact, send_now: false)

        Timecop.travel(1.days.from_now)
        run_twice
        assert_mock action

        Timecop.travel(1.days.from_now)
        run_twice
        assert_mock action

        Timecop.travel(6.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign.steps.first)
        run_twice
        assert_mock action

        Timecop.travel(2.days.from_now)
        run_twice
        assert_mock action

        Timecop.travel(1.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign.steps.second)
        run_twice
        assert_mock action

        Timecop.travel(1.days.from_now)
        run_twice
        assert_mock action

        Timecop.travel(1.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign.steps.third)
        run_twice
        assert_mock action
      end

      test "it skips actions that don't match segments" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default wait: 0, action: action
          user_type "Contact"
          step :one, segment: ->(u) { u.traits["foo"] == "bar" }
        }
        contact = contacts(:one)
        campaign.add(contact, send_now: false)

        run_twice
        assert_mock action
      end

      test "it processes actions that match segments" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default wait: 0, action: action
          user_type "Contact"
          step :one, segment: ->(u) { u.traits["foo"] == "bar" }
        }
        contact = contacts(:one)
        contact.update_attribute(:traits, {foo: "bar"})
        campaign.add(contact, send_now: false)

        action.expect(:new, NullMail,
          user: contact,
          step: campaign.steps.first)

        run_twice
        assert_mock action
      end

      test "it waits for segments to match" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default action: action
          user_type "Contact"
          step :one, wait: 0
          step :two, wait: 2.days, segment: ->(u) { u.traits["foo"] == "bar" }
          step :three, wait: 1.day, segment: ->(u) { u.traits["bar"] == "baz" }
        }
        contact = contacts(:one)
        contact.update_attribute(:traits, {bar: "baz"})
        campaign.add(contact, send_now: false)

        action.expect(:new, NullMail,
          user: contact,
          step: campaign.steps.first)
        run_twice
        assert_mock action

        Timecop.travel(1.days.from_now)
        run_twice
        assert_mock action

        Timecop.travel(1.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign.steps.third)
        run_twice
        assert_mock action
      end

      test "it skips actions that don't match parent segments" do
        action = Minitest::Mock.new
        parent = create_test_campaign {
          segment { |u| u.traits["foo"] == "bar" }
        }
        child = create_test_campaign(name: "ChildCampaign", parent: parent) {
          default wait: 0, action: action
          user_type "Contact"
          step :one
        }
        contact = contacts(:one)
        child.add(contact, send_now: false)

        run_once
        assert_mock action
      end

      test "it processes actions that match parent segments" do
        action = Minitest::Mock.new
        parent = create_test_campaign {
          segment { |u| u.traits["foo"] == "bar" }
        }
        child = create_test_campaign(name: "ChildCampaign", parent: parent) {
          default wait: 0, action: action
          user_type "Contact"
          step :one
        }
        contact = contacts(:one)
        contact.update_attribute(:traits, {foo: "bar"})
        child.add(contact, send_now: false)

        action.expect(:new, NullMail,
          user: contact,
          step: child.steps.first)

        run_once
        assert_mock action
      end

      test "it skips actions that don't match campaign segment" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default wait: 0, action: action
          user_type "Contact"
          segment { |u| u.traits["foo"] == "foo" }
          step :one
        }
        contact = contacts(:one)
        campaign.add(contact, send_now: false)

        run_once

        assert_mock action
      end

      test "it processes actions that match campaign segment" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default wait: 0, action: action
          user_type "Contact"
          segment { |u| u.traits["foo"] == "foo" }
          step :one
        }
        contact = contacts(:one)
        contact.update_attribute(:traits, {foo: "foo"})
        campaign.add(contact, send_now: false)

        action.expect(:new, NullMail,
          user: contact,
          step: campaign.steps.first)

        run_once

        assert_mock action
      end

      test "it removes contacts from campaign at end" do
        campaign = create_test_campaign {
          default wait: 0
          user_type "Contact"
          step :one
          step :two
          step :three
        }
        contact = contacts(:one)
        campaign.add(contact, send_now: false)

        assert CampaignMembership.where(campaign_gid: campaign.gid, user: contact).exists?

        run_once
        run_once
        run_once

        refute CampaignMembership.where(campaign_gid: campaign.gid, user: contact).exists?
      end

      test "it processes campaign actions concurrently" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default wait: 0, action: action
          user_type "Contact"
          step :one
        }
        contact = contacts(:one)
        campaign.add(contact, send_now: false)

        action.expect(:new, NullMail,
          user: contact,
          step: campaign.steps.first)

        # Make sure missing constants are autoloaded >:]
        run_once

        20.times.map {
          Thread.new {
            run_once
          }
        }.each(&:join)

        assert_mock action
      end

      test "it processes multiple campaign actions in order" do
        action = Minitest::Mock.new
        campaign1 = create_test_campaign(name: "TestCampaign1") {
          default action: action
          user_type "Contact"
          step :one, wait: 5.days
        }
        campaign2 = create_test_campaign(name: "TestCampaign2") {
          default action: action
          user_type "Contact"
          step :one, wait: 3.days
        }
        campaign3 = create_test_campaign(name: "TestCampaign3") {
          default action: action
          user_type "Contact"
          step :one, wait: 2.days
        }
        contact = contacts(:one)
        campaign3.add(contact, send_now: false)
        campaign2.add(contact, send_now: false)
        campaign1.add(contact, send_now: false)

        Heya.configure do |config|
          config.campaigns.priority = [
            "TestCampaign1",
            "TestCampaign2",
            "TestCampaign3"
          ]
        end

        Timecop.travel(1.days.from_now)
        run_twice
        assert_mock action

        Timecop.travel(1.days.from_now)
        run_twice
        assert_mock action

        Timecop.travel(6.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign1.steps.first)
        run_twice
        assert_mock action

        Timecop.travel(2.days.from_now)
        run_twice
        assert_mock action

        Timecop.travel(1.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign2.steps.first)
        run_twice
        assert_mock action

        Timecop.travel(1.days.from_now)
        run_twice
        assert_mock action

        Timecop.travel(1.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign3.steps.first)
        run_twice
        assert_mock action
      end

      test "it processes concurrent campaign actions concurrently" do
        action = Minitest::Mock.new
        campaign1 = create_test_campaign(name: "TestCampaign1") {
          default action: action
          user_type "Contact"
          step :one, wait: 5.days
          step :two, wait: 2.days
          step :three, wait: 1.days
        }
        campaign2 = create_test_campaign(name: "TestCampaign2") {
          default action: action
          user_type "Contact"
          step :one, wait: 3.days
          step :two, wait: 3.days
        }
        campaign3 = create_test_campaign(name: "TestCampaign3") {
          default action: action
          user_type "Contact"
          step :one, wait: 2.days
        }
        contact = contacts(:one)
        campaign1.add(contact, send_now: false, concurrent: true)
        campaign2.add(contact, send_now: false)
        campaign3.add(contact, send_now: false)

        Timecop.travel(2.days.from_now)
        run_once
        assert_mock action

        Timecop.travel(3.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign1.steps.first)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign2.steps.first)
        run_once
        assert_mock action

        Timecop.travel(1.days.from_now)
        run_once
        assert_mock action

        Timecop.travel(1.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign1.steps.second)
        run_once
        assert_mock action

        Timecop.travel(1.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign1.steps.third)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign2.steps.second)
        run_once
        assert_mock action

        Timecop.travel(1.days.from_now)
        run_once
        assert_mock action

        Timecop.travel(1.days.from_now)
        action.expect(:new, NullMail,
          user: contact,
          step: campaign3.steps.first)
        run_once
        assert_mock action
      end

      test "it deletes orphaned campaign memberships" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          user_type "Contact"
          step :one, wait: 0
          step :two, wait: 0
          step :three, wait: 0
        }
        contact1 = contacts(:one)
        contact2 = contacts(:two)
        campaign.add(contact1, send_now: false)
        campaign.add(contact2, send_now: false)
        membership = CampaignMembership.where(
          campaign_gid: campaign.gid,
          user_type: "Contact"
        )

        run_once

        assert membership.where(user_id: contact1.id).exists?
        assert membership.where(user_id: contact2.id).exists?

        contact1.destroy

        run_once

        refute membership.where(user_id: contact1.id).exists?
        assert membership.where(user_id: contact2.id).exists?

        assert_mock action
      end

      test "it immediately skips steps that have receipts" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default action: action
          user_type "Contact"
          step :one, wait: 0
          step :two, wait: 3.days
          step :three, wait: 2.days
        }

        contact = contacts(:one)

        CampaignReceipt.create!(
          user: contact,
          step_gid: campaign.steps[1].gid
        )

        action.expect(:new, NullMail,
          user: contact,
          step: campaign.steps.first)

        campaign.add(contact)

        membership = CampaignMembership
          .where(user: contact, campaign_gid: campaign.gid)
          .first

        assert_equal campaign.steps[2].gid, membership.step_gid
      end

      # send_at scheduling tests

      test "it schedules steps at specified send_at time" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default action: action
          user_type "Contact"
          time_zone "UTC"
          step :one, wait: 1.day, send_at: "10:00"
          step :two, wait: 1.day, send_at: "14:00"
        }
        contact = contacts(:one)

        Timecop.freeze(Time.utc(2025, 1, 20, 8, 0)) do
          campaign.add(contact, send_now: false)
        end

        membership = CampaignMembership.where(user: contact, campaign_gid: campaign.gid).first
        # Monday 8:00 + 1 day = Tuesday, at 10:00
        assert_equal Time.utc(2025, 1, 21, 10, 0), membership.scheduled_for
      end

      test "it postpones campaign to next day when first step send_at is in past" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default action: action
          user_type "Contact"
          time_zone "UTC"
          step :one, wait: 0, send_at: "10:00"
          step :two, wait: 0, send_at: "14:00"
          step :three, wait: 0, send_at: "16:00"
        }
        contact = contacts(:one)

        # User joins at 18:00, after all send_at times
        Timecop.freeze(Time.utc(2025, 1, 20, 18, 0)) do
          campaign.add(contact, send_now: false)
        end

        membership = CampaignMembership.where(user: contact, campaign_gid: campaign.gid).first
        # 10:00 is past, so step 1 should be scheduled for next day
        assert_equal Time.utc(2025, 1, 21, 10, 0), membership.scheduled_for
      end

      test "it sends multiple steps on same day at different times" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default action: action
          user_type "Contact"
          time_zone "UTC"
          step :one, wait: 0, send_at: "10:00"
          step :two, wait: 0, send_at: "14:00"
          step :three, wait: 0, send_at: "16:00"
        }
        contact = contacts(:one)

        # User joins at 8:00
        Timecop.freeze(Time.utc(2025, 1, 20, 8, 0)) do
          campaign.add(contact, send_now: false)
        end

        membership = CampaignMembership.where(user: contact, campaign_gid: campaign.gid).first
        assert_equal Time.utc(2025, 1, 20, 10, 0), membership.scheduled_for

        # Process step 1 at 10:05
        Timecop.freeze(Time.utc(2025, 1, 20, 10, 5)) do
          action.expect(:new, NullMail, user: contact, step: campaign.steps[0])
          run_once
        end

        membership.reload
        assert_equal campaign.steps[1].gid, membership.step_gid
        assert_equal Time.utc(2025, 1, 20, 14, 0), membership.scheduled_for

        # Process step 2 at 14:05
        Timecop.freeze(Time.utc(2025, 1, 20, 14, 5)) do
          action.expect(:new, NullMail, user: contact, step: campaign.steps[1])
          run_once
        end

        membership.reload
        assert_equal campaign.steps[2].gid, membership.step_gid
        assert_equal Time.utc(2025, 1, 20, 16, 0), membership.scheduled_for

        assert_mock action
      end

      test "skipped step does not delay subsequent steps" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default action: action
          user_type "Contact"
          time_zone "UTC"
          step :one, wait: 2.days, send_at: "11:00"
          step :two, wait: 2.days, send_at: "10:00", segment: ->(u) { u.traits["premium"] }
          step :three, wait: 2.days, send_at: "9:00"
        }
        contact = contacts(:one)
        # Contact is NOT premium

        # User joins Monday 14:00
        Timecop.freeze(Time.utc(2025, 1, 20, 14, 0)) do
          campaign.add(contact, send_now: false)
        end

        membership = CampaignMembership.where(user: contact, campaign_gid: campaign.gid).first
        # Monday + 2 days = Wednesday, at 11:00
        assert_equal Time.utc(2025, 1, 22, 11, 0), membership.scheduled_for

        # Process step 1 at Wednesday 11:05
        Timecop.freeze(Time.utc(2025, 1, 22, 11, 5)) do
          action.expect(:new, NullMail, user: contact, step: campaign.steps[0])
          run_once
        end

        membership.reload
        assert_equal campaign.steps[1].gid, membership.step_gid
        # Wednesday 11:05 + 2 days = Friday, at 10:00
        assert_equal Time.utc(2025, 1, 24, 10, 0), membership.scheduled_for

        # Process step 2 at Friday 10:05 - should be SKIPPED (not premium)
        Timecop.freeze(Time.utc(2025, 1, 24, 10, 5)) do
          run_once
          # No action expectation - step is skipped
        end

        membership.reload
        assert_equal campaign.steps[2].gid, membership.step_gid
        # Step 3 should use last_sent_at (Wed 11:05) as reference
        # Wed 11:05 + 2 days = Friday, at 9:00
        # Friday 9:00 < Friday 10:05 (now), same day - send immediately
        # The scheduled_for will be Fri 9:00 but scheduler will pick it up immediately
        assert_equal Time.utc(2025, 1, 24, 9, 0), membership.scheduled_for

        # Step 3 should be processed immediately (Fri 9:00 < Fri 10:05)
        action.expect(:new, NullMail, user: contact, step: campaign.steps[2])
        Timecop.freeze(Time.utc(2025, 1, 24, 10, 5)) do
          run_once
        end

        assert_mock action
      end

      test "skipped step with past date rolls forward to next occurrence" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default action: action
          user_type "Contact"
          time_zone "UTC"
          step :one, wait: 0, send_at: "14:00"
          step :two, wait: 0, send_at: "10:00", segment: ->(u) { u.traits["premium"] }
          step :three, wait: 0, send_at: "16:00"
        }
        contact = contacts(:one)
        # Contact is NOT premium

        # User joins Monday 8:00
        Timecop.freeze(Time.utc(2025, 1, 20, 8, 0)) do
          campaign.add(contact, send_now: false)
        end

        membership = CampaignMembership.where(user: contact, campaign_gid: campaign.gid).first
        assert_equal Time.utc(2025, 1, 20, 14, 0), membership.scheduled_for

        # Process step 1 at Monday 14:05
        Timecop.freeze(Time.utc(2025, 1, 20, 14, 5)) do
          action.expect(:new, NullMail, user: contact, step: campaign.steps[0])
          run_once
        end

        membership.reload
        assert_equal campaign.steps[1].gid, membership.step_gid
        # 10:00 < 14:05, so rolls to next day
        assert_equal Time.utc(2025, 1, 21, 10, 0), membership.scheduled_for

        # Process step 2 at Tuesday 10:05 - should be SKIPPED
        Timecop.freeze(Time.utc(2025, 1, 21, 10, 5)) do
          run_once
        end

        membership.reload
        assert_equal campaign.steps[2].gid, membership.step_gid
        # Step 3: reference = Monday 14:05 (last_sent_at), send_at = 16:00
        # Monday 16:00 > Monday 14:05, so no roll for reference check
        # BUT Monday 16:00 < Tuesday 10:05 (now), past DATE
        # Should roll forward to Tuesday 16:00
        assert_equal Time.utc(2025, 1, 21, 16, 0), membership.scheduled_for

        # Step 3 should be processed at Tuesday 16:05
        Timecop.freeze(Time.utc(2025, 1, 21, 16, 5)) do
          action.expect(:new, NullMail, user: contact, step: campaign.steps[2])
          run_once
        end

        assert_mock action
      end

      test "step with later send_at followed by step with earlier send_at sends on different days" do
        action = Minitest::Mock.new
        campaign = create_test_campaign {
          default action: action
          user_type "Contact"
          time_zone "UTC"
          step :one, wait: 1.day, send_at: "11:00"
          step :two, wait: 1.day, send_at: "10:00"
        }
        contact = contacts(:one)

        # User joins Monday 14:00
        Timecop.freeze(Time.utc(2025, 1, 20, 14, 0)) do
          campaign.add(contact, send_now: false)
        end

        membership = CampaignMembership.where(user: contact, campaign_gid: campaign.gid).first
        # Monday 14:00 + 1 day = Tuesday, at 11:00
        assert_equal Time.utc(2025, 1, 21, 11, 0), membership.scheduled_for

        # Process step 1 at Tuesday 11:05
        Timecop.freeze(Time.utc(2025, 1, 21, 11, 5)) do
          action.expect(:new, NullMail, user: contact, step: campaign.steps[0])
          run_once
        end

        membership.reload
        assert_equal campaign.steps[1].gid, membership.step_gid
        # Step 2: reference = Tuesday 11:05 (last_sent_at) + 1 day = Wednesday, at 10:00
        assert_equal Time.utc(2025, 1, 22, 10, 0), membership.scheduled_for

        # Verify step 2 is NOT sent at Tuesday 11:10 (next cron run same day)
        Timecop.freeze(Time.utc(2025, 1, 21, 11, 10)) do
          run_once
        end
        assert_mock action # No action expected - step 2 should not fire yet

        # Step 2 should be sent at Wednesday 10:05
        Timecop.freeze(Time.utc(2025, 1, 22, 10, 5)) do
          action.expect(:new, NullMail, user: contact, step: campaign.steps[1])
          run_once
        end

        assert_mock action
      end

      test "campaign-level send_at is used as fallback for steps" do
        campaign = create_test_campaign {
          user_type "Contact"
          time_zone "UTC"
          send_at "10:00"
          step :one, wait: 1.day
          step :two, wait: 1.day, send_at: "14:00"
        }

        assert_equal "10:00", campaign.steps[0].send_at
        assert_equal "14:00", campaign.steps[1].send_at
      end
    end
  end
end
