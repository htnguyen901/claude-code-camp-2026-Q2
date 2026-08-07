#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 18 — Boukensha::Session, the Planner -> Player -> Judge driver
# (docs/plans/agent_loop/orchestrator.md §4). Unlike examples/example.rb
# (Boukensha.run — one Agent#run call, no plan), this seeds a plan via
# Tasks::Planner *before* the Player's first turn, then keeps calling
# Agent#run turn after turn — feeding the literal "continue" once the goal
# itself has been given — checking in with Tasks::Judge at every checkpoint
# (an iteration/token-limit wrap-up) to decide continue/replan/flag, until
# the Player naturally completes or the Judge flags a risk.
#
# Watch stderr: Session.play prints the Planner's plan as soon as it's
# produced, and the Judge's verdict (plus a fresh plan, on a replan) at
# every checkpoint reached. max_turns: is still an outer safety valve in
# case the Judge keeps saying "continue".
#
#   ruby examples/session_demo.rb --goal "explore the temple square" --player noir
#   ruby examples/session_demo.rb --goal "find and defeat the newbie zone rat" --player noir --max-turns 5
#
# Needs a real ANTHROPIC_API_KEY/OPENAI_API_KEY/etc. (whatever tasks.player/
# tasks.planner/tasks.judge in settings.yaml point at) and a reachable MUD — same
# prerequisites as example.rb, see this step's README. Like example.rb, this
# does not read ~/.boukensharc's boukensha_dir (that's bin/boukensha's own
# loader) — point BOUKENSHA_DIR at your config explicitly if it isn't
# ~/.boukensha, e.g.:
#   BOUKENSHA_DIR=/path/to/.boukensha ruby examples/session_demo.rb --goal "..." --player noir

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "boukensha"
require "boukensha/player_profile"
require "optparse"

goal      = "explore your surroundings and report back what you find"
player_name = nil
max_turns = Boukensha::Session::DEFAULT_MAX_TURNS

OptionParser.new do |o|
  o.banner = "usage: session_demo.rb --goal \"<goal text>\" [--player NAME] [--max-turns N]"
  o.on("--goal GOAL", "the goal the Planner seeds a plan for") { |v| goal = v }
  o.on("--player NAME", "log in as .boukensha/players/NAME.yaml") { |v| player_name = v }
  o.on("--max-turns N", Integer, "safety cap on Player turns before Judge exists (default #{max_turns})") { |v| max_turns = v }
end.parse!(ARGV)

cfg = Boukensha.config
puts "Config:  #{cfg}"
puts "Servers: #{cfg.mcp_servers.keys.join(', ')}"
puts "Goal:    #{goal}"
puts "Player:  #{player_name || '(none — will fail to log in unless mcp_servers.mud.env already has credentials)'}"
puts "Max turns (no Judge yet): #{max_turns}"
puts

player = nil
if player_name
  players_dir = File.join(cfg.dir, "players")
  player = Boukensha::PlayerProfile.load(player_name, players_dir: players_dir)
end

# world__room_knowledge/world__route_to arrive for free via settings.yaml's
# mcp_servers.log-viz entry (docs/plans/world_knowledge/world_knowledge.md)
# — no local tool registration needed here any more.
result = Boukensha::Session.play(goal: goal, player: player, max_turns: max_turns)

puts
puts "[session_demo] final Player output:"
puts result
