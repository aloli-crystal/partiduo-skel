# SPDX-License-Identifier: AGPL-3.0-or-later

# Exécute le bloc avec une autre liste de modules actifs (`PARTIDUO_MODULES`),
# puis restaure la configuration. Sans ligne dans `modules_activation`, c'est
# l'ensemble actif de l'instance (DECISIONS D-018).
def with_active_modules(codes : String?, &)
  previous = ENV["PARTIDUO_MODULES"]?
  codes.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = codes)
  yield
ensure
  previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
end

# Active l'extension sur l'instance, comme l'administrateur (ADR-006 D2).
def activate_skel : Nil
  Partiduo::Api::Modules.activate(Partiduo::Api::Actor.system, Skel::CODE).value!
  nil
end

# Publie `entry.posted` comme le fera le service d'écriture de la
# Comptabilité (DECISIONS D-SKEL-003).
def post_entry(entry_id : Int64, actor_user_id : Int64? = nil) : Partiduo::Events::Event
  Partiduo::Events.publish("entry.posted", {"entry_id" => entry_id.to_s}, actor_user_id: actor_user_id)
end

def skel_viewer : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(1_i64, [Skel::Api::VIEW])
end
