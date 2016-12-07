# frozen-string-literal: true

module Sequel
  class Dataset
    # ---------------------
    # :section: 6 - Miscellaneous methods
    # These methods don't fit cleanly into another section.
    # ---------------------
    
    NOTIMPL_MSG = "This method must be overridden in Sequel adapters".freeze
    ARRAY_ACCESS_ERROR_MSG = 'You cannot call Dataset#[] with an integer or with no arguments.'.freeze
    ARG_BLOCK_ERROR_MSG = 'Must use either an argument or a block, not both'.freeze
    IMPORT_ERROR_MSG = 'Using Sequel::Dataset#import an empty column array is not allowed'.freeze
    
    # The database related to this dataset.  This is the Database instance that
    # will execute all of this dataset's queries.
    attr_reader :db

    # The hash of options for this dataset, keys are symbols.
    attr_reader :opts

    # Constructs a new Dataset instance with an associated database and 
    # options. Datasets are usually constructed by invoking the Database#[] method:
    #
    #   DB[:posts]
    #
    # Sequel::Dataset is an abstract class that is not useful by itself. Each
    # database adapter provides a subclass of Sequel::Dataset, and has
    # the Database#dataset method return an instance of that subclass.
    def initialize(db)
      @db = db
      @opts = {}
      @cache = {}
    end

    # Define a hash value such that datasets with the same DB, opts, and SQL
    # will be considered equal.
    def ==(o)
      o.is_a?(self.class) && db == o.db && opts == o.opts && sql == o.sql
    end

    # An object representing the current date or time, should be an instance
    # of Sequel.datetime_class.
    def current_datetime
      Sequel.datetime_class.now
    end

    # Alias for ==
    def eql?(o)
      self == o
    end

    if TRUE_FREEZE
      # Similar to #clone, but returns an unfrozen clone if the receiver is frozen.
      def dup
        _clone(:freeze=>false)
      end
    else
      # :nocov:
      def dup
        c = clone
        c.instance_variable_set(:@opts, Hash[c.opts])
        c
      end
      # :nocov:
    end
    
    # Yield a dataset for each server in the connection pool that is tied to that server.
    # Intended for use in sharded environments where all servers need to be modified
    # with the same data:
    #
    #   DB[:configs].where(:key=>'setting').each_server{|ds| ds.update(:value=>'new_value')}
    def each_server
      db.servers.each{|s| yield server(s)}
    end

    # Returns the string with the LIKE metacharacters (% and _) escaped.
    # Useful for when the LIKE term is a user-provided string where metacharacters should not
    # be recognized. Example:
    #
    #   ds.escape_like("foo\\%_") # 'foo\\\%\_'
    def escape_like(string)
      string.gsub(/[\\%_]/){|m| "\\#{m}"}
    end

    if TRUE_FREEZE
      # Freeze the opts when freezing the dataset.
      def freeze
        @opts.freeze
        super
      end
    else
      # :nocov:
      # :nodoc:
      def freeze
        @opts.freeze
        self
      end

      # :nodoc:
      def frozen?
        @opts.frozen?
      end
      # :nocov:
    end
   
    # Alias of +first_source_alias+
    def first_source
      first_source_alias
    end

    # The first source (primary table) for this dataset.  If the dataset doesn't
    # have a table, raises an +Error+.  If the table is aliased, returns the aliased name.
    #
    #   DB[:table].first_source_alias
    #   # => :table
    #
    #   DB[:table___t].first_source_alias
    #   # => :t
    def first_source_alias
      source = @opts[:from]
      if source.nil? || source.empty?
        raise Error, 'No source specified for query'
      end
      case s = source.first
      when SQL::AliasedExpression
        s.alias
      when Symbol
        _, _, aliaz = split_symbol(s)
        aliaz ? aliaz.to_sym : s
      else
        s
      end
    end
    
    # The first source (primary table) for this dataset.  If the dataset doesn't
    # have a table, raises an error.  If the table is aliased, returns the original
    # table, not the alias
    #
    #   DB[:table].first_source_table
    #   # => :table
    #
    #   DB[:table___t].first_source_table
    #   # => :table
    def first_source_table
      source = @opts[:from]
      if source.nil? || source.empty?
        raise Error, 'No source specified for query'
      end
      case s = source.first
      when SQL::AliasedExpression
        s.expression
      when Symbol
        sch, table, aliaz = split_symbol(s)
        aliaz ? (sch ? SQL::QualifiedIdentifier.new(sch, table) : table.to_sym) : s
      else
        s
      end
    end

    # Define a hash value such that datasets with the same DB, opts, and SQL
    # will have the same hash value
    def hash
      [db, opts, sql].hash
    end
    
    # The String instance method to call on identifiers before sending them to
    # the database.
    def identifier_input_method
      @opts.fetch(:identifier_input_method, db.identifier_input_method)
    end
    
    # The String instance method to call on identifiers before sending them to
    # the database.
    def identifier_output_method
      @opts.fetch(:identifier_output_method, db.identifier_output_method)
    end
    
    # Returns a string representation of the dataset including the class name 
    # and the corresponding SQL select statement.
    def inspect
      "#<#{visible_class_name}: #{sql.inspect}>"
    end
    
    # Whether this dataset is a joined dataset (multiple FROM tables or any JOINs).
    def joined_dataset?
     !!((opts[:from].is_a?(Array) && opts[:from].size > 1) || opts[:join])
    end

    # The alias to use for the row_number column, used when emulating OFFSET
    # support and for eager limit strategies
    def row_number_column
      :x_sequel_row_number_x
    end

    # The row_proc for this database, should be any object that responds to +call+ with
    # a single hash argument and returns the object you want #each to return.
    def row_proc
      @opts[:row_proc]
    end
    
    # Splits a possible implicit alias in +c+, handling both SQL::AliasedExpressions
    # and Symbols.  Returns an array of two elements, with the first being the
    # main expression, and the second being the alias.
    def split_alias(c)
      case c
      when Symbol
        c_table, column, aliaz = split_symbol(c)
        [c_table ? SQL::QualifiedIdentifier.new(c_table, column.to_sym) : column.to_sym, aliaz]
      when SQL::AliasedExpression
        [c.expression, c.alias]
      when SQL::JoinClause
        [c.table, c.table_alias]
      else
        [c, nil]
      end
    end

    # This returns an SQL::Identifier or SQL::AliasedExpression containing an
    # SQL identifier that represents the unqualified column for the given value.
    # The given value should be a Symbol, SQL::Identifier, SQL::QualifiedIdentifier,
    # or SQL::AliasedExpression containing one of those.  In other cases, this
    # returns nil
    def unqualified_column_for(v)
      unless v.is_a?(String)
        _unqualified_column_for(v)
      end
    end

    # Creates a unique table alias that hasn't already been used in the dataset.
    # table_alias can be any type of object accepted by alias_symbol.
    # The symbol returned will be the implicit alias in the argument,
    # possibly appended with "_N" if the implicit alias has already been
    # used, where N is an integer starting at 0 and increasing until an
    # unused one is found.
    #
    # You can provide a second addition array argument containing symbols
    # that should not be considered valid table aliases.  The current aliases
    # for the FROM and JOIN tables are automatically included in this array.
    #
    #   DB[:table].unused_table_alias(:t)
    #   # => :t
    #
    #   DB[:table].unused_table_alias(:table)
    #   # => :table_0
    #
    #   DB[:table, :table_0].unused_table_alias(:table)
    #   # => :table_1
    #
    #   DB[:table, :table_0].unused_table_alias(:table, [:table_1, :table_2])
    #   # => :table_3
    def unused_table_alias(table_alias, used_aliases = [])
      table_alias = alias_symbol(table_alias)
      used_aliases += opts[:from].map{|t| alias_symbol(t)} if opts[:from]
      used_aliases += opts[:join].map{|j| j.table_alias ? alias_alias_symbol(j.table_alias) : alias_symbol(j.table)} if opts[:join]
      if used_aliases.include?(table_alias)
        i = 0
        loop do
          ta = :"#{table_alias}_#{i}"
          return ta unless used_aliases.include?(ta)
          i += 1 
        end
      else
        table_alias
      end
    end

    # Return a modified dataset with quote_identifiers set.
    def with_quote_identifiers(v)
      clone(:quote_identifiers=>v, :skip_symbol_cache=>true)
    end
    
    # Return a modified dataset with identifier_input_method set.
    def with_identifier_input_method(meth)
      clone(:identifier_input_method=>meth, :skip_symbol_cache=>true)
    end
    
    # Return a modified dataset with identifier_output_method set.
    def with_identifier_output_method(meth)
      clone(:identifier_output_method=>meth)
    end

    protected

    # Access the cache for the current dataset.  Should be used with caution,
    # as access to the cache is not thread safe without a mutex if other
    # threads can reference the dataset.  Symbol keys prefixed with an
    # underscore are reserved for internal use.
    attr_reader :cache

    # Retreive a value from the dataset's cache in a thread safe manner.
    def cache_get(k)
      Sequel.synchronize{@cache[k]}
    end

    # Set a value in the dataset's cache in a thread safe manner.
    def cache_set(k, v)
      Sequel.synchronize{@cache[k] = v}
    end

    # Clear the columns hash for the current dataset.  This is not a
    # thread safe operation, so it should only be used if the dataset
    # could not be used by another thread (such as one that was just
    # created via clone).
    def clear_columns_cache
      @cache.delete(:_columns)
    end

    # The cached columns for the current dataset.
    def _columns
      cache_get(:_columns)
    end

    private

    # Check the cache for the given key, returning the value.
    # Otherwise, yield to get the dataset, and if the current dataset
    # is frozen, cache the dataset under the given key.
    def cached_dataset(key)
      unless ds = cache_get(key)
        ds = yield
        cache_set(key, ds) if frozen?
      end

      ds
    end

    # Set the columns for the current dataset.
    def columns=(v)
      cache_set(:_columns, v)
    end

    # Set the db, opts, and cache for the copy of the dataset.
    def initialize_copy(c)
      @db = c.db
      @opts = Hash[c.opts]
      if cols = c.cache_get(:_columns)
        @cache = {:_columns=>cols}
      else
        @cache = {}
      end
    end

    # Internal recursive version of unqualified_column_for, handling Strings inside
    # of other objects.
    def _unqualified_column_for(v)
      case v
      when Symbol
        _, c, a = Sequel.split_symbol(v)
        c = Sequel.identifier(c)
        a ? c.as(a) : c
      when String
        Sequel.identifier(v)
      when SQL::Identifier
        v
      when SQL::QualifiedIdentifier
        _unqualified_column_for(v.column)
      when SQL::AliasedExpression
        if expr = unqualified_column_for(v.expression)
          SQL::AliasedExpression.new(expr, v.alias)
        end
      end
    end

    # Return the class name for this dataset, but skip anonymous classes
    def visible_class_name
      c = self.class
      c = c.superclass while c.name.nil? || c.name == ''
      c.name
    end
  end
end
