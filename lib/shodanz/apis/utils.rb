# frozen_string_literal: true

require_relative 'utils.rb'

# fronzen_string_literal: true

module Shodanz
  module API
    # Utils provides simply get, post, and slurp_stream functionality
    # to the client. Under the hood they support both async and non-async
    # usage. You should basically never need to use these methods directly.
    #
    # @author Kent 'picat' Gruber
    module Utils
      # Perform a direct GET HTTP request to the REST API.
      def get(path, **params)
        return sync_get(path, **params) unless Async::Task.current?

        async_get(path, **params)
      end

      # Perform a direct POST HTTP request to the REST API.
      def post(path, body: nil, **params)
        return sync_post(path, params: params, body: body) unless Async::Task.current?

        async_post(path, params: params, body: body)
      end

      # Perform the main function of consuming the streaming API.
      def slurp_stream(path, **params)
        if Async::Task.current?
          async_slurp_stream(path, **params) do |result|
            yield result
          end
        else
          sync_slurp_stream(path, **params) do |result|
            yield result
          end
        end
      end

      def turn_into_query(**params)
        filters = params.reject { |key, _| key == :query }
        filters.each do |key, value|
          params[:query] << " #{key}:#{value}"
        end
        params.select { |key, _| key == :query }
      end

      def turn_into_facets(**facets)
        return {} if facets.nil?

        filters = facets.reject { |key, _| key == :facets }
        facets[:facets] = []
        filters.each do |key, value|
          facets[:facets] << "#{key}:#{value}"
        end
        facets[:facets] = facets[:facets].join(',')
        facets.select { |key, _| key == :facets }
      end

      private

      RATELIMIT    = 'rate limit reached'
      NOINFO       = 'no information available'
      NOQUERY      = 'empty search query'
      ACCESSDENIED = 'access denied'
      INVALIDKEY   = 'invalid API key'

      def handle_any_json_errors(json)
        if json.is_a?(Hash) && json.key?('error')
          raise Shodanz::Errors::RateLimited if json['error'].casecmp(RATELIMIT) >= 0
          raise Shodanz::Errors::NoInformation if json['error'].casecmp(NOINFO) >= 0
          raise Shodanz::Errors::NoQuery if json['error'].casecmp(NOQUERY) >= 0
          raise Shodanz::Errors::AccessDenied if json['error'].casecmp(ACCESSDENIED) >= 0
          raise Shodanz::Errors::InvalidKey if json['error'].casecmp(INVALIDKEY) >= 0
        end
        return json
      end

      def getter(path, **params)
        # param keys should all be strings
        params = params.transform_keys(&:to_s)
        # build up url string based on special params
        url = "/#{path}?key=#{@key}"
        # special params
        params.each do |param,value|
          next if value.is_a?(String) && value.empty?
          value = URI.encode_www_form_component("#{value}")
          url += "&#{param}=#{value}"
        end

        resp = @client.get(url)

        if resp.success?
          # parse all lines in the response body as JSON
          json = JSON.parse(resp.body.join)

          handle_any_json_errors(json)

          return json
        else
          raise "Got response status #{resp.status}"
        end
      ensure
        @client.pool.close
        resp&.close
      end

      def poster(path, params: nil, body: nil)
        # param keys should all be strings
        params = params.transform_keys(&:to_s)
        # and the key param is constant
        params["key"] = @key
        # encode as a URL string
        params = URI.encode_www_form(params)
        # build URL path
        path = "/#{path}?#{params}"

        headers = nil

        if body
          body = URI.encode_www_form(body)
          headers = [['Content-Type', 'application/x-www-form-urlencoded']]
        end

        # make POST request to server
        resp = @client.post(path, headers, body)

        if resp.success?
          json = JSON.parse(resp.body.join)

          handle_any_json_errors(json)

          return json
        else
          raise "Got response status #{resp.status}"
        end
      ensure
        @client.pool.close
        resp&.close
      end

      def slurper(path, **params)
        # param keys should all be strings
        params = params.transform_keys(&:to_s)
        # check if limit
        if (limit = params.delete('limit'))
          counter = 0
        end
        # make GET request to server
        resp = @client.get("/#{path}?key=#{@key}", params)
        # read body line-by-line
        until resp.body.nil? || resp.body.empty?
          resp.body.read.each_line do |line|
            next if line.strip.empty?

            yield JSON.parse(line)
            if limit
              counter += 1
              resp.close if counter == limit
            end
          end
        end
      ensure
        resp&.close
      end

      def async_get(path, **params)
        Async::Task.current.async do
          getter(path, **params)
        end
      end

      def sync_get(path, **params)
        Async do
          getter(path, **params)
        end.wait
      end

      def async_post(path, params: nil, body: nil)
        Async::Task.current.async do
          poster(path, params: params, body: body)
        end
      end

      def sync_post(path, params: nil, body: nil)
        Async do
          poster(path, params: params, body: body)
        end.wait
      end

      def async_slurp_stream(path, **params)
        Async::Task.current.async do
          slurper(path, **params) { |data| yield data }
        end
      end

      def sync_slurp_stream(path, **params)
        Async do
          slurper(path, **params) { |data| yield data }
        end.wait
      end
    end
  end
end
