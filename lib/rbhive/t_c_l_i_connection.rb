# suppress warnings
old_verbose, $VERBOSE = $VERBOSE, nil

raise 'Thrift is not loaded' unless defined?(Thrift)
raise 'RBHive is not loaded' unless defined?(RBHive)

# require thrift autogenerated files
require File.join(File.dirname(__FILE__), *%w[.. thrift t_c_l_i_service_constants])
require File.join(File.dirname(__FILE__), *%w[.. thrift t_c_l_i_service])
require File.join(File.dirname(__FILE__), *%w[.. thrift sasl_client_transport])

# restore warnings
$VERBOSE = old_verbose


module RBHive
  def tcli_connect(server, port=10_000, sasl_params={})
    connection = RBHive::TCLIConnection.new(server, port, sasl_params)
    ret = nil
    begin
      connection.open
      connection.open_session
      ret = yield(connection)
    ensure
      connection.close_session if connection.session?
      connection.close
      ret
    end
  end
  module_function :tcli_connect

  class StdOutLogger
    %w(fatal error warn info debug).each do |level|
      define_method level.to_sym do |message|
        STDOUT.puts(message)
     end
   end
  end

  class TCLIConnection
    attr_reader :client

    def initialize(server, port=10_000, sasl_params={}, logger=StdOutLogger.new)
      @socket = Thrift::Socket.new(server, port)
      @socket.timeout = 1800
      @logger = logger
      if sasl_params.present?
        @logger.info("Initializing transport with SASL support")
        @transport = Thrift::SaslClientTransport.new(@socket, sasl_params)
      else
        @transport = Thrift::BufferedTransport.new(@socket)
      end
      @protocol = Thrift::BinaryProtocol.new(@transport)
      @client = TCLIService::Client.new(@protocol)
      @session = nil
      @logger.info("Connecting to HiveServer2 #{server} on port #{port}")
      @mutex = Mutex.new
    end

    def open
      @transport.open
    end

    def close
      @transport.close
    end

    def open_session
      @session = @client.OpenSession(prepare_open_session)
    end

    def close_session
      @client.CloseSession prepare_close_session
      @session = nil
    end

    def session?
      @session && @session.sessionHandle
    end

    def client
      @client
    end

    def execute(query)
      execute_safe(query)
    end

    def priority=(priority)
      set("mapred.job.priority", priority)
    end

    def queue=(queue)
      set("mapred.job.queue.name", queue)
    end

    def set(name,value)
      @logger.info("Setting #{name}=#{value}")
      self.execute("SET #{name}=#{value}")
    end

    def fetch(query)
      safe do
        op_handle = execute_unsafe(query).operationHandle
        fetch_req = prepare_fetch_results(op_handle)
        fetch_results = client.FetchResults(fetch_req)
        raise fetch_results.status.try(:errorMessage, 'Execution failed!').to_s if fetch_results.status.statusCode != 0
        rows = fetch_results.results.rows
        the_schema = TCLISchemaDefinition.new(get_schema_for( op_handle ), rows.first)
        TCLIResultSet.new(rows, the_schema)
      end
    end

    def method_missing(meth, *args)
      client.send(meth, *args)
    end

    private

    def execute_safe(query)
      safe { execute_unsafe(query) }
    end

    def execute_unsafe(query)
      @logger.info("Executing Hive Query: #{query}")
      req = prepare_execute_statement(query)
      client.ExecuteStatement(req)
    end

    def safe
      ret = nil
      @mutex.synchronize { ret = yield }
      ret
    end

    def prepare_open_session
      TOpenSessionReq.new
    end

    def prepare_close_session
      TCloseSessionReq.new( sessionHandle: @session.sessionHandle )
    end

    def prepare_execute_statement(query)
      TExecuteStatementReq.new( sessionHandle: @session.sessionHandle, statement: query.to_s )
    end

    def prepare_fetch_results(handle, orientation=:first, rows=100)
      orientation = orientation.to_s.upcase
      orientation = 'FIRST' unless TFetchOrientation::VALID_VALUES.include?( "FETCH_#{orientation}" )
      TFetchResultsReq.new( operationHandle: handle, orientation: eval("TFetchOrientation::FETCH_#{orientation}"), maxRows: rows )
    end

    def get_schema_for(handle)
      req = TGetResultSetMetadataReq.new( operationHandle: handle )
      metadata = client.GetResultSetMetadata( req )
      metadata.schema
    end
  end
end
