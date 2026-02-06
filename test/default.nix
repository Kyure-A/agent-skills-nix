# Test runner for agent-skills
{ pkgs ? import <nixpkgs> {} }:

let
  agentLib = import ../lib { inherit (pkgs) lib; inputs = {}; };
in
import ./transform-packages.nix { inherit pkgs agentLib; }
