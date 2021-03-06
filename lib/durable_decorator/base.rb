require 'digest/md5'

module DurableDecorator
  class Base
    class << self
      DECORATION_MODES = ['strict']
      REDEFINITIONS = {}

      def redefine clazz, method_name, meta, &block
        if method_name.to_s.match /^self\./
          redefine_instance (class << clazz; self; end), method_name.to_s.gsub("self.",''), meta, &block
        else
          redefine_instance clazz, method_name, meta, &block
        end
      end

      def redefine_instance clazz, method_name, meta, &block
        return unless old_method = existing_method(clazz, method_name, meta, &block)

        alias_definitions clazz, method_name, method_sha(old_method)
        redefine_method clazz, method_name, &block

        store_redefinition clazz, method_name, old_method, block
      end

      # Ensure method exists before creating new definitions
      def existing_method clazz, method_name, meta, &block
        return if redefined? clazz, method_name, &block

        old_method = validate_existing_definition clazz, method_name
        validate_method_arity clazz, method_name, old_method, &block
        validate_decoration_meta clazz, method_name, old_method, meta

        old_method
      end

      def validate_decoration_meta clazz, method_name, old_method, meta
        return unless meta

        chill_meta = {}
        meta.each do |k,v|
          chill_meta[k.to_sym] = v
        end

        raise InvalidDecorationError, "The hash provided to the decorator is invalid" unless DECORATION_MODES.include? chill_meta[:mode] and chill_meta[:sha] and !chill_meta[:sha].empty?
        
        raise TamperedDefinitionError, "Method SHA mismatch, the definition has been tampered with" unless method_sha(old_method) == chill_meta[:sha]
      end

      def validate_method_arity clazz, method_name, old_method, &block
        raise BadArityError, "Attempting to override #{clazz}'s #{method_name} with incorrect arity." if block.arity != old_method.arity and block.arity > 0 # See the #arity behavior disparity between 1.8- and 1.9+
      end

      def validate_existing_definition clazz, method_name
        begin
          clazz.instance_method(method_name)
        rescue NameError => e
          raise UndefinedMethodError, "#{clazz}##{method_name} is not defined."
        end
      end

      def redefine_method clazz, method_name, &block
        clazz.class_eval do
          define_method(method_name.to_sym, &block)
        end
      end

      def alias_definitions clazz, method_name, old_sha
        clazz.class_eval do
          alias_method("#{method_name}_#{old_sha}", method_name)
          alias_method("#{method_name}_old", method_name)
        end
      end

      def store_redefinition clazz, name, old_method, new_method
        class_name = clazz.name || ''
        class_name = "Meta#{clazz.superclass.to_s}" if class_name.empty?
        class_index = REDEFINITIONS[class_name.to_sym] ||= {}
        method_index = class_index[name.to_sym] ||= []
       
        to_store = [new_method]
        to_store.unshift(old_method) if method_index.empty?
        
        to_store.each do |method|
          method_index << method_hash(name, method)
        end

        true
      end

      def method_hash name, method
        {
          :name => name,
          :sha => method_sha(method) 
        }
      end

      def method_sha method
        Digest::MD5.hexdigest(method.source.gsub(/\s+/, ' '))
      end

      def redefined? clazz, method_name, &block
        begin
          result =
            overrides = REDEFINITIONS[clazz][method_name] and
            overrides.select{|o| o == method_hash(method_name)}.first and
            true
        rescue
          false
        end
      end

      def logger
        return @logger if @logger

        @logger = Logging.logger(STDOUT)
        @logger.level = :warn
        @logger
      end

      def determine_sha target
        raise "Please provide a fully qualified method name: Module::Clazz#instance_method or ::clazz_method" unless target.match(/\.|#/)

        class_name, separator, method_name = target.match(/(.*)(\.|#)(.*)/)[1..3]
        clazz = Constantizer.constantize(class_name)
        method = if separator == '#'
          clazz.instance_method(method_name)
        else
          clazz.method(method_name)
        end

        method_sha(method)
      end
    end
  end
end
