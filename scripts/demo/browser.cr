# SPDX-License-Identifier: AGPL-3.0-or-later

# Navigateur en mémoire des démonstrations de bout en bout (`demo_jalon1.cr`,
# `demo_jalon2.cr`) : les requêtes traversent la vraie pile de Marten
# (gestion des erreurs, middlewares, routage, handlers, gabarits) sans ouvrir
# de port (BLOCAGES B-UI-001).
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

    # Champs répétés (cases cochées d'un même nom) : paires dans l'ordre.
    def post_pairs(path : String, pairs : Array({String, String}), headers : ::HTTP::Headers? = nil) : ::HTTP::Client::Response
      body = URI::Params.build do |form|
        pairs.each { |(name, value)| form.add(name, value) }
        form.add("csrftoken", @csrf.to_s)
      end
      perform("POST", path, body, headers)
    end

    def follow(response : ::HTTP::Client::Response) : ::HTTP::Client::Response
      get(response.headers["Location"])
    end

    private def perform(method : String, path : String, body : String? = nil, extra : ::HTTP::Headers? = nil) : ::HTTP::Client::Response
      headers = ::HTTP::Headers{"Host" => @host, "Accept-Language" => @locale, "User-Agent" => "partiduo-demo"}
      extra.try &.each { |name, values| headers[name] = values }
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
end
