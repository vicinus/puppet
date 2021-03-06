require_relative 'hiera_config'

# Add support for Hiera-like interpolation expressions. The expressions may contain keys that uses dot-notation
# to further navigate into hashes and arrays
#
module Puppet::DataProviders::HieraInterpolate
  def interpolate(subject, lookup_invocation, allow_methods)
    case subject
    when String
      subject.index('%{').nil? ? subject : interpolate_string(subject, lookup_invocation, allow_methods)
    when Array
      subject.map { |element| interpolate(element, lookup_invocation, allow_methods) }
    when Hash
      Hash[subject.map { |k, v| [k, interpolate(v, lookup_invocation, allow_methods)] }]
    else
      subject
    end
  end

  private

  def interpolate_string(subject, lookup_invocation, allow_methods)
    lookup_invocation.with(:interpolate, subject) do
      subject.gsub(/%\{([^\}]*)\}/) do |match|
        expr = $1
        # Leading and trailing spaces inside an interpolation expression are insignificant
        expr.strip!
        unless expr.empty? || expr == '::'
          method_key, key = get_method_and_data(expr, allow_methods)
          is_alias = method_key == 'alias'

          # Alias is only permitted if the entire string is equal to the interpolate expression
          raise Puppet::DataBinding::LookupError, "'alias' interpolation is only permitted if the expression is equal to the entire string" if is_alias && subject != match

          segments = key.split('.')
          value = interpolate_method(method_key).call(segments[0], lookup_invocation)
          value = qualified_lookup(segments.drop(1), value) if segments.size > 1
          value = lookup_invocation.check(key) { interpolate(value, lookup_invocation, allow_methods) }

          # break gsub and return value immediately if this was an alias substitution. The value might be something other than a String
          return value if is_alias
        end
        value || ''
      end
    end
  end

  def interpolate_method(method_key)
    @@interpolate_methods ||= begin
      global_lookup = lambda { |key, lookup_invocation| Puppet::Pops::Lookup.lookup(key, nil, '', true, nil, lookup_invocation) }
      scope_lookup = lambda do |key, lookup_invocation|
        lookup_invocation.with(:scope, nil) do
          ovr = lookup_invocation.override_values
          if ovr.include?(key)
            lookup_invocation.report_found_in_overrides(key, ovr[key])
          else
            scope = lookup_invocation.scope
            if scope.include?(key)
              lookup_invocation.report_found(key, scope[key])
            else
              defaults = lookup_invocation.default_values
              if defaults.include?(key)
                lookup_invocation.report_found_in_defaults(key, defaults[key])
              else
                nil
              end
            end
          end
        end
      end


      {
        'lookup' => global_lookup,
        'hiera' => global_lookup, # this is just an alias for 'lookup'
        'alias' => global_lookup, # same as 'lookup' but expression must be entire string. The result that is not subject to string substitution
        'scope' => scope_lookup,
        'literal' => lambda { |key, _| key }
      }
    end
    interpolate_method = @@interpolate_methods[method_key]
    raise Puppet::DataBinding::LookupError, "Unknown interpolation method '#{method_key}'" unless interpolate_method
    interpolate_method
  end

  def qualified_lookup(segments, value)
    segments.each do |segment|
      throw :no_such_key if value.nil?
      if segment =~ /^[0-9]+$/
        segment = segment.to_i
        raise Puppet::DataBinding::LookupError, "Data provider type mismatch: Got #{value.class.name} when Array was expected to enable lookup using key '#{segment}'" unless value.instance_of?(Array)
        throw :no_such_key unless segment < value.size
      else
        raise Puppet::DataBinding::LookupError, "Data provider type mismatch: Got #{value.class.name} when a non Array object that responds to '[]' was expected to enable lookup using key '#{segment}'" unless value.respond_to?(:'[]') && !value.instance_of?(Array)
        throw :no_such_key unless value.include?(segment)
      end
      value = value[segment]
    end
    value
  end

  def get_method_and_data(data, allow_methods)
    if match = data.match(/^(\w+)\((?:["]([^"]+)["]|[']([^']+)['])\)$/)
      raise Puppet::DataBinding::LoookupError, 'Interpolation using method syntax is not allowed in this context' unless allow_methods
      key = match[1]
      data = match[2] || match[3] # double or single qouted
    else
      key = 'scope'
    end
    [key, data]
  end
end
