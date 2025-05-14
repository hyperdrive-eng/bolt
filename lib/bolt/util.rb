# frozen_string_literal: true

require 'base64'
require 'find'
require 'json'
require 'logging'
require 'pathname'
require 'puppet/util/colors'
require 'bolt/logger'
require 'set'

module Bolt
  module Util
    extend Logging

    # Initializes the valid Ruby types supported by Bolt: YAML, JSON, and binary.
    RUBY_EXTENSIONS = %w[.rb].freeze
    YAML_EXTENSIONS = %w[.yml .yaml].freeze
    JSON_EXTENSIONS = %w[.json].freeze
    BINARY_EXTENSIONS = %w[.sh .exe].freeze

    # Misc defaults.
    PASSWORD_PROMPT = "Please enter your password: "

    # Method to determine if running on Windows
    def self.windows?
      if defined?(Bolt::Util::Platform) && Bolt::Util::Platform.respond_to?(:windows?)
        Bolt::Util::Platform.windows?
      else
        !!File::ALT_SEPARATOR
      end
    end

    # Method to determine if PowerShell is available
    def self.powershell?
      windows?
    end

    sudo_exec = windows? ? 'cmd.exe /c' : 'sudo -S -E -n'
    SUDO_EXEC = ENV['BOLT_SUDO_EXE'] || sudo_exec
    SUDO_PROMPT = 'sudo password: '

    NT_SEPARATOR = ';'
    POSIX_SEPARATOR = ':'
    DEFAULT_PATH_SEPARATOR = windows? ? NT_SEPARATOR : POSIX_SEPARATOR

    def self.read_yaml_hash(path, file)
      logger.debug("Reading yaml hash file at #{path}")
      require 'bolt/yaml'
      # Try to load as YAML fist, if that doesn't work try JSON
      # If users wanted to use require_relative PATH/FILE.json in a plan
      # the relative path would have to be from the modulepath
      # This allows users to not use a specific extension
      begin
        result = Bolt::YAML.safe_load_file(File.expand_path(path), wrap: false)
        unless result.is_a?(Hash)
          raise Bolt::FileError, "Invalid YAML when loading #{file}, expected a Hash but got #{result.inspect}"
        end
        result
      rescue Bolt::FileError
        raise Bolt::FileError, "Could not parse #{file} as JSON or YAML"
      end
    end

    # For compatibility with existing code that expects this method
    def self.read_optional_yaml_hash(path, file)
      if File.exist?(path)
        read_yaml_hash(path, file)
      else
        {}
      end
    end

    def self.get_proxies
      patterns = [
        /^https?_proxy$/,
        /^http_proxy$/,
        /^https?_proxy_/,
        /^no_proxy$/,
        /^ssl_/
      ]

      ENV.keys.each_with_object({}) do |key, proxies|
        proxy_patterns = patterns.find { |pattern| key.downcase =~ pattern }
        if proxy_patterns
          proxies[key.downcase] = ENV[key]
        end
      end
    end

    def self.windows_basename(path)
      elements = path.split(/[:\/\\]/)
      elements[-1]
    end

    def self.windows_dirname(path)
      elements = path.split(/[:\/\\]/)
      elements.pop
      elements.join('\\')
    end

    def self.path_split(path)
      if path =~ /^#{Regexp.escape(File::SEPARATOR)}/
        abs = true
        parts = path.split(File::SEPARATOR)
        parts.shift
      else
        abs = false
        parts = path.split(File::SEPARATOR)
      end

      [abs, parts]
    end

    def self.path_join(abs, parts)
      path = abs ? File::SEPARATOR : ''
      parts.each do |part|
        if part == ''
          next
        elsif path == ''
          path = part
        elsif path == File::SEPARATOR
          path += part
        else
          path += File::SEPARATOR + part
        end
      end
      path
    end

    def self.to_code(string)
      case string
      when Numeric, true, false
        string.inspect
      else
        "\"#{string}\""
      end
    end

    def self.deep_merge(hash1, hash2)
      recursive_merge = proc do |_key, h1, h2|
        if h1.is_a?(Hash) && h2.is_a?(Hash)
          h1.merge(h2, &recursive_merge)
        else
          h2
        end
      end
      hash1.merge(hash2, &recursive_merge)
    end

    def self.deep_clone(obj)
      case obj
      when Hash
        obj.transform_values { |v| deep_clone(v) }
      when Array
        obj.map { |v| deep_clone(v) }
      when NilClass, Numeric, Symbol, TrueClass, FalseClass
        obj
      else
        obj.clone
      end
    end

    # This is stubbed for testing validate_file
    def self.file_stat(path)
      File.stat(path)
    end

    def self.validate_file(type, path, allow_dir = false)
      stat = file_stat(path)

      if !allow_dir && stat.directory?
        raise Bolt::FileError.new("The #{type} '#{path}' is a directory, not a file", path)
      elsif !stat.file? && !stat.directory?
        raise Bolt::FileError.new("The #{type} '#{path}' is not a file or directory", path)
      elsif !stat.readable?
        raise Bolt::FileError.new("The #{type} '#{path}' is not readable", path)
      elsif stat.directory? && !stat.executable?
        raise Bolt::FileError.new("The #{type} '#{path}' is not executable", path)
      end
    rescue Errno::ENOENT
      raise Bolt::FileError.new("The #{type} '#{path}' does not exist", path)
    end

    def self.safe_task_hash(task)
      {
        name: task.name,
        description: task.description,
        parameters: task.parameters,
        supports_noop: task.supports_noop,
        module: task.module_name,
        files: task.files.map { |file| file.path.to_s },
        implementations: task.implementations.map do |impl|
          {
            name: impl['name'],
            requirements: impl['requirements'],
            input_method: impl['input_method'],
            files: impl['files'].map { |file| file.path.to_s }
          }
        end
      }
    end

    def self.powershell_feature_flags(features)
      if features.any?
        flags = features.map do |feature|
          "$PSNativeCommandArgumentPassing = '#{feature}'"
        end
        "[System.Environment]::SetEnvironmentVariable('POWERSHELL_NATIVE_COMMAND_PASSING', '#{features[0]}')"
        flags.join("; ")
      end
    end

    def self.powershell_parameters(params)
      if params.any?
        "&{ #{powershell_feature_flags(params[:features])}; #{params[:command]} }"
      else
        params[:command]
      end
    end

    def self.wrap_script(script)
      wrapper = File.expand_path(File.join(__dir__, '..', '..', 'resources', 'wrapper.ps1'))
      # Call the script with its arguments. Escape the script path and all arguments.
      path = Powershell.escape(script)

      "& \"#{wrapper}\" \"#{path}\" #{STDIN.isatty ? '$true' : '$false'}"
    end

    # Returns the headers that should be used for a request
    def self.default_headers
      headers = { 'User-Agent' => 'Bolt'}
      headers
    end

    def self.format_successful_count(targets)
      pluralize(targets.count, 'target')
    end

    def self.format_error_count(errors)
      format_count(errors.count, 'target had errors')
    end

    def self.format_count(count, noun)
      "#{count} #{count == 1 ? noun : inflect(noun)}"
    end

    def self.inflect(noun)
      if noun.end_with?('s', 'o', 'ch', 'sh')
        "#{noun}es"
      elsif noun.end_with?('y') && !noun.end_with?('ay', 'ey', 'iy', 'oy', 'uy')
        noun.chomp('y') + 'ies'
      else
        "#{noun}s"
      end
    end

    def self.pluralize(value, noun)
      "#{value} #{value == 1 ? noun : inflect(noun)}"
    end

    def self.validate_stdin_load_type(input, input_format, load_type)
      valid_format = case load_type
                     when 'json'
                       input_format == 'json'
                     when 'yaml'
                       %w[yaml yml].include?(input_format)
                     when 'both'
                       true
                     else
                       raise "Unexpected load type: '#{input}'"
                     end
      raise Bolt::CLIError, "Unable to read from STDIN: expected format '#{load_type}', got '#{input_format}'" unless valid_format
    end

    def self.map_vals(hash)
      hash.each_with_object({}) do |(k, v), acc|
        acc[k] = yield(v)
      end
    end

    # Accepts a Data object and returns a copy with all hash keys
    # modified by block. use &:to_s to stringify keys or &:to_sym to symbolize them
    def self.walk_keys(data, &block)
      case data
      when Hash
        data.each_with_object({}) do |(k, v), acc|
          v = walk_keys(v, &block)
          acc[yield(k)] = v
        end
      when Array
        data.map { |v| walk_keys(v, &block) }
      else
        data
      end
    end

    # Accepts a Data object and returns a copy with all hash and array values
    # modified by block. Useful for debugging with &:inspect
    # Also accepts an optional visitor Proc that will be passed each container
    # along with its parent.
    def self.walk_vals(data, skip_top = false, visited = {}, &block)
      # Return data immediately if we've seen this object before
      return data if visited[data.object_id]
      visited[data.object_id] = true

      data = yield(data) unless skip_top
      case data
      when Hash
        data.transform_values { |v| walk_vals(v, false, visited, &block) }
      when Array
        data.map { |v| walk_vals(v, false, visited, &block) }
      else
        data
      end
    end

    def self.symbolize_top_level_keys(data)
      data.each_with_object({}) do |(k, v), acc|
        acc[k.to_sym] = v
      end
    end

    # Returns path to first directory that exists, or closest ancestor that is a directory
    # Returns nil if given nil or empty string as the target_path
    def self.get_working_dir(target_path)
      return nil if target_path.nil? || target_path.empty?
      working_dir = File.exist?(target_path) ? target_path : File.dirname(target_path)
      until Dir.exist?(working_dir)
        working_dir = File.dirname(working_dir)
      end
      working_dir
    end

    # Generate a random string of max_len. Each char is a random
    # alphanumeric, length between 0 and max
    def self.random_string_max(max_len)
      rand(max_len + 1).times.map { ('a'..'z').to_a.sample }.join
    end

    # Format the resource values for Puppet
    def self.puppet_resource_values(resources)
      resources.each_with_object([]) do |(tag, resources_by_tag), targets|
        resources_by_tag.each do |(title, params), resources_by_title|
          result = {}
          result[:target] = title.to_s
          result[:params] = params
          result[:tag] = tag
          targets << result
        end
      end
    end

    # Format the resource values for Puppet resource_instance
    def self.puppet_resource_instance_values(resources)
      resources.map do |resource_obj|
        type = resource_obj.dig('type', 'name')
        title = resource_obj['title']
        params = resource_obj.fetch('parameters', {})
        attributes = resource_obj.fetch('attributes', [])
        {
          'type'        => type,
          'title'       => title,
          'parameters'  => params,
          'attributes'  => attributes
        }
      end
    end

    # Return a map of base64 encoded data to a path
    # to the tempfile it's stored in
    def self.get_tempfiles(data)
      data.transform_values.with_index do |content, index|
        content = Base64.decode64(content)
        file = Tempfile.new("bolt")
        file.binmode
        file.write(content)
        file.close
        file.path
      end
    end

    def self.deep_merge_unit_hash(plan)
      plan.reduce(Concurrent::Hash.new) do |acc, (agg, targets)|
        acc.merge!(agg => targets) do |_key, old, new|
          new + old
        end
      end
    end

    def self.deep_sort_with_recurse(data)
      if data.is_a?(Hash)
        data.keys.sort_by(&:to_s).each_with_object({}) do |k, acc|
          v = data[k]
          acc[k] = deep_sort(v)
        end
      elsif data.is_a?(Array)
        data.map { |v| deep_sort(v) }
      else
        data
      end
    end

    def self.deep_sort(data)
      if data.is_a?(Hash)
        data.keys.sort_by(&:to_s).each_with_object({}) do |k, acc|
          v = data[k]
          acc[k] = v.is_a?(Hash) ? deep_sort(v) : v
        end
      else
        data
      end
    end
  end
end
