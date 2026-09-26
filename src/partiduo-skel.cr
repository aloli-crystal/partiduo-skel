# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-skel` : le métier de l'extension de
# référence (manifeste, modèle, abonnement, contrat `Skel::Api`), sans
# interface. L'interface Bulma est dans `ui/bulma/`, requise à part par la
# distribution : `require "partiduo-skel/ui/bulma"`.
#
# La distribution ajoute ensuite `Skel::INSTALLED_APPS` à ses applications
# Marten, et `require "partiduo-skel/cli"` à sa ligne de commande (migrations).
require "partiduo"

require "./skel/app"
