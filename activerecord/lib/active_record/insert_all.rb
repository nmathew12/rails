# frozen_string_literal: true

module ActiveRecord
  class InsertAll
    attr_reader :model, :connection, :inserts, :keys
    attr_reader :on_duplicate, :returning, :unique_by

    def initialize(model, inserts, on_duplicate:, returning: nil, unique_by: nil)
      raise ArgumentError, "Empty list of attributes passed" if inserts.blank?

      @model, @connection, @inserts, @keys = model, model.connection, inserts, inserts.first.keys.map(&:to_s).to_set
      @on_duplicate, @returning, @unique_by = on_duplicate, returning, unique_by

      @returning = (connection.supports_insert_returning? ? primary_keys : false) if @returning.nil?
      @returning = false if @returning == []

      @on_duplicate = :skip if @on_duplicate == :update && updatable_columns.empty?

      ensure_valid_options_for_connection!
    end

    def execute
      connection.exec_query to_sql, "Bulk Insert"
    end

    def updatable_columns
      keys - readonly_columns - unique_by_columns
    end

    def skip_duplicates?
      on_duplicate == :skip
    end

    def update_duplicates?
      on_duplicate == :update
    end

    def map_key_with_value
      inserts.map do |attributes|
        attributes = attributes.stringify_keys
        verify_attributes(attributes)

        keys.map do |key|
          yield key, attributes[key]
        end
      end
    end

    private
      def ensure_valid_options_for_connection!
        if returning && !connection.supports_insert_returning?
          raise ArgumentError, "#{connection.class} does not support :returning"
        end

        unless %i{ raise skip update }.member?(on_duplicate)
          raise NotImplementedError, "#{on_duplicate.inspect} is an unknown value for :on_duplicate. Valid values are :raise, :skip, and :update"
        end

        if on_duplicate == :skip && !connection.supports_insert_on_duplicate_skip?
          raise ArgumentError, "#{connection.class} does not support skipping duplicates"
        end

        if on_duplicate == :update && !connection.supports_insert_on_duplicate_update?
          raise ArgumentError, "#{connection.class} does not support upsert"
        end

        if unique_by && !connection.supports_insert_conflict_target?
          raise ArgumentError, "#{connection.class} does not support :unique_by"
        end
      end

      def to_sql
        connection.build_insert_sql(ActiveRecord::InsertAll::Builder.new(self))
      end

      def readonly_columns
        primary_keys + model.readonly_attributes.to_a
      end

      def unique_by_columns
        unique_by ? unique_by.fetch(:columns).map(&:to_s) : []
      end

      def primary_keys
        Array.wrap(model.primary_key)
      end

      def verify_attributes(attributes)
        if keys != attributes.keys.to_set
          raise ArgumentError, "All objects being inserted must have the same keys"
        end
      end


      class Builder
        attr_reader :model

        delegate :skip_duplicates?, :update_duplicates?, to: :insert_all

        def initialize(insert_all)
          @insert_all, @model, @connection = insert_all, insert_all.model, insert_all.connection
        end

        def into
          "INTO #{model.quoted_table_name}(#{columns_list})"
        end

        def values_list
          types = extract_types_from_columns_on(model.table_name, keys: insert_all.keys)

          values_list = insert_all.map_key_with_value do |key, value|
            bind = Relation::QueryAttribute.new(key, value, types[key])
            connection.with_yaml_fallback(bind.value_for_database)
          end

          Arel::InsertManager.new.create_values_list(values_list).to_sql
        end

        def returning
          quote_columns(insert_all.returning).join(",") if insert_all.returning
        end

        def conflict_target
          return unless conflict_columns
          sql = +"(#{quote_columns(conflict_columns).join(',')})"
          sql << " WHERE #{where}" if where
          sql
        end

        def updatable_columns
          quote_columns(insert_all.updatable_columns)
        end

        private
          attr_reader :connection, :insert_all

          def columns_list
            quote_columns(insert_all.keys).join(",")
          end

          def extract_types_from_columns_on(table_name, keys:)
            columns = connection.schema_cache.columns_hash(table_name)

            unknown_column = (keys - columns.keys).first
            raise UnknownAttributeError.new(model.new, unknown_column) if unknown_column

            keys.map { |key| [ key, connection.lookup_cast_type_from_column(columns[key]) ] }.to_h
          end

          def quote_columns(columns)
            columns.map(&connection.method(:quote_column_name))
          end

          def conflict_columns
            @conflict_columns ||= begin
              conflict_columns = insert_all.unique_by.fetch(:columns) if insert_all.unique_by
              conflict_columns ||= Array.wrap(model.primary_key) if update_duplicates?
              conflict_columns
            end
          end

          def where
            insert_all.unique_by && insert_all.unique_by[:where]
          end
      end
  end
end
