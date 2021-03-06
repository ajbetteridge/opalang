/*
    Copyright © 2011-2013 MLstate

    This file is part of Opa.

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
/**
 * Postgres low-level driver
 *
 * This file provides the implemented methods of the Postgres API.
 *
 * @category web
 * @author Norman Scaife, 2012
 * @destination public
 * @stability Work in progress
 */

import stdlib.io.socket
import stdlib.apis.apigenlib
import stdlib.crypto

/**
 * {1 About this module}
 *
 * This module provides basic, low-level support for connecting to a PosgreSQL server.
 * Routines are provided to send a subset of the PostgreSQL commands and a single input
 * routine is provided to handle incoming messages.  Note that some of the messages sent
 * do not expect a reply whereas others do.
 *
 * The connection object includes some status information gathered during the send and receive operations
 * but mostly the driver operates by calling the listener callback.  This performs three functions:
 * it is passed row and row description data as it is returned from the server, it is passed
 * error and notice messages retrned from the server (note that an SQL operation can generate
 * more than one of these) and a final message called once all data has been received and the
 * server is ready for more queries.  The final message will receive either a success outcome
 * of an updated connection object or a copy of the *last* failure message.
 *
 * {1 Where should I start?}
 *
 * Take a look at the example code (test_pg.opa).  This shows how to perform basic queries
 * and handle the results.  Currently, only the raw data is returned, functions may be
 * provided in future to convert the result data into Opa format.
 *
 * {1 What if I need more?}
 *
 * Study the auto-generated module Pg which shows how the underlying code works.  You can
 * add more functionality exterior to this module by copying the code shown there.
 *
 */

/**
 * {1 Types defined in this module}
 */

/** A message (error or notice) from the PostgreSQL server.
 */
type Postgres.msg = list((int,string))

/** Either a PostgreSQL error or notice.
 */
type Postgres.en =
   { error : Postgres.msg }
 / { notice : Postgres.msg }

/** Types of replies to [Authentication] message replies.
 */
type Postgres.auth_reply =
     { Ok }
   / { MD5Password: binary }
   / { GSSContinue: binary }
   / { SSPI }
   / { GSS }
   / { SCMCredential }
   / { CleartextPassword }
   / { KerberosV5 }

/** Type of a reply from PostgreSQL.
 */
type Postgres.reply =
   { ReadyForQuery: string }
 / { ErrorResponse: Postgres.msg }
 / { NoticeResponse: Postgres.msg }
 / { DataRow: list(binary) }
 / { RowDescription: list((string, int, int, int, int, int, int)) }
 / { EmptyQueryResponse }
 / { BackendKeyData: (int, int) }
 / { ParameterStatus: (string, string) }
 / { Authentication: Postgres.auth_reply }
 / { PortalSuspended }
 / { ParameterDescription: list(int) }
 / { NotificationResponse: (int, string, string) }
 / { NoData }
 / { FunctionCallResponse: binary }
 / { CopyBothResponse: (int, list(int)) }
 / { CopyOutResponse: (int, list(int)) }
 / { CopyDoneB }
 / { CopyDataB: binary }
 / { CloseComplete }
 / { BindComplete }
 / { CommandComplete: string }
 / { ParseComplete }

/** Type of errors from the Postgres driver, includes [Apigen] failures as
 * well as errors from the PostgreSQL server and driver internal errors.
 */
type Postgres.failure =
   { api_failure : Apigen.failure }
 / { postgres : Postgres.en }
 / { bad_reply : Postgres.reply }
 / { bad_row : (list(Postgres.rowdesc),list(binary)) }
 / { bad_format : int }
 / { bad_ssl_response : string }
 / { bad_type : string }
 / { sql : string }
 / { no_key }
 / { not_found }

/** The type of a value passed to the listener callback.
 */
type Postgres.listener_arg =
   { final: Postgres.result }
 / { rowdescs: Postgres.rowdescs }
 / { DataRow: list(binary) }
 / { ErrorResponse: Postgres.msg }
 / { NoticeResponse: Postgres.msg }

/** The type of a Postgres listener */
type Postgres.listener = (Postgres.connection, Postgres.listener_arg -> void)

/** Failure return for some Postgres module function (it includes the connection itself).
 */
type Postgres.unsuccessful = (Postgres.connection,Postgres.failure)

/** Standard success value is just an updated connection.
 */
type Postgres.success = Postgres.connection

/** Standard result value.
 */
type Postgres.result = outcome(Postgres.success,Postgres.unsuccessful)

/** Row description, value returned from the PostgreSQL server.
 */
type Postgres.rowdesc = {
  name : string
  table_id : int
  table_attribute_number : int
  type_id : Postgres.type_id
  data_type_size : int
  type_modifier : int
  format_code : int
}

/** List of row descriptions.
 */
type Postgres.rowdescs = list(Postgres.rowdesc)

/** A row is just a list of binary values.  You need the [format_code] values
 * to tell if each one is text or binary.
 */
type Postgres.row = list(binary)

/** A row value passed to the row continuation.
 * Includes the row number (in the command return values), the row description and the raw row data.
 */
type Postgres.full_row = (int,Postgres.rowdescs,Postgres.row)

/** A complete set of rows, one row description and multiple rows.
 */
type Postgres.rows = (list(Postgres.rowdesc),list(Postgres.row))

/** A Postgres driver connection object.
 */
