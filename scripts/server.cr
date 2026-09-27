# SPDX-License-Identifier: AGPL-3.0-or-later

# Serveur de développement composé comme une distribution : cœur, interface
# Bulma et SKEL (page /ext/SKEL/). `crystal run scripts/server.cr`, avec
# DATABASE_URL et PARTIDUO_MODULES de l'instance ; port : PORT (défaut 8000).
require "partiduo-ui-bulma/partiduo_ui"
require "../src/partiduo-skel"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"

Marten.start
