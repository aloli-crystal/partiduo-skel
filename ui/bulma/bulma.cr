# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension (ADR-005 D4) : routes, handlers, gabarits et
# libellés d'écran, montés par `partiduo-ui-bulma` sous `/ext/SKEL/`
# (ADR-003 D3). La distribution la requiert après l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-skel"
# require "partiduo-skel/ui/bulma"
# ```
#
# puis ajoute `Skel::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Skel::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`, exemple « ne parle au
# cœur, depuis ui/bulma, que par Partiduo::Api ») ; le contrôle d'accès
# est fait par l'interface, avant le handler, à partir du manifeste.
require "../../src/partiduo-skel"

require "./handlers/**"

module Skel
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/skel/`) et libellés d'écran (`locales/`, clés `skel_ui.*`).
    class App < Marten::App
      label "skel_ui"
    end

    INSTALLED_APPS = [Skel::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/SKEL/`, nommées `skel:<nom>` : `skel:index`
    # est la route que cite le menu du manifeste.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Skel::Ui::IndexHandler, name: "index"
    end
  end
end

# Toutes les routes de l'extension exigent `skel.view`, déclarée par le
# manifeste. Sans `permission:`, l'interface appliquerait celle de l'entrée
# de menu qui porte la route ; la citer ici rend la règle explicite.
PartiduoUi::Extensions.mount Skel::CODE, Skel::Ui::ROUTES, permission: Skel::Api::VIEW
