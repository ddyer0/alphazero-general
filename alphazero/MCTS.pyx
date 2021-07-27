# cython: language_level=3
# cython: boundscheck=False
# cython: wraparound=False
# cython: nonecheck=False
# cython: overflowcheck=False
# cython: initializedcheck=False
# cython: cdivision=True
# cython: auto_pickle=True

from libc.math cimport sqrt

import numpy as np
from alphazero.utils import dotdict
# import cython

NOISE_ALPHA_RATIO = 10.83
_DRAW_VALUE = 0.5

np.seterr(all='raise')


"""
def rebuild_node(children, a, cpuct, num_players, e, q, n, p, player):
    childs = []
    for child_state in children:
        rebuild, args = child_state[0], child_state[1:]
        child = rebuild(*args)
        childs.append(child)

    node = Node(a, cpuct, num_players)
    node._children = childs
    node.a = a
    node.cpuct = cpuct
    node.e = e
    node.q = q
    node.n = n
    node.p = p
    node.player = player

    return node
"""


# @cython.auto_pickle(True)
cdef class Node:
    cdef public list _children
    cdef public int a
    cdef public float cpuct
    cdef public int _players
    cdef public tuple e
    cdef public float q
    cdef public float v
    cdef public int n
    cdef public float p
    cdef public int player

    def __init__(self, int action, float cpuct, int num_players):
        self._children = []
        self.a = action
        self.cpuct = cpuct
        self._players = num_players
        self.e = tuple([False]*(num_players + 1))
        self.q = 0
        self.v = 0
        self.n = 0
        self.p = 0
        self.player = 0

    # def __reduce__(self):
    #    return rebuild_node, ([n.__reduce__() for n in self._children], self.a, self.cpuct, self._players, self.e, self.q, self.n, self.p, self.player)

    cdef add_children(self, int[:] v):
        cdef Py_ssize_t a
        for a in range(len(v)):
            if v[a] == 1:
                self._children.append(Node(a, self.cpuct, self._players))
        # shuffle children
        np.random.shuffle(self._children)

    cdef update_policy(self, float[:] pi):
        cdef Node c
        for c in self._children:
            c.p = pi[c.a]

    cdef float uct(self, float sqrtParentN, float fpu_value):
        return (fpu_value if self.n == 0 else self.q) + self.cpuct * self.p * sqrtParentN / (1 + self.n)

    cdef Node best_child(self, float fpu_reduction):
        cdef float seen_policy = sum([c.p for c in self._children if c.n > 0])
        cdef float fpu_value = self.v - fpu_reduction * sqrt(seen_policy)
        child = None
        cdef float curBest = -float('inf')
        cdef float sqrtN = sqrt(self.n)
        cdef Node c
        for c in self._children:
            uct = c.uct(sqrtN, fpu_value)
            if uct > curBest:
                curBest = uct
                child = c
        return child


"""
def rebuild_mcts(num_players, cpuct, root, curnode, path):
    mcts = MCTS(num_players, cpuct)
    mcts.cpuct = cpuct
    mcts._root = root
    mcts._curnode = curnode
    mcts.path = path
    return mcts
"""


