require 'ostruct'

module Fluent
  class RecordReformerOutput < Output
    Fluent::Plugin.register_output('record_reformer', self)

  def initialize
    super
    require  'socket'

  end

    config_param :output_tag, :string, :default => nil # obsolete
    config_param :tag, :string, :default => nil
    config_param :remove_keys, :string, :default => nil
    config_param :keep_keys, :string, :default => nil
    config_param :renew_record, :bool, :default => false
    config_param :renew_time_key, :string, :default => nil
    config_param :enable_ruby, :bool, :default => true # true for lower version compatibility
    config_param :auto_typecast, :bool, :default => false # false for lower version compatibility

    BUILTIN_CONFIGURATIONS = %W(type tag output_tag remove_keys renew_record keep_keys enable_ruby renew_time_key auto_typecast)

    # To support log_level option implemented by Fluentd v0.10.43
    unless method_defined?(:log)
      define_method("log") { $log }
    end

    # Define `router` method of v0.12 to support v0.10 or earlier
    unless method_defined?(:router)
      define_method("router") { Fluent::Engine }
    end

    $dockername
    $uuid
    def configure(conf)
      super
 
      if File.exist?("/etc/omega/agent/omega-agent.conf")
        filecontent = ""
        file = File.new("/etc/omega/agent/omega-agent.conf", "r")
        while (line = file.gets)
          #log.warn "#{counter}: #{line}"
          filecontent = filecontent.concat(line)
        end
        file.close
        filecontent = filecontent.gsub(/\s*|\t|\r|\n/, "")
        $uuid = parse_value(filecontent)["OmegaUUID"]
        log.info "#{filecontent} -- #{$uuid}"
      else
        log.warn "uuid file is not found"
      end
 
      $dockername = DockerNameResolverOutput.new
      @map = {}
      conf.each_pair { |k, v|
        next if BUILTIN_CONFIGURATIONS.include?(k)
        conf.has_key?(k) # to suppress unread configuration warning
        @map[k] = parse_value(v)
      }
      # <record></record> directive
      conf.elements.select { |element| element.name == 'record' }.each { |element|
        element.each_pair { |k, v|
          element.has_key?(k) # to suppress unread configuration warning
          @map[k] = parse_value(v)
        }
      }

      if @remove_keys
        @remove_keys = @remove_keys.split(',')
      end

      if @keep_keys
        raise Fluent::ConfigError, "out_record_reformer: `renew_record` must be true to use `keep_keys`" unless @renew_record
        @keep_keys = @keep_keys.split(',')
      end

      if @output_tag and @tag.nil? # for lower version compatibility
        log.warn "out_record_reformer: `output_tag` is deprecated. Use `tag` option instead."
        @tag = @output_tag
      end
      if @tag.nil?
        raise Fluent::ConfigError, "out_record_reformer: `tag` must be specified"
      end

      placeholder_expander_params = {
        :log           => log,
        :auto_typecast => @auto_typecast,
      }
      @placeholder_expander =
        if @enable_ruby
          # require utilities which would be used in ruby placeholders
          require 'pathname'
          require 'uri'
          require 'cgi'
          RubyPlaceholderExpander.new(placeholder_expander_params)
        else
          PlaceholderExpander.new(placeholder_expander_params)
        end

      @hostname = Socket.gethostname
    end

    def emit(tag, es, chain)
      tag_parts = tag.split('.')
      container_id = tag_parts[5]
      #dockername.say()
      tag_prefix = tag_prefix(tag_parts)
      tag_suffix = tag_suffix(tag_parts)
      containername = $dockername.rewrite_tag(tag)
      placeholders = {
        'tag' => tag,
        'tags' => tag_parts,
        'tag_parts' => tag_parts,
        'tag_prefix' => tag_prefix,
        'tag_suffix' => tag_suffix,
        'containername' => containername,
        'uuid' => $uuid,
        'hostname' => @hostname,
      }
      last_record = nil
      es.each {|time, record|
        last_record = record # for debug log
        new_tag, new_record = reform(@tag, time, record, placeholders)
        if new_tag
          if @renew_time_key && new_record.has_key?(@renew_time_key)
            time = new_record[@renew_time_key].to_i
          end
          router.emit(new_tag, time, new_record)
        end
      }
      chain.next
    rescue => e
      log.warn "record_reformer: #{e.class} #{e.message} #{e.backtrace.first}"
      log.debug "record_reformer: tag:#{@tag} map:#{@map} record:#{last_record} placeholders:#{placeholders}"
    end

    private

    def parse_value(value_str)
      if value_str.start_with?('{', '[')
        JSON.parse(value_str)
      else
        value_str
      end
    rescue => e
      log.warn "failed to parse #{value_str} as json. Assuming #{value_str} is a string", :error_class => e.class, :error => e.message
      value_str # emit as string
    end

    def reform(tag, time, record, opts)
      @placeholder_expander.prepare_placeholders(time, record, opts)
      new_tag = @placeholder_expander.expand(tag)

      new_record = @renew_record ? {} : record.dup
      @keep_keys.each {|k| new_record[k] = record[k]} if @keep_keys and @renew_record
      new_record.merge!(expand_placeholders(@map))
      @remove_keys.each {|k| new_record.delete(k) } if @remove_keys

      [new_tag, new_record]
    end

    def expand_placeholders(value)
      if value.is_a?(String)
        new_value = @placeholder_expander.expand(value)
      elsif value.is_a?(Hash)
        new_value = {}
        value.each_pair do |k, v|
          new_value[@placeholder_expander.expand(k, true)] = expand_placeholders(v)
        end
      elsif value.is_a?(Array)
        new_value = []
        value.each_with_index do |v, i|
          new_value[i] = expand_placeholders(v)
        end
      else
        new_value = value
      end
      new_value
    end

    def tag_prefix(tag_parts)
      return [] if tag_parts.empty?
      tag_prefix = [tag_parts.first]
      1.upto(tag_parts.size-1).each do |i|
        tag_prefix[i] = "#{tag_prefix[i-1]}.#{tag_parts[i]}"
      end
      tag_prefix
    end

    def tag_suffix(tag_parts)
      return [] if tag_parts.empty?
      rev_tag_parts = tag_parts.reverse
      rev_tag_suffix = [rev_tag_parts.first]
      1.upto(tag_parts.size-1).each do |i|
        rev_tag_suffix[i] = "#{rev_tag_parts[i]}.#{rev_tag_suffix[i-1]}"
      end
      rev_tag_suffix.reverse!
    end

    class PlaceholderExpander
      attr_reader :placeholders, :log

      def initialize(params)
        @log = params[:log]
        @auto_typecast = params[:auto_typecast]
      end

      def prepare_placeholders(time, record, opts)
        placeholders = { '${time}' => Time.at(time).to_s }
        record.each {|key, value| placeholders.store("${#{key}}", value) }

        opts.each do |key, value|
          if value.kind_of?(Array) # tag_parts, etc
            size = value.size
            value.each_with_index { |v, idx|
              placeholders.store("${#{key}[#{idx}]}", v)
              placeholders.store("${#{key}[#{idx-size}]}", v) # support [-1]
            }
          else # string, interger, float, and others?
            placeholders.store("${#{key}}", value)
          end
        end

        @placeholders = placeholders
      end

      def expand(str, force_stringify=false)
        if @auto_typecast and !force_stringify
          single_placeholder_matched = str.match(/\A(\${[^}]+}|__[A-Z_]+__)\z/)
          if single_placeholder_matched
            log_unknown_placeholder($1)
            return @placeholders[single_placeholder_matched[1]]
          end
        end
        str.gsub(/(\${[^}]+}|__[A-Z_]+__)/) {
          log_unknown_placeholder($1)
          @placeholders[$1]
        }
      end

      private
      def log_unknown_placeholder(placeholder)
        unless @placeholders.include?(placeholder)
          log.warn "record_reformer: unknown placeholder `#{placeholder}` found"
        end
      end
    end

    class RubyPlaceholderExpander
      attr_reader :placeholders, :log

      def initialize(params)
        @log = params[:log]
        @auto_typecast = params[:auto_typecast]
      end

      # Get placeholders as a struct
      #
      # @param [Time]   time        the time
      # @param [Hash]   record      the record
      # @param [Hash]   opts        others
      def prepare_placeholders(time, record, opts)
        struct = UndefOpenStruct.new(record)
        struct.time = Time.at(time)
        opts.each {|key, value| struct.__send__("#{key}=", value) }
        @placeholders = struct
      end

      # Replace placeholders in a string
      #
      # @param [String] str         the string to be replaced
      def expand(str, force_stringify=false)
        if @auto_typecast and !force_stringify
          single_placeholder_matched = str.match(/\A\${([^}]+)}\z/)
          if single_placeholder_matched
            code = single_placeholder_matched[1]
            return eval code, @placeholders.instance_eval { binding }
          end
        end
        interpolated = str.gsub(/\$\{([^}]+)\}/, '#{\1}') # ${..} => #{..}
        eval "\"#{interpolated}\"", @placeholders.instance_eval { binding }
      rescue => e
        log.warn "record_reformer: failed to expand `#{str}`", :error_class => e.class, :error => e.message
        log.warn_backtrace
        nil
      end

      class UndefOpenStruct < OpenStruct
        (Object.instance_methods).each do |m|
          undef_method m unless m.to_s =~ /^__|respond_to_missing\?|object_id|public_methods|instance_eval|method_missing|define_singleton_method|respond_to\?|new_ostruct_member/
        end
      end
    end

    class Fluent::DockerNameResolverOutput < Fluent::Output
      # Define `log` method for v0.10.42 or earlier
      unless method_defined?(:log)
        define_method("log") { $log }
      end

      def initialize
        super
        require 'docker'

        @containers = Docker::Container.all

        @find_containers = Proc.new do |id|
          container = @containers.select{|c| c.id == id}.first

          if container.nil?
            @containers = Docker::Container.all 
            @containers.select{|c| c.id == id}.first
          else
            container
          end
        end
      end

      def rewrite_tag(tag)
        container_id, _ , _ = tag.split('.').last(3)

        #log.warn "****************#{container_id}"

        container = @find_containers.call(container_id)

        return tag unless container

        image_name = container.info['Image']
        container_name = container.info['Names'].first

        return tag if image_name.nil? or container_name.nil?

        container_name.sub!(/^\//, '')
        container_name.tr!('.','_')
        image_name.tr!('.','_')

        #rewrited_tag = "docker.container.%s.%s.%s" % [image_name, container_name, container_id]
        #return rewrited_tag
        return container_name
      end

    end

  end
end
