# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Page de l'extension SKEL sous /ext/SKEL/ (ADR-003 D3, ADR-005 D4)" do
  it "est montée sous le code de l'extension, au nom de route du manifeste" do
    Marten.routes.reverse("skel:index").should eq("/ext/SKEL/")
    PartiduoUi::Extensions["SKEL"]?.try(&.permission).should eq("skel.view")
  end

  it "n'existe pas tant que l'extension est inactive (404)" do
    PartiduoUi::Accounts.create
    PartiduoUi::Accounts.signed_in.get("/ext/SKEL/").status.should eq(404)
  end

  it "renvoie un visiteur non connecté vers la connexion" do
    activate_skel
    response = PartiduoUi::Browser.new.get("/ext/SKEL/")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fext%2FSKEL%2F")
  end

  it "s'affiche pour un profil qui a skel.view, avec les écritures reçues" do
    activate_skel
    viewer = PartiduoUi::Accounts.profile("Lecteur SKEL", ["skel.view"])
    PartiduoUi::Accounts.create(profile: nil, profile_id: viewer)
    browser = PartiduoUi::Accounts.signed_in

    response = browser.get("/ext/SKEL/")
    response.status.should eq(200)
    response.html.should contain("Écritures reçues")
    response.html.should contain("0 écriture reçue.")
    response.html.should contain("Aucune écriture reçue")
    # L'entrée du menu du manifeste mène à la page.
    response.html.should contain(%(href="/ext/SKEL/"))

    post_entry(42_i64)
    post_entry(43_i64)
    response = browser.get("/ext/SKEL/")
    response.html.should contain("2 écritures reçues.")
    response.html.should contain("<td>42</td>")
    response.html.should contain("<td>43</td>")
  end

  it "s'affiche pour l'administrateur, qui a toutes les permissions actives" do
    activate_skel
    PartiduoUi::Accounts.create
    PartiduoUi::Accounts.signed_in.get("/ext/SKEL/").status.should eq(200)
  end

  it "est refusée aux profils sans skel.view (403), avant le handler" do
    activate_skel
    profile = PartiduoUi::Accounts.profile("Sans extension", ["accounting.entry.read"])
    PartiduoUi::Accounts.create(profile: nil, profile_id: profile)
    response = PartiduoUi::Accounts.signed_in.get("/ext/SKEL/")
    response.status.should eq(403)
    response.html.should contain("Accès refusé")
    response.html.should_not contain("Écritures reçues")
    response.html.should_not contain(%(href="/ext/SKEL/"))
  end

  it "se traduit selon la langue de l'utilisateur" do
    activate_skel
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    {"en" => "Received entries", "nl" => "Ontvangen boekingen", "fr" => "Écritures reçues"}.each do |locale, title|
      browser.post("/language", {"locale" => locale, "next" => "/ext/SKEL/"})
      browser.get("/ext/SKEL/").html.should contain(title)
    end
  end
end
