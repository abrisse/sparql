require 'json'

##
# Extensions for Ruby's `NilClass` class.
class NilClass

  def evaluate(bindings, options = {})
    self
  end

end

##
# Extensions for Ruby's `Object` class.
class Object
  ##
  # Returns the SXP binary representation of this object, defaults to `self`.
  #
  # @return [String]
  def to_sxp_bin
    self
  end
  
  ##
  # Make sure the object is in SXP form and transform it to a string form
  # @return String
  def to_sse
    SXP::Generator.string(self.to_sxp_bin)
  end
end

##
# Extensions for Ruby's `Array` class.
class Array
  ##
  # Returns the SXP representation of this object, defaults to `self`.
  #
  # @return [String]
  def to_sxp_bin
    map {|x| x.to_sxp_bin}
  end

  ##
  # Evaluates the array using the given variable `bindings`.
  #
  # In this case, the Array has two elements, the first of which is
  # an XSD datatype, and the second is the expression to be evaluated.
  # The result is cast as a literal of the appropriate type
  #
  # @param  [RDF::Query::Solution] bindings
  #   a query solution containing zero or more variable bindings
  # @param [Hash{Symbol => Object}] options ({})
  #   options passed from query
  # @return [RDF::Term]
  # @see {SPARQL::Algebra::Expression.evaluate}
  def evaluate(bindings, options = {})
    SPARQL::Algebra::Expression.extension(*self.map {|o| o.evaluate(bindings, options)})
  end

  ##
  # If `#execute` is invoked, it implies that a non-implemented Algebra operator
  # is being invoked
  #
  # @param  [RDF::Queryable] queryable
  #   the graph or repository to query
  # @param  [Hash{Symbol => Object}] options
  # @raise [NotImplementedError]
  #   If an attempt is made to perform an unsupported operation
  # @see    http://www.w3.org/TR/rdf-sparql-query/#sparqlAlgebra
  def execute(queryable, options = {})
    raise NotImplementedError, "SPARQL::Algebra '#{first}' operator not implemented"
  end

  ##
  # Returns `true` if any of the operands are variables, `false`
  # otherwise.
  #
  # @return [Boolean] `true` or `false`
  # @see    #constant?
  def variable?
    any? do |operand|
      operand.is_a?(Variable) ||
        (operand.respond_to?(:variable?) && operand.variable?)
    end
  end
  def constant?; !(variable?); end
  def evaluatable?; true; end
  def executable?; false; end
  def aggregate?; false; end

  ##
  # Replace operators which are variables with the result of the block
  # descending into operators which are also evaluatable
  #
  # @yield var
  # @yieldparam [RDF::Query::Variable] var
  # @yieldreturn [RDF::Query::Variable, SPARQL::Algebra::Evaluatable]
  # @return [SPARQL::Algebra::Evaluatable] self
  def replace_vars!(&block)
    map! do |op|
      case
      when op.respond_to?(:variable?) && op.variable?
        yield op
      when op.respond_to?(:replace_vars!)
        op.replace_vars!(&block) 
      else
        op
      end
    end
    self
  end

  ##
  # Recursively re-map operators to replace aggregates with temporary variables returned from the block
  #
  # @yield agg
  # @yieldparam [SPARQL::Algebra::Aggregate] agg
  # @yieldreturn [RDF::Query::Variable]
  # @return [SPARQL::Algebra::Evaluatable, RDF::Query::Variable] self
  def replace_aggregate!(&block)
    map! do |op|
      case
      when op.respond_to?(:aggregate?) && op.aggregate?
        yield op
      when op.respond_to?(:replace_aggregate!)
        op.replace_aggregate!(&block) 
      else
        op
      end
    end
    self
  end
end

##
# Extensions for Ruby's `Hash` class.
class Hash
  ##
  # Returns the SXP representation of this object, defaults to `self`.
  #
  # @return [String]
  def to_sxp_bin
    to_a.to_sxp_bin
  end
  def to_sxp; to_sxp_bin; end
end

##
# Extensions for `RDF::Term`.
module RDF::Term
  include SPARQL::Algebra::Expression
  
  # @param  [RDF::Query::Solution] bindings
  #   a query solution containing zero or more variable bindings
  # @param [Hash{Symbol => Object}] options ({})
  #   options passed from query
  # @return [RDF::Term]
  def evaluate(bindings, options = {})
    self
  end

  def aggregate?; false; end

  # Term compatibility according to SPARQL
  #
  # Compatibility of two arguments is defined as:
  # * The arguments are simple literals or literals typed as xsd:string
  # * The arguments are plain literals with identical language tags
  # * The first argument is a plain literal with language tag and the second argument is a simple literal or literal typed as xsd:string
  #
  # @example
  #     compatible?("abc"	"b")                         #=> true
  #     compatible?("abc"	"b"^^xsd:string)             #=> true
  #     compatible?("abc"^^xsd:string	"b")             #=> true
  #     compatible?("abc"^^xsd:string	"b"^^xsd:string) #=> true
  #     compatible?("abc"@en	"b")                     #=> true
  #     compatible?("abc"@en	"b"^^xsd:string)         #=> true
  #     compatible?("abc"@en	"b"@en)                  #=> true
  #     compatible?("abc"@fr	"b"@ja)                  #=> false
  #     compatible?("abc"	"b"@ja)                      #=> false
  #     compatible?("abc"	"b"@en)                      #=> false
  #     compatible?("abc"^^xsd:string	"b"@en)          #=> false
  #
  # @see http://www.w3.org/TR/sparql11-query/#func-arg-compatibility
  def compatible?(other)
    return false unless literal?  && other.literal? && plain? && other.plain?

    dtr = other.datatype

    # * The arguments are simple literals or literals typed as xsd:string
    # * The arguments are plain literals with identical language tags
    # * The first argument is a plain literal with language tag and the second argument is a simple literal or literal typed as xsd:string
    has_language? ?
      (language == other.language || dtr == RDF::XSD.string) :
      dtr == RDF::XSD.string
  end
