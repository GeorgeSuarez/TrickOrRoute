# TrickOrRoute

A World of Warcraft (retail) addon that walks you through an **efficient guided
tour of every Hallow's End candy bucket** — roughly **281 stops** across 11
travel phases, ordered to minimize backtracking, with automatic map waypoints.
Inside each zone the stops are re-ordered by their shortest path, so the tour
doesn't zig-zag between inns.

![icon](https://wow.zamimg.com/images/wow/icons/large/achievement_halloween_candy_01.jpg)

## What it does

- **Ordered route** — stops are grouped into phases that follow the portal
  network (Eastern Kingdoms → Outland through the Dark Portal, Kalimdor via
  Exodar/Caverns of Time portals, then Dalaran → Pandaria → Draenor → Broken
  Isles → Dragon Isles → Khaz Algar → Midnight/Quel'Thalas).
- **Shortest-path zone ordering** — within each zone's stretch of the route the
  buckets are re-ordered by the shortest path between them (exact up to 12
  stops, nearest-first + 2-opt/or-opt beyond), keeping the zone's entry and
  exit stop so the portal-to-portal route still flows. Every bucket is priced
  from every other with Dijkstra, the same way Mapzeroth plans a tour.
  `/tor paths <zone>` shows the shortest order from **each** bucket;
  `/tor optimize` toggles it.
- **Server-truth completion tracking** — every candy bucket is a one-time
  quest, so the addon checks real quest flags (`C_QuestLog`). No guessing.
- **Auto-advance** — when you loot a `Handful of Treats`, turn in a bucket
  quest, or simply fly within 40 yards of the current stop, the tour moves to
  the next incomplete bucket automatically (toggleable).
- **Waypoints** — one click sets the built-in map waypoint and supertracks it.
  If you run **TomTom**, tick "Use TomTom" to place TomTom arrows instead.
- **`/way` dump** — export every remaining stop as TomTom `/way #map x y`
  lines (use the *Paste* addon to import them in bulk).
- **Faction aware** — automatically shows only neutral + your faction's
  buckets (Alliance ~199, Horde ~196).
- **Handles the traps** — flags every **Zidormi-phased** bucket (Blasted
  Lands, Undercity/Brill, Theramore, Teldrassil/Darnassus), the Tier 3
  garrison requirement on Draenor, and the **Aldor/Scryer** inns in Outland.
- **Account-wide settings** — theme, UI scale, auto-advance radius, HUD
  position, saved routes and every toggle are shared by all characters. On the
  first login after updating, the current character's settings become the
  account-wide ones.
- **Per-character progress** — the current stop, manual skips and folded
  sections stay per character (`SavedVariablesPerCharacter`), since candy
  buckets are one-time quests and a character can be on either faction.
- **Polished single-window UI** — a progress bar that shades from ember to gold,
  live distance-to-stop readout (green when you're in auto-advance range), a
  region dropdown that names the current region and greens out finished ones,
  action tooltips, and a checklist view with per-region "N left" counts, foldable
  region sections, and a minimize button that collapses the window to a compact
  toolbar.
- **Mini tracker HUD** — a compact, draggable bar under the minimap always shows
  the next stop, a live direction arrow and distance (left-click sets the
  waypoint, right-click opens the window), so you don't have to keep the main
  window open while flying.
- **Direction arrow** — both the mini tracker and the stop card point at the
  next bucket relative to where your character is facing, and turn green when
  you're inside the auto-advance radius. (Same idea as Mapzeroth's navigator.)
- **Searchable checklist** — the full route list has a search box that matches
  stop names, zones and region hints (`zul aman`, `loch`, `inn`), auto-expands
  matching sections, and jumps to the first match on Enter.
- **Saved routes** — turn any search into a named route: `/tor save Khaz Algar`,
  then `/tor route Khaz Algar` any time to re-filter the checklist (Next/Skip
  stay inside the filter until `/tor unroute`).
- **Settings page** — `/tor settings` opens a page in the game's own Settings
  window (Game Menu → Options → AddOns → TrickOrRoute): auto-advance radius and
  UI-scale sliders, the shortest-path zone ordering toggle, every checkbox in
  one place, and the theme cycler. Options are account-wide.
- **Share a map pin** — shift-click any stop to drop a clickable
  `Name - Zone (x, y) [Map Pin Location]` link into chat; anyone who clicks it
  gets that spot as their map waypoint. Ctrl-click prints a `/way` line instead.

## Install

1. Copy the `TrickOrRoute` folder into your
   `World of Warcraft/_retail_/Interface/AddOns/` folder
   (or unzip `TrickOrRoute.zip` there).
2. Log in / `/reload`.
3. Type **`/tor`** or click the candy-bucket minimap button.

## Commands

| Command | Effect |
| --- | --- |
| `/tor` | toggle the route window |
| `/tor next` / `/tor prev` | browse stops |
| `/tor wp` | set a waypoint on the current stop |
| `/tor map` | open the world map at the current stop |
| `/tor skip` | manually skip the current stop (e.g. rep-gated inns) |
| `/tor list` | print remaining stops as TomTom `/way` lines |
| `/tor auto` | toggle auto-advance |
| `/tor optimize` | toggle shortest-path ordering inside each zone |
| `/tor paths [zone]` | list zones, or show the shortest path from every bucket in one |
| `/tor tomtom` | toggle TomTom integration |
| `/tor hud` | toggle the mini tracker HUD |
| `/tor minimap` | toggle the minimap button |
| `/tor theme` | cycle the window theme (Classic / Modern Dark / Steel) |
| `/tor scale 1.2` | resize the window and mini tracker (0.7 – 1.5) |
| `/tor settings` | open the settings page in the game's Settings window |
| `/tor save <name>` | save the current checklist search as a named route |
| `/tor route <name>` | apply a saved route's filter |
| `/tor routes` / `/tor unroute` | list saved routes / clear the filter |
| `/tor unskip` | clear manual skips |
| `/tor reset` | wipe account settings and per-character progress |

## The route at a glance

1. **Eastern Kingdoms** — start Stormwind (A) or Silvermoon (H), loop south,
   up the coast, and finish in Twilight Highlands
2. **Outland** — in through the Dark Portal, loop, back out
3. **Kalimdor** — Exodar islands (A) / Orgrimmar (H), then the big clockwise loop
4. **Deepholm & Vashj'ir** — Cataclysm portals (bring water breathing!)
5. **Northrend** — portal to Dalaran, clockwise loop
6. **Pandaria** — portal to the Jade Forest, clockwise loop
7. **Draenor** — Garrison Hearthstone (Tier 3 garrison)
8. **Broken Isles** — Dalaran Hearthstone
9. **Dragon Isles** — portal to Valdrakken
10. **Khaz Algar** — portal to Dornogal
11. **Midnight** — portal to Silvermoon; Eversong, Zul'Aman, Harandar, Voidstorm

## Data & credits

Bucket positions and quest IDs are sourced from the actively-maintained
[CandyBuckets](https://github.com/Vladinator/wow-addon-candybuckets) community
dataset (v12.1.0, Hallow's End 2026) and cross-checked against Wowhead's
Hallow's End guide and achievement-comment waypoints. `RouteData.lua` is
generated — don't edit it by hand.

UI ideas (themes, mini tracker, direction arrow, map docking, minimap
compartment, map-pin sharing, searchable picker) are inspired by
[Mapzeroth](https://www.curseforge.com/wow/addons/mapzeroth), a great
travel-routing addon. The zone ordering follows its two-step pathfinder: one
Dijkstra per stop for all-pairs costs (`Pathfinder.lua`), then exact or
nearest-first + 2-opt/or-opt ordering (`MultiRoute.lua`). If you want GPS-style
directions between stops, run Mapzeroth alongside this one. Its source is at
[github.com/tr0tsky0/Mapzeroth](https://github.com/tr0tsky0/Mapzeroth).

## Known caveats

- A handful of stops ship generic labels/positions because upstream data is
  ambiguous (`Candy Bucket (unverified position)` in Eastern Kingdoms, one
  Alliance inn in Krasarang, one inn on the Veiled Stair road). The in-game
  zone name always displays correctly.
- A few inns that existed in earlier years (Light's Hope Chapel, Stormfeather
  Outpost, Eastpoint Tower has moved, the Shrines of Seven Stars / Two Moons)
  are absent because they are no longer lootable in the current client.
- Built for retail (Interface 120100). Classic clients are not supported
  (different bucket quest IDs).
- The zone ordering measures straight-line world yards (what a flying mount
  covers), not roads or flight masters. It keeps each run's existing entry and
  exit stop, so a zone that spans several UI maps is ordered one map at a time.

Have a spooky, efficient Hallow's End! 🎃
