# SPDX-License-Identifier: AGPL-3.0-or-later

# Démonstration de bout en bout du jalon P + 0 + 1 sur une instance
# provisionnée par `bin/partiduo-provision` (cœur + interface Bulma + SKEL,
# composés comme une distribution).
#
# Les requêtes HTTP traversent la vraie pile de Marten (gestion des erreurs,
# middlewares — session, CSRF, langue… —, routage, handlers, gabarits), en
# mémoire : le bac à sable n'ouvre pas de port (BLOCAGES B-UI-001). Les
# formulaires sont envoyés avec le jeton CSRF lu dans la page, comme un
# navigateur.
#
# ```
# DATABASE_URL='postgres:///partiduo_j1_fr?host=/tmp' crystal run scripts/demo_jalon1.cr -- \
#   --host=demo-fr.partiduo.localhost --email=admin@demo-fr.test \
#   --invitation=https://demo-fr.partiduo.localhost/invitation/<jeton>
# ```
#
# Sans `--invitation`, l'administrateur se connecte avec `--password` (compte
# déjà enrôlé : second passage). Code de sortie 1 si une étape échoue.
ENV["MARTEN_ENV"] ||= "development"

require "http/client"
require "option_parser"
require "partiduo-ui-bulma/partiduo_ui"
require "../src/partiduo-skel"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"

