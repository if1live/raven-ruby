require 'raven/interfaces'

module Raven
  class HttpInterface < Interface

    name 'request'
    attr_accessor :url
    attr_accessor :method
    attr_accessor :data
    attr_accessor :query_string
    attr_accessor :cookies
    attr_accessor :headers
    attr_accessor :env

    def initialize(*arguments)
      self.headers = {}
      self.env = {}
      self.cookies = nil
      super(*arguments)
    end

    def from_rack(env)
      req = ::Rack::Request.new(env)
      self.url = req.scheme && req.url.split('?').first
      self.method = req.request_method
      self.query_string = req.query_string
      env.each_pair do |key, value|
        key = key.to_s #rack env can contain symbols
        next unless key.upcase == key # Non-upper case stuff isn't either
        if key.start_with?('HTTP_')
          # Header
          http_key = key[5..key.length - 1].split('_').map { |s| s.capitalize }.join('-')
          self.headers[http_key] = value.to_s
        elsif ['CONTENT_TYPE', 'CONTENT_LENGTH'].include? key
          self.headers[key.capitalize] = value.to_s
        elsif ['REMOTE_ADDR', 'SERVER_NAME', 'SERVER_PORT'].include? key
          # Environment
          self.env[key] = value.to_s
        end
      end

      # overwrite ip address (for proxy)
      # sentry use REMOTE_ADDR as ip address. overwrite it.
      env_table = {}
      env.each_pair do |key, value|
        env_table[key.to_s] = value
      end

      if env_table.include? 'HTTP_X_FORWARDED_FOR'
        self.env['REMOTE_ADDR'] = env_table['HTTP_X_FORWARDED_FOR']
      elsif env_table.include? 'REMOTE_ADDR'
        self.env['REMOTE_ADDR'] = env_table['REMOTE_ADDR']
      end

      self.data =
        if req.form_data?
          req.POST
        elsif req.body
          data = req.body.read
          req.body.rewind
          data
        end
    end
  end

  register_interface :http => HttpInterface
end