end # RDF::Term

# Override RDF::Queryable to execute against SPARQL::Algebra::Query elements as well as RDF::Query and RDF::Pattern
module RDF::Queryable
  alias_method :query_without_sparql, :query
  ##
  # Queries `self` for RDF statements matching the given `pattern`.
  #
  # Monkey patch to RDF::Queryable#query to execute a {SPARQL::Algebra::Operator}
  # in addition to an {RDF::Query} object.
  #
  # @example
  #     queryable.query([nil, RDF::DOAP.developer, nil])
  #     queryable.query(:predicate => RDF::DOAP.developer)
  #
  #     op = SPARQL::Algebra::Expression.parse(%q((bgp (triple ?a doap:developer ?b))))
  #     queryable.query(op)
  #
  # @param  [RDF::Query, RDF::Statement, Array(RDF::Term), Hash, SPARQL::Operator] pattern
  # @yield  [statement]
  #   each matching statement
  # @yieldparam  [RDF::Statement] statement
  # @yieldreturn [void] ignored
  # @return [Enumerator]
  # @see    RDF::Queryable#query_pattern
  def query(pattern, options = {}, &block)
    raise TypeError, "#{self} is not queryable" if respond_to?(:queryable?) && !queryable?

    if pattern.is_a?(SPARQL::Algebra::Operator) && pattern.respond_to?(:execute)
      before_query(pattern) if respond_to?(:before_query)
      solutions = if method(:query_execute).arity == 1
        query_execute(pattern, &block)
      else
        query_execute(pattern, options, &block)
      end
      after_query(pattern) if respond_to?(:after_query)

      if !pattern.respond_to?(:query_yeilds_solutions?) || pattern.query_yields_solutions?
        # Just return solutions
        solutions
      else
        # Return an enumerator
        enum_for(:query, pattern, options)
      end
    else
      query_without_sparql(pattern, options, &block)
    end
  end
  
end

class RDF::Query
  # Equivalence for Queries:
  #   Same Patterns
  #   Same Context
  # @return [Boolean]
  def ==(other)
    other.is_a?(RDF::Query) && patterns == other.patterns && context == context
  end
      
  ##
  # Don't do any more rewriting
  # @return [SPARQL::Algebra::Expression] `self`
  def rewrite(&block)
    self
  end

  # Transform Query into an Array form of an SSE
  #
  # If Query is named, it's treated as a GroupGraphPattern, otherwise, a BGP
  #
  # @return [Array]
  def to_sxp_bin
    res = [:bgp] + patterns.map(&:to_sxp_bin)
    (context ? [:graph, context, res] : res)
  end
  # Query results in a boolean result (e.g., ASK)
  # @return [Boolean]
  def query_yields_boolean?
    false
  end

  # Query results statements (e.g., CONSTRUCT, DESCRIBE, CREATE)
  # @return [Boolean]
  def query_yields_statements?
    false
  end

  # Query results solutions (e.g., SELECT)
  # @return [Boolean]
  def query_yields_solutions?
    true
  end
end

class RDF::Query::Pattern
  # Transform Query Pattern into an SXP
  # @return [Array]
  def to_sxp_bin
    [:triple, subject, predicate, object]
  end
end

##
# Extensions for `RDF::Query::Variable`.
class RDF::Query::Variable
  include SPARQL::Algebra::Expression

  ##
  # Returns the value of this variable in the given `bindings`.
  #
  # @param  [RDF::Query::Solution] bindings
  #   a query solution containing zero or more variable bindings
  # @param [Hash{Symbol => Object}] options ({})
  #   options passed from query
  # @return [RDF::Term] the value of this variable
  # @raise [TypeError] if the variable is not bound
  def evaluate(bindings, options = {})
    raise TypeError if bindings.respond_to?(:bound?) && !bindings.bound?(self)
    bindings[name.to_sym]
  end

  def to_s
    prefix = distinguished? || name.to_s[0,1] == '.' ? '?' : "??"
    unbound? ? "#{prefix}#{name}" : "#{prefix}#{name}=#{value}"
  end
end # RDF::Query::Variable

##
# Extensions for `RDF::Query::Solutions`.
class RDF::Query::Solutions
  alias_method :filter_without_expression, :filter

  ##
  # Filters this solution sequence by the given `criteria`.
  #
  # @param  [SPARQL::Algebra::Expression] expression
  # @yield  [solution]
  #   each solution
  # @yieldparam  [RDF::Query::Solution] solution
  # @yieldreturn [Boolean]
  # @return [void] `self`
  def filter(expression = {}, &block)
    case expression
      when SPARQL::Algebra::Expression
        filter_without_expression do |solution|
          expression.evaluate(solution).true?
        end
        filter_without_expression(&block) if block_given?
        self
      else filter_without_expression(expression, &block)
    end
  end
  alias_method :filter!, :filter
end # RDF::Query::Solutions
