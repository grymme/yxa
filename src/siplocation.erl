%%       ___How REGISTER requests are processed___
%% - - - - - - - - - - - - - - - - - -
%%
%%    UAC     UAC     UAC    ....     (e.g. IP-phones)
%%      \      |      /
%%       \    _|_____/_
%%        \__/         \__
%%        /               \
%%       |    Internet     |
%%        \__           __/
%%           \_________/
%%                |
%% - - - - - - - -|- - - - - - - - - - YXA
%%           \    |    /
%%            \   |   /
%%         -----------------
%%        | Transport layer |    requests are received from the
%%         -----------------     network
%%                |
%%        -------------------
%%       | Transaction layer |   sipserver is used to spawn one
%%        -------------------    process per sip request and process
%%          /       |       \    them asynchronously
%%         /        |        \
%%    sipserver   sipserver   sipserver ...
%%        |
%% - - - -|- - - - - - - - - - - - - - PROCESS PROCESSING REQUEST
%%        |
%%    incomingproxy.erl          entry point in processing REGISTER
%%        |                      request
%%        |
%%    siplocation.erl            the database update calls are done
%%        |                      in this module
%%        |
%% - - - -|- - - - - - - - - - - - - - DATABASE UPDATES
%%   \    |    /
%%    \   |   /
%%     mnesia                    mnesia supplies transaction support,
%%                               so that requests can be processed
%%                               atomically and can also
%%                               (transparently) be distributed on
%%                               several erlang nodes
%%
%%       ___Notes on the current RFC compliance___
%%
%% RFC 3261 chapter 10.3 p62 - "REGISTER requests MUST be processed
%% by a registrar in the order that they are received."
%% RFC 3261 chapter 10.3 p64 - "... , it MUST remove the binding only
%% if the CSeq in the request is higher than the value stored for
%% that binding.  Otherwise, the update MUST be aborted and the
%% request fails." - in regards to request that arrive out of order
%%
%% The first quote is can be interpreted in a number of ways which
%% contradict the actions taken in the second quote:
%%
%% * the "simple way" - process REGISTERs in order
%% - this is hard because the transport layer receives messages from
%%   various sources on different physical connections. It also limits
%%   scalability (parallelism) in the system.
%%
%% * would it be enough to process REGISTERs for the same UAC
%%   (Call-ID) in order ?
%% - this would be doable but would require solutions like delaying
%%   REGISTERs[1] which have CSeq number which are to high
%%   (NewCSeq - OldCSeq >= 2) compared to the last entry in the DB.
%% - looking at quote no.2 we can conclude that we don't need to
%%   reorder requests that were received out of order, when they come
%%   from the network.
%% - If REGISTERs are sent very quickly in succession - something that
%%   is unlikely to occur in practice, the asynchronous nature of
%%   YXAs request processing may indeed result in out of order
%%   processing, but it would be much rarer than out of order
%%   request received from the network - which don't need to be
%%   reordered. The two REGISTERs could of course be received from a
%%   single client pipelined using TCP, but see the conclusions below.
%%
%%  [1]: spawning a "wait & retry" process or resending request
%%       to the process mailbox
%%
%%  Conclusion:
%%  * Quote no.1 appears incorrect in requiring all REGISTERs to be
%%    processed "in order". The requirement appears to be a
%%    "best effort" attempt at processing requests in order.
%%  * Full compliance to quote no. 1 appears both unnecessary,
%%    tedious to implement and to make the system less scalable - so
%%    the current implementation will be retained.
%%
%%--------------------------------------------------------------------

-module(siplocation).
%%-compile(export_all).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	 process_register_request/5,
	 prioritize_locations/1,
	 get_locations_for_users/1,
	 get_user_with_contact/1,
	 to_url/1,

	 test/0
	]).

