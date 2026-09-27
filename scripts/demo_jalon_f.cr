# SPDX-License-Identifier: AGPL-3.0-or-later

# Vérification de bout en bout du jalon F (Facturation) sur une instance
# provisionnée par `bin/partiduo-provision`, « Facturation seule »
# (`--modules invoicing`) ou « Comptabilité + Facturation » (défaut).
#
# Parcours, par l'interface (partiduo-ui-bulma) : enrôlement de
# l'administrateur, fiche client et articles, devis saisi puis validé,
# accepté, transformé en facture, facture validée (numéro attribué), PDF/A-3
# Factur-X téléchargé et contrôlé par `pdf-validate` (profil `pdf-a-3b`),
# puis réglée :
#
# * Facturation seule : règlements saisis sur la facture (partiel puis
#   solde), statut « payée », aucun appel à la Comptabilité ;
# * Comptabilité + Facturation : écriture de vente générée au journal de
#   ventes (pièce = numéro de facture), encaissement saisi en banque, lettré
#   avec la vente depuis l'écran de lettrage, facture payée.
#
# Sans `--base-url`, les requêtes traversent la pile de Marten en mémoire
# (comme `demo_jalon1.cr`) ; avec `--base-url=http://127.0.0.1:8000`, elles
# partent vers un serveur réellement démarré (`scripts/server.cr`) sur la
# même base. Code de sortie 1 si une étape échoue.
#
# ```
# PARTIDUO_MODULES=invoicing DATABASE_URL='postgres:///partiduo_j3_inv?host=/tmp' \
#   crystal run scripts/demo_jalon_f.cr -- --host=jf-inv.partiduo.localhost \
#   --email=admin@jf-inv.test --invitation='<lien affiché par partiduo-provision>'
# ```
ENV["MARTEN_ENV"] ||= "development"

require "http/client"
require "option_parser"
require "partiduo-ui-bulma/partiduo_ui"
require "../src/partiduo-skel"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"

