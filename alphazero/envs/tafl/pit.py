import pyximport
pyximport.install()

from alphazero.Arena import Arena
from alphazero.GenericPlayers import *
from alphazero.NNetWrapper import NNetWrapper as NNet


"""
use this script to play any two agents against each other, or play manually with
any agent.
"""
if __name__ == '__main__':
    from alphazero.envs.tafl.brandubh import TaflGame as Game
    from alphazero.envs.tafl.train import args
    #from alphazero.envs.tafl.train_brandubh import args as args2
    from alphazero.envs.tafl.players import HumanTaflPlayer
    import random

    args.numMCTSSims = 2000
    #args.arena_batch_size = 64
    args.temp_scaling_fn = lambda x,y,z:0.25
    #args2.temp_scaling_fn = args.temp_scaling_fn
    
    batched_arena = False

    # nnet players
    nn1 = NNet(Game, args)
    nn1.load_checkpoint('./checkpoint/' + args.run_name, 'iteration-0112.pkl')
    nn2 = NNet(Game, args)
    nn2.load_checkpoint('./checkpoint/brandubh2', 'iteration-0112.pkl')
    #player1 = nn1.process
    #player2 = nn2.process

    player1 = MCTSPlayer(Game, nn1, args=args, verbose=True)
    #player2 = MCTSPlayer(Game, nn1, args=args, verbose=True)
    #player2 = RandomPlayer()
    #player2 = GreedyTaflPlayer()
    #player2 = RandomPlayer()
    #player2 = OneStepLookaheadConnect4Player()
    #player2 = RawMCTSPlayer(Game, args)
    player2 = HumanTaflPlayer()

    players = [player1, player2]
    #random.shuffle(players)

    arena = Arena(players, Game, use_batched_mcts=batched_arena, args=args, display=print)
    if batched_arena:
        wins, draws, winrates = arena.play_games(args.arenaCompare)
        for i in range(len(wins)):
            print(f'player{i+1}:\n\twins: {wins[i]}\n\twin rate: {winrates[i]}')
        print('draws: ', draws)
    else:
        arena.play_game(verbose=True)