module Demo
  # Navigateur en mémoire : cookies, en-tête Host de l'instance, jeton CSRF
  # repris de la dernière page lue.
  class Browser
    getter jar = ::HTTP::Cookies.new
    @csrf : String? = nil

    def initialize(@host : String, @locale : String = "fr")
      @chain = ::HTTP::Server.build_middleware([
        Marten::Server::Handlers::Error.new,
        Marten::Server::Handlers::Middleware.new,
        Marten::Server::Handlers::Routing.new,
      ] of ::HTTP::Handler)
    end

    def get(path : String) : ::HTTP::Client::Response
      perform("GET", path)
    end

    # Formulaire : la page `form_path` est lue d'abord (jeton CSRF).
    def submit(form_path : String, data : Hash(String, String), action : String = form_path) : ::HTTP::Client::Response
      get(form_path)
      post(action, data)
    end

    def post(path : String, data : Hash(String, String) = {} of String => String) : ::HTTP::Client::Response
      form = data.dup
      form["csrftoken"] = @csrf.to_s
      perform("POST", path, URI::Params.encode(form))
    end

    def follow(response : ::HTTP::Client::Response) : ::HTTP::Client::Response
      get(response.headers["Location"])
    end

    private def perform(method : String, path : String, body : String? = nil) : ::HTTP::Client::Response
      headers = ::HTTP::Headers{"Host" => @host, "Accept-Language" => @locale, "User-Agent" => "partiduo-demo"}
      headers["Content-Type"] = "application/x-www-form-urlencoded" if body
      request = ::HTTP::Request.new(method, path, headers, body)
      @jar.add_request_headers(request.headers)
      io = IO::Memory.new
      response = ::HTTP::Server::Response.new(io)
      @chain.call(::HTTP::Server::Context.new(request, response))
      response.close
      io.rewind
      result = ::HTTP::Client::Response.from_io(io)
      result.cookies.each do |cookie|
        cookie.expired? || cookie.value.empty? ? @jar.delete(cookie.name) : (@jar << cookie)
      end
      if token = result.body.match(/name="csrftoken" value="([^"]+)"/).try(&.[1])
        @csrf = token
      end
      result
    end
  end

  class Run
    getter failures = 0

    def initialize(@host : String, @email : String, @password : String, @invitation : String?)
    end

    def check(label : String, & : -> Bool | String) : Nil
      outcome = begin
        yield
      rescue ex
        "#{ex.class}: #{ex.message}"
      end
      if outcome == true
        puts "  ok      #{label}"
      else
        @failures += 1
        puts "  ÉCHEC   #{label}#{outcome.is_a?(String) ? " — #{outcome}" : ""}"
      end
    end

    def expect(response : ::HTTP::Client::Response, status : Int32, *texts) : Bool | String
      return "HTTP #{response.status_code} au lieu de #{status}" unless response.status_code == status
      body = HTML.unescape(response.body)
      missing = texts.reject { |text| body.includes?(text) }
      missing.empty? ? true : "absent de la page : #{missing.join(" | ")}"
    end

    def system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def run : Nil
      settings = Partiduo::Api::Core.settings(system)
      regime = settings.tax_regime
      puts "== Instance #{@host} : « #{settings.company_name} », régime #{regime}, " \
           "modules actifs #{Partiduo::Modules::State.active_codes.to_a.sort!.join(", ")}"

      admin = Browser.new(@host)
      enroll(admin)
      reference_by_ui(admin, regime)
      reference_by_api(regime)
      skel(admin)
    end

    # --- Enrôlement et connexion ---------------------------------------------

    private def enroll(browser : Browser) : Nil
      puts "-- Enrôlement et connexion"
      check("page de connexion") { expect(browser.get("/login"), 200, "Connexion") }
      check("tableau de bord refusé sans session (redirection vers /login)") do
        response = browser.get("/")
        response.status_code == 302 && response.headers["Location"].starts_with?("/login") || "HTTP #{response.status_code}"
      end
      if invitation = @invitation
        path = invitation.includes?("/invitation/") ? "/invitation/#{invitation.split("/invitation/").last}" : "/invitation/#{invitation}"
        check("invitation acceptée, session d'enrôlement") do
          response = browser.submit(path, {} of String => String)
          response.status_code == 302 && response.headers["Location"] == "/account/enrollment" || "HTTP #{response.status_code}"
        end
        check("écran d'enrôlement (passkey proposée, repli mot de passe)") do
          expect(browser.get("/account/enrollment"), 200, @email)
        end
        check("mot de passe choisi, session d'enrôlement fermée") do
          response = browser.post("/account/enrollment", {"new_password" => @password, "confirmation" => @password})
          response.status_code == 302 && response.headers["Location"] == "/login" ||
            "HTTP #{response.status_code} #{HTML.unescape(response.body)[/is-danger[^<]*<[^<]*/]?}"
        end
        check("invitation à usage unique") do
          fresh = Browser.new(@host)
          expect(fresh.submit(path, {} of String => String), 422)
        end
      end
      check("connexion par mot de passe") do
        response = browser.submit("/login", {"email" => @email, "password" => @password})
        response.status_code == 302 || "HTTP #{response.status_code}"
      end
      check("tableau de bord") do
        expect(browser.get("/"), 200, Partiduo::Api::Core.settings(system).company_name)
      end
    end

    # --- Référentiel par l'interface -------------------------------------------

    private def reference_by_ui(browser : Browser, regime : String) : Nil
      puts "-- Référentiel par l'interface (partiduo-ui-bulma)"
      stamp = Time.local.to_s("%H%M%S")
      chart_by_ui(browser, regime, stamp)
      cards_by_ui(browser, regime, stamp)
      fiscal_year_by_ui(browser)
      ledgers_by_ui(browser, stamp)
    end

    private def chart_by_ui(browser : Browser, regime : String, stamp : String) : Nil
      if regime == "fr"
        check("plan comptable FR (PCG) : classes et comptes") do
          next "classe 1" unless expect(browser.get("/accounting/chart"), 200, "Plan comptable", ">101</a>", "Capital") == true
          expect(browser.get("/accounting/chart?class=4"), 200, ">410</a>", ">4456</a>")
        end
      else
        check("plan comptable BE (PCMN) : classes et comptes") do
          next "classe 1" unless expect(browser.get("/accounting/chart"), 200, "Plan comptable", ">100</a>", "Capital souscrit") == true
          expect(browser.get("/accounting/chart?class=4"), 200, ">400</a>", ">451</a>")
        end
      end

      parent = regime == "fr" ? "410" : "400"
      number = "#{parent}9#{stamp}"
      check("compte #{number} créé et consulté") do
        response = browser.submit("/accounting/chart/new", {"number" => number, "label" => "Clients démo #{stamp}", "direct_use" => "1"})
        next "HTTP #{response.status_code}" unless response.status_code == 302
        expect(browser.follow(response), 200, "Compte #{number} créé.", "Clients démo #{stamp}", ">#{parent} — ")
      end
      check("compte refusé sans numéro (422, message par champ)") do
        expect(browser.submit("/accounting/chart/new", {"number" => "", "label" => ""}), 422, "Indiquez le numéro du compte.")
      end
    end

    private def cards_by_ui(browser : Browser, regime : String, stamp : String) : Nil
      customer = Partiduo::Api::Cards.category_by_code(system, "CUSTOMER") || raise "catégorie CUSTOMER absente"
      name = "Client démo #{stamp}"
      card = {"category_id" => customer.id.to_s, "name" => name, "enabled" => "1", "email" => "client#{stamp}@exemple.test",
              "address.city" => regime == "fr" ? "Nantes" : "Namur", "address.postcode" => regime == "fr" ? "44000" : "5000"}
      card["siren"] = "732829320" if regime == "fr"
      card["vat_number"] = "BE0417497106" if regime == "be"
      card_id = 0_i64
      check("fiche client créée et consultée") do
        response = browser.submit("/cards/new?category=#{customer.id}", card, "/cards/new")
        next "HTTP #{response.status_code} #{HTML.unescape(response.body).scan(/is-danger">([^<]+)/).map(&.[1]).join(" | ")}" unless response.status_code == 302
        card_id = response.headers["Location"].split('/').last.to_i64
        expect(browser.follow(response), 200, name, regime == "fr" ? "44000 Nantes" : "5000 Namur")
      end
      check("liste des tiers, recherche") { expect(browser.get("/cards?q=#{URI.encode_www_form(name)}"), 200, name) }
      check("fiche client relue (#{card_id})") { expect(browser.get("/cards/#{card_id}"), 200, name) }
    end

    private def fiscal_year_by_ui(browser : Browser) : Nil
      year = (Partiduo::Api::Core.fiscal_years(system).max_of?(&.year) || Time.local.year - 1) + 1
      check("exercice #{year} créé (12 périodes) et consulté") do
        response = browser.submit("/fiscal-years", {"year" => year.to_s, "start_year" => year.to_s, "start_month" => "1",
                                                    "months" => "12", "label" => ""})
        next "HTTP #{response.status_code}" unless response.status_code == 302
        page = browser.follow(response)
        fy = Partiduo::Api::Core.fiscal_years(system).find { |item| item.year == year }
        next "exercice absent" unless fy
        next "#{fy.periods.size} périodes" unless fy.periods.size == 12
        expect(page, 200, year.to_s)
      end
      check("liste des exercices") { expect(browser.get("/fiscal-years"), 200, year.to_s) }
    end

    private def ledgers_by_ui(browser : Browser, stamp : String) : Nil
      check("journaux par défaut A01, V01, F01, O01") do
        expect(browser.get("/accounting/ledgers"), 200, ">A01</a>", ">V01</a>", ">F01</a>", ">O01</a>")
      end
      ledger = "Achats démo #{stamp}"
      check("journal « #{ledger} » créé et consulté") do
        response = browser.submit("/accounting/ledgers/new", {"name" => ledger, "kind" => "purchase", "currency_code" => "EUR",
                                                              "receipt_prefix" => "DEM-", "receipt_padding" => "4", "enabled" => "1"})
        next "HTTP #{response.status_code}" unless response.status_code == 302
        expect(browser.follow(response), 200, "Journal #{ledger} créé.", "DEM-0001")
      end
    end

    # --- Référentiel par le contrat ---------------------------------------------

    private def reference_by_api(regime : String) : Nil
      puts "-- Référentiel par Partiduo::Api (acteur de l'administrateur)"
      input = Partiduo::Api::Auth::PasswordLoginInput.new(@email, @password)
      token = Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous, input).value!.session_token!
      actor = Partiduo::Api::Auth.actor(token)
      stamp = Time.local.to_s("%H%M%S")

      check("plan comptable du régime (#{regime})") do
        chart = Partiduo::Api::Accounting.chart(actor)
        # Comptes des modèles de NOALYSS (`include/sql/mod2` FR, `mod1` BE).
        expected = regime == "fr" ? {"101", "400", "410", "4456", "51", "603", "707"} : {"100", "400", "440", "451", "550", "604", "700"}
        missing = expected.to_a - chart.map(&.account.number)
        missing.empty? ? true : "comptes absents : #{missing.join(", ")} (#{chart.size} comptes)"
      end
      number = (regime == "fr" ? "401" : "440") + "8#{stamp}"
      check("compte #{number} créé puis relu") do
        created = Partiduo::Api::Accounting.create_account(actor, Partiduo::Api::Accounting::AccountInput.new(number, "Fournisseur API #{stamp}"))
        next created.error_keys.join(", ") if created.failure?
        Partiduo::Api::Accounting.account(actor, number).label == "Fournisseur API #{stamp}"
      end
      check("fiche fournisseur créée puis retrouvée") do
        supplier = Partiduo::Api::Cards.category_by_code(actor, "SUPPLIER") || raise "SUPPLIER absente"
        created = Partiduo::Api::Cards.create_card(actor, Partiduo::Api::Cards::CardInput.new(category_id: supplier.id, name: "Fournisseur API #{stamp}"))
        next created.error_keys.join(", ") if created.failure?
        Partiduo::Api::Cards.cards(actor).any?(&.name.==("Fournisseur API #{stamp}"))
      end
      check("journal créé puis listé") do
        created = Partiduo::Api::Accounting.create_ledger(actor, Partiduo::Api::Accounting::LedgerInput.new(
          name: "Divers API #{stamp}", kind: Partiduo::Api::Accounting::LedgerKind::Misc))
        next created.error_keys.join(", ") if created.failure?
        Partiduo::Api::Accounting.ledgers(actor).any?(&.name.==("Divers API #{stamp}"))
      end
      check("exercices lus") { !Partiduo::Api::Core.fiscal_years(actor).empty? }
      check("utilisateur sans droit refusé par le contrat (Forbidden)") do
        Partiduo::Api::Accounting.create_account(Partiduo::Api::Actor.user(0_i64, [] of String),
          Partiduo::Api::Accounting::AccountInput.new("4019", "Refusé"))
        "accepté"
      rescue Partiduo::Api::Forbidden
        true
      end
    end

    # --- Extension de référence SKEL ------------------------------------------

    private def skel(admin : Browser) : Nil
      puts "-- Extension SKEL"
      actor = Partiduo::Api::Auth.actor(Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous,
        Partiduo::Api::Auth::PasswordLoginInput.new(@email, @password)).value!.session_token!)
      unless Partiduo::Modules.active?(Skel::CODE)
        check("SKEL inactive : /ext/SKEL/ répond 404") { expect(admin.get("/ext/SKEL/"), 404) }
        check("SKEL activée par l'administrateur (Partiduo::Api::Modules.activate)") do
          result = Partiduo::Api::Modules.activate(actor, Skel::CODE)
          result.success? || result.error_keys.join(", ")
        end
        actor = Partiduo::Api::Auth.actor(Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous,
          Partiduo::Api::Auth::PasswordLoginInput.new(@email, @password)).value!.session_token!)
      end
      check("SKEL active") { Partiduo::Modules.active?(Skel::CODE) }
      check("visiteur anonyme renvoyé vers la connexion") do
        response = Browser.new(@host).get("/ext/SKEL/")
        response.status_code == 302 && response.headers["Location"] == "/login?next=%2Fext%2FSKEL%2F" || "HTTP #{response.status_code}"
      end
      check("page servie à l'administrateur, entrée de menu présente") do
        expect(admin.get("/ext/SKEL/"), 200, "Écritures reçues", %(href="/ext/SKEL/"))
      end

      stamp = Time.local.to_s("%H%M%S")
      reader = user(actor, "lecteur-skel-#{stamp}", "Lecteur SKEL #{stamp}", [Skel::Api::VIEW])
      other = user(actor, "sans-skel-#{stamp}", "Sans SKEL #{stamp}", ["accounting.entry.read"])
      check("page servie à un profil qui a skel.view") { expect(reader.get("/ext/SKEL/"), 200, "Écritures reçues") }
      check("page refusée (403) à un profil sans skel.view, sans entrée de menu") do
        response = other.get("/ext/SKEL/")
        next "entrée de menu visible" if response.body.includes?(%(href="/ext/SKEL/"))
        expect(response, 403, "Accès refusé")
      end

      before = Skel::Api.summary(actor).count
      entry_id = Time.utc.to_unix
      check("entry.posted reçu par SKEL (Partiduo::Events.publish)") do
        Partiduo::Events.publish("entry.posted", {"entry_id" => entry_id.to_s}, actor_user_id: actor.user_id)
        summary = Skel::Api.summary(actor)
        summary.count == before + 1 && summary.latest.first.entry_id == entry_id || "#{summary.count} écritures reçues"
      end
      check("écriture reçue affichée sur /ext/SKEL/") { expect(reader.get("/ext/SKEL/"), 200, "<td>#{entry_id}</td>") }
    end

    private def user(actor : Partiduo::Api::Actor, login : String, profile_name : String, permissions : Array(String)) : Browser
      profile = Partiduo::Api::Auth.create_profile(actor, Partiduo::Api::Auth::ProfileInput.new(name: profile_name, permissions: permissions)).value!
      email = "#{login}@#{@host}"
      Partiduo::Api::Auth.create_user(actor, Partiduo::Api::Auth::UserInput.new(email: email, profile_id: profile.id, password: @password)).value!
      browser = Browser.new(@host)
      response = browser.submit("/login", {"email" => email, "password" => @password})
      raise "connexion de #{email} refusée (HTTP #{response.status_code})" unless response.status_code == 302
      browser
    end
  end
