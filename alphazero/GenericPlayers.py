from alphazero.MCTS import MCTS
from alphazero.Game import GameState
from alphazero.NNetWrapper import NNetWrapper
from alphazero.utils import dotdict

from abc import ABC, abstractmethod

import numpy as np
import torch


class BasePlayer(ABC):
    def __init__(self, game_cls: GameState = None):
        self.game_cls = game_cls

    def __call__(self, *args, **kwargs):
        return self.play(*args, **kwargs)

    @property
    def supports_process(self) -> bool:
        return False

    def update(self, state: GameState, action: int) -> None:
        pass

    def reset(self):
        pass

    @abstractmethod
    def play(self, state: GameState) -> int:
        pass

    def process(self, batch):
        raise NotImplementedError


class RandomPlayer(BasePlayer):
    def play(self, state):
        valids = state.valid_moves()
        valids = valids / np.sum(valids)
        a = np.random.choice(state.action_size(), p=valids)
        return a


class NNPlayer(BasePlayer):
    def __init__(self, game_cls: GameState, nn: NNetWrapper, args: dotdict):
        super().__init__(game_cls)
        self.nn = nn
        self.args = args
        self.temp = args.startTemp

    def play(self, state) -> int:
        policy, _ = self.nn.predict(state.observation())
        valids = state.valid_moves()
        options = policy * valids
        self.temp = self.args.temp_scaling_fn(self.temp, state.turns, self.args.max_moves)
        if self.temp == 0:
            bestA = np.argmax(options)
            probs = [0] * len(options)
            probs[bestA] = 1
        else:
            probs = [x ** (1. / self.temp) for x in options]
            probs /= np.sum(probs)

        choice = np.random.choice(
            np.arange(state.action_size()), p=probs
        )

        if valids[choice] == 0:
            print()
            print(self.temp)
            print(valids)
            print(policy)
            print(probs)
            assert valids[choice] > 0

        return choice


class MCTSPlayer(BasePlayer):
    def __init__(self, game_cls: GameState, nn: NNetWrapper, args: dotdict, print_policy=False, verbose=False):
        super().__init__(game_cls)
        self.nn = nn
        self.args = args
        self.temp = args.startTemp
        self.print_policy = print_policy
        self.verbose = verbose
        self.reset()
        if self.verbose:
            self.mcts.search(game_cls(), self.nn, self.args.numMCTSSims, args.add_root_noise, args.add_root_temp)
            value = self.mcts.value()
            self.__rel_val_split = value if value > 0.5 else 1 - value
            print('initial value:', self.__rel_val_split)

    def update(self, state: GameState, action: int) -> None:
        self.mcts.update_root(state, action)

    def reset(self):
        self.mcts = MCTS(self.args)

    def play(self, state) -> int:
        self.mcts.search(state, self.nn, self.args.numMCTSSims, self.args.add_root_noise, self.args.add_root_temp)
        self.temp = self.args.temp_scaling_fn(self.temp, state.turns, self.args.max_moves)
        policy = self.mcts.probs(state, self.temp)

        if self.print_policy:
            print(f'policy: {policy}')
        if self.verbose:
            _, value = self.nn.predict(state.observation())
            print('max tree depth:', self.mcts.max_depth)
            print(f'raw network value: {value}')
            value = self.mcts.value()
            rel_val = 0.5 * (value - self.__rel_val_split) / (1 - self.__rel_val_split) + 0.5 \
                if value >= self.__rel_val_split else (value / self.__rel_val_split) * 0.5
            print(f'value for player {state.player}: {value}')
            print('relative value:', rel_val)

        action = np.random.choice(len(policy), p=policy)
        if self.verbose:
            print('confidence of action:', policy[action])

        return action


class RawMCTSPlayer(MCTSPlayer):
    def __init__(self, game_cls: GameState, args: dotdict, verbose=False):
        super().__init__(game_cls, None, args, verbose)
        self._POLICY_SIZE = self.game_cls.action_size()
        self._POLICY_FILL_VALUE = 1 / self._POLICY_SIZE
        self._VALUE_SIZE = self.game_cls.num_players() + 1

    @property
    def supports_process(self) -> bool:
        return True

    def play(self, state) -> int:
        self.mcts.raw_search(state, self.args.numMCTSSims, self.args.add_root_noise, self.args.add_root_temp)
        self.temp = self.args.temp_scaling_fn(self.temp, state.turns, self.args.max_moves)
        policy = self.mcts.probs(state, self.temp)

        if self.verbose:
            print('max tree depth:', self.mcts.max_depth)
            # print(f'value for player {state.player}: {value}')
            print(f'policy: {policy}')

        return np.random.choice(len(policy), p=policy)

    def process(self, batch: torch.Tensor):
        return torch.full((batch.shape[0], self._POLICY_SIZE), self._POLICY_FILL_VALUE).to(batch.device), \
               torch.zeros(batch.shape[0], self._VALUE_SIZE).to(batch.device)
