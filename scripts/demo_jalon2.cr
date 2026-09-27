# SPDX-License-Identifier: AGPL-3.0-or-later

# Démonstration de bout en bout du jalon 2 (saisie d'écritures) sur une
# instance provisionnée par `bin/partiduo-provision` (cœur + interface Bulma +
# SKEL, composés comme une distribution) : enrôlement, exercice, fiches,
# saisie des quatre formes par l'interface (contrôle instantané HTMX compris),
# refus, consultation, lettrage, annulation par extourne, éditions (balance,
# grand livre, journaux, FEC) et contrôle au centime par `Partiduo::Api`,
# réception de `entry.posted` par SKEL.
#
# ```
# PARTIDUO_MODULES=accounting,invoicing,skel \
# DATABASE_URL='postgres:///partiduo_j2_fr?host=/tmp' crystal run scripts/demo_jalon2.cr -- \
#   --host=j2-fr.partiduo.localhost --email=admin@j2-fr.test \
#   --invitation=https://j2-fr.partiduo.localhost/invitation/<jeton> [--fec=export.txt]
# ```
#
# Sans `--invitation`, l'administrateur se connecte avec `--password`. La
# démonstration suppose une instance sans écriture (premier passage) : les
# totaux attendus sont ceux des seules écritures qu'elle passe. Code de sortie
# 1 si une étape échoue.
ENV["MARTEN_ENV"] ||= "development"

require "http/client"
require "option_parser"
require "partiduo-ui-bulma/partiduo_ui"
require "../src/partiduo-skel"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"
require "./demo/browser"

