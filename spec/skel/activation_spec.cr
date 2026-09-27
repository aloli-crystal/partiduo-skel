# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def admin : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(1_i64, [Partiduo::Api::Modules::MANAGE_MODULES])
end

private def menu_routes(entries : Array(Partiduo::Api::Modules::MenuView)) : Array(String?)
  entries.flat_map { |entry| [entry.route] + menu_routes(entry.children) }
end

describe "Extension SKEL : manifeste et activation (ADR-003 D2, D4 ; ADR-006 D2)" do
  it "déclare une extension conforme au contrat du cœur" do
    manifest = Partiduo::Modules[Skel::CODE]
    manifest.kind.should eq(Partiduo::Modules::Kind::Extension)
    manifest.version.should eq(Skel::VERSION)
    manifest.permissions.should eq(["skel.view"])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route, menu.permission} }
      .should eq([{"SKEL", "EXTENSION", "skel:index", "skel.view"}])
    manifest.subscribed_events.should eq(["entry.posted"])
    manifest.uis.map(&.path).should eq(["ui/bulma"])
    Partiduo::Modules.structure_errors.should be_empty
    manifest.depends_on.should eq(["ACCOUNTING"])
    Partiduo::Modules.dependency_errors(manifest, Set{Skel::CODE, "ACCOUNTING"}).should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Skel::CODE}).should_not be_empty
  end

  it "traduit son nom, sa permission et son menu en fr, en et nl" do
    manifest = Partiduo::Modules[Skel::CODE]
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        keys.each { |key| I18n.t(key).should_not contain("missing") }
      end
    end
  end

  it "est inactive tant que l'instance ne l'active pas" do
    Partiduo::Api::Modules.get(admin, "skel").active.should be_false
    Partiduo::Api::Modules.permissions(admin).map(&.name).should_not contain("skel.view")
    menu_routes(Partiduo::Api::Modules.menu(skel_viewer)).should_not contain("skel:index")
    expect_raises(Partiduo::Api::ModuleDisabled) { Skel::Api.summary(skel_viewer) }
  end

  it "s'active sur l'instance par l'administrateur, puis se désactive en gardant ses données" do
    result = Partiduo::Api::Modules.activate(admin, "skel")
    result.success?.should be_true
    result.value!.active.should be_true
    result.value!.kind.should eq("extension")
    Partiduo::Modules.check!

    Partiduo::Api::Modules.permissions(admin).map(&.name).should contain("skel.view")
    menu_routes(Partiduo::Api::Modules.menu(skel_viewer)).should contain("skel:index")
    menu_routes(Partiduo::Api::Modules.menu(Partiduo::Api::Actor.user(2_i64, [] of String))).should_not contain("skel:index")

    post_entry(42_i64)
    Skel::Api.summary(skel_viewer).count.should eq(1)

    Partiduo::Api::Modules.deactivate(admin, "skel").value!.active.should be_false
    expect_raises(Partiduo::Api::ModuleDisabled) { Skel::Api.summary(skel_viewer) }
    Skel::ReceivedEntry.all.count.should eq(1)

    Partiduo::Api::Modules.activate(admin, "skel").value!.active.should be_true
    Skel::Api.summary(skel_viewer).latest.map(&.entry_id).should eq([42_i64])
  end

  it "refuse l'activation sans la Comptabilité, qui publie entry.posted (ADR-006 D2)" do
    with_active_modules("invoicing") do
      result = Partiduo::Api::Modules.activate(admin, "skel")
      result.error_keys.should eq(["modules.errors.activation.missing_dependency"])
      Partiduo::Api::Modules.get(admin, "skel").active.should be_false
    end
  end

  it "empêche de désactiver la Comptabilité tant que SKEL est active" do
    with_active_modules("accounting,invoicing") do
      Partiduo::Api::Modules.activate(admin, "skel").success?.should be_true
      result = Partiduo::Api::Modules.deactivate(admin, "accounting")
      result.errors.map { |error| error.params["dependent"]? }.should contain("SKEL")
      Partiduo::Api::Modules.get(admin, "accounting").active.should be_true
    end
  end

  it "s'active au provisionnement d'une instance (`partiduo-provision --with skel`)" do
    with_active_modules("accounting,skel") do
      settings = Partiduo::Api::Core::SettingsInput.new(
        company_name: "Exemple SARL", tax_regime: "fr", domain: "exemple.partiduo.localhost",
        street: "rue des Lilas", postcode: "44000", city: "Nantes",
      )
      input = Partiduo::Api::Core::ProvisionInput.new(settings: settings, modules: ["accounting"], extensions: ["skel"])
      view = Partiduo::Api::Core.provision(Partiduo::Api::Actor.system, input).value!
      view.active_modules.should contain("SKEL")
      Partiduo::Modules.check!
      Skel::Api.summary(skel_viewer).count.should eq(0)
    end
  end

  it "refuse son contrat sans la permission skel.view" do
    activate_skel
    expect_raises(Partiduo::Api::Forbidden) { Skel::Api.summary(Partiduo::Api::Actor.user(2_i64, [] of String)) }
    expect_raises(Partiduo::Api::Forbidden) { Skel::Api.received_entries(Partiduo::Api::Actor.anonymous) }
  end
end
