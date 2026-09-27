# SPDX-License-Identifier: AGPL-3.0-or-later

module Skel
  module Ui
    # Page de l'extension (`/ext/SKEL/`, route `skel:index`) : nombre
    # d'écritures reçues par l'abonnement à `entry.posted` et les plus
    # récentes. Écran de l'application (coquille, menu) ; l'accès a déjà été
    # contrôlé par `PartiduoUi::ExtensionHandler`, et `Skel::Api` le vérifie
    # encore.
    class IndexHandler < PartiduoUi::ScreenHandler
      def get
        summary = Skel::Api.summary(current.actor)
        entries = summary.latest.map do |entry|
          {
            "entry_id"    => entry.entry_id.to_s,
            "received_at" => fmt.datetime(entry.received_at),
          }
        end
        page("skel/index.html", {
          "received" => I18n.t("skel_ui.index.received", count: summary.count),
          "entries"  => listed(entries),
        })
      end
    end
  end
end