module DemoF
  # Navigateur : cookies, en-tête Host de l'instance, jeton CSRF repris de la
  # dernière page lue. En mémoire (pile de Marten) ou vers un vrai serveur.
  class Browser
    getter jar = ::HTTP::Cookies.new
    @csrf : String? = nil
    @chain : ::HTTP::Handler? = nil

    def initialize(@host : String, @base_url : String? = nil, @locale : String = "fr")
      unless @base_url
        @chain = ::HTTP::Server.build_middleware([
          Marten::Server::Handlers::Error.new,
          Marten::Server::Handlers::Middleware.new,
          Marten::Server::Handlers::Routing.new,
        ] of ::HTTP::Handler)
      end
    end

    def get(path : String) : ::HTTP::Client::Response
      perform("GET", path)
    end

    def submit(form_path : String, data : Hash(String, String), action : String = form_path) : ::HTTP::Client::Response
      get(form_path)
      post(action, data)
    end

    def post(path : String, data : Hash(String, String) = {} of String => String) : ::HTTP::Client::Response
      post_pairs(path, data.to_a)
    end

    # Champs répétés (cases à cocher de même nom).
    def post_pairs(path : String, pairs : Array({String, String})) : ::HTTP::Client::Response
      params = URI::Params.new
      pairs.each { |(name, value)| params.add(name, value) }
      params.add("csrftoken", @csrf.to_s)
      perform("POST", path, params.to_s)
    end

    def follow(response : ::HTTP::Client::Response) : ::HTTP::Client::Response
      get(response.headers["Location"])
    end

    private def perform(method : String, path : String, body : String? = nil) : ::HTTP::Client::Response
      headers = ::HTTP::Headers{"Host" => @host, "Accept-Language" => @locale, "User-Agent" => "partiduo-demo"}
      headers["Content-Type"] = "application/x-www-form-urlencoded" if body
      # Référent de même origine, comme un navigateur (contrôle CSRF en HTTPS).
      headers["Referer"] = "http://#{@host}#{path}"
      request = ::HTTP::Request.new(method, path, headers, body)
      @jar.add_request_headers(request.headers)
      result = if base = @base_url
                 uri = URI.parse(base)
                 ::HTTP::Client.new(uri.host.to_s, uri.port) do |client|
                   client.exec(request)
                 end
               else
                 io = IO::Memory.new
                 response = ::HTTP::Server::Response.new(io)
                 (@chain || raise "navigateur sans pile de Marten").call(::HTTP::Server::Context.new(request, response))
                 response.close
                 io.rewind
                 ::HTTP::Client::Response.from_io(io)
               end
      result.cookies.each do |cookie|
        cookie.expired? || cookie.value.empty? ? @jar.delete(cookie.name) : (@jar << cookie)
      end
      html = result.content_type.to_s.includes?("html")
      if html && (token = result.body.match(/name="csrftoken" value="([^"]+)"/).try(&.[1]))
        @csrf = token
      end
      result
    end
  end

  class Run
    alias Inv = Partiduo::Api::Invoicing
    alias Acc = Partiduo::Api::Accounting

    getter failures = 0
    getter steps = 0
    @actor : Partiduo::Api::Actor? = nil

    def initialize(@host : String, @email : String, @password : String, @invitation : String?, @base_url : String?,
                   @pdf_dir : String?)
    end

    def check(label : String, & : -> Bool | String) : Nil
      @steps += 1
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
      return "HTTP #{response.status_code} au lieu de #{status}#{danger(response)}" unless response.status_code == status
      body = HTML.unescape(response.body).gsub(/[\x{00A0}\x{202F}]/, " ")
      missing = texts.reject { |text| body.includes?(text) }
      return true if missing.empty?
      "absent de la page : #{missing.join(" | ")}#{danger(response)}"
    end

    def redirect?(response : ::HTTP::Client::Response, prefix : String = "/") : Bool | String
      return true if response.status_code == 302 && response.headers["Location"].starts_with?(prefix)
      "HTTP #{response.status_code}#{danger(response)}"
    end

    # Messages d'erreur de la page (formulaire refusé, notification).
    def danger(response : ::HTTP::Client::Response) : String
      body = response.body
      blocks = body.scan(/<(?:ul|div|p)[^>]*is-danger[^>]*>(.*?)<\/(?:ul|div|p)>/m).map(&.[1])
      messages = blocks.flat_map { |block| HTML.unescape(block.gsub(/<[^>]+>/, "\n")).split('\n') }.map(&.strip).reject(&.empty?).uniq!
      messages.empty? ? "" : " — #{messages.first(4).join(" | ")}"
    end

    def system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def actor : Partiduo::Api::Actor
      @actor ||= Partiduo::Api::Auth.actor(Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous,
        Partiduo::Api::Auth::PasswordLoginInput.new(@email, @password)).value!.session_token!)
    end

    def standard_rate : Partiduo::Api::Vat::RateView
      rates = Partiduo::Api::Vat.rates(system)
      rates.find(&.code.==("NOR")) || rates.find!(&.code.==("21G"))
    end

    def accounting? : Bool
      Partiduo::Modules.active?("ACCOUNTING")
    end

    def run : Nil
      settings = Partiduo::Api::Core.settings(system)
      mode = @base_url ? "serveur HTTP #{@base_url}" : "pile de Marten en mémoire"
      puts "== Instance #{@host} : « #{settings.company_name} », régime #{settings.tax_regime}, " \
           "modules actifs #{Partiduo::Modules::State.active_codes.to_a.sort!.join(", ")} (#{mode})"
      browser = Browser.new(@host, @base_url)
      login(browser)
      stamp = Time.local.to_s("%H%M%S")
      customer = reference(browser, stamp)
      fiscal_year(browser) if accounting?
      quote_id = quote(browser, customer, stamp)
      return puts("  (arrêt : devis absent)") unless quote_id
      invoice_id = invoice(browser, quote_id)
      return puts("  (arrêt : facture absente)") unless invoice_id
      pdf(browser, invoice_id)
      if accounting?
        paid_with_accounting(browser, invoice_id, customer)
      else
        paid_without_accounting(browser, invoice_id)
      end
      lists(browser, invoice_id)
    end

    # --- Connexion ----------------------------------------------------------------

    private def login(browser : Browser) : Nil
      puts "-- Enrôlement et connexion"
      if invitation = @invitation
        path = "/invitation/#{invitation.split("/invitation/").last}"
        check("invitation acceptée") { redirect?(browser.submit(path, {} of String => String), "/account/enrollment") }
        check("mot de passe choisi à l'enrôlement") do
          browser.get("/account/enrollment")
          redirect?(browser.post("/account/enrollment", {"new_password" => @password, "confirmation" => @password}), "/login")
        end
      end
      check("connexion par mot de passe") { redirect?(browser.submit("/login", {"email" => @email, "password" => @password})) }
      check("tableau de bord (tuiles de la Facturation#{accounting? ? " et de la Comptabilité" : ""})") do
        expect(browser.get("/"), 200, Partiduo::Api::Core.settings(system).company_name, %(href="/invoicing/documents"))
      end
      check(accounting? ? "menu de la Comptabilité présent" : "Comptabilité absente : menu masqué, écrans en 404") do
        page = browser.get("/")
        if accounting?
          page.body.includes?(%(href="/accounting/entries)) || "menu des écritures absent"
        else
          next "menu des écritures visible" if page.body.includes?(%(href="/accounting/entries))
          expect(browser.get("/accounting/entries"), 404)
        end
      end
    end

    # --- Référentiel ----------------------------------------------------------------

    private def reference(browser : Browser, stamp : String) : String
      puts "-- Client et articles (fiches, par l'interface)"
      customers = Partiduo::Api::Cards.category_by_code(system, "CUSTOMER") || raise "catégorie CUSTOMER absente"
      items = Partiduo::Api::Cards.category_by_code(system, "SALE") || raise "catégorie SALE absente"
      rate = standard_rate
      code = "CLI#{stamp}"
      check("fiche client #{code} créée") do
        redirect?(browser.submit("/cards/new?category=#{customers.id}", {
          "category_id" => customers.id.to_s, "name" => "Atelier Morel #{stamp}", "code" => code, "enabled" => "1",
          "email" => "compta#{stamp}@morel.test", "siren" => "443061841", "vat_number" => "FR64443061841",
          "address.line1" => "3 rue du Port", "address.postcode" => "44100", "address.city" => "Nantes",
          "address.country_code" => "FR",
        }, "/cards/new"), "/cards/")
      end
      {"CONS#{stamp}" => {"Conseil (heure)", "HUR", "80"}, "RAM#{stamp}" => {"Carton de ramettes", "C62", "24,90"}}.each do |item, (name, unit, price)|
        check("article #{item} créé (#{price} € HT, TVA #{rate.code})") do
          redirect?(browser.submit("/cards/new?category=#{items.id}", {
            "category_id" => items.id.to_s, "name" => "#{name} #{stamp}", "code" => item, "enabled" => "1",
            "unit_code" => unit, "sale_price" => price, "vat_rate_id" => rate.id.to_s,
          }, "/cards/new"), "/cards/")
        end
      end
      code
    end

    private def fiscal_year(browser : Browser) : Nil
      year = Partiduo::Api::Core.today.year
      return if Partiduo::Api::Core.fiscal_years(system).any?(&.year.==(year))
      check("exercice #{year} créé (12 périodes)") do
        redirect?(browser.submit("/fiscal-years", {"year" => year.to_s, "start_year" => year.to_s, "start_month" => "1",
                                                   "months" => "12", "label" => ""}), "/fiscal-years")
      end
    end

    # --- Devis ------------------------------------------------------------------

    private def quote(browser : Browser, customer : String, stamp : String) : Int64?
      puts "-- Devis"
      quote_id = nil
      values = {"kind" => "quote", "customer" => customer,
                "line-0-item" => "CONS#{stamp}", "line-0-quantity" => "10",
                "line-1-item" => "RAM#{stamp}", "line-1-quantity" => "2",
                "line-2-description" => "Déplacement", "line-2-quantity" => "1", "line-2-unit_price" => "45",
                "line-2-vat_rate_id" => standard_rate.id.to_s}
      check("totaux instantanés du brouillon (check_document, HTMX)") do
        browser.get("/invoicing/documents/new?kind=quote")
        expect(browser.post("/invoicing/documents/check", values), 200, "894,80", "178,96", "1 073,76")
      end
      check("devis enregistré en brouillon") do
        response = browser.submit("/invoicing/documents/new?kind=quote", values, "/invoicing/documents/new")
        next redirect?(response) unless response.status_code == 302
        quote_id = response.headers["Location"].split('/').last.to_i64
        expect(browser.follow(response), 200, "Brouillon", "Atelier Morel #{stamp}", "1 073,76")
      end
      id = quote_id || return
      check("devis validé : numéro attribué") do
        response = browser.post("/invoicing/documents/#{id}/issue")
        next redirect?(response) unless response.status_code == 302
        number = Inv.document(actor, id).number || next "sans numéro"
        next "numéro #{number}" unless number.starts_with?("D")
        expect(browser.follow(response), 200, number)
      end
      check("devis accepté par le client") do
        document = Inv.document(actor, id)
        next "statut #{document.status} : décision non proposée" unless document.status == "sent"
        response = browser.post("/invoicing/documents/#{id}/decide", {"decision" => "accepted"})
        next redirect?(response) unless response.status_code == 302
        Inv.document(actor, id).status == "accepted" || "statut #{Inv.document(actor, id).status}"
      end
      quote_id
    end

    # --- Facture ----------------------------------------------------------------

    private def invoice(browser : Browser, quote_id : Int64) : Int64?
      puts "-- Facture"
      id = transform(browser, quote_id) || return
      issue(browser, id)
      check("devis source : lien vers la facture") do
        expect(browser.get("/invoicing/documents/#{quote_id}"), 200, "/invoicing/documents/#{id}")
      end
      check("facture émise intangible (modification refusée par la base)") do
        Marten::DB::Connection.default.open(&.exec("UPDATE invoicing_documents SET notes = 'x' WHERE id = $1", id))
        "modification acceptée"
      rescue PQ::PQError
        true
      end
      id
    end

    private def transform(browser : Browser, quote_id : Int64) : Int64?
      invoice_id = nil
      check("devis transformé en facture (lignes recopiées, lien conservé)") do
        browser.get("/invoicing/documents/#{quote_id}")
        response = browser.post("/invoicing/documents/#{quote_id}/transform?kind=invoice")
        next redirect?(response) unless response.status_code == 302 && response.headers["Location"].ends_with?("/edit")
        draft_id = response.headers["Location"].split('/')[-2].to_i64
        invoice_id = draft_id
        draft = Inv.document(actor, draft_id)
        next "#{draft.kind} #{draft.status}" unless draft.kind == "invoice" && draft.draft?
        next "#{draft.lines.size} lignes" unless draft.lines.count(&.priced?) == 3
        next "source #{draft.source.try(&.id)}" unless draft.source.try(&.id) == quote_id
        # Brouillon ouvert en édition : lignes recopiées (totaux chargés par HTMX).
        expect(browser.follow(response), 200, "800,00", "49,80", "45,00", %(hx-trigger="load,))
      end
      invoice_id
    end

    private def issue(browser : Browser, id : Int64) : Nil
      check("facture validée : numéro attribué, mentions figées, empreinte") do
        response = browser.post("/invoicing/documents/#{id}/issue")
        next redirect?(response) unless response.status_code == 302
        view = Inv.document(actor, id)
        number = view.number || next "sans numéro#{danger(browser.follow(response))}"
        next "numéro #{number}" unless number.matches?(/\AF/)
        next "total #{view.totals.total_gross}" unless view.totals.total_gross == BigDecimal.new("1073.76")
        next "aucune mention" if view.mentions.empty?
        next "empreinte invalide" unless Inv.verify_fingerprint(actor, id)
        puts "          facture #{number} du #{view.issue_date.try(&.to_s("%Y-%m-%d"))}, " \
             "#{view.totals.total_gross} € TTC, échéance #{view.due_date.try(&.to_s("%Y-%m-%d"))}"
        expect(browser.follow(response), 200, number, "1 073,76")
      end
    end

    private def pdf(browser : Browser, id : Int64) : Nil
      puts "-- PDF/A-3 Factur-X"
      number = Inv.document(actor, id).number.to_s
      check("PDF téléchargé par l'interface") do
        response = browser.get("/invoicing/documents/#{id}/pdf")
        next "HTTP #{response.status_code}" unless response.status_code == 200
        next "type #{response.content_type}" unless response.content_type == "application/pdf"
        bytes = response.body.to_slice
        next "pas un PDF" unless String.new(bytes[0, 5]) == "%PDF-"
        stored = Inv.document_pdf(actor, id).content
        next "différent du PDF conservé à l'émission (#{bytes.size} ≠ #{stored.size} octets)" unless bytes == stored
        @pdf = bytes
        if dir = @pdf_dir
          Dir.mkdir_p(dir)
          File.write(File.join(dir, "#{@host}-#{number}.pdf"), bytes)
        end
        disposition = response.headers["Content-Disposition"]? || ""
        disposition.includes?("#{number}.pdf") || "Content-Disposition : #{disposition}"
      end
      bytes = @pdf || return
      validate_pdf(bytes)
      facturx(bytes, id, number)
    end

    private def validate_pdf(bytes : Bytes) : Nil
      check("pdf-validate, profil pdf-a-3b : conforme (#{bytes.size} octets)") do
        report = PDF::Validate.bytes(bytes, profile: "pdf-a-3b")
        failures = report.fatal_failures.map(&.rule.id)
        ignored = failures & Partiduo::Invoicing::Output::IGNORED_RULES
        puts "          règles de pdf-validate en échec : #{failures.empty? ? "aucune" : failures.join(", ")}" \
             "#{ignored.empty? ? "" : " (écartée(s), B-INV-001)"}"
        rest = failures - ignored
        rest.empty? || rest.join(", ")
      end
    end

    private def facturx(bytes : Bytes, id : Int64, number : String) : Nil
      text = String.new(bytes)
      check("XML Factur-X embarqué (factur-x.xml, relation Data) et identification XMP") do
        missing = ["factur-x.xml", "/AFRelationship /Data", "fx:DocumentType", "INVOICE", "fx:ConformanceLevel",
                   "pdfaid:part"].reject { |needle| text.includes?(needle) }
        missing.empty? || "absent : #{missing.join(", ")}"
      end
      check("XML CII EN 16931 : type 380, numéro, montants") do
        document = XML.parse(String.new(Inv.facturx_xml(actor, id).content))
        ns = {"rsm" => "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100",
              "ram" => "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"}
        values = {
          "guideline" => document.xpath_string("string(//ram:GuidelineSpecifiedDocumentContextParameter/ram:ID)", namespaces: ns),
          "type"      => document.xpath_string("string(//rsm:ExchangedDocument/ram:TypeCode)", namespaces: ns),
          "number"    => document.xpath_string("string(//rsm:ExchangedDocument/ram:ID)", namespaces: ns),
          "gross"     => document.xpath_string("string(//ram:GrandTotalAmount)", namespaces: ns),
          "due"       => document.xpath_string("string(//ram:DuePayableAmount)", namespaces: ns),
        }
        expected = {"guideline" => "urn:cen.eu:en16931:2017", "type" => "380", "number" => number,
                    "gross" => "1073.76", "due" => "1073.76"}
        wrong = expected.reject { |key, value| values[key] == value }
        wrong.empty? || wrong.keys.map { |key| "#{key} = #{values[key].inspect}" }.join(", ")
      end
    end

    @pdf : Bytes? = nil

    # --- Règlement, Facturation seule --------------------------------------------

    private def paid_without_accounting(browser : Browser, id : Int64) : Nil
      puts "-- Règlements (Facturation seule)"
      today = Partiduo::Api::Core.today.to_s("%d/%m/%Y")
      check("règlement partiel de 400 € : partiellement payée") do
        page = browser.get("/invoicing/documents/#{id}/payment")
        next expect(page, 200) unless page.status_code == 200
        response = browser.post("/invoicing/documents/#{id}/payment", {"amount" => "400", "paid_on" => today, "method" => "transfer", "reference" => "VIR-1"})
        next redirect?(response) unless response.status_code == 302
        view = Inv.document(actor, id)
        view.effective_status == "partially_paid" && view.totals.amount_due == BigDecimal.new("673.76") ||
          "#{view.effective_status}, reste #{view.totals.amount_due}"
      end
      check("solde de 673,76 € : facture payée") do
        response = browser.submit("/invoicing/documents/#{id}/payment", {"amount" => "673,76", "paid_on" => today, "method" => "transfer", "reference" => "VIR-2"})
        next redirect?(response) unless response.status_code == 302
        view = Inv.document(actor, id)
        next "#{view.effective_status}, reste #{view.totals.amount_due}" unless view.effective_status == "paid" && view.totals.amount_due.zero?
        expect(browser.follow(response), 200, "Payé", "400,00", "673,76")
      end
      check("aucun règlement de plus (reste nul) : action retirée") do
        !browser.get("/invoicing/documents/#{id}").body.includes?("/invoicing/documents/#{id}/payment") || "action encore proposée"
      end
      exports_without_accounting(id)
    end

    private def exports_without_accounting(id : Int64) : Nil
      check("événements consignés au socle (invoice.issued, payment.recorded ×2)") do
        source = "invoice:#{id}"
        names = Partiduo::Events.journal(Partiduo::Events::JOURNALED).select { |event| event.payload["source"]? == source || event.payload["invoice_id"]? == id.to_s }.map(&.name)
        names.count("invoice.issued") == 1 && names.count("payment.recorded") == 2 || names.join(", ")
      end
      check("Comptabilité inactive : contrat refusé (ModuleDisabled)") do
        Acc.invoicing_history(system)
        "accepté"
      rescue Partiduo::Api::ModuleDisabled
        true
      end
      check("journal des ventes et encaissements (CSV)") do
        csv = Inv.sales_journal_csv(actor, Partiduo::Api::Core.today - 31.days, Partiduo::Api::Core.today)
        text = String.new(csv.content)
        number = Inv.document(actor, id).number.to_s
        text.includes?(number) || "facture absente du journal"
      end
    end

    # --- Règlement, Comptabilité + Facturation ------------------------------------

    private def paid_with_accounting(browser : Browser, id : Int64, customer : String) : Nil
      puts "-- Écriture de vente et lettrage (Comptabilité + Facturation)"
      number = Inv.document(actor, id).number.to_s
      entry = sale_entry(id, number) || return
      card = Partiduo::Api::Cards.card_by_code(actor, customer) || raise "fiche #{customer} absente"
      account = (Acc.card_account(actor, card.id) || raise "client sans compte").account.number
      customer_line = entry.lines.find! { |line| line.account_number == account }
      check("écriture consultée par l'interface") do
        expect(browser.get("/accounting/entries/#{entry.id}"), 200, number, "1 073,76")
      end
      check("rien à comptabiliser dans l'historique de la Facturation") do
        Acc.invoicing_history(actor).none?(&.source.==("invoice:#{id}")) || "facture proposée"
      end
      payment_line = receive_and_match(browser, entry, customer_line.id, customer, number) || return
      settled(browser, id, entry, customer_line.id, payment_line, number)
    end

    private def sale_entry(id : Int64, number : String) : Acc::EntryView?
      sale = nil
      source = "invoice:#{id}"
      check("écriture de vente générée (journal de ventes, pièce #{number}, équilibrée)") do
        entries = Acc.entries(actor, Acc::EntryQuery.new(source: source))
        next "#{entries.size} écriture(s)" unless entries.size == 1
        entry = entries.first
        sale = entry
        next "pièce #{entry.receipt}" unless entry.receipt == number
        next "déséquilibrée" unless entry.total_debit == entry.total_credit
        lines = entry.lines.map { |line| "#{line.account_number} #{line.side.debit? ? "D" : "C"} #{line.amount}" }
        puts "          #{entry.ledger_code} #{entry.date.to_s("%Y-%m-%d")} : #{lines.join(" ; ")}"
        vat = entry.lines.select(&.account_number.starts_with?("4457")).sum(BigDecimal.new(0), &.amount)
        net = entry.lines.select(&.account_number.starts_with?("7")).sum(BigDecimal.new(0), &.amount)
        next "TVA #{vat}" unless vat == BigDecimal.new("178.96")
        next "ventes #{net}" unless net == BigDecimal.new("894.80")
        entry.total_debit == BigDecimal.new("1073.76") || "total #{entry.total_debit}"
      end
      sale
    end

    # Encaissement en banque puis lettrage ; ligne de l'encaissement lettrée.
    private def receive_and_match(browser : Browser, entry : Acc::EntryView, customer_line : Int64, customer : String,
                                  number : String) : Int64?
      today = Partiduo::Api::Core.today.to_s("%d/%m/%Y")
      bank = Acc.ledger_by_code(actor, "F01")
      check("encaissement saisi en banque (extrait financier, #{bank.code})") do
        browser.get("/accounting/entries/financial")
        response = browser.post("/accounting/entries/financial", {"ledger_id" => bank.id.to_s, "date" => today,
                                                                  "line-0-account" => customer, "line-0-label" => "Virement #{number}",
                                                                  "line-0-debit" => "1073,76"})
        redirect?(response, "/accounting/entries/financial")
      end
      payment_line = nil
      check("lettrage de la vente et de l'encaissement par l'écran de lettrage") do
        page = browser.get("/accounting/matching?#{URI::Params.encode({"q" => customer})}")
        next expect(page, 200) unless page.status_code == 200
        ids = page.body.scan(/name="line" value="(\d+)"/).map(&.[1].to_i64)
        next "ligne de la vente absente (#{ids})" unless ids.includes?(customer_line)
        payment_line = ids.find(&.!=(customer_line))
        other = payment_line || next "ligne de l'encaissement absente"
        response = browser.post_pairs("/accounting/matching", [{"q", customer}, {"line", customer_line.to_s}, {"line", other.to_s}])
        next redirect?(response) unless response.status_code == 302
        # Code tiré de l'identifiant du lettrage (global, comme `jnt_letter` de NOALYSS).
        code = Acc.entry(actor, entry.id).lines.find! { |item| item.id == customer_line }.matching_code
        expect(browser.follow(response), 200, "Lettrage #{code} créé (2 lignes).")
      end
      payment_line
    end

    private def settled(browser : Browser, id : Int64, entry : Acc::EntryView, customer_line : Int64, payment_line : Int64,
                        number : String) : Nil
      check("payment.matched → facture payée, règlement enregistré") do
        view = Inv.document(actor, id)
        next "#{view.effective_status}, reste #{view.totals.amount_due}" unless view.effective_status == "paid" && view.totals.amount_due.zero?
        payments = Inv.payments(actor, id)
        next "#{payments.size} règlement(s)" unless payments.size == 1 && payments.first.amount == BigDecimal.new("1073.76")
        expect(browser.get("/invoicing/documents/#{id}"), 200, "Payé")
      end
      check("ligne client de la vente lettrée avec l'encaissement, lettrage équilibré") do
        line = Acc.entry(actor, entry.id).lines.find! { |item| item.id == customer_line }
        matching = Acc.matching(actor, line.matching_id || next "non lettrée")
        next "lignes #{matching.lines.map(&.line_id)}" unless matching.lines.map(&.line_id).sort! == [customer_line, payment_line].sort!
        puts "          lettrage #{line.matching_code} : vente #{number} ↔ encaissement en banque"
        matching.balanced? || "lettrage déséquilibré"
      end
      check("pas de saisie de règlement dans la Facturation (lettrage en Comptabilité)") do
        !browser.get("/invoicing/documents/#{id}").body.includes?("/invoicing/documents/#{id}/payment") || "action proposée"
      end
    end

    private def lists(browser : Browser, id : Int64) : Nil
      puts "-- Listes"
      number = Inv.document(actor, id).number.to_s
      check("liste des documents : facture payée") { expect(browser.get("/invoicing/documents?kind=invoice"), 200, number, "Payé") }
      check("aperçu imprimable") { expect(browser.get("/invoicing/documents/#{id}/preview"), 200, number) }
    end
  end
end

host = "demo.partiduo.localhost"
email = ""
password = ENV["PARTIDUO_DEMO_PASSWORD"]? || "Demo-jalonF-Partiduo-2026"
invitation = nil
base_url = nil
pdf_dir = nil
OptionParser.parse do |parser|
  parser.banner = "Usage : crystal run scripts/demo_jalon_f.cr -- --host=HÔTE --email=ADRESSE [--invitation=LIEN] [--base-url=URL]"
  parser.on("--host=HOST", "hôte de l'instance (<dossier>.<domaine>)") { |value| host = value }
  parser.on("--email=EMAIL", "adresse de l'administrateur") { |value| email = value }
  parser.on("--password=PASSWORD", "mot de passe à choisir ou à utiliser") { |value| password = value }
  parser.on("--invitation=LINK", "lien (ou jeton) d'invitation affiché par partiduo-provision") { |value| invitation = value }
  parser.on("--base-url=URL", "serveur démarré (sinon : pile de Marten en mémoire)") { |value| base_url = value }
  parser.on("--pdf-dir=DIR", "où déposer le PDF de la facture") { |value| pdf_dir = value }
end
abort "--email est obligatoire" if email.empty?

Marten.configure(&.log_level=(::Log::Severity::Warn))
Marten.setup
demo = DemoF::Run.new(host, email, password, invitation, base_url, pdf_dir)
demo.run
puts demo.failures.zero? ? "== Tout est vert (#{demo.steps} étapes)." : "== #{demo.failures} étape(s) en échec sur #{demo.steps}."
exit(demo.failures.zero? ? 0 : 1)