@abstract
type Postgres.connection = {
  name           : string /** A name for the connection */
  secure         : option(SSL.secure_type) /** Optional SSL security information */
  ssl_accepted   : bool /** The server has accepted an SSL connection */
  conn           : ApigenLib.connection /** The underlying ApigenLib connection object */
  major_version  : int /** The major version for the protocol */
  minor_version  : int /** The minor version for the protocol */
  dbase          : string /** The name of the database to connected to */
  params         : stringmap(string) /** Map of parameter values returned during authentication */
  query          : string /** A note of the last query command */
  status         : string /** The last received status code from the server */
  suspended      : bool /** Whether an execution was suspended or not */
  in_transaction : bool /** Set during a block (not for external queries) */
  error          : option(Postgres.failure) /** The last received error value (driver internal) */
  empty          : bool /** Whether the last query returned an empty reply */
  completed      : list(string) /** List of [CommandComplete] messages received */
  rows           : int /** The number of rows received during a query */
  rowdescs       : Postgres.rowdescs /** Stored value of the last row description received */
  paramdescs     : list(int) /** List of the last-received parameter descriptions */
  handlers       : intmap((string,OpaType.ty,Postgres.abstract_handler)) /** Handlers for unknown data types */
  backhandlers   : stringmap(int) /** Reverse map for outgoing data */
  init_session   : Postgres.connection -> Postgres.connection
}

/** Defines whether an operation is for a prepared statement or a portal */
type Postgres.sp = {statement} / {portal}

/** Listener definition, functions for each event generated by the postgres driver.
 */
type Postgres.listener_def = {
  on_success  : option(Postgres.connection -> void)
  on_failure  : option(Postgres.connection, Postgres.failure -> void)
  on_rowdescs : option(Postgres.connection, Postgres.rowdescs -> void)
  on_row      : option(Postgres.connection, Postgres.row -> void)
  on_error    : option(Postgres.connection, Postgres.msg -> void)
  on_notice   : option(Postgres.connection, Postgres.msg -> void)
}

/** Cursor direction flags. */
type Postgres.cursor_direction = {forward} / {backward}

/** Cursor amount indicator. */
type Postgres.cursor_amount = {num:int} / {all} / {next} / {prior}

type Postgres.data = Postgres.opatype

/**
 * {1 Interface}
 */