end

host = "demo.partiduo.localhost"
email = ""
password = ENV["PARTIDUO_DEMO_PASSWORD"]? || "Demo-jalon1-Partiduo-2026"
invitation = nil
OptionParser.parse do |parser|
  parser.banner = "Usage : crystal run scripts/demo_jalon1.cr -- --host=HÔTE --email=ADRESSE [--invitation=LIEN]"
  parser.on("--host=HOST", "hôte de l'instance (<dossier>.<domaine>)") { |value| host = value }
  parser.on("--email=EMAIL", "adresse de l'administrateur") { |value| email = value }
  parser.on("--password=PASSWORD", "mot de passe à choisir ou à utiliser") { |value| password = value }
  parser.on("--invitation=LINK", "lien (ou jeton) d'invitation affiché par partiduo-provision") { |value| invitation = value }
end
abort "--email est obligatoire" if email.empty?

# Journal de Marten réduit aux avertissements : la sortie est la liste des étapes.
Marten.configure(&.log_level=(::Log::Severity::Warn))
Marten.setup
demo = Demo::Run.new(host, email, password, invitation)
demo.run
puts demo.failures.zero? ? "== Tout est vert." : "== #{demo.failures} étape(s) en échec."
exit(demo.failures.zero? ? 0 : 1)
