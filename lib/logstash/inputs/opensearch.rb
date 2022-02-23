# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/json"
require "logstash/util/safe_uri"
require 'logstash/plugin_mixins/validator_support/field_reference_validation_adapter'
require 'logstash/plugin_mixins/event_support/event_factory_adapter'
require 'logstash/plugin_mixins/ecs_compatibility_support'
require 'logstash/plugin_mixins/ecs_compatibility_support/target_check'
require "base64"

require "opensearch"
require "opensearch/transport/transport/http/manticore"
require_relative "opensearch/patches/_opensearch_transport_http_manticore"
require_relative "opensearch/patches/_opensearch_transport_connections_selector"
#include(OpenSearch::Transport::Transport::HTTP::Manticore)

# .Compatibility Note
# [NOTE]
# ================================================================================
# Starting with OpenSearch 5.3, there's an {ref}modules-http.html[HTTP setting]
# called `http.content_type.required`. If this option is set to `true`, and you
# are using Logstash 2.4 through 5.2, you need to update the OpenSearch input
# plugin to version 4.0.2 or higher.
# 
# ================================================================================
# 
# Read from an OpenSearch cluster, based on search query results.
# This is useful for replaying test logs, reindexing, etc.
# It also supports periodically scheduling lookup enrichments
# using a cron syntax (see `schedule` setting).
#
# Example:
# [source,ruby]
#     input {
#       # Read all documents from OpenSearch matching the given query
#       opensearch {
#         hosts => "localhost"
#         query => '{ "query": { "match": { "statuscode": 200 } }, "sort": [ "_doc" ] }'
#       }
#     }
#
# This would create an OpenSearch query with the following format:
# [source,json]
#     curl 'http://localhost:9200/logstash-*/_search?&scroll=1m&size=1000' -d '{
#       "query": {
#         "match": {
#           "statuscode": 200
#         }
#       },
#       "sort": [ "_doc" ]
#     }'
#
# ==== Scheduling
#
# Input from this plugin can be scheduled to run periodically according to a specific
# schedule. This scheduling syntax is powered by https://github.com/jmettraux/rufus-scheduler[rufus-scheduler].
# The syntax is cron-like with some extensions specific to Rufus (e.g. timezone support ).
#
# Examples:
#
# |==========================================================
# | `* 5 * 1-3 *`               | will execute every minute of 5am every day of January through March.
# | `0 * * * *`                 | will execute on the 0th minute of every hour every day.
# | `0 6 * * * America/Chicago` | will execute at 6:00am (UTC/GMT -5) every day.
# |==========================================================
#
#
# Further documentation describing this syntax can be found https://github.com/jmettraux/rufus-scheduler#parsing-cronlines-and-time-strings[here].
#
#
class LogStash::Inputs::OpenSearch < LogStash::Inputs::Base

  include LogStash::PluginMixins::ECSCompatibilitySupport(:disabled, :v1, :v8 => :v1)
  include LogStash::PluginMixins::ECSCompatibilitySupport::TargetCheck

  include LogStash::PluginMixins::EventSupport::EventFactoryAdapter

  extend LogStash::PluginMixins::ValidatorSupport::FieldReferenceValidationAdapter

  config_name "opensearch"

  # List of opensearch hosts to use for querying.
  # Each host can be either IP, HOST, IP:port or HOST:port.
  # Port defaults to 9200
  config :hosts, :validate => :array

  # The index or alias to search.
  config :index, :validate => :string, :default => "logstash-*"

  # The query to be executed. Read the OpenSearch query DSL documentation
  # for more info
  # https://opensearch.org/docs/latest/opensearch/query-dsl/index/
  config :query, :validate => :string, :default => '{ "sort": [ "_doc" ] }'

  # This allows you to set the maximum number of hits returned per scroll.
  config :size, :validate => :number, :default => 1000

  # This parameter controls the keepalive time in seconds of the scrolling
  # request and initiates the scrolling process. The timeout applies per
  # round trip (i.e. between the previous scroll request, to the next).
  config :scroll, :validate => :string, :default => "1m"

  # This parameter controls the number of parallel slices to be consumed simultaneously
  # by this pipeline input.
  config :slices, :validate => :number

  # If set, include OpenSearch document information such as index, type, and
  # the id in the event.
  #
  # It might be important to note, with regards to metadata, that if you're
  # ingesting documents with the intent to re-index them (or just update them)
  # that the `action` option in the opensearch output wants to know how to
  # handle those things. It can be dynamically assigned with a field
  # added to the metadata.
  #
  # Example
  # [source, ruby]
  #     input {
  #       opensearch {
  #         hosts => "es.production.mysite.org"
  #         index => "mydata-2018.09.*"
  #         query => "*"
  #         size => 500
  #         scroll => "5m"
  #         docinfo => true
  #       }
  #     }
  #     output {
  #       opensearch {
  #         index => "copy-of-production.%{[@metadata][_index]}"
  #         document_type => "%{[@metadata][_type]}"
  #         document_id => "%{[@metadata][_id]}"
  #       }
  #     }
  #
  config :docinfo, :validate => :boolean, :default => false

  # Where to move the OpenSearch document information.
  # default: [@metadata][input][opensearch] in ECS mode, @metadata field otherwise
  config :docinfo_target, :validate=> :field_reference

  # List of document metadata to move to the `docinfo_target` field.
  config :docinfo_fields, :validate => :array, :default => ['_index', '_type', '_id']

  # Basic Auth - username
  config :user, :validate => :string

  # Basic Auth - password
  config :password, :validate => :password

  # Connection Timeout, in Seconds
  config :connect_timeout_seconds, :validate => :positive_whole_number, :default => 10

  # Request Timeout, in Seconds
  config :request_timeout_seconds, :validate => :positive_whole_number, :default => 60

  # Socket Timeout, in Seconds
  config :socket_timeout_seconds, :validate => :positive_whole_number, :default => 60

  # Set the address of a forward HTTP proxy.
  config :proxy, :validate => :uri_or_empty

  # SSL
  config :ssl, :validate => :boolean, :default => false

  # SSL Certificate Authority file in PEM encoded format, must also include any chain certificates as necessary 
  config :ca_file, :validate => :path

  # Schedule of when to periodically run statement, in Cron format
  # for example: "* * * * *" (execute query every minute, on the minute)
  #
  # There is no schedule by default. If no schedule is given, then the statement is run
  # exactly once.
  config :schedule, :validate => :string

  # If set, the _source of each hit will be added nested under the target instead of at the top-level
  config :target, :validate => :field_reference

  def initialize(params={})
    super(params)

    if docinfo_target.nil?
      @docinfo_target = ecs_select[disabled: '@metadata', v1: '[@metadata][input][opensearch]']
    end
  end

  def register
    require "rufus/scheduler"

    @options = {
      :index => @index,
      :scroll => @scroll,
      :size => @size
    }
    @base_query = LogStash::Json.load(@query)
    if @slices
      @base_query.include?('slice') && fail(LogStash::ConfigurationError, "OpenSearch Input Plugin's `query` option cannot specify specific `slice` when configured to manage parallel slices with `slices` option")
      @slices < 1 && fail(LogStash::ConfigurationError, "OpenSearch Input Plugin's `slices` option must be greater than zero, got `#{@slices}`")
    end


    transport_options = {:headers => {}}
    transport_options[:headers].merge!(setup_basic_auth(user, password))
    transport_options[:headers].merge!({'user-agent' => prepare_user_agent()})
    transport_options[:request_timeout] = @request_timeout_seconds unless @request_timeout_seconds.nil?
    transport_options[:connect_timeout] = @connect_timeout_seconds unless @connect_timeout_seconds.nil?
    transport_options[:socket_timeout]  = @socket_timeout_seconds  unless @socket_timeout_seconds.nil?

    hosts = setup_hosts
    ssl_options = setup_ssl

    @logger.warn "Supplied proxy setting (proxy => '') has no effect" if @proxy.eql?('')

    transport_options[:proxy] = @proxy.to_s if @proxy && !@proxy.eql?('')

    @client = OpenSearch::Client.new(
      :hosts => hosts,
      :transport_options => transport_options,
      :transport_class => ::OpenSearch::Transport::Transport::HTTP::Manticore,
      :ssl => ssl_options
    )
    test_connection!
    @client
  end


  def run(output_queue)
    if @schedule
      @scheduler = Rufus::Scheduler.new(:max_work_threads => 1)
      @scheduler.cron @schedule do
        do_run(output_queue)
      end

      @scheduler.join
    else
      do_run(output_queue)
    end
  end

  def stop
    @scheduler.stop if @scheduler
  end

  private

  def do_run(output_queue)
    # if configured to run a single slice, don't bother spinning up threads
    return do_run_slice(output_queue) if @slices.nil? || @slices <= 1

    logger.warn("managed slices for query is very large (#{@slices}); consider reducing") if @slices > 8

    @slices.times.map do |slice_id|
      Thread.new do
        LogStash::Util::set_thread_name("#{@id}_slice_#{slice_id}")
        do_run_slice(output_queue, slice_id)
      end
    end.map(&:join)
  end

  def do_run_slice(output_queue, slice_id=nil)
    slice_query = @base_query
    slice_query = slice_query.merge('slice' => { 'id' => slice_id, 'max' => @slices}) unless slice_id.nil?

    slice_options = @options.merge(:body => LogStash::Json.dump(slice_query) )

    logger.info("Slice starting", slice_id: slice_id, slices: @slices) unless slice_id.nil?

    begin
      r = search_request(slice_options)

      r['hits']['hits'].each { |hit| push_hit(hit, output_queue) }
      logger.debug("Slice progress", slice_id: slice_id, slices: @slices) unless slice_id.nil?

      has_hits = r['hits']['hits'].any?
      scroll_id = r['_scroll_id']

      while has_hits && scroll_id && !stop?
        has_hits, scroll_id = process_next_scroll(output_queue, scroll_id)
        logger.debug("Slice progress", slice_id: slice_id, slices: @slices) if logger.debug? && slice_id
      end
      logger.info("Slice complete", slice_id: slice_id, slices: @slices) unless slice_id.nil?
    ensure
      clear_scroll(scroll_id)
    end
  end

  ##
  # @param output_queue [#<<]
  # @param scroll_id [String]: a scroll id to resume
  # @return [Array(Boolean,String)]: a tuple representing whether the response
  #
  def process_next_scroll(output_queue, scroll_id)
    r = scroll_request(scroll_id)
    r['hits']['hits'].each { |hit| push_hit(hit, output_queue) }
    [r['hits']['hits'].any?, r['_scroll_id']]
  rescue => e
    # this will typically be triggered by a scroll timeout
    logger.error("Scroll request error, aborting scroll", message: e.message, exception: e.class)
    # return no hits and original scroll_id so we can try to clear it
    [false, scroll_id]
  end

  def push_hit(hit, output_queue)
    event = targeted_event_factory.new_event hit['_source']
    set_docinfo_fields(hit, event) if @docinfo
    decorate(event)
    output_queue << event
  end

  def set_docinfo_fields(hit, event)
    # do not assume event[@docinfo_target] to be in-place updatable. first get it, update it, then at the end set it in the event.
    docinfo_target = event.get(@docinfo_target) || {}

    unless docinfo_target.is_a?(Hash)
      @logger.error("Incompatible Event, incompatible type for the docinfo_target=#{@docinfo_target} field in the `_source` document, expected a hash got:", :docinfo_target_type => docinfo_target.class, :event => event.to_hash_with_metadata)

      # TODO: (colin) I am not sure raising is a good strategy here?
      raise Exception.new("OpenSearch input: incompatible event")
    end

    @docinfo_fields.each do |field|
      docinfo_target[field] = hit[field]
    end

    event.set(@docinfo_target, docinfo_target)
  end

  def clear_scroll(scroll_id)
    @client.clear_scroll(:body => { :scroll_id => scroll_id }) if scroll_id
  rescue => e
    # ignore & log any clear_scroll errors
    logger.warn("Ignoring clear_scroll exception", message: e.message, exception: e.class)
  end

  def scroll_request scroll_id
    @client.scroll(:body => { :scroll_id => scroll_id }, :scroll => @scroll)
  end

  def search_request(options)
    @client.search(options)
  end

  def hosts_default?(hosts)
    hosts.nil? || ( hosts.is_a?(Array) && hosts.empty? )
  end

  def setup_ssl
    @ssl && @ca_file ? { :ssl  => true, :ca_file => @ca_file } : {}
    #@ssl ? { :ssl  => true } : {}
  end

  def setup_hosts
    @hosts = Array(@hosts).map { |host| host.to_s } # potential SafeURI#to_s
    if @ssl
      @hosts.map do |h|
        host, port = h.split(":")
        { :host => host, :scheme => 'https', :port => port }
      end
    else
      @hosts
    end
  end

  def setup_basic_auth(user, password)
    return {} unless user && password && password.value

    token = ::Base64.strict_encode64("#{user}:#{password.value}")
    { 'Authorization' => "Basic #{token}" }
  end

  def prepare_user_agent
      os_name = java.lang.System.getProperty('os.name')
      os_version = java.lang.System.getProperty('os.version')
      os_arch = java.lang.System.getProperty('os.arch')
      jvm_vendor = java.lang.System.getProperty('java.vendor')
      jvm_version = java.lang.System.getProperty('java.version')

      plugin_version = Gem.loaded_specs["logstash-input-opensearch"].version
      # example: logstash/7.14.1 (OS=Linux-5.4.0-84-generic-amd64; JVM=AdoptOpenJDK-11.0.11) logstash-input-opensearch/4.10.0
      "logstash/#{LOGSTASH_VERSION} (OS=#{os_name}-#{os_version}-#{os_arch}; JVM=#{jvm_vendor}-#{jvm_version}) logstash-#{@plugin_type}-#{config_name}/#{plugin_version}"
  end

  # @private used by unit specs
  attr_reader :client

  def test_connection!
    @client.ping
  rescue OpenSearch::UnsupportedProductError
    raise LogStash::ConfigurationError, "Could not connect to a compatible version of OpenSearch"
  end

  module URIOrEmptyValidator
    ##
    # @override to provide :uri_or_empty validator
    # @param value [Array<Object>]
    # @param validator [nil,Array,Symbol]
    # @return [Array(true,Object)]: if validation is a success, a tuple containing `true` and the coerced value
    # @return [Array(false,String)]: if validation is a failure, a tuple containing `false` and the failure reason.
    def validate_value(value, validator)
      return super unless validator == :uri_or_empty

      value = deep_replace(value)
      value = hash_or_array(value)

      return true, value.first if value.size == 1 && value.first.empty?

      return super(value, :uri)
    end
  end
  extend(URIOrEmptyValidator)

  module PositiveWholeNumberValidator
    ##
    # @override to provide :positive_whole_number validator
    # @param value [Array<Object>]
    # @param validator [nil,Array,Symbol]
    # @return [Array(true,Object)]: if validation is a success, a tuple containing `true` and the coerced value
    # @return [Array(false,String)]: if validation is a failure, a tuple containing `false` and the failure reason.
    def validate_value(value, validator)
      return super unless validator == :positive_whole_number

      is_number, coerced_number = super(value, :number)

      return [true, coerced_number.to_i] if is_number && coerced_number.denominator == 1 && coerced_number > 0

      return [false, "Expected positive whole number, got `#{value.inspect}`"]
    end
  end
  extend(PositiveWholeNumberValidator)
end