Postgres = {{

  @private bindump = (%% BslPervasives.bindump %%: binary -> string)

  @private to_rowdesc((name,table_id,table_attribute_number,type_id,data_type_size,type_modifier,format_code)) =
    ~{name table_id table_attribute_number type_id data_type_size type_modifier format_code} : Postgres.rowdesc

  @private string_of_sp(sp:Postgres.sp) =
    match sp with
    | {statement} -> "S"
    | {portal} -> "P"

  /** The default host for a local PostgreSQL server: localhost:5432 */
  default_host = Pg.default_host

  /** The default major version of the protocol, you shouldn't ever have to set this */
  default_major_version = Pg.default_major_version

  /** The default minor version of the protocol, you shouldn't ever have to set this */
  default_minor_version = Pg.default_minor_version

  @private
  pack_string_array(l):(int, Pack.u) =
    // Expected size if no escaping
    size = List.fold_left(size, str -> String.byte_length(str) + size + 3, 1, l)
    bin = Binary.create(size)
    rec aux_string(s, size, last, current) =
      if current == size then
        if last == 0 then Binary.add_string(bin, s)
        else Binary.add_string(bin, String.substring(last, current - last, s))
      else
        c = String.char_at(s, current)
        if c == '\"' then
          do Binary.add_string(bin, String.substring(last, current - last, s))
          do Binary.add_string(bin, "\\\"")
          aux_string(s, size, current+1, current+1)
        else aux_string(s, size, last, current+1)
    rec aux =
      | [] -> void
      | [s] ->
        do Binary.add_string(bin, "\"")
        do aux_string(s, String.length(s), 0, 0)
        Binary.add_string(bin, "\"")
      | [t|q] ->
        do Binary.add_string(bin, "\"")
        do aux_string(t, String.length(t), 0, 0)
        do Binary.add_string(bin, "\"")
        do Binary.add_string(bin, ",")
        aux(q)
    do Binary.add_string(bin, "\{")
    do aux(l)
    do Binary.add_string(bin, "}")
    (0, {Binary = bin})

  @private
  pack_int_array(l):(int, Pack.u) =
    bin = Binary.create(List.length(l)*5)
    rec aux =
      | [] -> void
      | [i] -> Binary.add_string(bin, Int.to_string(i))
      | [t|q] ->
        do Binary.add_string(bin, Int.to_string(t))
        do Binary.add_string(bin, ",")
        aux(q)
    do Binary.add_string(bin, "\{")
    do aux(l)
    do Binary.add_string(bin, "}")
    (0, {Binary = bin})

  pack(data: Postgres.data): (int, Pack.u) =
    match data with
    | {Null}      -> (1, {Int = -1})
    | ~{Int}      -> (1, ~{Int size={Ll}})
    | ~{Int16}    -> (1, {Int=Int16 size={S}})
    | ~{Int64}    -> (1, ~{Int64})
    | ~{Bool}     -> (1, ~{Bool})
    | {String=s}  -> (1, {Binary = Binary.of_string(s)})
    | ~{Real}     -> (1, {Float32 = Real})
    | ~{Float}    -> (1, ~{Float})
    | ~{Bytea}    -> (1, {Binary = Bytea})
    | {Date=d}    -> (1, {Int=Date.in_milliseconds(d) size={S}})
    | {Time=d}    -> (1, {Int=Date.in_milliseconds(d)})
    | {Timestamp=d} -> (1, {Int=Date.in_milliseconds(d)})
    | {StringArray1=l} -> pack_string_array(l)
    | {IntArray1=l} -> pack_int_array(l)
    | {Duration=_}
    | {Timestamptz=_}
    | {Money=_}
    | {Numeric=_}
    | {IntArray2=_}
    | {IntArray3=_}
    | {Int16Array1=_}
    | {Int16Array2=_}
    | {Int16Array3=_}
    | {Int64Array1=_}
    | {Int64Array2=_}
    | {Int64Array3=_}
    | {RealArray1=_}
    | {RealArray2=_}
    | {RealArray3=_}
    | {FloatArray1=_}
    | {FloatArray2=_}
    | {FloatArray3=_}
    | {StringArray2=_}
    | {StringArray3=_}
    | {TypeId=_}
    | {BadData=_}
    | {BadText=_}
    | {BadCode=_}
    | {BadDate=_}
    | {BadEnum=_} ->
      do Log.error("Postgres", "NYI: {data}")
      @fail

  /**
   * Serialize a postgres value to it's binary representation.
   * @param data The value to serialize
   / @return The serialized reprensentation of [data]
   */
  serialize(data:Postgres.data): (int, binary) =
    (code, data) = pack(data)
    (code, match data with
    | ~{Binary} -> Binary
    | pdata ->
      x = Binary.create(Pack.Encode.packlen([pdata]))
      _ = Pack.Encode.pack_u(x, false, false, {S}, pdata)
      x)

  /**
   * Returns the name of the database
   * @param db A Postgres database
   * @return Name of database
   */
  get_name(conn:Postgres.connection) = conn.name

  /** Create connection object.
   *
   * This function returns a fresh [Postgres.connection] object.
   * All internal parameters are reset and the object contains all the information
   * to manage the connection but doesn't actually open a connection to the server
   * until an operation is performed on the connection.
   *
   * @param db The Postgres database to connect
   * @returns An outcome of either a connection object or an [Apigen.failure] value.
   */
  connect(name:string, secure:option(SSL.secure_type), dbase:string): outcome(Postgres.connection, _) =
    preamble = if Option.is_some(secure) then {some=request_ssl} else none
    match Pg.connect(name,secure,preamble,true) with
    | {success=conn} ->
      {success={ ~name ~secure ~conn ~dbase ssl_accepted=false
                 major_version=default_major_version minor_version=default_minor_version
                 params=StringMap.empty
                 query="" status="" suspended=false in_transaction=false error=none
                 empty=true completed=[] paramdescs=[] rows=0 rowdescs=[]
                 handlers=IntMap.empty backhandlers=StringMap.empty
                 init_session=identity
                }}
    | {~failure} -> {~failure}

  /** Return the last query made on the connection. */
  get_query(conn:Postgres.connection) : string = conn.query

  /** Return the list of operations completed by the last call. */
  get_completed(conn:Postgres.connection) : list(string) = conn.completed

  /** Close a connection object.
   *
   * This routine closes the connection to the server and releases any associated resources.
   *
   * @param conn The connection object.
   * @param terminate If true, a [Terminate] message will be sent to the server before closing the connection.
   * @returns An outcome of the updated connection or an [Apigen.failure] value.
   */
  close(conn:Postgres.connection, terminate:bool) =
    sconn =
      if terminate
      then Pg.terminate({success=conn.conn})
      else {success=conn.conn}
    match Pg.close(sconn) with
    | {success=c} -> {success={conn with conn=c}}
    | {~failure} -> {~failure}

  /**
   * Returns the error status of the connection.
   * @param conn A Postgres connection
   * @return Error status of [conn]
   */
  get_error(conn:Postgres.connection) = conn.error

  /** Search for PostgreSQL parameter.
   *
   * During authentication, the driver accumulates all the parameter values
   * returned by the server.  This routine allows you to search for a parameter.
   * Note that you can get at the raw [StringMap] from [conn.params].
   *
   * @param conn The connection object.
   * @param name The name of the parameter.
   * @returns An optional string value for the parameter.
   */
  param(conn:Postgres.connection, name:string) : option(string) =
    StringMap.get(name, conn.params)

  /** Return the stored [processid] and [secret_key] values.
   *
   * During authentication the driver stores the identifiers for the connection to
   * be used in cancellation requests.  This returns those values but they are
   * only useful for these cancellation requests.
   *
   * @param conn The connection object.
   * @returns An optional object with the key data.
   */
  keydata(conn:Postgres.connection) : option({processid:int; secret_key:int}) =
    match conn.conn.auth with
    | {some=auth} ->
      if auth.authenticated && auth.i1 != -1 && auth.i2 != -1
      then {some={processid=auth.i1; secret_key=auth.i2}}
      else {none}
    | {none} -> {none}

  /** Return last status value.
   *
   * At the end of a command cycle the server returns a [ReadyForQuery] message
   * which contains a status value (I=idle, T=in transaction, E=in failed transaction).
   * This function returns the last received status value but note that it may not be
   * present during a sequence of extended commands.
   *
   * @param conn The connection object.
   * @returns An optional status character.
   */
  status(conn:Postgres.connection) : option(string) =
    if conn.status == "" then {none} else {some=conn.status}

  /** Set the protocol major version number.
   *
   * This is used in startup messages and should reflect the version of the protocol implemented by the driver.
   * Should probably never be necessary.
   *
   * @param conn The connection object.
   * @param major_version The major version number (default is currently 3).
   * @returns An updated connection object.
   */
  set_major_version(conn:Postgres.connection, major_version:int) : Postgres.connection = {conn with ~major_version}

  /**
   * Add a session initializer.
   */
  add_init_session(conn: Postgres.connection, init): Postgres.connection =
    {conn with init_session= (c -> conn.init_session(init(c)))}

  /** Install a handler for a given Postgres type id.
   *
   * The type_id is specific to a given PostgreSQL server so we attach the handler
   * to the connection.  See the PostgresTypes module for the use of handlers.
   * You can also install a handler for an ENUM type using the [create_enum] function.
   *
   * @param conn The connection object.
   * @param type_id The PostgreSQL type id number, can be read from the server.
   * @param name The type name.
   * @param handler A handler function, should return an option of an opa value corresponding to the type.
   * @returns An updated connection with the handler installed.
   */
  install_handler(conn:Postgres.connection, type_id:Postgres.type_id, name:string, handler:Postgres.handler('a))
                 : Postgres.connection =
    nty = PostgresTypes.name_type(@typeval('a))
    {conn with
       handlers=IntMap.add(type_id,(name,nty,@unsafe_cast(handler)),conn.handlers)
       backhandlers=StringMap.add("{nty}",type_id,conn.backhandlers)
    }

  /** Set the protocol minor version number.
   *
   * @param conn The connection object.
   * @param minor_version The minor version number (default is currently 0).
   * @returns An updated connection object.
   */
  set_minor_version(conn:Postgres.connection, minor_version:int) : Postgres.connection = {conn with ~minor_version}

  @private ignore_listener(_, _, _) = void

  @private again(conn:Postgres.connection, result:Postgres.listener_arg, acc, f) =
    loop(conn, f(conn, result, acc), f)

  @private final(conn:Postgres.connection, result:Postgres.listener_arg, acc, f) =
    (conn, f(conn, result, acc))

  @private error(conn:Postgres.connection, failure:Postgres.failure, acc, f) =
    (conn, f(conn, {final={failure=(conn, failure)}}, acc))

  /* Implementation note, the PostgreSQL docs recomment using a single input
   * point for all incoming messages from PostgreSQL.  This is how we implement
   * this driver.  Only the authentication, query, sync and flush commands call this routine.
   */
  @private loop(conn:Postgres.connection, acc:'a, f) : (Postgres.connection, 'a) =
    get_result(conn,status) : Postgres.listener_arg =
      conn = {conn with ~status}
      {final=
        match conn.error with
        | {some=failure} -> {failure=(conn,failure)}
        | {none} -> {success=conn}}
    match Pg.reply({success=conn.conn}) with
    | {success=(c,{Authentication={Ok}})} ->
      loop({conn with conn=c}, acc, f)
    | {success=(c,{Authentication={CleartextPassword}})} ->
       match (Pg.password({success=c},c.conf.password)) with
       | {success=c} -> loop({conn with conn=c}, acc, f)
       | ~{failure} -> loop({conn with error={some={api_failure=failure}}}, acc, f)
       end
    | {success=(c,{Authentication={MD5Password=salt}})} ->
       inner = Crypto.Hash.md5(c.conf.password^c.conf.user)
       outer = Crypto.Hash.md5(inner^(%%bslBinary.to_encoding%%(salt,"binary")))
       md5password = "md5"^outer
       match (Pg.password({success=c},md5password)) with
       | {success=c} -> loop({conn with conn=c}, acc, f)
       | ~{failure} -> loop({conn with error={some={api_failure=failure}}}, acc, f)
       end
    | {success=(c,{ParameterStatus=(n,v)})} ->
      loop({conn with conn=c; params=StringMap.add(n,v,conn.params)}, acc, f)
    | {success=(c,{BackendKeyData=(processid,secret_key)})} ->
      c = {c with auth={some={authenticated=true; i1=processid; i2=secret_key}}}
      loop({conn with conn=c}, acc, f)
    | {success=(c,{~CommandComplete})} ->
      loop({conn with conn=c; completed=[CommandComplete|conn.completed]}, acc, f)
    | {success=(c,{EmptyQueryResponse})} ->
      loop({conn with conn=c; empty=true}, acc, f)
    | {success=(c,{~ParameterDescription})} ->
      loop({conn with conn=c; paramdescs=ParameterDescription}, acc, f)
    | {success=(c,{NoData})} ->
      loop({conn with conn=c; paramdescs=[]}, acc, f)
    | {success=(c,{ParseComplete})} ->
      loop({conn with conn=c}, acc, f)
    | {success=(c,{BindComplete})} ->
      loop({conn with conn=c}, acc, f)
    | {success=(c,{CloseComplete})} ->
      loop({conn with conn=c}, acc, f)

    | {success=(c,{~RowDescription})} ->
      rowdescs = List.map(to_rowdesc,RowDescription)
      again({conn with conn=c; ~rowdescs},{~rowdescs}, acc, f)
    | {success=(c,{~DataRow})} ->
      again({conn with conn=c; rows=conn.rows+1},~{DataRow}, acc, f)
    | {success=(c,{~NoticeResponse})} ->
      again({conn with conn=c},~{NoticeResponse}, acc, f)
    | {success=(c,{~ErrorResponse})} ->
      again({conn with conn=c; error={some={postgres={error=ErrorResponse}}}}, ~{ErrorResponse}, acc, f)
    | {success=(c,{PortalSuspended})} ->
      conn = {conn with conn=c}
      final(conn, get_result({conn with suspended=true},""), acc, f)
    | {success=(c,{ReadyForQuery=status})} ->
      conn = {conn with conn=c};
      final(conn, get_result(conn, status), acc, f)

    | {success=(c,reply)} ->
      error({conn with conn=c}, {bad_reply=reply}, acc, f)
    | ~{failure} ->
      error(conn, {api_failure=failure}, acc, f)
    end

  @private init_conn(conn:Postgres.connection, query) : Postgres.connection =
    // We now verify that the connection has been authenticated upon each command.
    conn = authenticate(conn)
    if Option.is_none(conn.error)
    then {conn with error=none; empty=false; suspended=false; completed=[]; rows=0; rowdescs=[]; paramdescs=[]; ~query}
    else conn

  /* Failed attempt to get SSL connection.  We do everything the docs say,
   * we send the SSLRequest message, we get back "S" and then we call
   * tls.connect with the old socket value.  But it just hangs... (EINPROGRESS).
   *
   * This function is a preamble function which SocketPool inserts between
   * an open insecure socket and a secure reconnect with the SSL options.
   */
  @private request_ssl(conn:Socket.t) : SocketPool.result =
    do jlog("request_ssl")
    timeout = 60*60*1000
    match Socket.binary_write_with_err_cont(conn.conn, timeout, Pg.packed_SSLRequest) with
    | {success=cnt} ->
      if cnt == Binary.length(Pg.packed_SSLRequest)
      then
        do jlog("sent ssl request")
        match Socket.read_fixed(conn.conn, timeout, 1, conn.mbox) with
        | {success=mbox} ->
          match Mailbox.sub(mbox, 1) with
          | {success=(mbox,binary)} ->
             if Binary.length(binary) == 1
             then
               match Binary.get_string(binary,0,1) with
               | "S" -> do jlog("SSL accepted") {success={conn with ~mbox}}
               | "N" -> do jlog("SSL rejected") {failure="request_ssl: Server does not accept SSL connections"}
               | code -> {failure="request_ssl: Unknown code, expected 'S' or 'N', got '{code}'"}
               end
             else
               {failure="request_ssl: Wrong length, expected 1 byte got {Binary.length(binary)}"}
          | {~failure} -> {~failure}
          end
        | {~failure} -> {~failure}
        end
      else {failure="request_ssl: Socket write failure (didn't send whole data)"}
    | ~{failure} -> ~{failure}
    end

  is_authenticated(conn:Postgres.connection) : bool =
    match conn.conn.auth with
    | {some={authenticated={true}; i1=processid; i2=secret_key}} -> processid != -1 && secret_key != -1
    | _ -> false

  /** Authenticate with the PostgreSQL server.
   *
   * This function sends a [StartupMessage] message which includes the user and database names.
   * The server then responds with an authentication request (currently only MD5 password and
   * clear-text passwords are supported) which the driver responds to.
   * The driver then reads back a large number of reply messages including the server parameters
   * and the connection id ([processid] and [secret_key]).
   *
   * @param conn The connection object.
   * @param listener A Postgres listener callback.
   * @returns An updated connection with connection data installed.
   */
  authenticate(conn:Postgres.connection) : Postgres.connection =
    // We have to ensure that the connection is pre-allocated here
    // since Pg.start might be given a socket which is already authenticated.
    match Pg.Conn.allocate(conn.conn) with
    | {success=c} ->
      conn = {conn with conn=c}
      if is_authenticated(conn)
      then conn
      else
        conn = {conn with error=none; empty=false; suspended=false; completed=[]; rows=0; rowdescs=[]; paramdescs=[];
                          query="authentication"}
        version = Bitwise.lsl(Bitwise.land(conn.major_version,0xffff),16) + Bitwise.land(conn.minor_version,0xffff)
        match Pg.start({success=conn.conn}, (version, [("user",conn.conn.conf.user),("database",conn.dbase)])) with
        | {success=c} ->
          c = loop({conn with conn=c}, void, ignore_listener).f1
          c.init_session(c: Postgres.connection)
        | ~{failure} -> error(conn,{api_failure=failure}, void, ignore_listener).f1
        end
     | ~{failure} -> error(conn,{api_failure=failure}, void, ignore_listener).f1
     end

  /** Issue simple query command and read back responses.

   * The simple query protocol is a simple command to which the server will
   * reply with the results of the query.  It is similar to doing
   * [Parse]/[Bind]/[Describe]/[Execute]/[Sync]. On each returned row data the
   * [folder] function will be called, likewise for errors and notices.  Note that this
   * routine also returns an updated connection object upon failure since the
   * effects of previously successful messages received from the server may be
   * retained.

   * @param conn The connection object.
   * @param init The initial value.
   * @param query The query string (can contain multiple queries).
   * @param folder A function that called on each result.
   * @return The updated connection and the result of successive calls to the
   * [folder] function.
   */
  query(conn:Postgres.connection, init, query, folder) =
    conn = init_conn(conn, query)
    if Option.is_none(conn.error)
    then
      match Pg.query({success=conn.conn}, query) with
      | {success=c} -> loop({conn with conn=c}, init, folder)
      | ~{failure} -> error(conn, {api_failure=failure}, init, folder)
      end
    else (conn,init)


  /** Send a parse query message.
   *
   * This routine causes a prepared statement to be placed in the server.
   * This routine only sends the message, if you want to see the result
   * immediately, you have to then send a flush message to force an early reply.
   *
   * @param conn The connection object.
   * @param name The name of the prepared statement (empty means the unnamed prepared statement).
   * @param query The query string (may contain placeholders for later data, eg. "$1" etc.).
   * @param oids The object ids for the types of the parameters (may be zero to keep the type unspecified).
   * @param listener A Postgres listener callback.
   * @return An updated connection object or failure.
   */
  parse(conn:Postgres.connection, name, query, oids) : Postgres.connection =
    conn = init_conn(conn, "Parse({query},{name})")
    if Option.is_none(conn.error)
    then
      match Pg.parse({success=conn.conn}, (name,query,oids)) with
      | {success=c} ->
        conn = {conn with conn=c}
        final(conn, {final={success=conn}}, void, ignore_listener).f1
      | ~{failure} ->
        error(conn, {api_failure=failure}, void, ignore_listener).f1
      end
    else conn

  /** Bind parameters to a prepared statement and a portal.
   *
   * @param conn The connection object.
   * @param portal The name of the destination portal (empty means the unnamed portal).
   * @param name The name of the source prepared statement.
   * @param params The list of parameters.
   * @param result_codes A list of the result column return codes (0=text, 1=binary).
   * @param listener A Postgres listener callback.
   * @returns The original connection object or failure.
   */
  bind(conn:Postgres.connection, portal, name, params:list(Postgres.data)) : Postgres.connection =
    params = List.map(serialize, params)
    (codes, params) = List.unzip(params)
    conn = init_conn(conn, "Bind({name},{portal})")
    if Option.is_none(conn.error)
    then
      match Pg.bind({success=conn.conn}, (portal, name, codes, params, [0])) with
      | {success=c} ->
        conn = {conn with conn=c}
        final(conn,{final={success=conn}}, void, ignore_listener).f1
      | ~{failure} ->
        error(conn, {api_failure=failure}, void, ignore_listener).f1
      end
    else conn

  /** Execute named portal.
   *
   * @param conn The connection object.
   * @param init The initial value.
   * @param portal The name of the portal to execute (empty means the unnamed portal).
   * @param rows_to_return The number of rows to return (zero means unlimited).
   * @param folder A function that called on each result.
   * @return The updated connection and the result of successive calls to the
   * [folder] function.
   */
  execute(conn:Postgres.connection, init, portal, rows_to_return, folder) =
    // should we fold on sync instead of execute ?
    conn = init_conn(conn, "Execute({portal})")
    if Option.is_none(conn.error)
    then
      match Pg.execute({success=conn.conn},(portal,rows_to_return)) with
      | {success=c} ->
        conn = {conn with conn=c}
        loop(sync(conn), init, folder)
      | ~{failure} ->
        error(conn, {api_failure=failure}, init, folder)
      end
    else (conn, init)

  /** Describe portal or statement.
   *
   * This triggers the return of row description data, it can be used to type the
   * values passed to or returned from prepared statements or portals.
   *
   * @param conn The connection object.
   * @param sp Statement or portal flag
   * @param name The name of the prepared statement or portal.
   * @param listener A Postgres listener callback.
   * @returns The original connection object or failure.
   */
  describe(conn:Postgres.connection, sp:Postgres.sp, name) : Postgres.connection =
    conn = init_conn(conn, "Describe({string_of_sp(sp)},{name})")
    if Option.is_none(conn.error)
    then
      match Pg.describe({success=conn.conn},(string_of_sp(sp),name)) with
      | {success=c} ->
        conn = {conn with conn=c}
        final(conn,{final={success=conn}}, void, ignore_listener).f1
      | ~{failure} ->
        error(conn,{api_failure=failure}, void, ignore_listener).f1
      end
    else conn

  /** Close a prepared statement or portal.
   *
   * Note that this does not close the connection, it is used to release resources
   * associated with prepared statements and portals on the server, otherwise they
   * persist (apart from the unnamed statement/portal which can be overwritten and in fact
   * are destroyed by simple query commands).
   *
   * @param conn The connection object.
   * @param sp Statement or portal flag
   * @param name The name of the prepared statement or portal.
   * @param listener A Postgres listener callback.
   * @returns The original connection object or failure.
   */
  closePS(conn:Postgres.connection, sp:Postgres.sp, name) : Postgres.connection =
    conn = init_conn(conn, "Close({string_of_sp(sp)},{name})")
    if Option.is_none(conn.error)
    then
      match Pg.closePS({success=conn.conn},(string_of_sp(sp),name)) with
      | {success=c} ->
            conn = {conn with conn=c}
        final(conn, {final={success=conn}}, void, ignore_listener).f1
      | ~{failure} ->
        error(conn, {api_failure=failure}, void, ignore_listener).f1
      end
    else conn

  /** Send [Sync] command and read back response data.
   *
   * This command is the normal way to terminate an extended query.
   * Upon receiving this command the server will flush out any pending messages
   * and end with a [ReadyForQuery] message.
   *
   * @param conn The connection object.
   * @param listener A Postgres listener callback.
   * @returns An updated connection object or failure.
   */
  sync(conn:Postgres.connection) : Postgres.connection =
    conn = init_conn(conn, "Sync")
    if Option.is_none(conn.error)
    then
      match Pg.sync({success=conn.conn}) with
      | {success=c} ->
        conn = {conn with conn=c}
        final(conn, {final={success=conn}}, void, ignore_listener).f1
      | ~{failure} ->
        error(conn,{api_failure=failure}, void, ignore_listener).f1
      end
    else conn

  /** Send a [Flush] command and read back response data.
   *
   * This requests the server to flush any pending messages.
   *
   * @param conn The connection object.
   * @param listener A Postgres listener callback.
   * @returns An updated connection object or failure.
   */
  flush(conn:Postgres.connection) : Postgres.connection =
    conn = init_conn(conn, "Flush")
    if Option.is_none(conn.error)
    then
      match Pg.flush({success=conn.conn}) with
      | {success=c} ->
        conn = {conn with conn=c}
        loop(conn, void, ignore_listener).f1
      | ~{failure} ->
        error(conn,{api_failure=failure}, void, ignore_listener).f1
      end
    else conn

  /** Send cancel request message on secondary channel.
   *
   * This operates differently from the other commands.
   * A second connection to the server is opened but instead of
   * performing authentication an immediate [CancelRequest] message
   * is sent which contains the connection id received during the authentication
   * of the connection passed in here.  The original connection is
   * untouched by this operation but we return it for consistency with
   * the structure of the other functions in this API.  Note that the only
   * way of knowing if the cancel succeeded is to monitor the original connection.
   *
   * @param conn The connection object.
   * @returns An outcome of a void or an [Apigen.failure] object.
   */
  cancel(conn:Postgres.connection) : Postgres.result =
    (processid, secret_key) =
      match conn.conn.auth with
      | {some={authenticated={true}; i1=processid; i2=secret_key}} -> (processid,secret_key)
      | _ -> (-1,-1)
    if processid == -1 || secret_key == -1
    then {failure=(conn,{no_key})}
    else
      match connect(conn.name, conn.secure, conn.dbase) with
      | {success=conn} ->
         match Pg.cancel({success=conn.conn},(processid,secret_key)) with
         | {success=c} ->
            _ = close(conn, false)
            {success={conn with conn=c}}
         | ~{failure} -> {failure=(conn,{api_failure=failure})}
         end
      | ~{failure} -> {failure=(conn,{api_failure=failure})}

  // Some support code

  /* Turn a Postgres message into a string */
  string_of_msg(msg:Postgres.msg) : string = String.concat("\n  ",List.map(((c, m) -> "{c}: {m}"),msg))

  /**
   * A simple listener, does nothing except count rows and print out
   * error and notice messages.
   */
  default_listener_def : Postgres.listener_def =
    { on_success=none; on_failure=none; on_rowdescs=none; on_row=none; on_error=none; on_notice=none }

  /**
   * Make a listener from a listener definition.
   * @param def A [Postgres.listener_def] value with handler functions for specific actions.
   * @returns A valid listener function.
   */
  make_listener(def:Postgres.listener_def) : Postgres.listener =
    (conn:Postgres.connection, arg:Postgres.listener_arg ->
      match arg with
      | {~final} ->
        match final with
        | {success=conn} ->
          match def.on_success with
          | {some=on_success} -> on_success(conn)
          | {none} -> void
          end
        | {failure=(conn,failure)} ->
          match def.on_failure with
          | {some=on_failure} -> on_failure(conn,failure)
          | {none} -> Log.error("Postgres.listener({conn.query})","{failure}")
          end
        end
      | {~rowdescs} ->
        match def.on_rowdescs with
        | {some=on_rowdescs} -> on_rowdescs(conn,rowdescs)
        | {none} -> void
        end
      | {~DataRow} ->
        match def.on_row with
        | {some=on_row} -> on_row(conn,DataRow)
        | {none} -> void
        end
      | {~ErrorResponse} ->
          match def.on_error with
          | {some=on_error} -> on_error(conn,ErrorResponse)
          | {none} -> Log.error("Postgres.listener({conn.query})","\n  {string_of_msg(ErrorResponse)}")
          end
      | {~NoticeResponse} ->
          match def.on_notice with
          | {some=on_notice} -> on_notice(conn,NoticeResponse)
          | {none} -> Log.notice("Postgres.listener({conn.query})","\n  {string_of_msg(NoticeResponse)}")
          end
      end)

  /** A default listener built from [default_listener_def]. */
  default_listener : Postgres.listener = make_listener(default_listener_def)

  /** Get the [type_id] value from the server for the named type.
   *
   * Performs a "SELECT oid from pg_type WHERE typname='name'" query on the
   * server and returns the [oid] value returned.
   *
   * @param conn The connection object.
   * @param name The name of the type.
   * @returns A tuple of the updated connection (maybe with an [error] value) and the type_id ([-1] means "not found").
   */
  get_type_id(conn:Postgres.connection, name:string) : (Postgres.connection,int) =
    query(conn, -1, "SELECT oid from pg_type WHERE typname='{name}'",
          (conn, msg, tid ->
            match msg with
            | {DataRow = row} ->
              match StringMap.get("oid",PostgresTypes.getRow(conn.rowdescs,row)) with
              | {some={Int=tid}} -> tid
              | _ -> tid
              end
            | _ -> tid)
         )



  /** Fold a function over a list, with connection.
   *
   * Fold a function f(conn, element) for each element in a list.
   *
   * @param f The function to fold.
   * @param conn The connection object.
   * @param l The list of elements.
   * @returns The final result or the first error.
   */
  @private
  fold(f:Postgres.connection, 'a -> Postgres.result, conn:Postgres.connection, l:list('a)) : Postgres.result =
    rec aux(conn, l) =
      match l with
      | [v|l] ->
         match f(conn, v) with
         | {success=conn} -> aux(conn, l)
         | {~failure} -> {~failure}
         end
      | [] -> {success=conn}
      end
    aux(conn, l)

  /** Insert a row into a database.
   *
   * @param conn The connection object.
   * @param dbase The name of the database.
   * @param value The value to be inserted.
   * @param k The listener.
   * @returns An updated connection object.
   */
  insert(conn:Postgres.connection, dbase:string, value:'a) =
    query(conn, void, PostgresTypes.insert(conn, dbase, value), ignore_listener).f1

  /** Update rows in a database. Sets individual fields only.
   *
   * @param conn The connection object.
   * @param dbase The name of the database.
   * @param value A value representing the fields to be updated.
   * @param select A value representing which fields select the data to be updated.
   * @param k The listener.
   * @returns An updated connection object.
   */
  update(conn:Postgres.connection, dbase:string, value:'a, select:'b) =
    query(conn, void, PostgresTypes.update(conn, dbase, value, select), ignore_listener).f1

  /** Delete a value from a database.
   *
   * @param conn The connection object.
   * @param dbase The name of the database.
   * @param select A value representing which fields select the rows to be deleted.
   * @param k The listener.
   * @returns An updated connection object.
   */
  delete(conn:Postgres.connection, dbase:string, select:'b) : Postgres.connection =
    query(conn, void, PostgresTypes.delete(conn, dbase, select), ignore_listener).f1

  /** Open a transaction block.
   *
   * @param conn The connection object.
   * @param k The listener.
   * @returns An updated connection object.
   */
  begin(conn:Postgres.connection) : Postgres.connection =
    {query(conn, void, "BEGIN", ignore_listener).f1 with in_transaction=true}

  /** Close a transaction block.
   *
   * @param conn The connection object.
   * @param k The listener.
   * @returns An updated connection object.
   */
  commit(conn:Postgres.connection) : Postgres.connection =
    {query(conn, void, "COMMIT", ignore_listener).f1 with in_transaction=false}

  /** Roll back a transaction.
   *
   * @param conn The connection object.
   * @param k The listener.
   * @returns An updated connection object.
   */
  rollback(conn:Postgres.connection) : Postgres.connection =
    {query(conn, void, "ROLLBACK", ignore_listener).f1 with in_transaction=false}

  /** Declare a cursor.
   *
   * @param conn The connection object.
   * @param binary Whether the data should be binary or not.
   * @param name A name for the cursor.
   * @param query The query string for the cursor.
   * @param k The listener.
   * @returns An updated connection object.
   */
  declare_cursor(conn:Postgres.connection, binary:bool, name:string, query:string) : Postgres.connection =
    if conn.in_transaction
    then Postgres.query(conn, void, "DECLARE {name} {if binary then "BINARY " else ""}CURSOR FOR {query}", ignore_listener).f1
    else error(conn, {sql="Cannot declare cursor outside of transaction"}, void, ignore_listener).f1

  @private string_of_cursor_direction(cd:option(Postgres.cursor_direction)) : string =
    match cd with
    | {some={forward}} -> "FORWARD "
    | {some={backward}} -> "BACKWARD "
    | {none} -> ""

  @private string_of_cursor_amount(ca:option(Postgres.cursor_amount)) : string =
    match ca with
    | {some={~num}} -> Int.to_string(num)^" "
    | {some={all}} -> "ALL "
    | {some={next}} -> "NEXT "
    | {some={prior}} -> "PRIOR "
    | {none} -> ""

  /** Fetch rows from a cursor.
   *
   * @param conn The connection object.
   * @param name A name for the cursor.
   * @param direction Optional direction flag (default: forward).
   * @param amount Optional number of rows to return (default: all).
   * @param k The listener.
   * @returns An updated connection object.
   */
  fetch(conn:Postgres.connection,
        init,
        name:string,
        direction:option(Postgres.cursor_direction),
        amount:option(Postgres.cursor_amount),
        f) : Postgres.connection =
    query(conn, init,
          "FETCH {string_of_cursor_direction(direction)}{string_of_cursor_amount(amount)}FROM {name}", f).f1

  /** Move a cursor pointer.
   *
   * @param conn The connection object.
   * @param name A name for the cursor.
   * @param direction Optional direction flag (default: forward).
   * @param amount Optional number of rows to move (default: all).
   * @param k The listener.
   * @returns An updated connection object.
   */
  move(conn:Postgres.connection,
       name:string,
       direction:option(Postgres.cursor_direction),
       amount:option(Postgres.cursor_amount)) : Postgres.connection =
    query(conn, void, "MOVE {string_of_cursor_direction(direction)}{string_of_cursor_amount(amount)}IN {name}", ignore_listener).f1

  /** Close and destroy a cursor.
   *
   * @param conn The connection object.
   * @param name A name for the cursor.
   * @param k The listener.
   * @returns An updated connection object.
   */
  close_cursor(conn:Postgres.connection, name:string) : Postgres.connection =
    query(conn, void, "CLOSE {name}", ignore_listener).f1

  release(conn:Postgres.connection) : void =
    ignore(Pg.Conn.release(conn.conn))

}}

// End of file postgres.opa
