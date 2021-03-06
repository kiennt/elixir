%% Translate Elixir quoted expressions to Erlang Abstract Format.
%% Expects the tree to be expanded.
-module(elixir_translator).
-export([translate/2, translate_arg/3, translate_args/2]).
-import(elixir_scope, [mergev/2, mergec/2]).
-include("elixir.hrl").

%% =

translate({'=', Meta, [{'_', _, Atom}, Right]}, S) when is_atom(Atom) ->
  {TRight, SR} = translate(Right, S),
  {{match, ?ann(Meta), {var, ?ann(Meta), '_'}, TRight}, SR};

translate({'=', Meta, [Left, Right]}, S) ->
  {TRight, SR} = translate(Right, S),
  {TLeft, SL} = elixir_clauses:match(fun translate/2, Left, SR),
  {{match, ?ann(Meta), TLeft, TRight}, SL};

%% Containers

translate({'{}', Meta, Args}, S) when is_list(Args) ->
  {TArgs, SE} = translate_args(Args, S),
  {{tuple, ?ann(Meta), TArgs}, SE};

translate({'%{}', Meta, Args}, S) when is_list(Args) ->
  translate_map(Meta, Args, S);

translate({'%', Meta, [Left, Right]}, S) ->
  translate_struct(Meta, Left, Right, S);

translate({'<<>>', Meta, Args}, S) when is_list(Args) ->
  elixir_bitstring:translate(Meta, Args, S);

%% Blocks

translate({'__block__', Meta, Args}, S) when is_list(Args) ->
  {TArgs, SA} = translate_block(Args, [], S),
  {{block, ?ann(Meta), TArgs}, SA};

%% Compilation environment macros

