module PgQuery
  def self.parse(query)
    result, stderr = parse_protobuf(query)

    begin
      result = PgQuery::ParseResult.decode(result)
    rescue Google::Protobuf::ParseError
      raise PgQuery::ParseError.new('Failed to parse tree', __FILE__, __LINE__, -1)
    end

    warnings = []
    stderr.each_line do |line|
      next unless line[/^WARNING/]
      warnings << line.strip
    end

    PgQuery::ParserResult.new(query, result, warnings)
  end

  class ParserResult
    attr_reader :query
    attr_reader :tree
    attr_reader :warnings

    def initialize(query, tree, warnings = [])
      @query = query
      @tree = tree
      @warnings = warnings
      @tables = nil
      @aliases = nil
      @cte_names = nil
    end

    def dup_tree
      ParseResult.decode(ParseResult.encode(@tree))
    end

    def tables
      tables_with_details.map { |t| t[:name] }.uniq
    end

    def select_tables
      tables_with_details.select { |t| t[:type] == :select }.map { |t| t[:name] }.uniq
    end

    def dml_tables
      tables_with_details.select { |t| t[:type] == :dml }.map { |t| t[:name] }.uniq
    end

    def ddl_tables
      tables_with_details.select { |t| t[:type] == :ddl }.map { |t| t[:name] }.uniq
    end

    def cte_names
      load_tables_and_aliases! if @cte_names.nil?
      @cte_names
    end

    def aliases
      load_tables_and_aliases! if @aliases.nil?
      @aliases
    end

    def tables_with_details
      load_tables_and_aliases! if @tables.nil?
      @tables
    end

    protected

    def load_tables_and_aliases! # rubocop:disable Metrics/CyclomaticComplexity
      @tables = [] # types: select, dml, ddl
      @cte_names = []
      @aliases = {}

      statements = @tree.stmts.dup.to_a.map(&:stmt)
      from_clause_items = [] # types: select, dml, ddl
      subselect_items = []

      loop do
        statement = statements.shift
        if statement
          case statement.node
          when :list
            statements += statement.list.items
          # The following statement types do not modify tables and are added to from_clause_items
          # (and subsequently @tables)
          when :select_stmt
            subselect_items.concat(statement.select_stmt.target_list)
            subselect_items << statement.select_stmt.where_clause if statement.select_stmt.where_clause
            subselect_items.concat(statement.select_stmt.sort_clause.collect { |h| h.sort_by.node })
            subselect_items.concat(statement.select_stmt.group_clause)
            subselect_items << statement.select_stmt.having_clause if statement.select_stmt.having_clause

            case statement.select_stmt.op
            when :SETOP_NONE
              (statement.select_stmt.from_clause || []).each do |item|
                if item.node == :range_subselect
                  statements << item.range_subselect.subquery
                else
                  from_clause_items << { item: item, type: :select }
                end
              end
            when :SETOP_UNION
              statements << PgQuery::Node.new(select_stmt: statement.select_stmt.larg) if statement.select_stmt.larg
              statements << PgQuery::Node.new(select_stmt: statement.select_stmt.rarg) if statement.select_stmt.rarg
            end

            if statement.select_stmt.with_clause
              cte_statements, cte_names = statements_and_cte_names_for_with_clause(statement.select_stmt.with_clause)
              @cte_names.concat(cte_names)
              statements.concat(cte_statements)
            end
          # The following statements modify the contents of a table
          when :insert_stmt, :update_stmt, :delete_stmt
            value = statement.public_send(statement.node)
            from_clause_items << { item: PgQuery::Node.new(range_var: value.relation), type: :dml }
            statements << value.select_stmt if statement.node == :insert_stmt && value.select_stmt

            subselect_items.concat(statement.update_stmt.target_list) if statement.node == :update_stmt
            subselect_items << statement.update_stmt.where_clause if statement.node == :update_stmt && statement.update_stmt.where_clause
            subselect_items << statement.delete_stmt.where_clause if statement.node == :delete_stmt && statement.delete_stmt.where_clause

            if value.with_clause
              cte_statements, cte_names = statements_and_cte_names_for_with_clause(value.with_clause)
              @cte_names.concat(cte_names)
              statements.concat(cte_statements)
            end
          when :copy_stmt
            from_clause_items << { item: PgQuery::Node.new(range_var: statement.copy_stmt.relation), type: :dml } if statement.copy_stmt.relation
            statements << statement.copy_stmt.query
          # The following statement types are DDL (changing table structure)
          when :alter_table_stmt
            from_clause_items << { item: PgQuery::Node.new(range_var: statement.alter_table_stmt.relation), type: :ddl }
          when :create_stmt
            from_clause_items << { item: PgQuery::Node.new(range_var: statement.create_stmt.relation), type: :ddl }
          when :create_table_as_stmt
            if statement.create_table_as_stmt.into && statement.create_table_as_stmt.into.rel
              from_clause_items << { item: PgQuery::Node.new(range_var: statement.create_table_as_stmt.into.rel), type: :ddl }
            end
            statements << statement.create_table_as_stmt.query if statement.create_table_as_stmt.query
          when :truncate_stmt
            from_clause_items += statement.truncate_stmt.relations.map { |r| { item: r, type: :ddl } }
          when :view_stmt
            from_clause_items << { item: PgQuery::Node.new(range_var: statement.view_stmt.view), type: :ddl }
            statements << statement.view_stmt.query
          when :index_stmt
            from_clause_items << { item: PgQuery::Node.new(range_var: statement.index_stmt.relation), type: :ddl }
          when :create_trig_stmt
            from_clause_items << { item: PgQuery::Node.new(range_var: statement.create_trig_stmt.relation), type: :ddl }
          when :rule_stmt
            from_clause_items << { item: PgQuery::Node.new(range_var: statement.rule_stmt.relation), type: :ddl }
          when :vacuum_stmt
            from_clause_items += statement.vacuum_stmt.rels.map { |r| { item: PgQuery::Node.new(range_var: r.vacuum_relation.relation), type: :ddl } if r.node == :vacuum_relation }
          when :refresh_mat_view_stmt
            from_clause_items << { item: PgQuery::Node.new(range_var: statement.refresh_mat_view_stmt.relation), type: :ddl }
          when :drop_stmt
            objects = statement.drop_stmt.objects.map do |obj|
              case obj.node
              when :list
                obj.list.items.map { |obj2| obj2.string.str if obj2.node == :string }
              when :string
                obj.string.str
              end
            end
            case statement.drop_stmt.remove_type
            when :OBJECT_TABLE
              @tables += objects.map { |r| { name: r.join('.'), type: :ddl } }
            when :OBJECT_RULE, :OBJECT_TRIGGER
              @tables += objects.map { |r| { name: r[0..-2].join('.'), type: :ddl } }
            end
          when :grant_stmt
            objects = statement.grant_stmt.objects
            case statement.grant_stmt.objtype
            when :OBJECT_COLUMN # Column # rubocop:disable Lint/EmptyWhen
              # FIXME
            when :OBJECT_TABLE # Table
              from_clause_items += objects.map { |o| { item: o, type: :ddl } }
            when :OBJECT_SEQUENCE # Sequence # rubocop:disable Lint/EmptyWhen
              # FIXME
            end
          when :lock_stmt
            from_clause_items += statement.lock_stmt.relations.map { |r| { item: r, type: :ddl } }
          # The following are other statements that don't fit into query/DML/DDL
          when :explain_stmt
            statements << statement.explain_stmt.query
          end
        end

        next_item = subselect_items.shift
        if next_item
          case next_item.node
          when :a_expr
            %w[lexpr rexpr].each do |side|
              elem = next_item.a_expr.public_send(side)
              next unless elem
              if elem.is_a?(Array) # FIXME: this needs to traverse a list
                subselect_items += elem
              else
                subselect_items << elem
              end
            end
          when :bool_expr
            subselect_items.concat(next_item.bool_expr.args)
          when :res_target
            subselect_items << next_item.res_target.val
          when :sub_link
            statements << next_item.sub_link.subselect
          end
        end

        break if subselect_items.empty? && statements.empty?
      end

      loop do
        next_item = from_clause_items.shift
        break unless next_item && next_item[:item]

        case next_item[:item].node
        when :join_expr
          from_clause_items << { item: next_item[:item].join_expr.larg, type: next_item[:type] }
          from_clause_items << { item: next_item[:item].join_expr.rarg, type: next_item[:type] }
        when :row_expr
          from_clause_items += next_item[:item].row_expr.args.map { |a| { item: a, type: next_item[:type] } }
        when :range_var
          rangevar = next_item[:item].range_var
          next if rangevar.schemaname.empty? && @cte_names.include?(rangevar.relname)

          table = [rangevar.schemaname, rangevar.relname].reject { |s| s.nil? || s.empty? }.join('.')
          @tables << {
            name: table,
            type: next_item[:type],
            location: rangevar.location,
            schemaname: (rangevar.schemaname unless rangevar.schemaname.empty?),
            relname: rangevar.relname,
            inh: rangevar.inh
          }
          @aliases[rangevar.alias.aliasname] = table if rangevar.alias
        when :range_subselect
          from_clause_items << { item: next_item[:item].range_subselect.subquery, type: next_item[:type] }
        when :select_stmt
          from_clause = next_item[:item].select_stmt.from_clause
          from_clause_items += from_clause.map { |r| { item: r, type: next_item[:type] } } if from_clause
        end
      end

      @tables.uniq!
      @cte_names.uniq!
    end

    def statements_and_cte_names_for_with_clause(with_clause) # FIXME
      statements = []
      cte_names = []

      with_clause.ctes.each do |item|
        next unless item.node == :common_table_expr
        cte_names << item.common_table_expr.ctename
        statements << item.common_table_expr.ctequery
      end

      [statements, cte_names]
    end
  end
end
