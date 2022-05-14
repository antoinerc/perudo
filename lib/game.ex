defmodule Perudex.Game do
  @moduledoc """
  Provides functions to manipulate a game of Perudex.
  """
  alias __MODULE__

  alias Perudex.Hand

  defstruct [
    :current_player_id,
    :all_players,
    :remaining_players,
    :current_bid,
    :players_hands,
    :max_dice,
    :instructions
  ]

  @opaque t :: %Game{
            current_player_id: player_id,
            all_players: [player_id],
            current_bid: bid,
            remaining_players: [player_id],
            players_hands: [%{player_id: player_id, hand: Hand.t()}],
            max_dice: integer(),
            instructions: [instruction]
          }

  @type player_id :: any
  @type move :: {:outbid, bid} | :calza | :dudo
  @type instruction :: {:notify_player, player_id, player_instruction}
  @type bid :: {:count, :die}
  @type move_result :: {:outbid, bid} | {:calza, boolean} | {:dudo, boolean}

  @type player_instruction ::
          :move
          | {:reveal_players_hands, [{player_id, Hand.t()}]}
          | {:last_move, player_id, move_result}
          | :unauthorized_move
          | :invalid_bid
          | :illegal_move
          | {:new_hand, Hand.t()}
          | {:winner, player_id}
          | {:loser, player_id}
          | {:game_started, [player_id]}

  @doc """
  Initialize a game of Perudo with `players_ids` and specified `max_dice` a player can hold.

  Returns a tuple containing a list of `Perudex.Game.player_instruction()` and a `Perudex.Game` struct.

  ## Examples
      iex>
      :rand.seed(:exsplus, {101, 102, 103})
      Perudex.Game.start([1, 2], 5)
      {[
        {:notify_player, 1, {:game_started, [1, 2]}},
        {:notify_player, 2, {:game_started, [1, 2]}},
        {:notify_player, 1, {:new_hand, %Perudex.Hand{dice: [5, 5, 2, 6, 4], remaining_dice: 5}}},
        {:notify_player, 2, {:new_hand, %Perudex.Hand{dice: [1, 3, 6, 4, 2], remaining_dice: 5}}},
        {:notify_player, 1, :move}
      ],
      %Perudex.Game{
        all_players: [1, 2],
        current_bid: {0, 0},
        current_player_id: 1,
        instructions: [],
        max_dice: 5,
        players_hands: [
          %{
            hand: %Perudex.Hand{dice: [5, 5, 2, 6, 4], remaining_dice: 5},
            player_id: 1
          },
          %{
            hand: %Perudex.Hand{dice: [1, 3, 6, 4, 2], remaining_dice: 5},
            player_id: 2
          }
        ],
        remaining_players: [1, 2]
      }}
  """
  @spec start([player_id], integer) :: {[player_instruction], Perudex.Game.t()}
  def start(player_ids, max_dice) do
    %Game{
      current_player_id: hd(player_ids),
      all_players: player_ids,
      remaining_players: player_ids,
      players_hands: [],
      max_dice: max_dice,
      instructions: []
    }
    |> initialize_players_hands()
    |> warn_game_start()
    |> start_round(hd(player_ids))
    |> instructions_and_state()
  end

  @doc """
  Play a Perudo `move` on the current game.

  A move can either be an outbid, a calza (exactly the same amount of dice as the previous bid) or a dudo (bid is too ambitious).
  ## Examples
      iex> Perudex.Game.play_move(
      ...> %Perudex.Game{
      ...>    all_players: [1, 2],
      ...>    current_bid: {2, 3},
      ...>    current_player_id: 2,
      ...>    instructions: [],
      ...>    max_dice: 5,
      ...>    players_hands: [
      ...>      %{
      ...>        hand: %Perudex.Hand{dice: [2, 4, 2, 5, 6], remaining_dice: 5},
      ...>        player_id: 1
      ...>      },
      ...>      %{
      ...>        hand: %Perudex.Hand{dice: [1, 3, 4, 4, 5], remaining_dice: 5},
      ...>        player_id: 2
      ...>      }
      ...>    ],
      ...>    remaining_players: [1, 2]
      ...>  },
      ...>  1,
      ...>  {:outbid, {2, 3}})

      {[
        {:notify_player, 1, {:last_move, 1, {:outbid, {2, 3}}}},
        {:notify_player, 2, {:last_move, 1, {:outbid, {2, 3}}}},
        {:notify_player, 2, :move}
      ],
      %Perudex.Game{
        all_players: [1, 2],
        current_bid: {2, 3},
        current_player_id: 2,
        instructions: [],
        max_dice: 5,
        players_hands: [
          %{
            hand: %Perudex.Hand{dice: [2, 4, 2, 5, 6], remaining_dice: 5},
            player_id: 1
          },
          %{
            hand: %Perudex.Hand{dice: [1, 3, 4, 4, 5], remaining_dice: 5},
            player_id: 2
          }
        ],
        remaining_players: [1, 2]
      }}
  """
  @spec play_move(t, player_id, move) :: {[instruction], t()}
  def play_move(%Game{current_player_id: player_id} = game, player_id, move) do
    %Game{game | instructions: []}
    |> handle_move(move)
  end

  def play_move(game, player_id, _move) do
    %Game{game | instructions: []}
    |> notify_player(player_id, :unauthorized_move)
    |> take_instructions()
  end

  defp handle_move(game, {:outbid, bid} = move) do
    case outbid(game, bid) do
      {:ok, game} ->
        game
        |> notify_players({:last_move, game.current_player_id, move})
        |> find_next_player()
        |> instructions_and_state()

      {:error, game} ->
        game
        |> notify_player(game.current_player_id, :invalid_bid)
        |> take_instructions()
    end
  end

  defp handle_move(game, :calza) do
    move_initiator = game.current_player_id

    case calza(game) do
      {:ok, game, success_status} ->
        game
        |> notify_players({:last_move, move_initiator, {:calza, success_status}})
        |> reveal_players_hands()
        |> check_for_loser()
        |> start_round(game.current_player_id)
        |> instructions_and_state()

      {:error, game} ->
        game
        |> notify_player(game.current_player_id, :illegal_move)
        |> take_instructions()
    end
  end

  defp handle_move(game, :dudo) do
    move_initiator = game.current_player_id

    case dudo(game) do
      {:ok, game, success_status} ->
        game
        |> notify_players({:last_move, move_initiator, {:dudo, success_status}})
        |> reveal_players_hands()
        |> check_for_loser()
        |> start_round(game.current_player_id)
        |> instructions_and_state()

      {:error, game} ->
        game
        |> notify_player(game.current_player_id, :illegal_move)
        |> take_instructions()
    end
  end

  defp dudo(%Game{current_bid: {0, 0}} = game), do: {:error, game}

  defp dudo(
         %Game{
           players_hands: players_hands,
           current_bid: {current_count, current_die},
           current_player_id: current_player
         } = game
       ) do
    current_count_frequency = get_current_die_frequency(players_hands, current_die)
    previous_player = find_previous_player(game)

    case current_count_frequency < current_count do
      true ->
        {:ok,
         %Game{
           game
           | current_player_id: previous_player,
             players_hands:
               Enum.map(players_hands, fn hand ->
                 if hand.player_id == previous_player,
                   do: %{hand | hand: Hand.take(hand.hand)},
                   else: hand
               end)
         }, current_count_frequency < current_count}

      _ ->
        {:ok,
         %Game{
           game
           | players_hands:
               Enum.map(players_hands, fn hand ->
                 if hand.player_id == current_player,
                   do: %{hand | hand: Hand.take(hand.hand)},
                   else: hand
               end)
         }, current_count_frequency < current_count}
    end
  end

  defp calza(%Game{current_bid: {0, 0}} = game), do: {:error, game}

  defp calza(
         %Game{
           players_hands: players_hands,
           current_bid: {current_count, current_die},
           current_player_id: current_player
         } = game
       ) do
    current_count_frequency = get_current_die_frequency(players_hands, current_die)

    case current_count_frequency == current_count do
      true ->
        {:ok,
         %Game{
           game
           | players_hands:
               Enum.map(players_hands, fn player_hand ->
                 if player_hand.player_id == current_player,
                   do: %{player_hand | hand: Hand.add(player_hand.hand)},
                   else: player_hand
               end)
         }, current_count_frequency == current_count}

      _ ->
        {:ok,
         %Game{
           game
           | players_hands:
               Enum.map(players_hands, fn player_hand ->
                 if player_hand.player_id == current_player,
                   do: %{player_hand | hand: Hand.take(player_hand.hand)},
                   else: player_hand
               end)
         }, current_count_frequency == current_count}
    end
  end

  defp outbid(%Game{current_bid: {0, 0}} = game, {_new_count, 1}), do: {:error, game}
  defp outbid(%Game{current_bid: {count, dice}} = game, {count, dice}), do: {:error, game}
  defp outbid(game, {_, dice}) when dice > 6, do: {:error, game}
  defp outbid(game, {count, dice}) when dice < 1 or count < 1, do: {:error, game}

  defp outbid(%Game{current_bid: {current_count, 1}} = game, {new_count, 1}) do
    case new_count > current_count do
      true ->
        {:ok, %Game{game | instructions: [], current_bid: {new_count, 1}}}

      _ ->
        {:error, game}
    end
  end

  defp outbid(%Game{current_bid: {current_count, _current_die}} = game, {new_count, 1}) do
    case new_count >= ceil(current_count / 2) do
      true ->
        {:ok, %Game{game | instructions: [], current_bid: {new_count, 1}}}

      _ ->
        {:error, game}
    end
  end

  defp outbid(%Game{current_bid: {current_count, 1}} = game, {new_count, new_die}) do
    case new_count >= current_count * 2 + 1 do
      true ->
        {:ok, %Game{game | instructions: [], current_bid: {new_count, new_die}}}

      _ ->
        {:error, game}
    end
  end

  defp outbid(%Game{current_bid: {current_count, current_die}} = game, {new_count, new_die}) do
    case (new_count >= current_count && new_die > current_die) ||
           (new_count > current_count && new_die >= current_die) do
      true ->
        {:ok, %Game{game | instructions: [], current_bid: {new_count, new_die}}}

      _ ->
        {:error, game}
    end
  end

  defp reveal_players_hands(game),
    do: notify_players(game, {:reveal_players_hands, game.players_hands})

  defp find_next_player(%Game{remaining_players: [winner]} = game),
    do: %Game{game | current_player_id: winner}

  defp find_next_player(game) do
    current_player_index =
      Enum.find_index(game.remaining_players, fn id -> id == game.current_player_id end)

    next_player =
      Enum.at(game.remaining_players, current_player_index + 1, hd(game.remaining_players))

    %Game{game | current_player_id: next_player}
  end

  defp find_previous_player(game) do
    current_player_index =
      Enum.find_index(game.remaining_players, fn id -> id == game.current_player_id end)

    Enum.at(game.remaining_players, current_player_index - 1, hd(game.remaining_players))
  end

  defp check_for_loser(%Game{} = game) do
    loser = Enum.find(game.players_hands, fn hand -> hand.hand.remaining_dice == 0 end)

    case loser != nil do
      true ->
        game = notify_players(game, {:loser, loser.player_id})

        %Game{
          game
          | remaining_players:
              Enum.filter(game.remaining_players, fn player -> player != loser.player_id end)
        }
        |> find_next_player()

      false ->
        game
    end
  end

  defp get_current_die_frequency(players_hands, current_die) do
    dice_frequencies = get_dice_frequencies(players_hands)
    if dice_frequencies[current_die] == nil, do: 0, else: dice_frequencies[current_die]
  end

  defp get_dice_frequencies(players_hands) do
    players_hands
    |> Enum.flat_map(fn %{hand: hand} -> hand.dice end)
    |> Enum.frequencies()
  end

  defp notify_player(game, player_id, data) do
    %Game{
      game
      | instructions: [{:notify_player, player_id, data} | game.instructions]
    }
  end

  defp notify_players(game, data) do
    Enum.reduce(
      game.all_players,
      game,
      &notify_player(
        &2,
        &1,
        data
      )
    )
  end

  defp instructions_and_state(game) do
    game
    |> tell_current_player_to_move()
    |> take_instructions()
  end

  defp tell_current_player_to_move(%Game{current_player_id: nil} = game), do: game

  defp tell_current_player_to_move(game),
    do: notify_player(game, game.current_player_id, :move)

  defp initialize_players_hands(%Game{max_dice: max_dice, remaining_players: players} = game) do
    %Game{
      game
      | players_hands:
          Enum.map(players, fn p ->
            %{player_id: p, hand: Hand.new(%Hand{remaining_dice: max_dice})}
          end)
    }
  end

  defp start_round(%Game{remaining_players: [winner]} = game, _) do
    game = %Game{game | current_player_id: nil, players_hands: [], current_bid: nil}
    notify_players(game, {:winner, winner})
  end

  defp start_round(game, next_player) do
    game = %Game{
      game
      | current_player_id: next_player,
        players_hands:
          Enum.map(game.remaining_players, fn p ->
            %{
              player_id: p,
              hand: Hand.new(Enum.find(game.players_hands, fn x -> x.player_id == p end).hand)
            }
          end),
        current_bid: {0, 0}
    }

    Enum.reduce(
      game.remaining_players,
      game,
      &notify_player(
        &2,
        &1,
        {:new_hand, Enum.find(game.players_hands, fn x -> x.player_id == &1 end).hand}
      )
    )
  end

  defp warn_game_start(game), do: notify_players(game, {:game_started, game.remaining_players})

  defp take_instructions(game),
    do: {Enum.reverse(game.instructions), %Game{game | instructions: []}}
end