module Demo
  class Jalon2
    alias Acc = Partiduo::Api::Accounting

    getter failures = 0

    @actor : Partiduo::Api::Actor? = nil
    @customer = ""
    @supplier = ""
    @year = 0
    @sale_id = 0_i64
    @misc_id = 0_i64

    def initialize(@host : String, @email : String, @password : String, @invitation : String?, @fec_out : String?)
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

    # Page lue sans entités ni espaces de groupement (montants « 1 200,00 »).
    def text(response : ::HTTP::Client::Response) : String
      HTML.unescape(response.body).gsub(/[   ]/, "")
    end

    def expect(response : ::HTTP::Client::Response, status : Int32, *texts) : Bool | String
      return "HTTP #{response.status_code} au lieu de #{status}#{errors_of(response)}" unless response.status_code == status
      body = text(response)
      missing = texts.reject { |item| body.includes?(item.gsub(/[   ]/, "")) }
      missing.empty? ? true : "absent de la page : #{missing.join(" | ")}"
    end

    def errors_of(response : ::HTTP::Client::Response) : String
      body = HTML.unescape(response.body)
      found = body.scan(/pd-field-errors[^>]*>(.*?)<\/ul>/m).flat_map { |match| match[1].scan(/<li>([^<]+)<\/li>/).map(&.[1].strip) }
      found.concat(body.scan(/notification is-danger[^>]*>\s*([^<]+)/).map(&.[1].strip))
      found.empty? ? "" : " (#{found.uniq.first(4).join(" | ")})"
    end

    def actor : Partiduo::Api::Actor
      @actor ||= begin
        input = Partiduo::Api::Auth::PasswordLoginInput.new(@email, @password)
        Partiduo::Api::Auth.actor(Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous, input).value!.session_token!)
      end
    end

    def d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def run : Nil
      settings = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system)
      puts "== Instance #{@host} : « #{settings.company_name} », régime #{settings.tax_regime}, " \
           "modules actifs #{Partiduo::Modules::State.active_codes.to_a.sort!.join(", ")}"
      admin = Browser.new(@host)
      enroll(admin)
      return if @failures > 0
      prerequisites(admin)
      return if @failures > 0
      skel_before = Skel::Api.summary(actor).count
      entries_by_ui(admin)
      refusals(admin)
      consultation(admin)
      matching(admin)
      cancellation(admin)
      reports(admin)
      contract
      skel(skel_before)
    end

    # --- Enrôlement ------------------------------------------------------------

    private def enroll(browser : Browser) : Nil
      puts "-- Enrôlement et connexion"
      if invitation = @invitation
        path = "/invitation/#{invitation.split("/invitation/").last}"
        check("invitation acceptée") do
          response = browser.submit(path, {} of String => String)
          response.status_code == 302 && response.headers["Location"] == "/account/enrollment" || "HTTP #{response.status_code}"
        end
        check("mot de passe choisi") do
          browser.get("/account/enrollment")
          response = browser.post("/account/enrollment", {"new_password" => @password, "confirmation" => @password})
          response.status_code == 302 || "HTTP #{response.status_code}#{errors_of(response)}"
        end
      end
      check("connexion de l'administrateur") do
        response = browser.submit("/login", {"email" => @email, "password" => @password})
        response.status_code == 302 || "HTTP #{response.status_code}"
      end
    end

    # --- Exercice et fiches ----------------------------------------------------

    private def prerequisites(browser : Browser) : Nil
      puts "-- Exercice et fiches"
      @year = Partiduo::Api::Core.today.year
      if Partiduo::Api::Core.fiscal_years(actor).none? { |item| item.year == @year }
        check("exercice #{@year} créé par l'interface") do
          response = browser.submit("/fiscal-years", {"year" => @year.to_s, "start_year" => @year.to_s, "start_month" => "1",
                                                      "months" => "12", "label" => ""})
          response.status_code == 302 || "HTTP #{response.status_code}#{errors_of(response)}"
        end
      end
      {"6226" => "Honoraires", "627" => "Services bancaires et assimilés"}.each do |number, label|
        next unless Acc.chart(actor).none? { |item| item.account.number == number }
        check("compte #{number} « #{label} » créé par l'interface") do
          response = browser.submit("/accounting/chart/new", {"number" => number, "label" => label, "direct_use" => "1"})
          response.status_code == 302 || "HTTP #{response.status_code}#{errors_of(response)}"
        end
      end
      stamp = Time.local.to_s("%H%M%S")
      @customer = card("CUSTOMER", "Client J2 #{stamp}")
      @supplier = card("SUPPLIER", "Fournisseur J2 #{stamp}")
      check("fiches client #{@customer} et fournisseur #{@supplier} rattachées à un compte (card.saved)") do
        [@customer, @supplier].all? do |code|
          card = Partiduo::Api::Cards.card_by_code(actor, code) || next false
          !Acc.card_account(actor, card.id).nil?
        end || "compte absent"
      end
    end

    private def card(category : String, name : String) : String
      code = ""
      check("fiche #{name} (#{category})") do
        cat = Partiduo::Api::Cards.category_by_code(actor, category) || raise "catégorie #{category} absente"
        created = Partiduo::Api::Cards.create_card(actor, Partiduo::Api::Cards::CardInput.new(category_id: cat.id, name: name))
        next created.error_keys.join(", ") if created.failure?
        code = created.value!.code
        true
      end
      code
    end

    private def ledger(code : String) : Acc::LedgerView
      Acc.ledgers(actor).find { |item| item.code == code } || raise "journal #{code} absent"
    end

    private def day(number : Int32) : String
      "%02d/09/%d" % {number, @year}
    end

    # --- Saisie par l'interface ------------------------------------------------

    private def entries_by_ui(browser : Browser) : Nil
      puts "-- Saisie par l'interface (quatre formes)"
      check("écran de saisie des ventes") { expect(browser.get("/accounting/entries/sale"), 200, "V01") }
      sale = {"ledger_id" => ledger("V01").id.to_s, "date" => day(10), "receipt" => "", "label" => "Facture J2",
              "third_party" => @customer, "due_date" => day(30),
              "line-0-account" => "706", "line-0-label" => "Prestation", "line-0-amount" => "1000,00", "line-0-vat_rate" => "NOR"}
      check("contrôle instantané (HTMX) de la vente : TVA calculée, 1 200,00 TTC") do
        browser.get("/accounting/entries/sale")
        response = browser.post("/accounting/entries/sale/check", sale)
        expect(response, 200, "44571", "200,00", "1200,00")
      end
      check("facture de vente enregistrée (V01, 1 000,00 HT + TVA 20 %)") do
        response = browser.submit("/accounting/entries/sale", sale)
        next "HTTP #{response.status_code}#{errors_of(response)}" unless response.status_code == 302
        expect(browser.follow(response), 200, "V-00001")
      end
      @sale_id = Acc.entries(actor).find { |entry| entry.receipt == "V-00001" }.try(&.id) || 0_i64

      purchase = {"ledger_id" => ledger("A01").id.to_s, "date" => day(12), "label" => "Facture fournisseur J2",
                  "third_party" => @supplier, "due_date" => day(28), "receipt" => "",
                  "line-0-account" => "6226", "line-0-label" => "Honoraires", "line-0-amount" => "250,00", "line-0-vat_rate" => "NOR"}
      check("facture d'achat enregistrée (A01, 250,00 HT + TVA 20 %)") do
        response = browser.submit("/accounting/entries/purchase", purchase)
        next "HTTP #{response.status_code}#{errors_of(response)}" unless response.status_code == 302
        expect(browser.follow(response), 200, "A-00001")
      end

      financial = {"ledger_id" => ledger("F01").id.to_s, "date" => day(20), "receipt" => "",
                   "line-0-account" => @customer, "line-0-label" => "Règlement client", "line-0-debit" => "1200,00", "line-0-credit" => "",
                   "line-1-account" => @supplier, "line-1-label" => "Règlement fournisseur", "line-1-debit" => "", "line-1-credit" => "300,00"}
      check("extrait bancaire enregistré (F01, deux écritures)") do
        response = browser.submit("/accounting/entries/financial", financial)
        next "HTTP #{response.status_code}#{errors_of(response)}" unless response.status_code == 302
        expect(browser.follow(response), 200, "F-00001", "F-00002")
      end

      misc = {"ledger_id" => ledger("O01").id.to_s, "date" => day(25), "receipt" => "", "label" => "Frais bancaires J2",
              "line-0-account" => "627", "line-0-label" => "Frais", "line-0-debit" => "15,00", "line-0-credit" => "",
              "line-1-account" => "510001", "line-1-label" => "Frais", "line-1-debit" => "", "line-1-credit" => "15,00",
              "line-2-account" => "", "line-2-label" => "", "line-2-debit" => "", "line-2-credit" => ""}
      check("contrôle instantané (HTMX) de l'opération diverse : équilibrée") do
        browser.get("/accounting/entries/misc")
        expect(browser.post("/accounting/entries/misc/check", misc), 200, "15,00")
      end
      check("opération diverse enregistrée (O01, 15,00)") do
        response = browser.submit("/accounting/entries/misc", misc)
        next "HTTP #{response.status_code}#{errors_of(response)}" unless response.status_code == 302
        expect(browser.follow(response), 200, "O-00001")
      end
      @misc_id = Acc.entries(actor).find { |entry| entry.receipt == "O-00001" }.try(&.id) || 0_i64
    end

    private def refusals(browser : Browser) : Nil
      puts "-- Refus"
      base = {"ledger_id" => ledger("O01").id.to_s, "date" => day(26), "receipt" => "", "label" => "Refusée",
              "line-0-account" => "627", "line-0-label" => "", "line-0-debit" => "10,00", "line-0-credit" => "",
              "line-1-account" => "510001", "line-1-label" => "", "line-1-debit" => "", "line-1-credit" => "9,99"}
      count = Acc.count_entries(actor)
      check("écriture déséquilibrée d'un centime refusée (422)") do
        response = browser.submit("/accounting/entries/misc", base)
        response.status_code == 422 || "HTTP #{response.status_code}"
      end
      check("contrôle instantané : écart de 0,01 affiché") do
        browser.get("/accounting/entries/misc")
        expect(browser.post("/accounting/entries/misc/check", base), 200, "0,01")
      end
      outside = base.merge({"date" => "15/06/#{@year + 5}", "line-1-credit" => "10,00"})
      check("écriture hors exercice refusée (422)") do
        response = browser.submit("/accounting/entries/misc", outside)
        response.status_code == 422 || "HTTP #{response.status_code}"
      end
      unknown = base.merge({"line-0-account" => "999999", "line-1-credit" => "10,00"})
      check("compte inconnu refusé (422)") do
        response = browser.submit("/accounting/entries/misc", unknown)
        response.status_code == 422 || "HTTP #{response.status_code}"
      end
      check("aucune écriture enregistrée par les refus") { Acc.count_entries(actor) == count || "#{Acc.count_entries(actor)} écritures" }
    end

    # --- Consultation, lettrage, annulation -----------------------------------

    private def consultation(browser : Browser) : Nil
      puts "-- Consultation"
      check("liste des écritures (5)") do
        expect(browser.get("/accounting/entries"), 200, "V-00001", "A-00001", "F-00001", "F-00002", "O-00001")
      end
      check("écriture de vente consultée : lignes 411, 706, 44571") do
        expect(browser.get("/accounting/entries/#{@sale_id}"), 200, "706", "44571", "1200,00", "1000,00", "200,00")
      end
      check("relevé du client : solde nul") do
        statement = Acc.account_statement(actor, Acc::StatementQuery.new(card: @customer))
        statement.balance.zero? && statement.total_debit == d("1200") || "solde #{statement.balance}"
      end
      check("écran des comptes et tiers") { expect(browser.get("/accounting/accounts?q=#{@customer}"), 200, "1200,00") }
    end

    private def matching(browser : Browser) : Nil
      puts "-- Lettrage"
      statement = Acc.account_statement(actor, Acc::StatementQuery.new(card: @customer, unmatched_only: true))
      ids = statement.lines.map(&.line_id)
      check("deux lignes non lettrées du client") { ids.size == 2 || "#{ids.size} lignes" }
      pairs = [{"q", @customer}] + ids.map { |id| {"line", id.to_s} }
      check("sélection contrôlée (HTMX) : équilibrée") do
        browser.get("/accounting/matching?q=#{@customer}")
        expect(browser.post_pairs("/accounting/matching/check", pairs), 200, "1200,00")
      end
      check("lettrage enregistré par l'interface") do
        browser.get("/accounting/matching?q=#{@customer}")
        response = browser.post_pairs("/accounting/matching", pairs)
        next "HTTP #{response.status_code}#{errors_of(response)}" unless response.status_code == 302
        browser.follow(response).status_code == 200 &&
          Acc.account_statement(actor, Acc::StatementQuery.new(card: @customer, unmatched_only: true)).lines.empty? || "lignes encore ouvertes"
      end
      check("balance âgée : client soldé, fournisseur soldé") do
        aged = Acc.aged_balance(actor)
        open = aged.rows.select(&.card_code.in?(@customer, @supplier))
        open.all?(&.remaining.zero?) || open.map { |row| "#{row.card_code} #{row.remaining}" }.join(", ")
      end
    end

    private def cancellation(browser : Browser) : Nil
      puts "-- Annulation par extourne"
      check("opération diverse O-00001 annulée (extourne O-00002)") do
        browser.get("/accounting/entries/#{@misc_id}")
        response = browser.post("/accounting/entries/#{@misc_id}/cancel")
        next "HTTP #{response.status_code}" unless response.status_code == 302
        expect(browser.follow(response), 200, "O-00002")
      end
      check("seconde annulation refusée") do
        result = Acc.cancel_entry(actor, Acc::CancelEntryInput.new(@misc_id))
        result.failure? || "acceptée"
      end
    end

    # --- Éditions --------------------------------------------------------------

    private def reports(browser : Browser) : Nil
      puts "-- Éditions"
      from = "01/01/#{@year}"
      to = "31/12/#{@year}"
      check("balance générale (écran)") do
        expect(browser.get("/accounting/reports/trial-balance?from=#{from}&to=#{to}"), 200, "706", "44571", "3030,00")
      end
      check("balance générale (CSV)") do
        response = browser.get("/accounting/reports/trial-balance?from=#{from}&to=#{to}&format=csv")
        response.status_code == 200 && response.body.includes?("706") || "HTTP #{response.status_code}"
      end
      check("grand livre (écran)") do
        expect(browser.get("/accounting/reports/general-ledger?from=#{from}&to=#{to}"), 200, "706", "V-00001")
      end
      check("journaux (écran)") do
        expect(browser.get("/accounting/reports/journals?from=#{from}&to=#{to}"), 200, "V-00001", "O-00002")
      end
      check("écran du FEC") { expect(browser.get("/accounting/reports/fec"), 200, "FEC") }
    end

    # --- Contrôle au centime par le contrat ------------------------------------

    private def contract : Nil
      puts "-- Contrôle au centime par Partiduo::Api"
      from = Time.local(@year, 1, 1, location: Partiduo::Api::Core.today.location)
      to = Time.local(@year, 12, 31, location: from.location)
      balance = Acc.trial_balance(actor, Acc::TrialBalanceQuery.new(date_from: from, date_to: to))
      balance_checks(balance)
      editions_checks(from, to)
    end

    private def balance_checks(balance : Acc::TrialBalanceView) : Nil
      solde = ->(number : String) { balance.rows.find { |row| row.number == number }.try(&.closing.signed) || d("0") }
      # Ventes 1 200 + achats 300 + extrait 1 200 + 300 + OD 15 + extourne 15.
      check("balance équilibrée : 3 030,00 au débit et au crédit") do
        balance.total.debit == d("3030") && balance.total.credit == d("3030") && balance.delta.zero? ||
          "débit #{balance.total.debit}, crédit #{balance.total.credit}"
      end
      check("706 : −1 000,00 ; 6226 : 250,00 ; 627 : 0,00 (OD annulée) ; 44571 : −200,00 ; 4456x : 50,00") do
        deductible = balance.rows.select(&.number.starts_with?("44566")).sum(d("0"), &.closing.signed)
        solde.call("706") == d("-1000") && solde.call("6226") == d("250") && solde.call("627").zero? && solde.call("44571") == d("-200") && deductible == d("50") ||
          "706 #{solde.call("706")}, 6226 #{solde.call("6226")}, 627 #{solde.call("627")}, 44571 #{solde.call("44571")}, 4456x #{deductible}"
      end
      check("banque 510001 : 900,00") { solde.call("510001") == d("900") || solde.call("510001").to_s }
      check("résultat : 750,00") { balance.summary.result == d("750") || balance.summary.result.to_s }
    end

    private def editions_checks(from : Time, to : Time) : Nil
      journals = Acc.journals(actor, Acc::JournalQuery.new(date_from: from, date_to: to))
      check("journaux : 6 écritures") do
        total = journals.ledgers.sum(&.entries.size)
        total == 6 || "#{total} écritures"
      end
      check("FEC de l'exercice : 14 lignes, équilibré") do
        file = Acc.fec(actor, Acc::FecQuery.new(date_from: from, date_to: to)).value!
        content = String.new(file.content)
        @fec_out.try { |path| File.write(path, file.content) }
        lines = content.scrub.lines.reject(&.empty?)
        next "#{lines.size - 1} lignes (#{file.filename})" unless lines.size - 1 == 14
        cells = lines[1..].map(&.split('|'))
        debit = cells.sum(d("0")) { |cell| d(cell[11].tr(",", ".")) }
        credit = cells.sum(d("0")) { |cell| d(cell[12].tr(",", ".")) }
        debit == d("3030") && credit == debit || "débit #{debit}, crédit #{credit}"
      end
      check("écriture directe refusée à un utilisateur sans droit (Forbidden)") do
        Acc.post_entry(Partiduo::Api::Actor.user(0_i64, [] of String), Acc::EntryInput.new(
          ledger_id: ledger("O01").id, date: from, lines: [] of Acc::EntryLineInput))
        "acceptée"
      rescue Partiduo::Api::Forbidden
        true
      end
    end

    private def skel(before : Int64) : Nil
      puts "-- SKEL : entry.posted publié par les vraies écritures"
      check("6 écritures reçues par SKEL (5 saisies + 1 extourne)") do
        count = Skel::Api.summary(actor).count
        count - before == 6 || "#{count - before} reçues"
      end
    end
  end
