# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Extension SKEL : abonnement à entry.posted (ADR-003 D7)" do
  it "n'est pas appelée tant qu'elle est inactive" do
    Partiduo::Events.subscribers("entry.posted").should_not contain(Skel::CODE)
    post_entry(41_i64)
    Skel::ReceivedEntry.all.count.should eq(0)
  end

  it "consigne chaque écriture enregistrée, avec son auteur" do
    activate_skel
    Partiduo::Events.subscribers("entry.posted").should contain(Skel::CODE)

    post_entry(42_i64, actor_user_id: 7_i64)
    post_entry(43_i64)

    summary = Skel::Api.summary(skel_viewer)
    summary.count.should eq(2)
    summary.latest.map(&.entry_id).should eq([43_i64, 42_i64])
    summary.latest.map(&.actor_user_id).should eq([nil, 7_i64])
    Skel::Api.received_entries(skel_viewer, limit: 1).map(&.entry_id).should eq([43_i64])
  end

  it "est annulée avec la transaction de l'écriture" do
    activate_skel
    Marten::DB::Connection.default.transaction do
      post_entry(44_i64)
      Skel::ReceivedEntry.all.count.should eq(1)
      raise Marten::DB::Errors::Rollback.new
    end
    Skel::ReceivedEntry.all.count.should eq(0)
  end

  it "annule l'opération si la charge utile est incohérente" do
    activate_skel
    expect_raises(ArgumentError, /entry_id illisible/) do
      Partiduo::Events.publish("entry.posted", {"entry_id" => "abc"})
    end
    Skel::ReceivedEntry.all.count.should eq(0)
  end
end
