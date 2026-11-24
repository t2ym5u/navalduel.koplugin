# Changelog

All notable changes to this project will be documented in this file.

## [1.0.2] - 2026-11-24

### Changed
- Picks up game-common 1.18.0: a status line cut off with "…" opens in full
  when tapped, so a long hint can be read.

## [1.0.1] - 2026-11-18

### Changed
- Picks up game-common 1.17.0 (a board redraw fix used by chess, binairo and
  tatami; no change in this game).

## [1.0.0] - 2026-11-10

### Added
- First release: a battleship game for two players with a reader each.
  Each reader hides its player's fleet and answers the shots called aloud
  (miss, hit, hit and sunk), so nobody can get the answer wrong; the second
  grid tracks your own shots and greys out the water around a sunk ship.
- 8×8 (5 ships) and 10×10 (5 ships) grids, ships touching or not, random
  fleet with Shuffle, ships moved and turned by tapping, Undo, auto-save.
