-module(elixir_fn).
-export([capture/3, expand/3]).
-import(elixir_errors, [compile_error/3, compile_error/4]).
-include("elixir.hrl").

expand(Meta, Clauses, E) when is_list(Clauses) ->
  Transformer = fun(Clause) ->
    {EClause, _} = elixir_exp_clauses:clause(Meta, fn, fun elixir_exp_clauses:head/2, Clause, E),
    EClause
  end,

  EClauses = lists:map(Transformer, Clauses),
  EArities = [fn_arity(Args) || {'->', _, [Args, _]} <- EClauses],

  case lists:usort(EArities) of
    [_] ->
      {{fn, Meta, EClauses}, E};
    _ ->
      compile_error(Meta, ?m(E, file),
                    "cannot mix clauses with different arities in anonymous functions")
  end.

fn_arity([{'when', _, Args}]) -> length(Args) - 1;
fn_arity(Args) -> length(Args).

%% Capture

capture(Meta, {'/', _, [{{'.', _, [_, F]} = Dot, RequireMeta, []}, A]}, E) when is_atom(F), is_integer(A) ->
  Args = args_from_arity(Meta, A, E),
  capture_require(Meta, {Dot, RequireMeta, Args}, E, true);

capture(Meta, {'/', _, [{F, _, C}, A]}, E) when is_atom(F), is_integer(A), is_atom(C) ->
  Args = args_from_arity(Meta, A, E),
  ImportMeta =
    case lists:keyfind(import_fa, 1, Meta) of
      {import_fa, {Receiver, Context}} ->
        lists:keystore(context, 1,
          lists:keystore(import, 1, Meta, {import, Receiver}),
          {context, Context}
        );
      false -> Meta
    end,
  capture_import(Meta, {F, ImportMeta, Args}, E, true);

capture(Meta, {{'.', _, [_, Fun]}, _, Args} = Expr, E) when is_atom(Fun), is_list(Args) ->
  capture_require(Meta, Expr, E, is_sequential_and_not_empty(Args));

capture(Meta, {{'.', _, [_]}, _, Args} = Expr, E) when is_list(Args) ->
  capture_expr(Meta, Expr, E, false);

capture(Meta, {'__block__', _, [Expr]}, E) ->
  capture(Meta, Expr, E);

capture(Meta, {'__block__', _, _} = Expr, E) ->
  Message = "invalid args for &, block expressions are not allowed, got: ~ts",
  compile_error(Meta, ?m(E, file), Message, ['Elixir.Macro':to_string(Expr)]);

capture(Meta, {Atom, _, Args} = Expr, E) when is_atom(Atom), is_list(Args) ->
  capture_import(Meta, Expr, E, is_sequential_and_not_empty(Args));

capture(Meta, {Left, Right}, E) ->
  capture(Meta, {'{}', Meta, [Left, Right]}, E);

capture(Meta, List, E) when is_list(List) ->
  capture_expr(Meta, List, E, is_sequential_and_not_empty(List));

capture(Meta, Integer, E) when is_integer(Integer) ->
  compile_error(Meta, ?m(E, file), "unhandled &~B outside of a capture", [Integer]);

capture(Meta, Arg, E) ->
  invalid_capture(Meta, Arg, E).

capture_import(Meta, {Atom, ImportMeta, Args} = Expr, E, Sequential) ->
  Res = Sequential andalso
        elixir_dispatch:import_function(ImportMeta, Atom, length(Args), E),
  handle_capture(Res, Meta, Expr, E, Sequential).

capture_require(Meta, {{'.', DotMeta, [Left, Right]}, RequireMeta, Args}, E, Sequential) ->
  Counter = erlang:unique_integer(),
  case escape(Left, Counter, E, []) of
    {EscLeft, []} ->
      {ELeft, EE} = elixir_exp:expand(EscLeft, E),
      Res = Sequential andalso case ELeft of
        {Name, _, Context} when is_atom(Name), is_atom(Context) ->
          {remote, ELeft, Right, length(Args)};
        _ when is_atom(ELeft) ->
          elixir_dispatch:require_function(RequireMeta, ELeft, Right, length(Args), EE);
        _ ->
          false
      end,
      handle_capture(Res, Meta, {{'.', DotMeta, [ELeft, Right]}, RequireMeta, Args},
                     EE, Sequential);
    {EscLeft, Escaped} ->
      capture_expr(Meta, {{'.', DotMeta, [EscLeft, Right]}, RequireMeta, Args},
                   Counter, E, Escaped, Sequential)
  end.