translate({'__CALLER__', Meta, Atom}, S) when is_atom(Atom) ->
  {{var, ?ann(Meta), '__CALLER__'}, S#elixir_scope{caller=true}};

%% Functions

translate({'&', Meta, [{'/', _, [{{'.', _, [Remote, Fun]}, _, []}, Arity]}]}, S)
    when is_atom(Fun), is_integer(Arity) ->
  {TRemote, SR} = translate(Remote, S),
  Ann = ?ann(Meta),
  TFun = {atom, Ann, Fun},
  TArity = {integer, Ann, Arity},
  {{'fun', Ann, {function, TRemote, TFun, TArity}}, SR};
translate({'&', Meta, [{'/', _, [{Fun, _, Atom}, Arity]}]}, S)
    when is_atom(Fun), is_atom(Atom), is_integer(Arity) ->
  {{'fun', ?ann(Meta), {function, Fun, Arity}}, S};

translate({fn, Meta, Clauses}, S) ->
  Transformer = fun({'->', CMeta, [ArgsWithGuards, Expr]}, Acc) ->
    {Args, Guards} = elixir_clauses:extract_splat_guards(ArgsWithGuards),
    {TClause, TS } = elixir_clauses:clause(CMeta, fun translate_fn_match/2,
                                            Args, Expr, Guards, Acc),
    {TClause, elixir_scope:mergec(S, TS)}
  end,
  {TClauses, NS} = lists:mapfoldl(Transformer, S, Clauses),
  {{'fun', ?ann(Meta), {clauses, TClauses}}, NS};

%% Cond

translate({'cond', CondMeta, [[{do, Pairs}]]}, S) ->
  [{'->', Meta, [[Condition], Body]} = H | T] = lists:reverse(Pairs),

  Case =
    case Condition of
      X when is_atom(X) and (X /= false) and (X /= nil) ->
        build_cond_clauses(T, Body, Meta);
      _ ->
        Error = {{'.', Meta, [erlang, error]}, [], [cond_clause]},
        build_cond_clauses([H | T], Error, Meta)
    end,
  translate(replace_case_meta(CondMeta, Case), S);

%% Case

translate({'case', Meta, [Expr, KV]}, S) ->
  Clauses = elixir_clauses:get_pairs(do, KV, match),
  {TExpr, NS} = translate(Expr, S),
  {TClauses, TS} = elixir_clauses:clauses(Meta, Clauses, NS#elixir_scope{extra=nil}),
  {{'case', ?ann(Meta), TExpr, TClauses}, TS#elixir_scope{extra=NS#elixir_scope.extra}};

%% Try

translate({'try', Meta, [Clauses]}, S) ->
  SN = S#elixir_scope{extra=nil},
  Do = proplists:get_value('do', Clauses, nil),
  {TDo, SB} = elixir_translator:translate(Do, SN),

  Catch = [Tuple || {X, _} = Tuple <- Clauses, X == 'rescue' orelse X == 'catch'],
  {TCatch, SC} = elixir_try:clauses(Meta, Catch, mergec(SN, SB)),

  {TAfter, SA} = case lists:keyfind('after', 1, Clauses) of
    {'after', After} ->
      {TBlock, SAExtracted} = translate(After, mergec(SN, SC)),
      {unblock(TBlock), SAExtracted};
    false ->
      {[], mergec(SN, SC)}
  end,

  Else = elixir_clauses:get_pairs(else, Clauses, match),
  {TElse, SE} = elixir_clauses:clauses(Meta, Else, mergec(SN, SA)),
  {{'try', ?ann(Meta), unblock(TDo), TElse, TCatch, TAfter}, mergec(S, SE)};

%% Receive

translate({'receive', Meta, [KV]}, S) ->
  Do = elixir_clauses:get_pairs(do, KV, match, true),

  case lists:keyfind('after', 1, KV) of
    false ->
      {TClauses, SC} = elixir_clauses:clauses(Meta, Do, S),
      {{'receive', ?ann(Meta), TClauses}, SC};
    _ ->
      After = elixir_clauses:get_pairs('after', KV, expr),
      {TClauses, SC} = elixir_clauses:clauses(Meta, Do ++ After, S),
      {FClauses, TAfter} = elixir_utils:split_last(TClauses),
      {_, _, [FExpr], _, FAfter} = TAfter,
      {{'receive', ?ann(Meta), FClauses, FExpr, FAfter}, SC}
  end;

%% Comprehensions

translate({for, Meta, [_ | _] = Args}, S) ->
  elixir_for:translate(Meta, Args, true, S);

%% With

translate({with, Meta, [_ | _] = Args}, S) ->
  elixir_with:translate(Meta, Args, S);

%% Variables

translate({'^', Meta, [{Name, VarMeta, Kind}]}, #elixir_scope{context=match, file=File} = S) when is_atom(Name), is_atom(Kind) ->
  Tuple = {Name, var_kind(VarMeta, Kind)},
  {ok, {Value, _Counter, Safe}} = maps:find(Tuple, S#elixir_scope.backup_vars),
  elixir_scope:warn_underscored_var_access(VarMeta, File, Name),
  elixir_scope:warn_unsafe_var(VarMeta, File, Name, Safe),

  PAnn = ?ann(Meta),
  PVar = {var, PAnn, Value},

  case S#elixir_scope.extra of
    pin_guard ->
      {TVar, TS} = elixir_scope:translate_var(VarMeta, Name, var_kind(VarMeta, Kind), S),
      Guard = {op, PAnn, '=:=', PVar, TVar},
      {TVar, TS#elixir_scope{extra_guards=[Guard | TS#elixir_scope.extra_guards]}};
    _ ->
      {PVar, S}
  end;

translate({'_', Meta, Kind}, #elixir_scope{context=match} = S) when is_atom(Kind) ->
  {{var, ?ann(Meta), '_'}, S};

translate({Name, Meta, Kind}, S) when is_atom(Name), is_atom(Kind) ->
  elixir_scope:translate_var(Meta, Name, var_kind(Meta, Kind), S);

%% Local calls

translate({Name, Meta, Args}, S) when is_atom(Name), is_list(Meta), is_list(Args) ->
  Ann = ?ann(Meta),
  {TArgs, NS} = translate_args(Args, S),
  {{call, Ann, {atom, Ann, Name}, TArgs}, NS};

%% Remote calls

translate({{'.', _, [Left, Right]}, Meta, []}, S)
    when is_tuple(Left), is_atom(Right), is_list(Meta) ->
  {TLeft, SL}  = translate(Left, S),
  {Var, _, SV} = elixir_scope:build_var('_', SL),

  Ann = ?ann(Meta),
  Generated = ?generated(Meta),
  TRight = {atom, Ann, Right},
  TVar = {var, Ann, Var},
  TError = {tuple, Ann, [{atom, Ann, badkey}, TRight, TVar]},

  %% TODO: there is a bug in Dialyzer that warns about generated matches that
  %% can never match on line 0. The is_map/1 guard is used instead of matching
  %% against an empty map to avoid the warning.
  {{'case', Generated, TLeft, [
    {clause, Generated,
      [{map, Ann, [{map_field_exact, Ann, TRight, TVar}]}],
      [],
      [TVar]},
    {clause, ?generated,
      [TVar],
      [[elixir_utils:erl_call(?generated, erlang, is_map, [TVar])]],
      [elixir_utils:erl_call(Ann, erlang, error, [TError])]},
    {clause, Generated,
      [TVar],
      [],
      [{call, Generated, {remote, Generated, TVar, TRight}, []}]}
  ]}, SV};

translate({{'.', _, [Left, Right]}, Meta, Args}, S)
    when (is_tuple(Left) orelse is_atom(Left)), is_atom(Right), is_list(Meta), is_list(Args) ->
  {TLeft, SL} = translate(Left, S),
  {TArgs, SA} = translate_args(Args, mergec(S, SL)),

  Ann    = ?ann(Meta),
  Arity  = length(Args),
  TRight = {atom, Ann, Right},
  SC = mergev(SL, SA),

  %% Rewrite Erlang function calls as operators so they
  %% work on guards, matches and so on.
  case (Left == erlang) andalso elixir_utils:guard_op(Right, Arity) of
    true ->
      case TArgs of
        [TOne]       -> {{op, Ann, Right, TOne}, SC};
        [TOne, TTwo] -> {{op, Ann, Right, TOne, TTwo}, SC}
      end;
    false ->
      {{call, Ann, {remote, Ann, TLeft, TRight}, TArgs}, SC}
  end;

%% Anonymous function calls

translate({{'.', _, [Expr]}, Meta, Args}, S) when is_list(Args) ->
  {TExpr, SE} = translate(Expr, S),
  {TArgs, SA} = translate_args(Args, mergec(S, SE)),
  {{call, ?ann(Meta), TExpr, TArgs}, mergev(SE, SA)};

%% Literals

translate(List, S) when is_list(List) ->
  Fun = case S#elixir_scope.context of
    match -> fun translate/2;
    _     -> fun(X, Acc) -> translate_arg(X, Acc, S) end
  end,
  translate_list(List, Fun, S, []);

translate({Left, Right}, S) ->
  {TArgs, SE} = translate_args([Left, Right], S),
  {{tuple, 0, TArgs}, SE};

translate(Other, S) ->
  {elixir_utils:elixir_to_erl(Other), S}.

%% Helpers

translate_list([{'|', _, [_, _]=Args}], Fun, Acc, List) ->
  {[TLeft, TRight], TAcc} = lists:mapfoldl(Fun, Acc, Args),
  {build_list([TLeft | List], TRight), TAcc};
translate_list([H | T], Fun, Acc, List) ->
  {TH, TAcc} = Fun(H, Acc),
  translate_list(T, Fun, TAcc, [TH | List]);
translate_list([], _Fun, Acc, List) ->
  {build_list(List, {nil, 0}), Acc}.

build_list([H | T], Acc) ->
  build_list(T, {cons, 0, H, Acc});
build_list([], Acc) ->
  Acc.

var_kind(Meta, Kind) ->
  case lists:keyfind(counter, 1, Meta) of
    {counter, Counter} -> Counter;
    false -> Kind
  end.

%% Pack a list of expressions from a block.
unblock({'block', _, Exprs}) -> Exprs;
unblock(Expr)                -> [Expr].

translate_fn_match(Arg, S) ->
  {TArg, TS} = elixir_translator:translate_args(Arg, S#elixir_scope{extra=pin_guard}),
  {TArg, TS#elixir_scope{extra=S#elixir_scope.extra}}.

%% Translate args

translate_arg(Arg, Acc, S) when is_number(Arg); is_atom(Arg); is_binary(Arg); is_pid(Arg); is_function(Arg) ->
  {TArg, _} = translate(Arg, S),
  {TArg, Acc};
translate_arg(Arg, Acc, S) ->
  {TArg, TAcc} = translate(Arg, mergec(S, Acc)),
  {TArg, mergev(Acc, TAcc)}.

translate_args(Args, #elixir_scope{context=match} = S) ->
  lists:mapfoldl(fun translate/2, S, Args);

translate_args(Args, S) ->
  lists:mapfoldl(fun(X, Acc) -> translate_arg(X, Acc, S) end, S, Args).

%% Translate blocks

translate_block([], Acc, S) ->
  {lists:reverse(Acc), S};
translate_block([H], Acc, S) ->
  {TH, TS} = translate(H, S),
  translate_block([], [TH | Acc], TS);
translate_block([{'__block__', _Meta, Args} | T], Acc, S) when is_list(Args) ->
  translate_block(Args ++ T, Acc, S);
translate_block([{for, Meta, [_ | _] = Args} | T], Acc, S) ->
  {TH, TS} = elixir_for:translate(Meta, Args, false, S),
  translate_block(T, [TH | Acc], TS);
translate_block([{'=', _, [{'_', _, Ctx}, {for, Meta, [_ | _] = Args}]} | T], Acc, S) when is_atom(Ctx) ->
  {TH, TS} = elixir_for:translate(Meta, Args, false, S),
  translate_block(T, [TH | Acc], TS);
translate_block([H | T], Acc, S) ->
  {TH, TS} = translate(H, S),
  translate_block(T, [TH | Acc], TS).

%% Cond

build_cond_clauses([{'->', NewMeta, [[Condition], Body]} | T], Acc, OldMeta) ->
  {NewCondition, Truthy, Other} = build_truthy_clause(NewMeta, Condition, Body),
  Falsy = {'->', OldMeta, [[Other], Acc]},
  Case = {'case', NewMeta, [NewCondition, [{do, [Truthy, Falsy]}]]},
  build_cond_clauses(T, Case, NewMeta);
build_cond_clauses([], Acc, _) ->
  Acc.

replace_case_meta(Meta, {'case', _, Args}) ->
  {'case', Meta, Args};
replace_case_meta(_Meta, Other) ->
  Other.

build_truthy_clause(Meta, Condition, Body) ->
  case returns_boolean(Condition, Body) of
    {NewCondition, NewBody} ->
      {NewCondition, {'->', Meta, [[true], NewBody]}, false};
    false ->
      Var  = {'cond', [], 'Elixir'},
      Head = {'when', [], [Var,
        {{'.', [], [erlang, 'andalso']}, [], [
          {{'.', [], [erlang, '/=']}, [], [Var, nil]},
          {{'.', [], [erlang, '/=']}, [], [Var, false]}
        ]}
      ]},
      {Condition, {'->', Meta, [[Head], Body]}, {'_', [], nil}}
  end.

%% In case a variable is defined to match in a condition
%% but a condition returns boolean, we can replace the
%% variable directly by the boolean result.
returns_boolean({'=', _, [{Var, _, Ctx}, Condition]}, {Var, _, Ctx}) when is_atom(Var), is_atom(Ctx) ->
  case elixir_utils:returns_boolean(Condition) of
    true  -> {Condition, true};
    false -> false
  end;

%% For all other cases, we check the condition but
%% return both condition and body untouched.
returns_boolean(Condition, Body) ->
  case elixir_utils:returns_boolean(Condition) of
    true  -> {Condition, Body};
    false -> false
  end.

%% Maps and structs

translate_map(Meta, [{'|', _Meta, [Update, Assocs]}], S) ->
  {TUpdate, US} = translate_arg(Update, S, S),
  translate_map(Meta, Assocs, {ok, TUpdate}, US);
translate_map(Meta, Assocs, S) ->
  translate_map(Meta, Assocs, none, S).

translate_struct(Meta, Name, {'%{}', _, [{'|', _, [Update, Assocs]}]}, S) ->
  Ann = ?ann(Meta),
  Generated = ?generated(Meta),
  {VarName, _, VS} = elixir_scope:build_var('_', S),

  Var = {var, Ann, VarName},
  Map = {map, Ann, [{map_field_exact, Ann, {atom, Ann, '__struct__'}, {atom, Ann, Name}}]},

  Match = {match, Ann, Var, Map},
  Error = {tuple, Ann, [{atom, Ann, badstruct}, {atom, Ann, Name}, Var]},

  {TUpdate, US} = translate_arg(Update, VS, VS),
  {TAssocs, TS} = translate_map(Meta, Assocs, {ok, Var}, US),

  {{'case', Generated, TUpdate, [
    {clause, Ann, [Match], [], [TAssocs]},
    {clause, Generated, [Var], [], [elixir_utils:erl_call(Ann, erlang, error, [Error])]}
  ]}, TS};
translate_struct(Meta, Name, {'%{}', _, Assocs}, S) ->
  translate_map(Meta, Assocs ++ [{'__struct__', Name}], none, S).

translate_map(Meta, Assocs, TUpdate, #elixir_scope{extra=Extra} = S) ->
  {Op, KeyFun, ValFun} = translate_key_val_op(TUpdate, S),
  Ann = ?ann(Meta),

  {TArgs, SA} = lists:mapfoldl(fun({Key, Value}, Acc) ->
    {TKey, Acc1}   = KeyFun(Key, Acc),
    {TValue, Acc2} = ValFun(Value, Acc1#elixir_scope{extra=Extra}),
    {{Op, ?ann(Meta), TKey, TValue}, Acc2}
  end, S, Assocs),

  build_map(Ann, TUpdate, TArgs, SA).

translate_key_val_op(_TUpdate, #elixir_scope{extra=map_key}) ->
  {map_field_assoc,
    fun(X, Acc) -> translate(X, Acc#elixir_scope{extra=map_key}) end,
    fun translate/2};
translate_key_val_op(_TUpdate, #elixir_scope{context=match}) ->
  {map_field_exact,
    fun(X, Acc) -> translate(X, Acc#elixir_scope{extra=map_key}) end,
    fun translate/2};
translate_key_val_op(TUpdate, S) ->
  KS = S#elixir_scope{extra=map_key},
  Op = if TUpdate == none -> map_field_assoc; true -> map_field_exact end,
  {Op,
    fun(X, Acc) -> translate_arg(X, Acc, KS) end,
    fun(X, Acc) -> translate_arg(X, Acc, S) end}.

build_map(Ann, {ok, TUpdate}, TArgs, SA) -> {{map, Ann, TUpdate, TArgs}, SA};
build_map(Ann, none, TArgs, SA) -> {{map, Ann, TArgs}, SA}.