# @cython.auto_pickle(True)
cdef class MCTS:
    cdef public float root_noise_frac
    cdef public float root_temp
    cdef public float min_discount
    cdef public float fpu_reduction
    cdef public float _cpuct
    cdef public int _num_players
    cdef public Node _root
    cdef public Node _curnode
    cdef public list _path
    cdef public int depth
    cdef public int max_depth
    cdef public int _discount_max_depth
    def __init__(self, args: dotdict):
        self.root_noise_frac = args.root_noise_frac
        self.root_temp = args.root_policy_temp
        self.min_discount = args.min_discount
        self.fpu_reduction = args.fpu_reduction
        self._cpuct = args.cpuct
        self._num_players = args.num_players
        self._root = Node(-1, self._cpuct, self._num_players)
        self._curnode = self._root
        self._path = []
        self.depth = 0
        self.max_depth = 0
        self._discount_max_depth = 0

    cpdef reset(self):
        self._root = Node(-1, self._cpuct, self._num_players)
        self._curnode = self._root
        self._path = []
        self.depth = 0
        self.max_depth = 0
        self._discount_max_depth = 0

    # def __reduce__(self):
    #   return rebuild_mcts, (self._root._players, self.cpuct, self._root, self._curnode, self._path)

    cpdef search(self, gs, nn, int sims, bint add_root_noise, bint add_root_temp):
        cdef float[:] v
        cdef float[:] p
        self.max_depth = 0

        for _ in range(sims):
            leaf = self.find_leaf(gs)
            p, v = nn(leaf.observation())
            self.process_results(leaf, v, p, add_root_noise, add_root_temp)

    cpdef raw_search(self, gs, int sims, bint add_root_noise, bint add_root_temp):
        cdef Py_ssize_t value_size = gs.num_players() + 1
        cdef Py_ssize_t policy_size = gs.action_size()
        cdef float[:] v = np.full((value_size,), 1 / value_size, dtype=np.float32)
        cdef float[:] p = np.full((policy_size,), 1 / policy_size, dtype=np.float32)
        self.max_depth = 0

        for _ in range(sims):
            leaf = self.find_leaf(gs)
            self.process_results(leaf, v, p, add_root_noise, add_root_temp)

    cpdef update_root(self, gs, int a):
        if not self._root._children:
            self._root.add_children(gs.valid_moves())

        cdef Node c
        for c in self._root._children:
            if c.a == a:
                self._root = c
                return

        raise ValueError(f'Invalid action encountered while updating root: {c.a}')

    cpdef add_root_noise(self):
        cdef int num_valid_moves = len(self._root._children)
        cdef float[:] noise = np.array(np.random.dirichlet(
            [NOISE_ALPHA_RATIO / num_valid_moves] * num_valid_moves
        ), dtype=np.float32)
        cdef Node c
        cdef float n

        for n, c in zip(noise, self._root._children):
            c.p = c.p * (1 - self.root_noise_frac) + self.root_noise_frac * n

    cpdef find_leaf(self, game_state):
        self.depth = 0
        self._curnode = self._root
        gs = game_state.clone()

        while self._curnode.n > 0 and not any(self._curnode.e):
            self._path.append(self._curnode)
            self._curnode = self._curnode.best_child(self.fpu_reduction)
            gs.play_action(self._curnode.a)
            self.depth += 1

        if self.depth > self.max_depth:
            self.max_depth = self.depth
            self._discount_max_depth = self.depth

        if self._curnode.n == 0:
            self._curnode.player = gs.player
            self._curnode.e = gs.win_state()
            self._curnode.add_children(gs.valid_moves())

        return gs

    cpdef process_results(self, gs, float[:] value, float[:] pi, bint add_root_noise, bint add_root_temp):
        cdef float[:] valids
        cdef Node c
        
        if any(self._curnode.e):
            value = np.array(self._curnode.e, dtype=np.float32)
        else:
            # reconstruct valid moves based on children of current node
            valids = np.zeros((gs.action_size(),), dtype=np.float32)
            for c in self._curnode._children:
                valids[c.a] = 1

            # mask invalid moves and rescale
            pi *= np.array(valids, dtype=np.float32)
            pi /= np.sum(pi)

            if self._curnode == self._root:
                # add root temperature
                if add_root_temp:
                    pi = (pi / np.sum(pi)) ** (1.0 / self.root_temp)
                    # renormalize
                    pi /= np.sum(pi)

                self._curnode.update_policy(pi)
                if add_root_noise:
                    self.add_root_noise()
            else:
                self._curnode.update_policy(pi)

        cdef Py_ssize_t num_players = gs.num_players()
        cdef Node parent
        cdef float v
        cdef float discount
        cdef int i = 0
        while self._path:
            parent = self._path.pop()
            v = self._get_value(value, parent.player, num_players)

            # apply discount only to current node's Q value
            discount = (self.min_discount ** (i / self._discount_max_depth))
            if v < _DRAW_VALUE:
                # (1 - discount) + 1 to invert it because bad values far away
                # are better than bad values close to root
                discount = 2 - discount
            elif v == _DRAW_VALUE:
                # don't discount value in the rare case that it is a draw (0.5)
                discount = 1
            # scale value to the range [-1, 1]
            v = 2 * v * discount - 1

            self._curnode.q = (self._curnode.q * self._curnode.n + v) / (self._curnode.n + 1)
            if self._curnode.n == 0:
                self._curnode.v = self._get_value(value, self._curnode.player, num_players) * 2 - 1
            self._curnode.n += 1
            self._curnode = parent
            i += 1

        self._root.n += 1

    cpdef float _get_value(self, float[:] value, Py_ssize_t player, Py_ssize_t num_players):
        return value[player] + value[num_players] / num_players

    cpdef int[:] counts(self, gs):
        cdef int[:] counts = np.zeros(gs.action_size(), dtype=np.intc)
        cdef Node c

        for c in self._root._children:
            counts[c.a] = c.n
        return np.asarray(counts)

    cpdef probs(self, gs, temp=1):
        counts = self.counts(gs)

        if temp == 0:
            bestA = np.argmax(counts)
            probs = np.zeros_like(counts)
            probs[bestA] = 1
            return probs

        try:
            probs = (counts / np.sum(counts)) ** (1.0/temp)
            probs /= np.sum(probs)
            return probs
        except OverflowError:
            bestA = np.argmax(counts)
            probs = np.zeros_like(counts)
            probs[bestA] = 1
            return probs

    cpdef float value(self, bint average=False):
        """Get the Q value of the current root node in the range [0, 1] by looking at the max value of child nodes (or averaging them)."""
        cdef float value = -1
        cdef Node c
        
        if average:
            value = sum([c.q for c in self._root._children]) / len(self._root._children)
        
        else:
            for c in self._root._children:
                if c.q > value:
                    value = c.q
            
        return (value + 1) / 2
