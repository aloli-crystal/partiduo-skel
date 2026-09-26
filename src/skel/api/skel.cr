# SPDX-License-Identifier: AGPL-3.0-or-later

module Skel
  # Contrat public de l'extension, sur le modèle de `Partiduo::Api` (DECISIONS
  # C2) : acteur en premier argument, contrôle d'accès en première ligne,
  # objets de vue immuables, jamais un modèle Marten en retour. L'interface
  # de l'extension (`ui/bulma/`) ne voit que ce module.
  module Api
    MODULE_CODE = Skel::CODE
    VIEW        = "skel.view"

    # Nombre d'écritures listées au plus par `received_entries`.
    DEFAULT_LIMIT = 20

    # Écriture reçue par l'abonnement à `entry.posted`.
    record ReceivedEntryView, id : Int64, entry_id : Int64, actor_user_id : Int64?, received_at : Time

    # Résumé affiché par la page de l'extension.
    record SummaryView, count : Int64, latest : Array(ReceivedEntryView)

    # Écritures reçues, de la plus récente à la plus ancienne.
    # Permission `skel.view` ; `ModuleDisabled` si l'extension est inactive.
    def self.received_entries(actor : Partiduo::Api::Actor, limit : Int32 = DEFAULT_LIMIT) : Array(ReceivedEntryView)
      Partiduo::Api::Guard.authorize!(actor, VIEW, module_code: MODULE_CODE)
      latest(limit)
    end

    # Nombre d'écritures reçues et les plus récentes. Permission `skel.view`.
    def self.summary(actor : Partiduo::Api::Actor, limit : Int32 = DEFAULT_LIMIT) : SummaryView
      Partiduo::Api::Guard.authorize!(actor, VIEW, module_code: MODULE_CODE)
      SummaryView.new(ReceivedEntry.all.count.to_i64, latest(limit))
    end

    private def self.latest(limit : Int32) : Array(ReceivedEntryView)
      ReceivedEntry.all.order("-id")[0...limit.clamp(1, 500)].to_a.map { |row| view(row) }
    end

    private def self.view(row : ReceivedEntry) : ReceivedEntryView
      ReceivedEntryView.new(
        id: row.id!.to_i64,
        entry_id: row.entry_id!.to_i64,
        actor_user_id: row.actor_user_id.try(&.to_i64),
        received_at: row.created_at!,
      )
    end
  end
end
