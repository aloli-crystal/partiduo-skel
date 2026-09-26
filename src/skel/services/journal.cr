# SPDX-License-Identifier: AGPL-3.0-or-later

module Skel
  # Consigne les événements reçus (interne ; appelé par l'abonnement du
  # manifeste).
  module Journal
    # Enregistre l'écriture d'un `entry.posted`. Appelé dans la transaction
    # de l'écriture : si celle-ci est annulée, la trace l'est aussi. Un
    # identifiant illisible lève `ArgumentError`, ce qui annule l'opération
    # (un abonné ne masque pas une incohérence du cœur).
    def self.record(event : Partiduo::Events::Event) : Nil
      entry_id = event["entry_id"].to_i64? ||
                 raise ArgumentError.new("entry.posted : entry_id illisible « #{event["entry_id"]} »")
      ReceivedEntry.create!(entry_id: entry_id, actor_user_id: event.actor_user_id)
      nil
    end
  end
end