%%--------------------------------------------------------------------
%% Internal exports
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("siprecords.hrl").
-include("phone.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------

%%====================================================================
%% External functions
%%====================================================================


%%--------------------------------------------------------------------
%% Function: process_register_request(Request, THandler, LogTag,
%%                                    LogStr, AppName)
%%           Request  = response record()
%%           THandler = term(), server transaction handler
%%           LogTag   = string(), tag for log messages
%%           LogStr   = string(), description of request
%%           AppName  = atom(), application name
%% Descrip.: Process a received REGISTER. First check if it is for
%%           one of our domains (homedomain), then check that it
%%           contains proper authentication and that the authenticated
%%           user is allowed to register using this address-of-record.
%%           Finally, let process_updates() process all the
%%           Contact headers and update the location database.
%% Returns : not_homedomain | void()
%%--------------------------------------------------------------------
process_register_request(Request, THandler, LogTag, LogStr, AppName) when is_record(Request, request),
									  is_list(LogStr), is_list(LogTag),
									  is_atom(AppName) ->
    URL = Request#request.uri,
    logger:log(debug, "~p: REGISTER ~p", [AppName, sipurl:print(URL)]),
    %% RFC 3261 chapter 10.3 - Processing REGISTER Request - step 1
    %% check if this registrar handles the domain the request wants to register for
    case local:homedomain(URL#sipurl.host) of
	true ->
	    register_require_supported(Request, LogStr, THandler, LogTag, AppName);
	false ->
	    %% act as proxy and forward message to other domain
	    logger:log(debug, "~p: REGISTER for non-homedomain ~p", [AppName, URL#sipurl.host]),
	    not_homedomain
    end.

%%--------------------------------------------------------------------
%% Function: register_require_supported(Request, LogStr, THandler,
%%                                      LogTag, AppName)
%%           Request  = request record()
%%           LogStr   = string(), describes REGISTER request
%%           THandler = thandler record(), server transaction handler
%%           LogTag   = string(), prefix for logging
%%           AppName  = atom(), incomingproxy | outgoingproxy
%% Descrip.: After we have checked that the REGISTER request is for
%%           one of our homedomains, we start checking the validity of
%%           the request. First, we do some checks in this function
%%           before going on to making sure the request is
%%           authenticated in register_authenticate(...).
%% Returns :
%%--------------------------------------------------------------------
register_require_supported(Request, LogStr, THandler, LogTag, AppName) ->
    Header = Request#request.header,
    %% RFC 3261 chapter 10.3 - Processing REGISTER Request - step 2
    case is_valid_register_request(Header) of
	true ->
	    register_authenticate(Request, LogStr, THandler, LogTag, AppName);
	{siperror, Status, Reason, ExtraHeaders} ->
	    transactionlayer:send_response_handler(THandler, Status, Reason, ExtraHeaders)
    end.

%% part of process_register/6
register_authenticate(Request, LogStr, THandler, LogTag, AppName) ->
    Header = Request#request.header,
    logger:log(debug, "~p: ~s -> processing", [AppName, LogStr]),
    %% delete any present Record-Route header (RFC3261, #10.3)
    NewHeader = keylist:delete("Record-Route", Header),
    {_, ToURL} = sipheader:to(Header),
    %% RFC 3261 chapter 10.3 - Processing REGISTER Request - step 3, step 4 and step 5
    %% authenticate UAC
    case local:can_register(NewHeader, ToURL) of
	{{true, _}, SIPuser} ->
	    Contacts = sipheader:contact(NewHeader),
	    logger:log(debug, "~s: user ~p, registering contact(s) : ~p",
		       [LogTag, SIPuser, sipheader:contact_print(Contacts)]),
	    %% RFC 3261 chapter 10.3 - Processing REGISTER Request - step 6, step 7 and step 8
	    NewRequest = Request#request{header = NewHeader},
	    LogPrefix = lists:concat([LogTag, ": ", AppName]),
	    %% Fetch configuration parameters here and pass as parameters, to make process_updates testable
	    {ok, DoGRUU} = yxa_config:get_env(experimental_gruu_enable),
	    {ok, PathParam} = yxa_config:get_env(allow_proxy_inserted_path),
	    case catch process_updates(LogPrefix, NewRequest, SIPuser, Contacts, AppName, DoGRUU, PathParam) of
		{ok, {Status, Reason, ExtraHeaders}} ->
		    transactionlayer:send_response_handler(THandler, Status, Reason, ExtraHeaders),
		    %% Make event about user sucessfully registered
		    L = [{register, ok}, {user, SIPuser},
			 {contacts, sipheader:contact_print(Contacts)}],
		    event_handler:generic_event(normal, location, LogTag, L),
		    ok;
		{siperror, Status, Reason} ->
		    transactionlayer:send_response_handler(THandler, Status, Reason);
		{siperror, Status, Reason, ExtraHeaders} ->
		    transactionlayer:send_response_handler(THandler, Status, Reason, ExtraHeaders);
		{'EXIT', Reason} ->
		    logger:log(error, "=ERROR REPORT==== siplocation:process_updates() failed :~n~p~n",
			       [Reason]),
		    transactionlayer:send_response_handler(THandler, 500, "Server Internal Error")
	    end;
	{stale, _} ->
	    logger:log(normal, "~s -> Authentication is STALE, sending new challenge", [LogStr]),
	    transactionlayer:send_challenge(THandler, www, true, none);
	{{false, eperm}, SipUser} when SipUser /= none ->
	    logger:log(normal, "~s: ~p: SipUser ~p NOT ALLOWED to REGISTER address ~s",
		       [LogTag, AppName, SipUser, sipurl:print(ToURL)]),
	    transactionlayer:send_response_handler(THandler, 403, "Forbidden"),
	    %% Make event about users failure to register
	    L = [{register, forbidden}, {user, SipUser}, {address, sipurl:print(ToURL)}],
	    event_handler:generic_event(normal, location, LogTag, L);
	{{false, nomatch}, SipUser} when SipUser /= none ->
	    logger:log(normal, "~s: ~p: SipUser ~p tried to REGISTER invalid address ~s",
		       [LogTag, AppName, SipUser, sipurl:print(ToURL)]),
	    transactionlayer:send_response_handler(THandler, 404, "Not Found"),
	    %% Make event about users failure to register
	    L = [{register, invalid_address}, {user, SipUser}, {address, sipurl:print(ToURL)}],
	    event_handler:generic_event(normal, location, LogTag, L);
	{false, none} ->
	    Prio = case keylist:fetch('authorization', Header) of
		       [] -> debug;
		       _ -> normal
		   end,
	    %% XXX send new challenge (current behavior) or send 403 Forbidden when authentication fails?
	    logger:log(Prio, "~s -> Authentication FAILED, sending challenge", [LogStr]),
	    transactionlayer:send_challenge(THandler, www, false, 3)
    end.

%%--------------------------------------------------------------------
%% Function: is_valid_register_request(Header)
%%           Header = keylist record()
%% Descrip.: looks for unsupported extensions.
%% Returns : true | SipError
%%--------------------------------------------------------------------
is_valid_register_request(Header) ->
    case keylist:fetch('require', Header) of
	[] ->
	    true;
	Require ->
	    case get_unsupported_extensions(Require) of
		[] ->
		    true;
		L ->
		    logger:log(normal, "Request check: The client requires unsupported extension(s) ~p", [Require]),
		    {siperror, 420, "Bad Extension", [{"Unsupported", L}]}
	    end
    end.

get_unsupported_extensions(In) ->
    {ok, DoGRUU} = yxa_config:get_env(experimental_gruu_enable),
    get_unsupported_extensions2(In, DoGRUU, []).

get_unsupported_extensions2(["gruu" | T], DoGRUU, Res) ->
    %% draft-ietf-sip-gruu-07
    case DoGRUU of
	true ->
	    get_unsupported_extensions2(T, DoGRUU, Res);
	false ->
	    logger:log(debug, "Request check: GRUU requested, but not enabled (experimental)"),
	    get_unsupported_extensions2(T, DoGRUU, ["gruu" | Res])
    end;
get_unsupported_extensions2(["path" | T], DoGRUU, Res) ->
    %% RFC3327
    get_unsupported_extensions2(T, DoGRUU, Res);
get_unsupported_extensions2([H | T], DoGRUU, Res) ->
    get_unsupported_extensions2(T, DoGRUU, [H | Res]);
get_unsupported_extensions2([], _DoGRUU, Res) ->
    lists:reverse(Res).


%%--------------------------------------------------------------------
%% Function: process_updates(LogTag, Request, SipUser, Contacts,
%%                           AppName, DoGRUU, PathParam)
%%           LogTag    = string(), logging prefix
%%           Request   = request record(), REGISTER request
%%           SipUser   = SIP authentication username (#phone.number
%%                       field entry, when using mnesia userdb)
%%           Contacts  = list() of contact record()
%%           AppName   = atom(), incomingproxy | outgoingproxy
%%           DoGRUU    = bool(), GRUU enabled in proxy config or not?
%%           PathParam = term(), Path configuration data
%% Descrip.: Update the location database, based on a REGISTER request
%%           we are processing. Either add or remove entrys.
%% Returns : {ok, {Status, Reason, ExtraHeaders}}
%%           {siperror, Status, Reason}
%%           {siperror, Status, Reason, ExtraHeaders}
%%           Status = integer(), SIP status code
%%           Reason = string(), SIP reason phrase
%%           ExtraHeaders = list() of {Key, NewValueList} see
%%           keylist:appendlist/2
%%--------------------------------------------------------------------
%% RFC 3261 chapter 10.3 - Processing REGISTER Request - step 6 and 7
%% remove, add or update contact info in location (phone) database

%% REGISTER request had no contact header
process_updates(_LogTag, Request, SipUser, [], _AppName, DoGRUU, _PathParam) ->
    %% RFC 3261 chapter 10.3 - Processing REGISTER Request - step 8
    {ok, create_process_updates_response(SipUser, Request#request.header, DoGRUU)};

process_updates(LogTag, Request, SipUser, Contacts, AppName, DoGRUU, PathParam) ->
    Header = Request#request.header,
    %% Processing REGISTER Request - step 6
    %% check for and process wildcard (request contact = *)
    case process_register_wildcard_isauth(LogTag, Header, SipUser, Contacts) of
	none ->
	    case process_updates_get_path_vector(Request, AppName, PathParam) of
		PathVector when is_list(PathVector) ->
		    %% Processing REGISTER Request - step 7
		    %% No wildcard found, register/update/remove entries in Contacts.
		    %% Process registration atomicly - change all or nothing in database.
		    F = fun() ->
				process_non_wildcard_contacts(LogTag, SipUser, Contacts, Header, PathVector)
			end,
		    case mnesia:transaction(F) of
			{aborted, Reason} ->
			    logger:log(error, "Location database: REGISTER request failed to add/update/remove one "
				       "or more contacts for user ~p, failed due to: ~n~p", [SipUser, Reason]),
			    %% Check if it was a siperror, otherwise return '500 Server Internal Error'
			    case Reason of
				{throw, {siperror, Status, Reason2}} ->
				    {siperror, Status, Reason2};
				_ ->
				    {siperror, 500, "Server Internal Error"}
			    end;
			{atomic, _ResultOfFun} ->
			    %% RFC 3261 chapter 10.3 - Processing REGISTER Request - step 8
			    {ok, create_process_updates_response(SipUser, Header, DoGRUU)}
		    end;
		Other ->
		    Other
	    end;
	ok ->
	    %% wildcard found and processed
	    %% RFC 3261 chapter 10.3 - Processing REGISTER Request - step 8
	    {ok, create_process_updates_response(SipUser, Header, DoGRUU)};
	SipError ->
	    SipError
    end.

%% Returns : PathVector = list() of string() |
%%           {siperror, Status, Reason, ExtraHeaders}
process_updates_get_path_vector(Request, AppName, IgnoreSupported)
  when is_record(Request, request), is_atom(AppName), is_boolean(IgnoreSupported) ->
    Proto = (Request#request.uri)#sipurl.proto,
    Header = Request#request.header,
    process_updates_get_path_vector2(Proto, Header, AppName, IgnoreSupported).

process_updates_get_path_vector2(Proto, Header, AppName, IgnoreSupported) ->
    case keylist:fetch('path', Header) of
	[] ->
	    process_updates_get_path_vector3(Proto, [], AppName);
	Path ->
	    %% Request has Path, check if UA says it supports Path. Reject with 420 Bad Extension
	    %% if Path is present but Supported: does not contain "path", unless configured not to
	    IsSupported = sipheader:is_supported("path", Header),
	    if
		IsSupported ->
		    process_updates_get_path_vector3(Proto, Path, AppName);
		IsSupported /= true, IgnoreSupported ->
		    logger:log(debug, "Location database: Notice: Storing path vector even though Supported: "
			       "does not contain \"path\""),
		    process_updates_get_path_vector3(Proto, Path, AppName);
		true ->
		    logger:log(debug, "Location database: Rejecting REGISTER request since it has Path: but "
			       "the originating UA hasn't indicated support for RFC3327"),
		    {siperror, 421, "Extension Required", [{"Require", ["path"]}]}
	    end
    end.

process_updates_get_path_vector3(Proto, Path, outgoingproxy) ->
    RouteStr = siprequest:construct_record_route(Proto),
    [RouteStr | Path];
process_updates_get_path_vector3(_Proto, Path, _AppName) ->
    Path.

%% part of process_updates/6. Returns {200, "OK", ExtraHeaders}
create_process_updates_response(SipUser, Header, GRUU_enabled) ->
    Do_GRUU = sipheader:is_supported("gruu", Header) andalso GRUU_enabled,
    Date = {"Date", [httpd_util:rfc1123_date()]},
    Path =
	case keylist:fetch('path', Header) of
	    [] ->
		[];
	    PathV ->
		%% "The registrar copies the Path header field values into a Path header
		%% field in the successful (200 Class) REGISTER response."
		%% RFC3327 #5.3 (Procedures at the Registrar)
		[{"Path", PathV}]
	end,
    case fetch_contacts(SipUser, Do_GRUU, keylist:fetch('to', Header)) of
	{ok, _AddRequireGRUU, []} ->
	    {200, "OK", [Date] ++ Path};
	{ok, AddRequireGRUU, NewContacts} when is_boolean(AddRequireGRUU), is_list(NewContacts) ->
	    H1 = [{"Contact", NewContacts}, Date] ++ Path,
	    ExtraHeaders =
		case AddRequireGRUU of
		    true ->
			%% "If the REGISTER response contains a gruu Contact header field
			%% parameter in any of the contacts, the REGISTER response MUST contain
			%% a Require header field with the value "gruu". " GRUU draft 06 #7.1.2.1
			%% (Processing a REGISTER Request)
			%% UPDATE: This is no longer required by the spec (removed in GRUU draft 07)
			%% so we can stop doing it when we anticipate that clients have been updated
			[{"Require", ["gruu"]} | H1];
		    false ->
			H1 
		end,
	    {200, "OK", ExtraHeaders}
    end.


%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Function: fetch_contacts(SipUser, Do_GRUU, To)
%%           SipUser = string(), SIP authentication user - key in
%%                     location database
%%           Do_GRUU = bool(), add gruu= parameters or not?
%%           To      = list() of string(), REGISTER request To header
%% Descrip.: find all the locations where a specific sipuser can be
%%           located (e.g. all the users phones)
%% Returns : {ok, GRUUs, Contacts}
%%           GRUUs    = bool(), true if one or more of the contacts
%%                      were equipped with 'gruu=' contact parameters
%%           Contacts = list() of string(), formated as a contact
%%                      field-value (see RFC 3261)
%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
fetch_contacts(SipUser, Do_GRUU, To) ->
    {ok, Locations} = phone:get_sipuser_locations(SipUser),
    {ContainsGRUUs, Contacts} = locations_to_contacts(Locations, SipUser, Do_GRUU, To),
    {ok, ContainsGRUUs, Contacts}.

%% return: list() of string() (contact:print/1 of contact record())
locations_to_contacts(Locations, SipUser, Do_GRUU, To) ->
    locations_to_contacts2(Locations, util:timestamp(), SipUser, Do_GRUU, To, false, []).

locations_to_contacts2([], _Now, _SipUser, _Do_GRUU, _To, GRUUs, Res) ->
    {GRUUs, Res};
locations_to_contacts2([#siplocationdb_e{expire = never} | T], Now, SipUser, Do_GRUU, To, GRUUs, Res) ->
    %% Don't include static contacts which never expire
    locations_to_contacts2(T, Now, SipUser, Do_GRUU, To, GRUUs, Res);
locations_to_contacts2([#siplocationdb_e{expire = Expire} = H | T], Now, SipUser, Do_GRUU, To, GRUUs, Res)
  when is_integer(Expire) ->
    Location = H#siplocationdb_e.address,

    %% Expires can't be less than 0 so make sure we don't end up with a negative Expires
    NewExpire = lists:max([0, Expire - Now]),

    {NewGRUUs, GRUUparams} = locations_to_contacts2_gruu(Do_GRUU, H, SipUser, To, GRUUs),
    Params = [{"expires", integer_to_list(NewExpire)} | GRUUparams],
    Contact = contact:new(Location, Params),
    locations_to_contacts2(T, Now, SipUser, Do_GRUU, To, NewGRUUs, [contact:print(Contact) | Res]).

locations_to_contacts2_gruu(_DoGRUU = false, _E, _SipUser, _To, GRUUs) ->
    {GRUUs, []};
locations_to_contacts2_gruu(_DoGRUU = true, H, SipUser, To, GRUUs) ->
    case lists:keysearch(instance_id, 1, H#siplocationdb_e.flags) of
	{value, {instance_id, InstanceId}} ->
	    case database_gruu:fetch_using_user_instance(SipUser, InstanceId) of
		{ok, [GRUUdbe]} ->
		    GRUU = gruu:extract(gruu, GRUUdbe),
		    GRUU_URL = gruu:make_url(SipUser, InstanceId, GRUU, To),
		    InstanceId = gruu:extract(instance_id, GRUUdbe),
		    %% GRUU draft 06 #7.1.2.1 (Processing a REGISTER Request)
		    %% ...
		    %% Furthermore, for each Contact header field value placed in the
		    %% response, if the registrar has stored an instance ID associated with
		    %% that contact, that instance ID is returned as a Contact header field
		    %% parameter.
		    %% ...
		    %% The value of the gruu parameter is a quoted string containing the URI
		    %% that is the GRUU for the associated instance ID/AOR pair.
		    GRUU_param = {"gruu", "\"" ++ sipurl:print(GRUU_URL) ++ "\""},
		    I_ID_param = {"+sip.instance", "\"" ++ InstanceId ++ "\""},
		    {true, [GRUU_param, I_ID_param]};
		nomatch ->
		    {GRUUs, []}
	    end;
	_ ->
	    {GRUUs, []}
    end.


%% return = ok       | wildcard processed
%%          none     | no wildcard found
%%          SipError   db error
%% RFC 3261 chapter 10.3 - Processing REGISTER Request - step 6
process_register_wildcard_isauth(LogTag, Header, SipUser, Contacts) ->
    case is_valid_wildcard_request(Header, Contacts) of
	true ->
	    logger:log(debug, "Location: Processing valid wildcard un-register"),
	    case phone:get_phone(SipUser) of
		{atomic, PhoneEntrys} ->
		    unregister(LogTag, Header, PhoneEntrys);
		E ->
		    logger:log(error, "Location: Failed fetching registered contacts for user ~p : ~p",
			       [SipUser, E]),
		    {siperror, 500, "Server Internal Error"}
	    end;
	false ->
	    none
    end.

%% return = ok       | wildcard processed
%%          SipError   db error
%% unregister all location entries for a sipuser
unregister(LogTag, Header, PhoneEntrys) ->
    %% unregister all Locations entries
    F = fun() ->
		unregister_contacts(LogTag, Header, PhoneEntrys)
	end,
    %% process unregistration atomically - change all or nothing in database
    case mnesia:transaction(F) of
	{aborted, Reason} ->
	    logger:log(error, "Database: unregister of registrations failed for one or more"
		       " contact entries, due to: ~p",
		       [Reason]),
	    case Reason of
		{throw, {siperror, Status, Reason2}} ->
		    {siperror, Status, Reason2};
		_ ->
		    {siperror, 500, "Server Internal Error"}
	    end;
	{atomic, _ResultOfFun} ->
	    ok
    end.

%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Function: is_valid_wildcard_request(Header, Contacts)
%%           Header      = keylist record(), the sip request headers
%%           Contacts    = list() of contact record()
%% Descrip.: determine if request is a properly formed wildcard
%%           request (see RFC 3261 Chapter 10 page 64 - step 6)
%% Returns : true     |
%%           false    |
%%           throw({siperror, ...})
%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% there is only one Contact and it's a wildcard
is_valid_wildcard_request(Header, [ #contact{urlstr = "*"} ]) ->
    case sipheader:expires(Header) of
	[Expire] ->
	    %% cast to integer so that "0", "00" ... and so on are all considered as 0
	    case catch list_to_integer(Expire) of
		0 ->
		    true;
		_ ->
		    {siperror, 400, "Wildcard with non-zero contact expires parameter"}
	    end;
	[] ->
	    {siperror, 400, "Wildcard without Expires header"};
	_ ->
	    {siperror, 400, "Wildcard with more than one expires parameter"}
    end;

%% There are 2+ elements in Contacts, make sure that none of them are wildcards
%% - there can only be one wildcard
is_valid_wildcard_request(_Header, Contacts) ->
    case wildcard_grep(Contacts) of
	true ->
	    {siperror, 400, "Wildcard present but not alone, invalid (RFC3261 10.3 #6)"};
	false ->
	    false
    end.

%% is there a wildcard in the contacts list ?
%% return = true | false
wildcard_grep([]) ->
    false;
wildcard_grep([ #contact{urlstr = "*"} | _Rest]) ->
    true;
wildcard_grep([_Foo | Rest]) ->
    wildcard_grep(Rest).


%%--------------------------------------------------------------------
%% Function: get_user_with_contact(URI)
%%           URI = sipurl record()
%% Descrip.: Checks if any of our users are registered at the
%%           location specified. Used to determine if we should
%%           proxy requests to a URI without authorization.
%% Returns : none | SIPuser
%%           SIPuser = #phone.number field value
%% NOTE    : If you want to know all the users (in case there is more
%%           than one), you have to call
%%           phone:get_sipusers_using_location/1 directly.
%%--------------------------------------------------------------------
get_user_with_contact(URI) when is_record(URI, sipurl) ->
    case phone:get_sipusers_using_location(URI) of
	{atomic, [SIPuser | _]} when is_list(SIPuser) ->
	    SIPuser;
	{atomic, []} ->
	    %% no one using URI found
	    none
    end.

%%--------------------------------------------------------------------
%% Function: get_locations_for_users(SipUserList)
%%           SipUserList = list() of string(), usernames
%% Descrip.: Looks up all locations for a list of users. Used
%%           to find out where a set of users are to see where
%%           we should route a request.
%% Returns : list() of siplocationdb_e record()
%%--------------------------------------------------------------------
get_locations_for_users(In) when is_list(In) ->
    get_locations_for_users2(In, []).

get_locations_for_users2([], Res) ->
    Res;
get_locations_for_users2([H | T], Res) when is_list(H) ->
    {ok, Locations} = phone:get_sipuser_locations(H),
    get_locations_for_users2(T, Res ++ Locations).

%%--------------------------------------------------------------------
%% Function: prioritize_locations(Locations)
%%           Locations = list of siplocationdb_e record()
%% Descrip.: Look through a list of siplocation DB entrys, figure out
%%           what the lowest priority amongst them are and then
%%           return all records which has that priority.
%% Returns : list of siplocationdb_e record()
%%--------------------------------------------------------------------
prioritize_locations(Locations) when is_list(Locations) ->
    case get_priorities(Locations) of
	[BestPrio | _] ->
	    get_locations_with_prio(BestPrio, Locations);
	_ ->
	    %% No locations or no locations with priority - return input list
	    Locations
    end.

%% Descrip. = examine all Flags entries in Locations and return all
%%            priority values (if any are given) sorted with lowest (best)
%%            priority first.
%% Returns  = list of integer()
get_priorities(Locations) when is_list(Locations) ->
    get_priorities2(Locations, []).

get_priorities2([#siplocationdb_e{flags=Flags} | T], Res) ->
    case lists:keysearch(priority, 1, Flags) of
	{value, {priority, Prio}} when Prio /= [] ->
	    get_priorities2(T, [Prio | Res]);
	false ->
	    %% no priority
	    get_priorities2(T, Res)
    end;
get_priorities2([], Res) ->
    lists:sort(Res).

%% Descrip.: find the Location/s that has the "best" priority in the Flags part of the tuple.
%%            Note that some may lack a {priority, PrioVal} entry
%% Returns : list() of siplocationdb_e record() (all with same "best" priority - Priority)
get_locations_with_prio(Priority, Locations) ->
    get_locations_with_prio2(Priority, Locations, []).

get_locations_with_prio2(_Priority, [], Res) ->
    lists:reverse(Res);
get_locations_with_prio2(Priority, [#siplocationdb_e{flags = Flags} = H | T], Res) ->
    case lists:keysearch(priority, 1, Flags) of
	{value, {priority, Priority}} ->
	    get_locations_with_prio2(Priority, T, [H | Res]);
	_ ->
	    %% other priority, or no priority
	    get_locations_with_prio2(Priority, T, Res)
    end.

%%--------------------------------------------------------------------
%% Function: process_non_wildcard_contacts(LogTag, SipUser, Location,
%%                                         Header, PathVector)
%%           LogTag     = string(),
%%           SipUser    =
%%           Locations  = list() of contact record(), binding to add
%%                        for SipUser
%%           Header     = keylist record(), REGISTER request header
%%           PathVector = list() of string(), RFC3327 Path vector
%% Descrip.: process a SIP Contact entry (thats not a wildcard)
%%           and do the appropriate db add/rm/update, see:
%%           RFC 3261 chapter 10.3 - Processing REGISTER Request -
%%           step 7 for more details
%% Returns : void() | throw(...) (throw is either a siperror or a
%%                                Mnesia error)
%%--------------------------------------------------------------------
process_non_wildcard_contacts(LogTag, SipUser, Locations, Header, PathVector) ->
    CallId = sipheader:callid(Header),
    {CSeqStr, _CSeqMethod} = sipheader:cseq(Header),
    CSeq = list_to_integer(CSeqStr),

    %% get expire value from request header only once, this will speed up the calls to
    %% parse_register_contact_expire/2 that are done for each Locations entry
    ExpireHeader = sipheader:expires(Header),
    process_non_wildcard_contacts2(LogTag, SipUser, CallId, CSeq, ExpireHeader, PathVector, Locations).

%% process_non_wildcard_contacts2 - part of process_non_wildcard_contacts()
process_non_wildcard_contacts2(LogTag, SipUser, CallId, CSeq, ExpireHeader, PathVector, [Location | T]) ->
    {atomic, R} = phone:get_sipuser_location_binding(SipUser, sipurl:parse(Location#contact.urlstr)),
    Priority = 100,
    %% check if SipUser-Location binding exists in database
    case R of
	[] ->
	    %% User has no bindings in the location database, register this one
	    register_contact(LogTag, SipUser, Location, Priority, ExpireHeader, CallId, CSeq, PathVector);
	[SipUserLocation] ->
	    %% User has exactly one binding in the location database matching this one, do some checking
	    check_same_call_id(LogTag, SipUser, Location, SipUserLocation, Priority,
			       CallId, CSeq, ExpireHeader, PathVector)
    end,
    process_non_wildcard_contacts2(LogTag, SipUser, CallId, CSeq, ExpireHeader, PathVector, T);
process_non_wildcard_contacts2(_LogTag, _SipUser, _CallId, _CSeq, _ExpireHeader, _PathVector, []) ->
    ok.

%% DBLocation = phone record(), currently stored sipuser-location info
%% ReqLocation = contact record(), sipuser-location binding data in REGISTER request
check_same_call_id(LogTag, SipUser, ReqLocation, DBLocation, Priority, CallId, CSeq, ExpireHeader, PathVector) ->
    case CallId == DBLocation#phone.callid of
	true ->
	    %% request has same call-id so a binding already exists
	    check_greater_cseq(LogTag, SipUser, ReqLocation, DBLocation,
			       Priority, CallId, CSeq, ExpireHeader, PathVector);
	false ->
	    %% call-id differs, so the UAC has probably been restarted.
	    case parse_register_contact_expire(ExpireHeader, ReqLocation) == 0 of
		true ->
		    %% zero expire-time, unregister binding
		    logger:log(normal, "~s: UN-REGISTER ~s at ~s (priority ~p)",
			       [LogTag, SipUser, DBLocation#phone.requristr, Priority]),
		    phone:delete_record(DBLocation);
		false ->
		    %% non-zero expire-time, update the binding
		    register_contact(LogTag, SipUser, ReqLocation, Priority, ExpireHeader, CallId, CSeq, PathVector)
	    end
    end.

check_greater_cseq(LogTag, SipUser, ReqLocation, DBLocation, Priority, CallId, CSeq, ExpireHeader, PathVector) ->
    %% only process reqest if cseq is > than the last one processed i.e. ignore
    %% old, out of order requests
    case CSeq > DBLocation#phone.cseq of
	true ->
	    case parse_register_contact_expire(ExpireHeader, ReqLocation) == 0 of
		true ->
		    %% unregister binding
		    logger:log(normal, "~s: UN-REGISTER ~s at ~s (priority ~p)",
			       [LogTag, SipUser, DBLocation#phone.requristr, Priority]),
		    phone:delete_record(DBLocation);
		false ->
		    %% update the binding
		    register_contact(LogTag, SipUser, ReqLocation, Priority, ExpireHeader, CallId, CSeq, PathVector)
	    end;
	false ->
	    logger:log(debug, "Location: NOT updating binding for user ~p, entry ~p in db has CSeq ~p "
		       "and request has ~p", [SipUser, DBLocation#phone.requristr, DBLocation#phone.cseq, CSeq]),
	    %% RFC 3261 doesn't appear to document the proper error code for this case
	    throw({siperror, 403, "Request out of order, contained old CSeq number"})
    end.

%%--------------------------------------------------------------------
%% Function: to_url(LDBE)
%%           LDBE = siplocationdb_e record()
%% Descrip.: Create a SIP URL from a SIP location db entry.
%% Returns : sipurl record()
%%--------------------------------------------------------------------
to_url(LDBE) when is_record(LDBE, siplocationdb_e) ->
    LDBE#siplocationdb_e.address.

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: register_contact(LogTag, SipUser, Location, Priority,
%%                            ExpireHeader, CallId, CSeq, PathVector)
%%           LogTag       = string()
%%           SipUser      = string()
%%           Location     = contact record()
%%           Priority     = integer()
%%           ExpireHeader = list() of string(), Expire header from
%%                          REGISTER request, or [] if not present
%%           CallId       = string(), Call-Id header from REGISTER
%%                          request
%%           CSeq         = integer(), CSeq number from REGISTER
%%                          request
%% Descrip.: add or update a Location entry
%% Returns : -
%%--------------------------------------------------------------------
register_contact(LogTag, SipUser, Location, Priority, ExpireHeader, CallId, CSeq, PathVector)
  when is_list(SipUser), is_record(Location, contact), is_integer(Priority), is_list(CallId), is_integer(CSeq) ->
    Expire = parse_register_expire(ExpireHeader, Location),
    logger:log(normal, "~s: REGISTER ~s at ~s (priority ~p, expire in ~p)",
	       [LogTag, SipUser, Location#contact.urlstr, Priority, Expire]),
    Flags = register_contact_flags(Priority, Location, PathVector),
    case lists:keysearch(instance_id, 1, Flags) of
	{value, {instance_id, Instance_Id}} ->
	    %% Always generate a GRUU for an instance id if there isn't any yet
	    gruu:create_if_not_exists(SipUser, Instance_Id);
	_ ->
	    ok
    end,
    phone:insert_purge_phone(SipUser, Flags, dynamic,
			     Expire + util:timestamp(),
			     sipurl:parse(Location#contact.urlstr),
			     CallId, CSeq).

%%--------------------------------------------------------------------
%% Function: register_contact_flags(Priority, Contact, Path)
%%           Priority = integer(), sorting parameter
%%           Contact  = contact record()
%%           Path     = list() of string(), RFC3327 path vector
%% Descrip.: Create flags to store in the location database for this
%%           registration. For outgoingproxy, this includes an 'addr'
%%           that is the address of the proxy to which the UAC
%%           (presumably) has a persistent TCP connection that must
%%           be used in order to reach this client with SIP messages.
%% Returns : L = list() of {Key, Value}
%%           Key   = atom()
%%           Value = term()
%% Note    : The registration_time is used by the GRUU mechanism in
%%           case there is more than one registered contact with the
%%           same instance id for a user.
%%           GRUU draft 06 #8.4.1 (Request Targeting)
%%--------------------------------------------------------------------
register_contact_flags(Priority, Contact, Path) ->
    case Path of
	[] ->
	    register_contact_flags2(Priority, Contact);
	_ ->
	    More = register_contact_flags2(Priority, Contact),
	    [{path, Path} | More]
    end.

register_contact_flags2(Priority, Contact) ->
    GRUU =
	case contact_param:find(Contact#contact.contact_param, "+sip.instance") of
	    [] -> [];
	    [Instance1] ->
		case string:chr(Instance1, 34) of    %% 34 is "
		    0 ->
			logger:log(debug, "Location: Ignoring +sip.instance parameter with non-quouted value ~p",
				   [Instance1]),
			[];
		    LeftQuoteIndex ->
			TempString = string:substr(Instance1, LeftQuoteIndex + 1),
			RightQuoteIndex = string:chr(TempString, 34),   %% 34 is "
			Instance = string:substr(TempString, 1, RightQuoteIndex - 1),
			[{instance_id, Instance}]
		end
	end,

    [{priority, Priority},
     {registration_time, util:timestamp()}
    ] ++ GRUU.

%% determine expiration time for a specific contact. Use default
%% value if contact/header supplies no expiration period.
%% Returns : integer(), time in seconds
parse_register_expire(ExpireHeader, Contact) when is_record(Contact, contact) ->
    ContactExpire = parse_register_contact_expire(ExpireHeader, Contact),
    case ContactExpire of
	%% no expire - use default
	none ->
	    3600;
	ContactExpire ->
	    %% expire value supplied by request - we can choose to accept,
	    %% change (shorten/increase expire period) or reject too short expire
	    %% times with a 423 (Interval Too Brief) error.
	    %% Currently implementation only limits the max expire period
	    {ok, MaxRegisterTime} = yxa_config:get_env(max_register_time),

	    lists:min([MaxRegisterTime, ContactExpire])
    end.


%%--------------------------------------------------------------------
%% Function: unregister_contacts(LogTag, RequestHeader, PhoneEntrys)
%%           LogTag        = string(),
%%           RequestHeader = keylist record(),
%%           PhoneEntrys   = list of phone record(),
%% Descrip.: handles wildcard based removal (RFC 3261 chapter 10
%%           page 64 - step 6), this function handles a list of
%%           Locations (sipuser-location binding)
%% Returns : ok |
%%           throw(SipError)
%%--------------------------------------------------------------------
unregister_contacts(LogTag, RequestHeader, PhoneEntrys) when is_record(RequestHeader, keylist),
							     is_list(PhoneEntrys) ->
    RequestCallId = sipheader:callid(RequestHeader),
    {CSeq, _}  = sipheader:cseq(RequestHeader),
    RequestCSeq = list_to_integer(CSeq),

    F = fun(Phone) when is_record(Phone, phone) ->
		unregister_phone(LogTag, Phone, RequestCallId, RequestCSeq)
	end,
    lists:foreach(F, PhoneEntrys).


%% Descrip.: handles wildcard based removal (RFC 3261 chapter 10
%%           page 64 - step 6), this function handles a single
%%           Phone (phone record/sipuser-location binding)
unregister_phone(LogTag, #phone{class = dynamic}=Location, RequestCallId, RequestCSeq) ->
    SameCallId = (RequestCallId == Location#phone.callid),
    HigherCSeq = (RequestCSeq > Location#phone.cseq),
    %% RFC 3261 chapter 10 page 64 - step 6 check to see if
    %% sipuser-location binding (stored in Location) should be removed
    RemoveLocation = case {SameCallId, HigherCSeq} of
			 {true, true} -> true;
			 {false, _} -> true;
			 _ -> false
		     end,

    case RemoveLocation of
	true ->
	    phone:delete_record(Location),

	    Flags = Location#phone.flags,
	    Priority = case lists:keysearch(priority, 1, Flags) of
			   {value, {priority, P}} -> P;
			   _ -> undefined
		       end,

	    SipUser = Location#phone.number,
	    logger:log(normal, "~s: UN-REGISTER ~s at ~s (priority ~p)",
		       [LogTag, SipUser, Location#phone.requristr, Priority]),
	    ok;
	false ->
	    %% Request CSeq value was too old, abort Request
	    %% RFC 3261 doesn't appear to document the proper error code for this case
	    throw({siperror, 403, "Request out of order, contained old CSeq number"})
    end;
unregister_phone(LogTag, Phone, _RequestCallId, _RequestCSeq) when is_record(Phone, phone) ->
    logger:log(debug, "~s: Not un-registering location with class not 'dynamic' : ~p",
	       [LogTag, Phone#phone.requristr]),
    ok.

%%--------------------------------------------------------------------
%% Function: parse_register_contact_expire(ExpireHeader, Contact)
%%           Header  = keylist record(), the request headers
%%           ExpireHeader = sipheader:expires(Header) return value
%%           Contact = contact record(), a contact entry from a request
%% Descrip.: determine the expire time supplied for a contact in a SIP
%%           REGISTER request
%% Returns : integer() |
%%           none        if no expire was supplied
%% Note    : Test order may not be changed as it is specified by
%%           RFC 3261 chapter 10 page 64 - step 6
%%--------------------------------------------------------------------
parse_register_contact_expire(ExpireHeader, Contact) when is_list(ExpireHeader),
							  is_record(Contact, contact) ->
    %% first check if "Contact" has a expire parameter
    case contact_param:find(Contact#contact.contact_param, "expires") of
	[ContactExpire] ->
	    list_to_integer(ContactExpire);
	[] ->
	    %% then check for a expire header
	    case ExpireHeader of
		[HExpire] ->
		    list_to_integer(HExpire);
		[] ->
		    %% no expire found
		    none
	    end
    end.


%%====================================================================
%% Test functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: test()
%% Descrip.: autotest callback
%% Returns : ok | throw()
%%--------------------------------------------------------------------
test() ->

    %% test get_priorities(Locations)
    %%--------------------------------------------------------------------
    Loc0 = #siplocationdb_e{flags = [], expire = 0},
    Loc1 = #siplocationdb_e{flags = [{priority, 1}], expire = 1},
    Loc2 = #siplocationdb_e{flags = [{priority, 2}], expire = 2},
    Loc3 = #siplocationdb_e{flags = [{priority, 2}], expire = 3},

    autotest:mark(?LINE, "get_priorities/1 - 1"),
    %% normal case
    [1, 2, 2] = get_priorities([Loc0, Loc1, Loc2, Loc3]),

    autotest:mark(?LINE, "get_priorities/1 - 2"),
    %% no location with priority
    [] = get_priorities([Loc0]),


    %% test prioritize_locations(Locations)
    %%--------------------------------------------------------------------
    Loc4 = #siplocationdb_e{flags = [{priority, 4}], expire = 4},

    autotest:mark(?LINE, "prioritize_locations/1 - 1"),
    [Loc1] = prioritize_locations([Loc0, Loc1, Loc2, Loc3, Loc4, Loc0]),

    autotest:mark(?LINE, "prioritize_locations/1 - 2"),
    [Loc2, Loc3] = prioritize_locations([Loc2, Loc3, Loc4]),

    autotest:mark(?LINE, "prioritize_locations/1 - 3"),
    [Loc4] = prioritize_locations([Loc4, Loc0]),

    autotest:mark(?LINE, "prioritize_locations/1 - 4"),
    %% test without priority flag
    [Loc0] = prioritize_locations([Loc0]),


    %% is_valid_wildcard_request(Header, ContactList)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "is_valid_wildcard_request/2 - 1"),
    %% test valid wildcard
    true = is_valid_wildcard_request(keylist:from_list([{"Expires", ["0"]}]), [contact:new("*")]),

    autotest:mark(?LINE, "is_valid_wildcard_request/2 - 2"),
    %% test non-zero Expires
    {siperror, 400, _} =
	(catch is_valid_wildcard_request(keylist:from_list([{"Expires", ["1"]}]), [contact:new("*")])),

    autotest:mark(?LINE, "is_valid_wildcard_request/2 - 3"),
    %% test non-zero Expires, starting with a zero
    {siperror, 400, "Wildcard with non-zero contact expires parameter"} =
	(catch is_valid_wildcard_request(keylist:from_list([{"Expires", ["01"]}]), [contact:new("*")])),

    autotest:mark(?LINE, "is_valid_wildcard_request/2 - 4"),
    %% test without Expires-header
    {siperror, 400, _} =
	(catch is_valid_wildcard_request(keylist:from_list([]), [contact:new("*")])),

    autotest:mark(?LINE, "is_valid_wildcard_request/2 - 5"),
    %% test with non-numeric Expires-header
    {siperror, 400, _} =
	(catch is_valid_wildcard_request(keylist:from_list([{"Expires", ["test"]}]), [contact:new("*")])),

    autotest:mark(?LINE, "is_valid_wildcard_request/2 - 6"),
    %% test with invalid Expires-header
    {siperror, 400, _} =
	(catch is_valid_wildcard_request(keylist:from_list([{"Expires", ["0 invalid"]}]), [contact:new("*")])),

    autotest:mark(?LINE, "is_valid_wildcard_request/2 - 7"),
    %% non-wildcard contact
    false = is_valid_wildcard_request(keylist:from_list([]), [contact:new("sip:ft@example.org")]),

    autotest:mark(?LINE, "is_valid_wildcard_request/2 - 8"),
    %% multiple non-wildcard contact
    false = is_valid_wildcard_request(keylist:from_list([]), [contact:new("sip:ft@example.org"),
							      contact:new("sip:ft@example.net")]),

    autotest:mark(?LINE, "is_valid_wildcard_request/2 - 9"),
    %% multiple contacts, one is a wildcard
    {siperror, 400, _} =
	(catch is_valid_wildcard_request(keylist:from_list([]), [contact:new("*"),
								 contact:new("sip:ft@example.org")])),

    autotest:mark(?LINE, "is_valid_wildcard_request/2 - 10"),
    %% more than one Expires header value
    {siperror, 400, "Wildcard with more than one expires parameter"} =
	(catch is_valid_wildcard_request(keylist:from_list([{"Expires", ["0", "1"]}]), [contact:new("*")])),


    %% parse_register_expire(ExpireHeader, Contact)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "parse_register_expire/2 - 1"),
    %% test default
    3600 = parse_register_expire([], contact:new("sip:ft@example.org")),

    autotest:mark(?LINE, "parse_register_expire/2 - 2"),
    %% test that contact parameter is used if present
    1201 = parse_register_expire(["1202"], contact:new("sip:ft@example.org", [{"expires", "1201"}])),

    autotest:mark(?LINE, "parse_register_expire/2 - 3"),
    %% test that expires header is used if contact parameter is absent
    1202 = parse_register_expire(["1202"], contact:new("sip:ft@example.org")),

    autotest:mark(?LINE, "parse_register_expire/2 - 4"),
    %% test that contact can't be larger than maximum
    43200 = parse_register_expire([], contact:new("sip:ft@example.org", [{"expires", "86400"}])),


    %% locations_to_contacts2(Locations, Now, SipUser, Do_GRUU, [])
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "locations_to_contacts2/5 - 0"),
    LTCNow = util:timestamp(),
    LTC_L1 = #siplocationdb_e{expire = LTCNow + 1, address = sipurl:parse("sip:ft@one.example.org")},
    LTC_L2 = #siplocationdb_e{expire = LTCNow + 2, address = sipurl:parse("sip:ft@two.example.org")},
    LTC_L3 = #siplocationdb_e{expire = never, address = sipurl:parse("sip:ft@static.example.org")},

    autotest:mark(?LINE, "locations_to_contacts2/5 - 1"),
    LTC_DoGRUU = false,
    LTC_To = ["<sip:testuser@example.org>"],
    LTC_GRUUs = false,
    %% test basic case
    {LTC_DoGRUU, ["<sip:ft@one.example.org>;expires=1", "<sip:ft@two.example.org>;expires=2"]} =
	locations_to_contacts2([LTC_L2, LTC_L1], LTCNow, "testuser", LTC_DoGRUU, LTC_To, LTC_GRUUs, []),

    autotest:mark(?LINE, "locations_to_contacts2/5 - 2"),
    %% test that we ignore entrys that never expire
    {LTC_DoGRUU, []} = locations_to_contacts2([LTC_L3], LTCNow, "testuser", LTC_DoGRUU, LTC_To, LTC_GRUUs, []),

    autotest:mark(?LINE, "locations_to_contacts2/5 - 3"),
    %% test that we ignore entrys that never expire together with other entrys
    {LTC_DoGRUU, ["<sip:ft@one.example.org>;expires=1", "<sip:ft@two.example.org>;expires=2"]} =
	locations_to_contacts2([LTC_L2, LTC_L3, LTC_L1], LTCNow, "testuser", LTC_DoGRUU, LTC_To, LTC_GRUUs, []),


    %% to_url(LDBE)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "to_url/1 - 0"),
    ToURL_URL1 = sipurl:parse("sip:ft@192.0.2.111;line=foo"),

    autotest:mark(?LINE, "to_url/1 - 1"),
    %% basic test
    ToURL_URL1 = to_url(#siplocationdb_e{flags = [], address = ToURL_URL1}),


    %% register_contact_flags(Priority, Contact, Path)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "register_contact_flags/3 - 1"),
    [RCF_Contact1] = contact:parse(["<sip:ft@192.0.2.123>"]),
    [{priority, 100}, {registration_time, _}] =
	lists:sort( register_contact_flags(100, RCF_Contact1, []) ),

    autotest:mark(?LINE, "register_contact_flags/3 - 2"),
    [{path, ["one", "two"]}, {priority, 102}, {registration_time, _}] =
	lists:sort( register_contact_flags(102, RCF_Contact1, ["one", "two"]) ),

    autotest:mark(?LINE, "register_contact_flags/3 - 3"),
    [RCF_Contact3] = contact:parse(["<sip:ft@192.0.2.123>;+sip.instance=\"<test-instance>\""]),
    [{instance_id, "<test-instance>"}, {priority, 100}, {registration_time, _}] =
	lists:sort( register_contact_flags(100, RCF_Contact3, []) ),

    autotest:mark(?LINE, "register_contact_flags/3 - 4"),
    %% test that we ignore non-quoted instance-ids
    [RCF_Contact4] = contact:parse(["<sip:ft@192.0.2.123>;+sip.instance=test"]),
    [{priority, 100}, {registration_time, _}] =
	lists:sort( register_contact_flags(100, RCF_Contact4, []) ),


    %% is_valid_register_request(Header)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "is_valid_register_request/1 - 1"),
    %% test without Require
    true = is_valid_register_request(keylist:from_list([])),

    autotest:mark(?LINE, "is_valid_register_request/1 - 2"),
    %% test with "path" required
    true = is_valid_register_request( keylist:from_list([{"Require", ["path"]}]) ),

    autotest:mark(?LINE, "is_valid_register_request/1 - 3"),
    %% test with unknown extensions required
    {siperror, 420, "Bad Extension", [{"Unsupported", ["unknown-ext1", "unknown-ext2"]}]} =
	is_valid_register_request( keylist:from_list([{"Require", ["unknown-ext1", "unknown-ext2"]}]) ),


    %% get_unsupported_extensions2(In, DoGRUU, [])
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_unsupported_extensions2/3 D- 1"),
    [] = get_unsupported_extensions2(["gruu", "path"], true, []),

    autotest:mark(?LINE, "get_unsupported_extensions2/3 - 2"),
    ["gruu"] = get_unsupported_extensions2(["gruu", "path"], false, []),


    %% process_updates_get_path_vector2(Proto, Header, AppName, IgnoreSupported)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "process_updates_get_path_vector2/4 - 0"),
    PUGPV_RRStr1 = siprequest:construct_record_route("sip"),
    PUGPV_RRStr2 = siprequest:construct_record_route("sips"),
    PUGPV_NoPathHeader = keylist:from_list([]),
    PUGPV_PathHeader = keylist:from_list([ {"Path", ["<sip:edge-proxy.example.com;lr>"]} ]),
    PUGPV_PathSupportedHeader = keylist:set("Supported", ["path"], PUGPV_PathHeader),
    PUGPV_ExtRequired = {siperror, 421, "Extension Required", [{"Require", ["path"]}]},

    autotest:mark(?LINE, "process_updates_get_path_vector2/4 - 1"),
    %% test with no Path, not outgoingproxy
    [] = process_updates_get_path_vector2("sip", PUGPV_NoPathHeader, incomingproxy, false),

    autotest:mark(?LINE, "process_updates_get_path_vector2/4 - 2"),
    %% test with no Path, outgoingproxy. Means this proxy should add itself.
    [PUGPV_RRStr1] = process_updates_get_path_vector2("sip", PUGPV_NoPathHeader, outgoingproxy, false),

    autotest:mark(?LINE, "process_updates_get_path_vector2/4 - 3"),
    %% test with path, Supported required
    PUGPV_ExtRequired = process_updates_get_path_vector2("sip", PUGPV_PathHeader, incomingproxy, false),

    autotest:mark(?LINE, "process_updates_get_path_vector2/4 - 4"),
    %% test with path, Supported NOT required, incomingproxy
    ["<sip:edge-proxy.example.com;lr>"] = process_updates_get_path_vector2("sip", PUGPV_PathHeader, incomingproxy, true),

    autotest:mark(?LINE, "process_updates_get_path_vector2/4 - 5"),
    %% test with path, Supported NOT required, outgoingproxy
    [PUGPV_RRStr1, "<sip:edge-proxy.example.com;lr>"] =
	process_updates_get_path_vector2("sip", PUGPV_PathHeader, outgoingproxy, true),

    autotest:mark(?LINE, "process_updates_get_path_vector2/4 - 6"),
    %% test with path, Supported required, incomingproxy
    ["<sip:edge-proxy.example.com;lr>"] =
	process_updates_get_path_vector2("sip", PUGPV_PathSupportedHeader, incomingproxy, false),

    autotest:mark(?LINE, "process_updates_get_path_vector2/4 - 6"),
    %% test with path, Supported required, outgoingproxy
    [PUGPV_RRStr2, "<sip:edge-proxy.example.com;lr>"] =
	process_updates_get_path_vector2("sips", PUGPV_PathSupportedHeader, outgoingproxy, false),


    %% process_updates_get_path_vector(Request, AppName)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "process_updates_get_path_vector/2 - 1"),
    %% simple test
    [] = process_updates_get_path_vector(#request{uri = sipurl:parse("sip:ft@192.0.2.22"),
						  header = keylist:from_list([])
						 }, incomingproxy, false),


    %% Mnesia dependant tests
    %%--------------------------------------------------------------------


    autotest:mark(?LINE, "Mnesia setup - 0"),

    phone:test_create_table(),
    database_gruu:test_create_table(),

    case mnesia:transaction(fun test_mnesia_dependant_functions/0) of
	{aborted, ok} ->
	    ok;
	{aborted, Res} ->
	    io:format("Test FAILED, test_mnesia_dependant_functions returned ~p", [Res]),
	    {error, Res}
    end.


test_mnesia_dependant_functions() ->

    %% register_contact(LogTag, SipUser, Location, Priority, ExpireHeader, CallId, CSeq, PathVector)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "register_contact/8 - 0"),
    Register_Contact1_Now = util:timestamp(),
    Register_Contact1_Expire_In = 3610,	%% use value not likely to be outside configured bounds
    Register_Contact1_Expire = Register_Contact1_Now + Register_Contact1_Expire_In,
    [Register_Contact1] = contact:parse(["<sip:user@192.0.2.11>;expires=" ++
					 integer_to_list(Register_Contact1_Expire_In)
					]),
    Register_Contact1_URL = sipurl:parse(Register_Contact1#contact.urlstr),

    [Register_Contact2] = contact:parse(["<sips:user@192.0.2.12>;expires=" ++
					 integer_to_list(Register_Contact1_Expire_In)
					]),
    Register_Contact2_URL = sipurl:parse(Register_Contact2#contact.urlstr),

    TestInstanceId1 = "<test:__unit_testing_instance_id_RC3__>",

    [Register_Contact3] = contact:parse(["<sips:user@192.0.2.13>;"
					 "+sip.instance=\"" ++ TestInstanceId1 ++ "\";expires=" ++
					 integer_to_list(Register_Contact1_Expire_In)
					]),
    Register_Contact3_URL = sipurl:parse(Register_Contact3#contact.urlstr),

    TestUser1 = "__unit-test__user1__",
    TestUser2 = "__unit-test__user2__",

    autotest:mark(?LINE, "register_contact/8 - 1.1"),
    %% test regular registration
    {atomic, ok} = register_contact("testing", TestUser1, Register_Contact1, 100,
				    [], "call-id123", 1, []),

    autotest:mark(?LINE, "register_contact/8 - 1.2"),
    %% verify result
    [#siplocationdb_e{address = Register_Contact1_URL,
		      flags   = Register_Contact1_Flags,
		      class   = dynamic,
		      expire  = Register_Contact1_Expire
		     }] = get_locations_for_users([TestUser1]),

    autotest:mark(?LINE, "register_contact/8 - 1.3"),
    [{priority, 100}, {registration_time, _}] = lists:sort(Register_Contact1_Flags),

    autotest:mark(?LINE, "register_contact/8 - 2.1"),
    %% test registration with path vector
    Register_Contact2_Path = ["sip:edge-proxy.example.com;lr", "sip:foo.example.net;lr"],
    {atomic, ok} = register_contact("testing", TestUser2, Register_Contact2, 100,
				    [], "call-id234", 1, Register_Contact2_Path),

    autotest:mark(?LINE, "register_contact/8 - 2.2"),
    [#siplocationdb_e{address = Register_Contact2_URL,
		      flags   = Register_Contact2_Flags}] = get_locations_for_users([TestUser2]),

    autotest:mark(?LINE, "register_contact/8 - 2.3"),
    %% verify resulting flags
    [{path, Register_Contact2_Path}, {priority, 100}, {registration_time, _}] = Register_Contact2_Flags,

    autotest:mark(?LINE, "register_contact/8 - 3.1"),
    %% test registration with instance ID, same user as in previous test
    {atomic, ok} = register_contact("testing", TestUser2, Register_Contact3, 100,
				    [], "call-id345", 1, []),

    autotest:mark(?LINE, "register_contact/8 - 3.2"),
    [#siplocationdb_e{address = Register_Contact2_URL},
     #siplocationdb_e{address = Register_Contact3_URL,
		      flags   = Register_Contact3_Flags}]
	= lists:sort( get_locations_for_users([TestUser2])),

    autotest:mark(?LINE, "register_contact/8 - 3.3"),
    %% verify resulting flags
    [{priority,			100},
     {registration_time,	_},
     {instance_id,		TestInstanceId1}
    ] = Register_Contact3_Flags,


    %% get_user_with_contact(URI)
    %%--------------------------------------------------------------------

    autotest:mark(?LINE, "get_user_with_contact/1 - 1"),
    %% fetch entrys from the last test
    TestUser1 = get_user_with_contact(Register_Contact1_URL),

    autotest:mark(?LINE, "get_user_with_contact/1 - 2 (disabled)"),
    %% fetch same user, but this time with SIPS URI (stored as SIP, should match SIPS as well)
    %TestUser1 = get_user_with_contact(sipurl:set([{proto, "sips"}], Register_Contact1_URL)),

    autotest:mark(?LINE, "get_user_with_contact/1 - 3"),
    %% test no matching contact
    none = get_user_with_contact(sipurl:parse("sip:__unit_test__3k4uhtihAKJFEt@example.org")),


    %% fetch_contacts(SipUser, Do_GRUU, To)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "fetch_contacts/3 - 1.1"),
    %% fetch first user from register_contact tests above, only one location
    {ok, false, FetchContacts1}	= fetch_contacts(TestUser1, true, ["<sip:ft@example.net>"]),
    ok = test_verify_contacts(3600, 3610, ["<sip:user@192.0.2.11>"], FetchContacts1),

    autotest:mark(?LINE, "fetch_contacts/3 - 1.2"),
    %% verify resulting contact

    autotest:mark(?LINE, "fetch_contacts/3 - 2.1"),
    FetchContacts2_To = ["<sip:ft@example.net>"],
    %% fetch other users contacts, one should have a GRUU
    {ok, true, FetchContacts2} = fetch_contacts(TestUser2, true, FetchContacts2_To),

    autotest:mark(?LINE, "fetch_contacts/3 - 2.2"),
    %% verify the contacts
    {ok, [FetchContacts2_GRUU]} = database_gruu:fetch_using_user_instance(TestUser2, TestInstanceId1),
    FetchContacts2_GRUU_URL = gruu:make_url(TestUser2, TestInstanceId1,
					    FetchContacts2_GRUU, FetchContacts2_To),
    ok = test_verify_contacts(3600, 3610, ["<sips:user@192.0.2.12>",
					  "<sips:user@192.0.2.13>;gruu=\"" ++
					   sipurl:print(FetchContacts2_GRUU_URL) ++ "\""
					   ";+sip.instance=\"" ++ TestInstanceId1 ++ "\""
					  ], FetchContacts2),


    %% process_register_request(Request, THandler, LogTag, LogStr, AppName)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "process_register_request/5 - 1"),
    Test_THandler = transactionlayer:test_get_thandler_self(),
    %% test non-homedomain
    PRR_Request1 = #request{method = "REGISTER",
			    uri    = sipurl:parse("sip:ft@something.not-local.test.example.org"),
			    header = keylist:from_list([{"To", ["<sip:ft@example.org>"]}])
			   },
    not_homedomain = process_register_request(PRR_Request1, Test_THandler, "test logtag", "test logstring", test),


    %% register_require_supported(Request, LogStr, THandler, LogTag, AppName)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "register_require_supported/5 - 1"),
    %% test with unsupported extensions required
    RRSup_Request1 = #request{method = "REGISTER",
			      uri    = sipurl:parse("sip:ft@example.org"),
			      header = keylist:from_list([{"To", ["<sip:ft@example.org>"]},
							  {"Require", ["X-unsupported"]}
							 ])
			     },

    register_require_supported(RRSup_Request1, "test logstr", Test_THandler, "logtag", test),
    %% verify result
    receive
	{'$gen_cast', {create_response, 420, "Bad Extension", _RRSup_ExtraHeaders, <<>>}} ->
	    ok;
	RRSup_M1 ->
	    RRSup_Msg1 = io_lib:format("Unknown signal received: ~p", [RRSup_M1]),
	    throw({error, lists:flatten(RRSup_Msg1)})
    after 0 ->
	    throw({error, "Test did not result in the expected create_response signal"})
    end,

    %% process_updates(LogTag, Request, SipUser, Contacts, AppName, DoGRUU)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "process_updates/5 - 0"),
    PU_Request1 = #request{method = "REGISTER",
			   uri    = sipurl:parse("sip:ft@example.org"),
			   header = keylist:from_list([{"To",		["<sip:ft@example.org>"]},
						       {"Expires",	["0"]},
						       {"Call-Id",	["call-id1245667"]},
						       {"CSeq",		["101 REGISTER"]}
						      ])
			  },
    PU_Contact1Str = "<sip:ft@192.0.2.10;up=foo>",

    autotest:mark(?LINE, "process_updates/5 - 1"),
    %% test unregister with wildcard first, to make sure we don't have any entrys for
    %% our test user in the database
    PU_Contacts1 = contact:parse(["*"]),
    {ok, {200, "OK", [{"Date", _}]}} =
	process_updates("test logtag", PU_Request1, TestUser1, PU_Contacts1, incomingproxy, false, false),

    autotest:mark(?LINE, "process_updates/5 - 2.1"),
    %% simple register
    PU_Contacts2 = contact:parse([PU_Contact1Str ++ ";expires=20"]),
    {ok, {200, "OK", [{"Contact", PU_Contacts2_CRes},
		      {"Date", _}
		     ]}} =
	process_updates("test logtag", PU_Request1, TestUser1, PU_Contacts2, incomingproxy, false, false),

    autotest:mark(?LINE, "process_updates/5 - 2.2"),
    %% verify contact read back from the database
    test_verify_contacts(15, 20, [PU_Contact1Str], PU_Contacts2_CRes),

    autotest:mark(?LINE, "process_updates/5 - 3"),
    %% test register again with the same call-id but not higher CSeq
    PU_Request3 = PU_Request1#request{header = keylist:set("CSeq", ["50 REGISTER"], PU_Request1#request.header)},
    {siperror, 403, "Request out of order, contained old CSeq number"}
	= (catch process_updates("test logtag", PU_Request3, TestUser1, PU_Contacts2, incomingproxy, false, false)),

    autotest:mark(?LINE, "process_updates/5 - 3.5"),
    %% test same thing with wildcard contact
    {siperror, 403, "Request out of order, contained old CSeq number"}
	= (catch process_updates("test logtag", PU_Request3, TestUser1, PU_Contacts1, incomingproxy, false, false)),

    autotest:mark(?LINE, "process_updates/5 - 4"),
    %% and again, with higher CSeq this time
    [PU_Contacts4_1] = PU_Contacts2,
    PU_Contacts4_2 = contact:rm_param(PU_Contacts4_1, "expires"),
    PU_Contacts4 = [contact:add_param(PU_Contacts4_2, "expires", "40")],
    PU_Request4 = PU_Request1#request{header = keylist:set("CSeq", ["401 REGISTER"], PU_Request1#request.header)},
    {ok, {200, "OK", [{"Contact", PU_Contacts4_CRes},
		      {"Date", _}
		     ]}} =
	process_updates("test logtag", PU_Request4, TestUser1, PU_Contacts4, incomingproxy, false, false),

    %% verify contact read back from the database
    test_verify_contacts(35, 40, [PU_Contact1Str], PU_Contacts4_CRes),

    autotest:mark(?LINE, "process_updates/5 - 6"),
    %% test without contacts, database readback only (should give exactly the same result as the previous test)
    {ok, {200, "OK", [{"Contact", PU_Contacts5_CRes},
		      {"Date", _}
		     ]}} =
	process_updates("test logtag", PU_Request3, TestUser1, [], incomingproxy, false, false),

    %% verify contact read back from the database
    test_verify_contacts(35, 40, [PU_Contact1Str], PU_Contacts5_CRes),

    autotest:mark(?LINE, "process_updates/5 - 7"),
    %% unregister the only contact for TestUser1 specifically
    PU_Contacts7 = contact:parse([PU_Contact1Str ++ ";expires=0"]),
    PU_Request7 = PU_Request1#request{header = keylist:set("CSeq", ["701 REGISTER"], PU_Request1#request.header)},
    {ok, {200, "OK", [{"Date", _}
		     ]}} =
	process_updates("test logtag", PU_Request7, TestUser1, PU_Contacts7, incomingproxy, false, false),


    autotest:mark(?LINE, "process_updates/5 - 8.1"),
    %% register again
    PU_Contacts8_1 = contact:parse([PU_Contact1Str ++ ";expires=10"]),
    {ok, {200, "OK", [{"Contact", PU_Contacts8_1_CRes},
		      {"Date", _}
		     ]}} =
	process_updates("test logtag", PU_Request1, TestUser1, PU_Contacts8_1, incomingproxy, false, false),

    test_verify_contacts(5, 10, [PU_Contact1Str], PU_Contacts8_1_CRes),

    autotest:mark(?LINE, "process_updates/5 - 8.2"),
    %% test new register with changed Call-Id, simulating a client that has rebooted
    PU_Contacts8_2 = contact:parse([PU_Contact1Str ++ ";expires=20"]),
    PU_Request8_2 = PU_Request1#request{header = keylist:set("Call-Id", ["other-call-id19237"],
							     PU_Request1#request.header)},
    {ok, {200, "OK", [{"Contact", PU_Contacts8_2_CRes},
		      {"Date", _}
		     ]}} =
	process_updates("test logtag", PU_Request8_2, TestUser1, PU_Contacts8_2, incomingproxy, false, false),

    %% verify binding was updated (longer expire now)
    test_verify_contacts(15, 20, [PU_Contact1Str], PU_Contacts8_2_CRes),

    autotest:mark(?LINE, "process_updates/5 - 8.3"),
    %% unregister the only contact for TestUser1 with different Call-Id once again
    PU_Request8_3 = PU_Request1#request{header = keylist:set("Call-Id", ["yet-another-call-id56622"],
							     PU_Request1#request.header)},
    PU_Contacts8_3 = contact:parse([PU_Contact1Str ++ ";expires=0"]),
    {ok, {200, "OK", [{"Date", _}
		     ]}} =
	process_updates("test logtag", PU_Request8_3, TestUser1, PU_Contacts8_3, incomingproxy, false, false),

    %%
    %% GRUU TESTS
    %%

    autotest:mark(?LINE, "process_updates/5 - 10.1"),
    %% Register with GRUU
    PU_Contacts10_Instance = "<test:__unit_testing_instance_id_PU10__>",
    PU_Contacts10 = contact:parse([PU_Contact1Str ++ ";+sip.instance=\"" ++ PU_Contacts10_Instance ++
				  "\";expires=20"]),
    PU_Request10_1 = PU_Request1#request{header = keylist:set("CSeq", ["1001 REGISTER"], PU_Request1#request.header)},
    PU_Request10_2 = PU_Request10_1#request{header = keylist:set("Supported", ["gruu"], PU_Request10_1#request.header)},

    %% Note: The 'Require: gruu' is no longer required by the GRUU draft (removed in -07)
    %% but we will keep doing it until we are sure that clients don't ignore the GRUUs otherwise
    {ok, {200, "OK", [{"Require",	["gruu"]},
		      {"Contact",	PU_Contacts10_CRes},
		      {"Date",		_}
		     ]}} =
	process_updates("test logtag", PU_Request10_2, TestUser1, PU_Contacts10, incomingproxy, true, false),

    autotest:mark(?LINE, "process_updates/5 - 10.2"),
    %% verify the contacts
    {ok, [PU_Contacts10_GRUU]} = database_gruu:fetch_using_user_instance(TestUser1, PU_Contacts10_Instance),
    PU_Contacts10_GRUU_URL = gruu:make_url(TestUser1, PU_Contacts10_Instance, PU_Contacts10_GRUU,
					   keylist:fetch('to', PU_Request10_2#request.header)),
    ok = test_verify_contacts(15, 20, [PU_Contact1Str ++ ";gruu=\"" ++
				       sipurl:print(PU_Contacts10_GRUU_URL) ++ "\""
				       ";+sip.instance=\"" ++ PU_Contacts10_Instance ++ "\""
				      ], PU_Contacts10_CRes),


    autotest:mark(?LINE, "process_updates/5 - 11.1"),
    %% test that GRUUs are not included if the client does not indicate support for it (through Supported: gruu)
    PU_Request11 = PU_Request1#request{header = keylist:set("CSeq", ["1101 REGISTER"], PU_Request1#request.header)},
    {ok, {200, "OK", [{"Contact",	PU_Contacts11_CRes},
		      {"Date",		_}
		     ]}} =
	process_updates("test logtag", PU_Request11, TestUser1, PU_Contacts10, incomingproxy, true, false),

    autotest:mark(?LINE, "process_updates/5 - 11.2"),
    %% verify the contacts
    ok = test_verify_contacts(15, 20, [PU_Contact1Str], PU_Contacts11_CRes),


    autotest:mark(?LINE, "process_updates/5 - 14"),
    %% unregister all contacts for TestUser1 with a wildcard, same Call-Id and increased CSeq
    PU_Contacts14 = contact:parse(["*"]),
    PU_Request14 = PU_Request1#request{header = keylist:set("CSeq", ["1401 REGISTER"], PU_Request1#request.header)},
    {ok, {200, "OK", [{"Date", _}
		     ]}} =
	process_updates("test logtag", PU_Request14, TestUser1, PU_Contacts14, incomingproxy, true, false),

    %%
    %% Path TESTS
    %%

    autotest:mark(?LINE, "process_updates/5 - 15"),
    %% test with path inserted by a previous proxy, but no UA support for Path
    PU_Request15_H1 = keylist:set("CSeq", ["1501 REGISTER"], PU_Request1#request.header),
    PU_Request15_H2 = keylist:set("Path", ["<sip:edge.example.org>"], PU_Request15_H1),
    PU_Request15 = PU_Request1#request{header = PU_Request15_H2},
    PU_Contacts15 = contact:parse([PU_Contact1Str ++ ";expires=20"]),
    {siperror, 421, "Extension Required", [{"Require", ["path"]}]} =
	process_updates("test logtag", PU_Request15, TestUser1, PU_Contacts15, incomingproxy, false, false),


    autotest:mark(?LINE, "process_updates/5 - 16.1"),
    %% test with path inserted by a previous proxy, no UA support for Path but configuration that says we
    %% should store such Path anyways
    {ok, {200, "OK", [{"Contact",	PU_Contacts16_CRes},
		      {"Date",		_},
		      {"Path",		["<sip:edge.example.org>"]}
		     ]}} =
	process_updates("test logtag", PU_Request15, TestUser1, PU_Contacts15, incomingproxy, false, true),

    autotest:mark(?LINE, "process_updates/5 - 16.2"),
    %% verify the contacts in the response
    ok = test_verify_contacts(15, 20, [PU_Contact1Str], PU_Contacts16_CRes),

    autotest:mark(?LINE, "process_updates/5 - 16.3"),
    %% verify the record in the location database
    [PU_Contacts16_Loc] = get_locations_for_users([TestUser1]),
    {value, {path, ["<sip:edge.example.org>"]}} = lists:keysearch(path, 1, PU_Contacts16_Loc#siplocationdb_e.flags),


    autotest:mark(?LINE, "process_updates/5 - 17.1"),
    %% test with path inserted by a previous proxy, and one inserted by this proxy (appname is outgoingproxy)
    %% (the one we insert should not be visible in the response)
    PU_Request17_H1 = keylist:set("CSeq", ["1701 REGISTER"], PU_Request15#request.header),
    PU_Request17_H2 = keylist:set("Supported", ["path"], PU_Request17_H1),
    PU_Request17 = PU_Request15#request{uri	= sipurl:parse("sips:example.org"),
					header	= PU_Request17_H2
				       },
    {ok, {200, "OK", [{"Contact",	PU_Contacts17_CRes},
		      {"Date",		_},
		      {"Path",		["<sip:edge.example.org>"]}
		     ]}} =
	process_updates("test logtag", PU_Request17, TestUser1, PU_Contacts15, outgoingproxy, false, false),

    autotest:mark(?LINE, "process_updates/5 - 17.2"),
    %% verify the contacts in the response
    ok = test_verify_contacts(15, 20, [PU_Contact1Str], PU_Contacts17_CRes),

    autotest:mark(?LINE, "process_updates/5 - 17.3"),
    %% verify the record in the location database
    PU_17_me = siprequest:construct_record_route("sips"),
    [PU_Contacts17_Loc] = get_locations_for_users([TestUser1]),
    {value, {path, [PU_17_me, "<sip:edge.example.org>"]}} =
	lists:keysearch(path, 1, PU_Contacts17_Loc#siplocationdb_e.flags),

    autotest:mark(?LINE, "process_updates/5 - 17.4"),
    %% wipe clean
    PU_Contacts17_4 = contact:parse(["*"]),
    PU_Request17_4 = PU_Request17#request{header = keylist:set("CSeq", ["1704 REGISTER"], PU_Request17_H2)},
    {ok, {200, "OK", [{"Date",	_},
		      {"Path",	["<sip:edge.example.org>"]}
		     ]}} =
	process_updates("test logtag", PU_Request17_4, TestUser1, PU_Contacts17_4, outgoingproxy, false, false),

    %%
    %% END Path TESTS
    %% 


    autotest:mark(?LINE, "process_updates/5 - 20.0"),
    %% put some unusual records into the location database
    PU_20_CSeq = keylist:fetch('cseq', PU_Request1#request.header),
    PU_20_Expire = util:timestamp() + 20,
    %% record with no priority
    {atomic, ok} = phone:insert_purge_phone(TestUser1, [], dynamic, PU_20_Expire,
					    sipurl:parse("sip:dynamic@192.0.2.12"), PU_20_CSeq, "2000"),
    %% static registration
    {atomic, ok} = phone:insert_purge_phone(TestUser1, [], static, never,
					    sipurl:parse("sip:static@example.org"), "", ""),

    autotest:mark(?LINE, "process_updates/5 - 20.1"),
    %% verify that the static registration isn't included in REGISTER responses
    PU_Request20 = PU_Request1#request{header = keylist:set("CSeq", ["2001 REGISTER"], PU_Request1#request.header)},
    {ok, {200, "OK", [{"Contact",       PU_Contacts20_CRes},
                      {"Date",          _}
                     ]}} =
        process_updates("test logtag", PU_Request20, TestUser1, [], test, true, true),

    autotest:mark(?LINE, "process_updates/5 - 20.2"),
    %% verify the contacts in the response
    ok = test_verify_contacts(15, 20, ["<sip:dynamic@192.0.2.12>"], PU_Contacts20_CRes),

    autotest:mark(?LINE, "process_updates/5 - 21"),
    %% test unregistering with wildcard when there are some 'strange' entrys there
    PU_Contacts21 = contact:parse(["*"]),
    PU_Request21 = PU_Request1#request{header = keylist:set("CSeq", ["2101 REGISTER"], PU_Request1#request.header)},
    {ok, {200, "OK", [{"Date", _}
		     ]}} =
	process_updates("test logtag", PU_Request21, TestUser1, PU_Contacts21, test, true, true),



    mnesia:abort(ok).


test_verify_contacts(ExpiresMin, ExpiresMax, ExpectList, Got) when is_integer(ExpiresMin), is_integer(ExpiresMax) ->
    test_verify_contacts2(ExpiresMin, ExpiresMax, ExpectList, contact:parse( lists:sort(Got) )).

test_verify_contacts2(ExpiresMin, ExpiresMax, [ExpectH | ExpectT], [GotH | GotT])
  when is_integer(ExpiresMin), is_integer(ExpiresMax), is_list(ExpectH), is_record(GotH, contact) ->
    case contact_param:find(GotH#contact.contact_param, "expires") of
	[ExpiresStr] ->
	    Expires = list_to_integer(ExpiresStr),
	    case (Expires >= ExpiresMin andalso Expires =< ExpiresMax) of
		true ->
		    This = contact:rm_param(GotH, "expires"),
		    case contact:print(This) of
			ExpectH ->
			    %% match, test next
			    test_verify_contacts2(ExpiresMin, ExpiresMax, ExpectT, GotT);
			Other ->
			    io:format("Contact (with expires parameter removed) :~n~p~n"
				      "does not match the expected :~n~p~n~n~n", [Other, ExpectH]),

			    {error, contact_mismatch}
		    end;
		false ->
		    io:format("Contact ~p expires out of bounds (~p..~p)",
			      [contact:print(GotH), ExpiresMin, ExpiresMax]),
		    {error, contact_expires_out_of_bounds}
	    end;
	[] ->
	    Msg = io_lib:format("Contact ~p missing expires parameter", [contact:print(GotH)]),
	    io:format(Msg),
	   {error, lists:flatten(Msg)}
    end;
test_verify_contacts2(_ExpiresMin, _ExpiresMax, [], []) ->
    ok.