handle_capture(false, Meta, Expr, E, Sequential) ->
  capture_expr(Meta, Expr, E, Sequential);
handle_capture(LocalOrRemote, _Meta, _Expr, _E, _Sequential) ->
  LocalOrRemote.

capture_expr(Meta, Expr, E, Sequential) ->
  capture_expr(Meta, Expr, erlang:unique_integer(), E, [], Sequential).
capture_expr(Meta, Expr, Counter, E, Escaped, Sequential) ->
  case escape(Expr, Counter, E, Escaped) of
    {_, []} when not Sequential ->
      invalid_capture(Meta, Expr, E);
    {EExpr, EDict} ->
      EVars = validate(Meta, EDict, 1, E),
      Fn = {fn, Meta, [{'->', Meta, [EVars, EExpr]}]},
      {expand, Fn, E}
  end.

invalid_capture(Meta, Arg, E) ->
  Message = "invalid args for &, expected an expression in the format of &Mod.fun/arity, "
            "&local/arity or a capture containing at least one argument as &1, got: ~ts",
  compile_error(Meta, ?m(E, file), Message, ['Elixir.Macro':to_string(Arg)]).

validate(Meta, [{Pos, Var} | T], Pos, E) ->
  [Var | validate(Meta, T, Pos + 1, E)];
validate(Meta, [{Pos, _} | _], Expected, E) ->
  compile_error(Meta, ?m(E, file), "capture &~B cannot be defined without &~B", [Pos, Expected]);
validate(_Meta, [], _Pos, _E) ->
  [].

escape({'&', _, [Pos]}, Counter, _E, Dict) when is_integer(Pos), Pos > 0 ->
  Var = {list_to_atom([$x | integer_to_list(Pos)]), [{counter, Counter}], elixir_fn},
  {Var, orddict:store(Pos, Var, Dict)};
escape({'&', Meta, [Pos]}, _Counter, E, _Dict) when is_integer(Pos) ->
  compile_error(Meta, ?m(E, file), "capture &~B is not allowed", [Pos]);
escape({'&', Meta, _} = Arg, _Counter, E, _Dict) ->
  Message = "nested captures via & are not allowed: ~ts",
  compile_error(Meta, ?m(E, file), Message, ['Elixir.Macro':to_string(Arg)]);
escape({Left, Meta, Right}, Counter, E, Dict0) ->
  {TLeft, Dict1}  = escape(Left, Counter, E, Dict0),
  {TRight, Dict2} = escape(Right, Counter, E, Dict1),
  {{TLeft, Meta, TRight}, Dict2};
escape({Left, Right}, Counter, E, Dict0) ->
  {TLeft, Dict1}  = escape(Left, Counter, E, Dict0),
  {TRight, Dict2} = escape(Right, Counter, E, Dict1),
  {{TLeft, TRight}, Dict2};
escape(List, Counter, E, Dict) when is_list(List) ->
  lists:mapfoldl(fun(X, Acc) -> escape(X, Counter, E, Acc) end, Dict, List);
escape(Other, _Counter, _E, Dict) ->
  {Other, Dict}.

args_from_arity(_Meta, A, _E) when is_integer(A), A >= 0, A =< 255 ->
  [{'&', [], [X]} || X <- lists:seq(1, A)];
args_from_arity(Meta, A, E) ->
  Message = "invalid arity for &, expected a number between 0 and 255, got: ~b",
  compile_error(Meta, ?m(E, file), Message, [A]).

is_sequential_and_not_empty([])   -> false;
is_sequential_and_not_empty(List) -> is_sequential(List, 1).

is_sequential([{'&', _, [Int]} | T], Int) -> is_sequential(T, Int + 1);
is_sequential([], _Int) -> true;
is_sequential(_, _Int) -> false.
