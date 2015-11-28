require 'json'
require 'nokogiri'
require 'faraday'
require 'faraday_middleware'
require 'excon'
require 'uri'

module Maremma
  def get_result(url, content_type: 'json', headers: {}, **options)
    conn = faraday_conn(content_type, options)
    conn = auth_conn(conn, options)

    conn.options[:timeout] = options[:timeout] || DEFAULT_TIMEOUT

    # make sure we use a 'Host' header
    headers['Host'] = URI.parse(url).host

    if options[:data]
      response = conn.post url, {}, headers do |request|
        request.body = options[:data]
      end
    else
      response = conn.get url, {}, headers
    end
    parse_response(response.body)
  rescue *NETWORKABLE_EXCEPTIONS => error
    rescue_faraday_error(error)
  end

  def faraday_conn(content_type = 'json', options = {})
    # use short version for html, xml and json
    content_types = { "html" => 'text/html; charset=UTF-8',
                      "xml" => 'application/xml',
                      "json" => 'application/json' }
    accept_header = content_types.fetch(content_type, content_type)

    # redirect limit
    limit = options[:limit] || 10

    Faraday.new do |c|
      c.headers['Accept'] = accept_header
      c.headers['User-Agent'] = "spinone - http://#{ENV['HOSTNAME']}"
      c.use      FaradayMiddleware::FollowRedirects, limit: limit, cookie: :all
      c.request  :multipart
      c.request  :json if accept_header == 'application/json'
      c.use      Faraday::Response::RaiseError
      c.response :encoding
      c.adapter  :excon
    end
  end

  def auth_conn(conn, options)
    if options[:bearer]
      conn.authorization :Bearer, options[:bearer]
    elsif options[:token]
      conn.authorization :Token, token: options[:token]
    elsif options[:username]
      conn.basic_auth(options[:username], options[:password])
    end
    conn
  end

  def rescue_faraday_error(error)
    if error.is_a?(Faraday::ResourceNotFound)
      { error: "resource not found", status: 404 }
    elsif error.is_a?(Faraday::TimeoutError) || error.is_a?(Faraday::ConnectionFailed) || (error.try(:response) && error.response[:status] == 408)
      { error: "execution expired", status: 408 }
    else
      { error: parse_error_response(error.message), status: 400 }
    end
  end

  def parse_error_response(string)
    string = parse_response(string)

    if string.is_a?(Hash) && string['error']
      string['error']
    else
      string
    end
  end

  def parse_response(string)
    as_json(string) || as_xml(string) || force_utf8(string)
  end

  protected

  def as_xml(string)
    if Nokogiri::XML(string).errors.empty?
      Hash.from_xml(string)
    else
      false
    end
  end

  def as_json(string)
    ::ActiveSupport::JSON.decode(string)
  rescue ::ActiveSupport::JSON.parse_error
    false
  end

  def force_utf8(string)
    string.gsub(/\s+\n/, "\n").strip.force_encoding('UTF-8')
  end
end