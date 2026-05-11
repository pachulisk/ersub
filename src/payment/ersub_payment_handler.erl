-module(ersub_payment_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path_info(Req0),
    handle(Method, Path, Req0, State).

%% GET /api/payment/config
handle(<<"GET">>, [<<"config">>], Req0, State) ->
    Providers = [<<"stripe">>, <<"alipay">>, <<"wechat">>],
    Enabled = [P || P <- Providers,
               ersub_config_srv:get(
                   list_to_atom("payment_" ++ binary_to_list(P) ++ "_enabled"),
                   false) =:= true],
    {ok, reply_json(200, #{data => #{providers => Enabled}}, Req0), State};

%% POST /api/payment/orders
handle(<<"POST">>, [<<"orders">>], Req0, State) ->
    case verify_jwt(Req0) of
        {error, _} ->
            {ok, reply_json(401, #{error => #{message => <<"Auth required">>}}, Req0), State};
        {ok, #{<<"user_id">> := UserId}} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            Params = jsx:decode(Body, [return_maps]),
            Provider = maps:get(<<"provider">>, Params, <<"stripe">>),
            Amount = maps:get(<<"amount">>, Params, 0),
            case ersub_payment_srv:create_order(UserId, Provider, Amount) of
                {ok, Order} ->
                    {ok, reply_json(201, #{data => Order}, Req1), State};
                {error, Reason} ->
                    {ok, reply_json(400, #{error => #{message => fmt(Reason)}}, Req1), State}
            end
    end;

%% GET /api/payment/orders/:id
handle(<<"GET">>, [<<"orders">>, IdBin], Req0, State) ->
    case verify_jwt(Req0) of
        {error, _} ->
            {ok, reply_json(401, #{error => #{message => <<"Auth required">>}}, Req0), State};
        {ok, _} ->
            Id = binary_to_integer(IdBin),
            case ersub_payment_srv:get_order(Id) of
                {ok, Order} ->
                    {ok, reply_json(200, #{data => Order}, Req0), State};
                {error, not_found} ->
                    {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State}
            end
    end;

%% POST /api/payment/webhooks/:provider
handle(<<"POST">>, [<<"webhooks">>, Provider], Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    logger:info("Payment webhook from ~s: ~s", [Provider, Body]),
    case jsx:is_json(Body) of
        true ->
            Payload = jsx:decode(Body, [return_maps]),
            _ = handle_webhook(Provider, Payload),
            {ok, reply_json(200, #{received => true}, Req1), State};
        false ->
            {ok, reply_json(400, #{error => #{message => <<"Invalid JSON">>}}, Req1), State}
    end;

%% POST /api/payment/redeem
handle(<<"POST">>, [<<"redeem">>], Req0, State) ->
    case verify_jwt(Req0) of
        {error, _} ->
            {ok, reply_json(401, #{error => #{message => <<"Auth required">>}}, Req0), State};
        {ok, #{<<"user_id">> := UserId}} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            #{<<"code">> := Code} = jsx:decode(Body, [return_maps]),
            case ersub_payment_srv:redeem_code(UserId, Code) of
                {ok, Amount} ->
                    {ok, reply_json(200, #{data => #{credited => Amount}}, Req1), State};
                {error, Reason} ->
                    {ok, reply_json(400, #{error => #{message => fmt(Reason)}}, Req1), State}
            end
    end;

handle(_, _, Req0, State) ->
    {ok, reply_json(404, #{error => #{message => <<"Not found">>}}, Req0), State}.

handle_webhook(<<"stripe">>, #{<<"type">> := <<"checkout.session.completed">>,
                                <<"data">> := #{<<"object">> := #{<<"id">> := SessionId}}}) ->
    %% Find order by provider_order_id and fulfill
    case ersub_repo:query(
        "SELECT id FROM payment_orders WHERE provider_order_id = $1 AND status = 'pending'",
        [SessionId]) of
        {ok, _, [{OrderId}]} ->
            ersub_payment_srv:fulfill_order(OrderId, SessionId);
        _ -> ok
    end;
handle_webhook(_, _) -> ok.

verify_jwt(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", T/binary>> -> ersub_auth_srv:verify_jwt(string:trim(T));
        _ -> {error, missing}
    end.

reply_json(S, B, R) ->
    cowboy_req:reply(S, #{<<"content-type">> => <<"application/json">>}, jsx:encode(B), R).

fmt(R) -> iolist_to_binary(io_lib:format("~p", [R])).
