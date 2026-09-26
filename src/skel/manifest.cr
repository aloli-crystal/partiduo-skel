# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension (ADR-003 D2, `doc/api/modules.adoc` du cœur).
#
# * `permission "skel.view"` : voir la page de l'extension ; libellé i18n
#   `skel.permissions.view`, coché par l'administrateur dans les profils (D4).
# * `menu "SKEL"` sous la rubrique `EXTENSION` du socle : route `skel:index`,
#   que l'interface monte sous `/ext/SKEL/` (D3) ; libellé `skel.menu.skel`.
# * `on("entry.posted")` : chaque écriture enregistrée est consignée dans la
#   table `skel_received_entry` (D7), dans la transaction de l'écriture.
Partiduo::Modules.register do
  code "SKEL"
  name "skel.module.name"
  version "0.1.0"
  requires_core "~> 0.1"

  permission "skel.view"

  menu "SKEL", parent: "EXTENSION", order: 100, route: "skel:index", permission: "skel.view"

  ui "bulma", path: "ui/bulma"

  on("entry.posted") { |event| Skel::Journal.record(event) }
end
