# SPDX-License-Identifier: AGPL-3.0-or-later

ENV["MARTEN_ENV"] = "test"

require "spec"

# Composition d'une distribution : l'interface (qui charge le cœur), le
# métier de l'extension, son interface Bulma, puis les réglages.
require "partiduo-ui-bulma/partiduo_ui"
require "../src/partiduo-skel"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"
# Migrations du cœur et de l'extension.
require "partiduo/cli"
require "../src/partiduo-skel/cli"

require "marten/spec"
require "marten_auth/spec"

# Comptes et navigateur de test de l'interface, créés par le contrat
# `Partiduo::Api::Auth` (DECISIONS D-SKEL-004).
require "../lib/partiduo-ui-bulma/spec/support/accounts"
require "../lib/partiduo-ui-bulma/spec/support/browser"

require "./support/**"