end

host = "demo.partiduo.localhost"
email = ""
password = ENV["PARTIDUO_DEMO_PASSWORD"]? || "Demo-jalon2-Partiduo-2026"
invitation = nil
fec = nil
OptionParser.parse do |parser|
  parser.banner = "Usage : crystal run scripts/demo_jalon2.cr -- --host=HÔTE --email=ADRESSE [--invitation=LIEN] [--fec=FICHIER]"
  parser.on("--host=HOST", "hôte de l'instance (<dossier>.<domaine>)") { |value| host = value }
  parser.on("--email=EMAIL", "adresse de l'administrateur") { |value| email = value }
  parser.on("--password=PASSWORD", "mot de passe à choisir ou à utiliser") { |value| password = value }
  parser.on("--invitation=LINK", "lien (ou jeton) d'invitation affiché par partiduo-provision") { |value| invitation = value }
  parser.on("--fec=FILE", "écrit le FEC de l'exercice exporté par l'instance") { |value| fec = value }
end
abort "--email est obligatoire" if email.empty?

Marten.configure(&.log_level=(::Log::Severity::Warn))
Marten.setup
demo = Demo::Jalon2.new(host, email, password, invitation, fec)
demo.run
puts demo.failures.zero? ? "== Tout est vert." : "== #{demo.failures} étape(s) en échec."
exit(demo.failures.zero? ? 0 : 1)
