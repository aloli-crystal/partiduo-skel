# SPDX-License-Identifier: AGPL-3.0-or-later

class Migration::Skel::V0001 < Marten::Migration
  def plan
    create_table :skel_received_entry do
      column :id, :big_int, primary_key: true, auto: true
      column :entry_id, :big_int, index: true
      column :actor_user_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end
  end
end
