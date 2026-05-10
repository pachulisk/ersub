-module(ersub_url_validator_tests).
-include_lib("eunit/include/eunit.hrl").

private_ip_test_() ->
    [
        {"10.x.x.x is private", fun() ->
            ?assert(ersub_url_validator:is_private_ip({10,0,0,1}))
        end},
        {"172.16.x.x is private", fun() ->
            ?assert(ersub_url_validator:is_private_ip({172,16,0,1}))
        end},
        {"172.15.x.x is NOT private", fun() ->
            ?assertNot(ersub_url_validator:is_private_ip({172,15,0,1}))
        end},
        {"192.168.x.x is private", fun() ->
            ?assert(ersub_url_validator:is_private_ip({192,168,1,1}))
        end},
        {"8.8.8.8 is NOT private", fun() ->
            ?assertNot(ersub_url_validator:is_private_ip({8,8,8,8}))
        end}
    ].

dns_rebinding_test_() ->
    [
        {"loopback blocked", fun() ->
            ?assertEqual({error, dns_rebinding_blocked},
                ersub_url_validator:validate_resolved_ip({127,0,0,1}))
        end},
        {"private blocked", fun() ->
            ?assertEqual({error, dns_rebinding_blocked},
                ersub_url_validator:validate_resolved_ip({10,0,0,1}))
        end},
        {"link-local blocked", fun() ->
            ?assertEqual({error, dns_rebinding_blocked},
                ersub_url_validator:validate_resolved_ip({169,254,1,1}))
        end},
        {"public IP ok", fun() ->
            ?assertEqual(ok,
                ersub_url_validator:validate_resolved_ip({8,8,8,8}))
        end}
    ].

url_validation_test_() ->
    {setup,
     fun() ->
         application:ensure_all_started(yamerl),
         {ok, _} = ersub_config_srv:start_link("config/ersub.yaml")
     end,
     fun(_) -> ok end,
     [
         {"https OK", fun() ->
             ?assertEqual(ok,
                 ersub_url_validator:validate_upstream_url(
                     <<"https://api.anthropic.com/v1/messages">>))
         end},
         {"http blocked by default", fun() ->
             ?assertEqual({error, https_required},
                 ersub_url_validator:validate_upstream_url(
                     <<"http://api.anthropic.com">>))
         end},
         {"invalid scheme", fun() ->
             ?assertEqual({error, invalid_scheme},
                 ersub_url_validator:validate_upstream_url(
                     <<"ftp://files.example.com">>))
         end}
     ]}.
