"""Minimal pyfsda example — FSDA's Score (Box-Cox test) on the wool data."""
import numpy as np
import pyfsda

# wool data (Box & Cox, 1964): columns x1 x2 x3, and y = cycles to failure
WOOL = np.array([
    [-1, -1, -1,  674], [-1, -1, 0,  370], [-1, -1, 1,  292],
    [-1,  0, -1,  338], [-1,  0, 0,  266], [-1,  0, 1,  210],
    [-1,  1, -1,  170], [-1,  1, 0,  118], [-1,  1, 1,   90],
    [ 0, -1, -1, 1414], [ 0, -1, 0, 1198], [ 0, -1, 1,  634],
    [ 0,  0, -1, 1022], [ 0,  0, 0,  620], [ 0,  0, 1,  438],
    [ 0,  1, -1,  442], [ 0,  1, 0,  332], [ 0,  1, 1,  220],
    [ 1, -1, -1, 3636], [ 1, -1, 0, 3184], [ 1, -1, 1, 2000],
    [ 1,  0, -1, 1568], [ 1,  0, 0, 1070], [ 1,  0, 1,  566],
    [ 1,  1, -1, 1140], [ 1,  1, 0,  884], [ 1,  1, 1,  360],
], dtype=float)

y = WOOL[:, -1].reshape(-1, 1)          # response, as an (n, 1) column
X = WOOL[:, :3]                         # the three factors
la = [-1.0, -0.5, 0.0, 0.5, 1.0]        # Box-Cox lambdas to test

# One call to FSDA's Score -- the MATLAB engine starts on first use.
out = pyfsda.Score(y, X, la=la, intercept=True)

# `out` is a dict (MATLAB struct -> Python dict); work with it like any dict + numpy array.
print("out is a", type(out).__name__, "with keys", list(out.keys()))

score = np.asarray(out["Score"]).reshape(-1)     # the score-test statistic per lambda
for lam, s in zip(la, score):
    print(f"  lambda = {lam:+.1f}   score = {s:8.4f}")

best = la[int(np.argmin(np.abs(score)))]         # lambda whose |score| is smallest
print("best-supported transformation: lambda =", best)
