require 'rubygems'
require 'socket'
require 'securerandom'
require 'digest/md5'

require 'raven/error'
require 'raven/linecache'

module Raven

  class Event

    LOG_LEVELS = {
      "debug" => 10,
      "info" => 20,
      "warn" => 30,
      "warning" => 30,
      "error" => 40,
      "fatal" => 50,
    }

    BACKTRACE_RE = /^(.+?):(\d+)(?::in `(.+?)')?$/

    PLATFORM = "ruby"

    attr_reader :id
    attr_accessor :project, :message, :timestamp, :time_spent, :level, :logger,
      :culprit, :server_name, :release, :modules, :extra, :tags, :context, :configuration,
      :checksum

    def initialize(init = {})
      @configuration = Raven.configuration
      @interfaces    = {}
      @context       = Raven.context
      @id            = generate_event_id
      @message       = nil
      @timestamp     = Time.now.utc
      @time_spent    = nil
      @level         = :error
      @logger        = 'root'
      @culprit       = nil
      @server_name   = @configuration.server_name || get_hostname
      @release       = @configuration.release
      @modules       = get_modules if @configuration.send_modules
      @user          = {}
      @extra         = {}
      @tags          = {}
      @checksum      = nil

      yield self if block_given?

      if !self[:http] && @context.rack_env
        interface :http do |int|
          int.from_rack(@context.rack_env)
        end
      end

      init.each_pair  { |key, val| instance_variable_set('@' + key.to_s, val) }

      @user = @context.user.merge(@user)
      @extra = @context.extra.merge(@extra)
      @tags = @configuration.tags.merge(@context.tags).merge(@tags)

      # Some type coercion
      @timestamp  = @timestamp.strftime('%Y-%m-%dT%H:%M:%S') if @timestamp.is_a?(Time)
      @time_spent = (@time_spent*1000).to_i if @time_spent.is_a?(Float)
      @level      = LOG_LEVELS[@level.to_s.downcase] if @level.is_a?(String) || @level.is_a?(Symbol)
    end

    def get_hostname
      # Try to resolve the hostname to an FQDN, but fall back to whatever the load name is
      hostname = Socket.gethostname
      Socket.gethostbyname(hostname).first rescue hostname
    end

    def get_modules
      # Older versions of Rubygems don't support iterating over all specs
      Hash[Gem::Specification.map { |spec| [spec.name, spec.version.to_s] }] if Gem::Specification.respond_to?(:map)
    end

    def interface(name, value = nil, &block)
      int = Raven.find_interface(name)
      raise Error.new("Unknown interface: #{name}") unless int
      @interfaces[int.name] = int.new(value, &block) if value || block
      @interfaces[int.name]
    end

    def [](key)
      interface(key)
    end

    def []=(key, value)
      interface(key, value)
    end

    def to_hash
      data = {
        :event_id => @id,
        :message => @message,
        :timestamp => @timestamp,
        :time_spent => @time_spent,
        :level => @level,
        :project => @project,
        :logger => @logger,
        :platform => PLATFORM,
      }
      data[:culprit] = @culprit if @culprit
      data[:server_name] = @server_name if @server_name
      data[:release] = @release if @release
      data[:modules] = @modules if @modules
      data[:extra] = @extra if @extra
      data[:tags] = @tags if @tags
      data[:user] = @user if @user
      data[:checksum] = @checksum if @checksum
      @interfaces.each_pair do |name, int_data|
        data[name.to_sym] = int_data.to_hash
      end
      data
    end

    def self.from_exception(exc, options = {}, &block)
      notes = exc.instance_variable_get(:@__raven_context) || {}
      options = notes.merge(options)

      configuration = options[:configuration] || Raven.configuration
      if exc.is_a?(Raven::Error)
        # Try to prevent error reporting loops
        Raven.logger.info "Refusing to capture Raven error: #{exc.inspect}"
        return nil
      end
      if configuration[:excluded_exceptions].any? { |x| (x === exc rescue false) || x == exc.class.name }
        Raven.logger.info "User excluded error: #{exc.inspect}"
        return nil
      end

      if configuration.capture_locals
        # fill local variables of caller
        backtrace = Backtrace.parse(exc.backtrace)
        target_file = backtrace.lines[0].file
        target_number = backtrace.lines[0].number

        caller_candidates = []
        binding.callers.each_with_index do |caller_obj, idx|
          iseq = caller_obj.instance_variable_get(:@iseq)
          path = iseq.path
          line_no = iseq.first_lineno

          if path == target_file && line_no <= target_number
            caller_candidates << {
              :count => idx,
              :line_no => line_no
            }
          end
        end

        # find closest caller
        caller_info = caller_candidates.min do
          |a, b| target_number - a[:line_no] <=> target_number - b[:line_no]
        end
        unless caller_info.nil?
          pop_count = caller_info[:count]

          exc.instance_variable_set(:@stack_info, binding.callers.drop(pop_count))
          binding.callers.drop(pop_count).each_with_index do |caller_obj, idx|
            exc.backtrace[idx].instance_variable_set(:@stack_info, caller_obj)
          end
        end
      end

      new(options) do |evt|
        evt.configuration = configuration
        evt.message = "#{exc.class}: #{exc.message}"
        evt.level = options[:level] || :error

        add_exception_interface(evt, exc)

        block.call(evt) if block
      end
    end

    def self.from_message(message, options = {})
      configuration = options[:configuration] || Raven.configuration
      new(options) do |evt|
        evt.configuration = configuration
        evt.message = message
        evt.level = options[:level] || :error
        evt.interface :message do |int|
          int.message = message
        end
        if options[:backtrace]
          evt.interface(:stacktrace) do |int|
            stacktrace_interface_from(int, evt, options[:backtrace])
          end
        end
      end
    end

    def self.add_exception_interface(evt, exc)
      evt.interface(:exception) do |exc_int|
        exceptions = [exc]
        while exc.respond_to?(:cause) && exc.cause
          exceptions << exc.cause
          exc = exc.cause
        end
        exceptions.reverse!

        exc_int.values = exceptions.map do |exc|
          SingleExceptionInterface.new do |int|
            int.type = exc.class.to_s
            int.value = exc.to_s
            int.module = exc.class.to_s.split('::')[0...-1].join('::')

            int.stacktrace = if exc.backtrace
              StacktraceInterface.new do |stacktrace|
                stacktrace_interface_from(stacktrace, evt, exc.backtrace)
              end
            end
          end
        end
      end
    end

    def self.stacktrace_interface_from(int, evt, backtrace)
      orig_backtrace = backtrace

      backtrace = Backtrace.parse(backtrace)
      int.frames = backtrace.lines.reverse.each_with_index.map do |line, idx|
        StacktraceInterface::Frame.new.tap do |frame|
          frame.abs_path = line.file if line.file
          frame.function = line.method if line.method
          frame.lineno = line.number
          frame.in_app = line.in_app
          frame.module = line.module_name if line.module_name

          # if dump all stack frame, data is too large
          if evt.configuration.capture_locals && frame.in_app
            target_idx = orig_backtrace.length - idx - 1
            stack_info = orig_backtrace[target_idx].instance_variable_get(:@stack_info)
            if !stack_info.nil?
              frame.vars = {}
              locals = stack_info.eval('local_variables')
              locals.each do |key|
                frame.vars[key.to_s] = stack_info.eval("#{key}").to_s
              end
            end
          end

          if evt.configuration[:context_lines] && frame.abs_path
            frame.pre_context, frame.context_line, frame.post_context = \
              evt.get_file_context(frame.abs_path, frame.lineno, evt.configuration[:context_lines])
          end
        end
      end.select { |f| f.filename }

      evt.culprit = evt.get_culprit(int.frames)
    end

    # Because linecache can go to hell
    def self._source_lines(_path, _from, _to)
    end

    def get_file_context(filename, lineno, context)
      return nil, nil, nil unless Raven::LineCache.is_valid_file(filename)
      lines = (2 * context + 1).times.map do |i|
        Raven::LineCache.getline(filename, lineno - context + i)
      end
      [lines[0..(context - 1)], lines[context], lines[(context + 1)..-1]]
    end

    def get_culprit(frames)
      lastframe = frames.reverse.find { |f| f.in_app } || frames.last
      "#{lastframe.filename} in #{lastframe.function} at line #{lastframe.lineno}" if lastframe
    end

    # For cross-language compat
    class << self
      alias :captureException :from_exception
      alias :captureMessage :from_message
      alias :capture_exception :from_exception
      alias :capture_message :from_message
    end

    private

    def generate_event_id
      # generate a uuid. copy-pasted from SecureRandom, this method is not
      # available in <1.9.
      ary = SecureRandom.random_bytes(16).unpack("NnnnnN")
      ary[2] = (ary[2] & 0x0fff) | 0x4000
      ary[3] = (ary[3] & 0x3fff) | 0x8000
      uuid = "%08x-%04x-%04x-%04x-%04x%08x" % ary
      ::Digest::MD5.hexdigest(uuid)
    end
  end
end
