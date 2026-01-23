# Upgrading Heya

## Unreleased (send_at feature)

If you're upgrading from a previous version and want to use the new `send_at`
feature for scheduling messages at specific times, you will need to run the upgrade
generator:

```bash
rails generate heya:upgrade
rails db:migrate
```

This adds the `scheduled_for` column and a partial index to the `heya_campaign_memberships` table.

Alternatively, you can create the migration manually:

```ruby
class AddScheduledForToHeyaCampaignMemberships < ActiveRecord::Migration[7.0]
  def change
    add_column :heya_campaign_memberships, :scheduled_for, :datetime
    add_index :heya_campaign_memberships, :scheduled_for, where: "scheduled_for IS NOT NULL"
  end
end
```

**Note:** Existing campaigns will continue to work without this migration using the
legacy `last_sent_at + wait` behavior. The new `scheduled_for` column is only required
if you want to use the `send_at` option for time-based scheduling.

See [CHANGELOG.md](./CHANGELOG.md) for more info.

## 0.4.0
If you're upgrading from Heya `< 0.4`, you will need the following migration:

```
class AddStepGidToHeyaCampaignMemberships < ActiveRecord::Migration[6.0]
  def up
    add_column :heya_campaign_memberships, :step_gid, :string
    Heya::CampaignMembership.migrate_next_step!
    change_column :heya_campaign_memberships, :step_gid, :string, null: false
  end

  def down
    remove_column :heya_campaign_memberships, :step_gid, :string
  end
end
```

See [CHANGELOG.md](./CHANGELOG.md) for more info.
