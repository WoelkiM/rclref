-module(rclref_vnode).

-behaviour(riak_core_vnode).

-include_lib("stdlib/include/assert.hrl").

-export([start_vnode/1, init/1, terminate/2, handle_command/3, is_empty/1, delete/1,
         handle_handoff_command/3, handoff_starting/2, handoff_cancelled/1, handoff_finished/2,
         handle_handoff_data/2, encode_handoff_item/2, handle_overload_command/3,
         handle_overload_info/2, handle_coverage/4, handle_exit/3]).

-ignore_xref([{start_vnode, 1}]).

-record(state, {index, mod, modstate}).

-record(riak_core_fold_req_v2, {
          foldfun :: fun(),
          acc0 :: term(),
          forwardable :: boolean(),
          opts = [] :: list()}).

-define(FOLD_REQ, #riak_core_fold_req_v2).

%% API
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Index]) ->
    %TODO: Get model from config
    Mod = case rclref_config:storage_backend() of
            ets ->
                rclref_ets_backend;
            _ ->
                ?assert(false)
          end,

    {ok, ModState} = Mod:start(Index, undefined),
    logger:debug("Successfully started ~p backend for index ~p", [Mod, Index]),
    State = #state{index = Index, mod = Mod, modstate = ModState},
    {ok, State}.

%% Sample command: respond to a ping
handle_command(ping, _Sender, State) ->
    {reply, {pong, node(), State#state.index}, State};
handle_command({kv_put_request, Key, Value, Pid},
               _Sender,
               State0 = #state{index = Index, mod = Mod, modstate = ModState0}) ->
    case Mod:put(Key, Value, ModState0) of
      {ok, ModState1} ->
          rclref_put_statem:result_of_put(Pid, {ok, ok}),
          State1 = State0#state{modstate = ModState1},
          {noreply, State1};
      {error, Reason, ModState1} ->
          logger:error("Failed to put kv with key: ~p, value: ~p for index: ~p, error: ~p",
                       [Key, Value, Index, Reason]),
          rclref_put_statem:result_of_put(Pid, {error, vnode_error}),
          State1 = State0#state{modstate = ModState1},
          {noreply, State1}
    end;
handle_command({kv_get_request, Key, Pid},
               _Sender,
               State0 = #state{index = Index, mod = Mod, modstate = ModState0}) ->
    case Mod:get(Key, ModState0) of
      {ok, not_found, ModState1} ->
          ok = rclref_get_statem:result_of_get(Pid, {error, not_found}),
          State1 = State0#state{modstate = ModState1},
          {noreply, State1};
      {ok, Value, ModState1} ->
          case Value of
            undefined ->
                ok = rclref_get_statem:result_of_get(Pid, {error, not_found});
            _ ->
                RObj = rclref_object:new(Key, Value),
                ok = rclref_get_statem:result_of_get(Pid, {ok, RObj})
          end,
          State1 = State0#state{modstate = ModState1},
          {noreply, State1};
      {error, Reason, ModState1} ->
          logger:error("Failed to get kv with key: ~p for index: ~p, error: ~p",
                       [Key, Index, Reason]),
          rclref_get_statem:result_of_get(Pid, {error, vnode_error}),
          State1 = State0#state{modstate = ModState1},
          {noreply, State1}
    end;
handle_command(Message, _Sender, State) ->
    logger:warning("unhandled_command ~p", [Message]),
    {noreply, State}.

handle_handoff_command(?FOLD_REQ{foldfun=FoldFun, acc0=Acc0}, _Sender, State = #state{mod = Mod, modstate = ModState}) ->
    % FoldFun 
    % -type fold_objects_fun() :: fun((term(), term(), any()) -> any() | no_return()).
    Acc = Mod:fold_objects(FoldFun, Acc0, [], ModState),
    {reply, Acc, State};
handle_handoff_command(Message, _Sender, State) ->
    logger:warning("handoff command ~p, ignoring", [Message]),
    {noreply, State}.

handoff_starting(TargetNode, State = #state{index = Index}) ->
    logger:info("handoff starting ~p: ~p", [Index, TargetNode]),
    {true, State}.

handoff_cancelled(State = #state{index = Index}) ->
    logger:info("handoff cancelled ~p", [Index]),
    {ok, State}.

handoff_finished(TargetNode, State = #state{index = Index}) ->
    logger:info("handoff finished ~p: ~p", [Index, TargetNode]),
    {ok, State}.

handle_handoff_data(BinData, State0 = #state{index = Index, mod = Mod, modstate = ModState0}) ->
    {Key, Value} = binary_to_term(BinData),
    logger:info("handoff data received ~p: ~p", [Index, Key]),
    {ok, ModState1} = Mod:put(Key, Value, ModState0),
    State1 = State0#state{modstate = ModState1},
    {reply, ok, State1}.

encode_handoff_item(Key, Value) ->
    term_to_binary({Key, Value}).

handle_overload_command(_, _, _) ->
    ok.

handle_overload_info(_, _Idx) ->
    ok.

is_empty(State = #state{mod = Mod, modstate = ModState}) ->
    case Mod:is_empty(ModState) of
        true ->
            logger:info("is_empty: ~p", [true]),
            {true, State};
        false ->
            logger:info("is_empty: ~p", [false]),
            {false, State};
        Other ->
            logger:error("is_empty error reason :~p", [Other]),
            {false, State}
    end.
                
delete(State0 = #state{index = Index, mod = Mod, modstate = ModState0 }) ->
    logger:info("delete index: ~p", [Index]),
    {ok, ModState1} = Mod:drop(ModState0),
    ok = Mod:stop(ModState1),
    State1 = State0#state{modstate = ModState1},
    {ok, State1}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
