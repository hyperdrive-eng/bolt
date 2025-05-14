# frozen_string_literal: true

require 'json'
require 'bolt/error'

module Bolt
  class Result
    attr_reader :target, :value, :action, :object

    def self.for_command(target, stdout, stderr, exit_code, action, command, elapsed_time = nil)
      value = {
        'stdout' => stdout,
        'stderr' => stderr,
        'exit_code' => exit_code,
        'action' => action,
        'command' => command
      }
      value['elapsed_time'] = elapsed_time if elapsed_time
      for_target(target, value)
    end

    def self.for_task(target, stdout, stderr, exit_code, task, elapsed_time = nil)
      # Parse the output if it's valid json
      # Due to the limitations of the ruby-json_pure gem when used in the trident
      # runtime, we need to tell it to parse the string as UTF-8.
      begin
        obj = JSON.parse(stdout, encoding: 'UTF-8')
      rescue StandardError
        obj = nil
      end

      if obj.nil?
        value = {
          '_output' => stdout,
          'stderr' => stderr,
          'exit_code' => exit_code
        }
      else
        value = obj
        value['stderr'] = stderr
        value['exit_code'] = exit_code
      end
      value['_task'] = task.name
      value['elapsed_time'] = elapsed_time if elapsed_time
      for_target(target, value)
    end

    def self.for_upload(target, source, destination, elapsed_time = nil)
      value = {
        'action' => 'upload',
        'path' => destination,
        'src' => source
      }
      value['elapsed_time'] = elapsed_time if elapsed_time
      for_target(target, value)
    end

    def self.for_download(target, source, destination, elapsed_time = nil)
      value = {
        'action' => 'download',
        'path' => source,
        'dest' => destination
      }
      value['elapsed_time'] = elapsed_time if elapsed_time
      for_target(target, value)
    end

    def self.for_message(target, message)
      value = {
        'action' => 'message',
        'message' => message
      }
      for_target(target, value)
    end

    def self.for_error(target, error)
      value = {
        'action' => 'error',
        'object' => error.message,
        'status' => 'failure'
      }
      details = error.to_h
      value.merge!(details) if details.is_a?(Hash)

      new(target, error, value)
    end

    def self.for_plan_error(target, error)
      value = {
        'action' => 'plan_error',
        'object' => error.message,
        'status' => 'failure'
      }
      details = error.to_h
      value.merge!(details) if details.is_a?(Hash)

      new(target, error, value)
    end

    def self.for_target(target, value = {})
      new(target, nil, value)
    end

    def initialize(target, error = nil, value = {})
      @target = target
      @value = value
      @action = value['action']
      @object = value['object']
      @error = error
    end

    def error_hash
      @error.to_h
    end

    def status
      if @error
        'failure'
      elsif @value.include?('_error')
        status = @value['_error']['status']
        if ['failure', 'success'].include?(status)
          status
        else
          msg = "Invalid status: '#{status}' in result from #{@target.safe_name}"
          raise Bolt::InvalidResultStatus, msg
        end
      else
        'success'
      end
    end

    def ok?
      status == 'success'
    end
    alias ok ok?
    alias success? ok?

    def error
      if @error
        @error
      elsif @value.include?('_error')
        begin
          err = Bolt::Error.new(
            @value['_error']['msg'],
            @value['_error']['kind'],
            @value['_error']['details']
          )
        rescue StandardError
          err = Bolt::Error.new(@value['_error'].to_s)
        end
        err
      end
    end

    def message
      @value['message'] || error&.message
    end

    def action_and_object
      "#{@action} #{@object}"
    end

    def safe_value
      Bolt::Util.walk_vals(value) do |val|
        if val.is_a?(Bolt::Error)
          # Create a simple hash representation without recursing to avoid circular references
          { 'kind' => val.kind, 'msg' => val.message }
        elsif val.is_a?(String)
          val.scrub { |c| c.bytes.map { |b| "\\x" + b.to_s(16).upcase }.join }
        else
          val
        end
      end
    end

    def to_json(opts = nil)
      to_data.to_json(opts)
    end

    def to_data
      {
        "target" => @target.name,
        "action" => @action,
        "object" => @object,
        "status" => status,
        "value" => safe_value
      }
    end

    def guess_target
      @target.guess_target
    end

    def host
      @target.host
    end

    def uri
      @target.uri
    end

    def safe_name
      @target.safe_name
    end

    def target_hash
      if defined? @target.to_h
        @target.to_h
      else
        @target.select_keys(%i[uri name host protocol user port])
      end
    end

    def eql?(other)
      self.class == other.class &&
        target == other.target &&
        value == other.value
    end

    def [](key)
      value[key]
    end

    def ==(other)
      eql?(other)
    end

    def to_h
      @value
    end

    def to_s
      to_json
    end

    def formatted_value
      to_h.to_s
    end
  end
end
