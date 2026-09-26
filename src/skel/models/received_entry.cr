# SPDX-License-Identifier: AGPL-3.0-or-later

module Skel
  # Écriture dont l'extension a reçu l'événement `entry.posted` : la trace
  # observable de l'abonnement. Interne : on la lit par `Skel::Api`.
  #
  # `entry_id` est l'identifiant de l'écriture dans le cœur, sans clé
  # étrangère : l'extension ne pose pas de contrainte sur une table du cœur
  # qu'elle ne lit que par `Partiduo::Api` (ADR-003 D5, D6).
  class ReceivedEntry < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :entry_id, :big_int, index: true
    # Auteur de l'écriture (`nil` : outil en ligne de commande).
    field :actor_user_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
